import Alaya

/-! `alaya` — the command line over a forest of logs. See `docs/cli.md` for the commands. -/

open Lean (Json)
open Alaya
open Alaya.Driver (Runtime Limits Stop)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM Cli.emit

/-- The data directory (`--data`, or `ALAYA_DATA`); its layout is in `docs/log-schema.md` §5. A
command opens it with `withData`, which gives the command a scratch directory of its own. -/
private structure DataDir where
  path : System.FilePath
  store : Store
  workspaces : Workspaces
  /-- This command's scratch, `tmp/<id>`: its work directory, a grader's checkout, restic's
  restores. Nothing in it lasts past the command, and no other command shares it. -/
  scratch : System.FilePath

private def DataDir.cache (data : DataDir) : System.FilePath := data.path / "cache"

/-- Opens the data directory at `path` for one command and runs `f` on it. Only `new` creates
one (`create`): any other command needs one that exists, so a wrong path is an error rather than
an empty forest. A command that writes (`write`) holds the directory's lock throughout, so it is
the only writer, and is refused at once when another has it; one that only reads takes no lock.
The command's scratch directory is removed when it ends, however it ends. -/
private def withData (path : System.FilePath) (f : DataDir → Result α) (write := false)
    (create := false) : Result α := do
  if !create && !(← Result.fromIO Error.storage (path / "entries").isDir) then
    throw <| .input s!"no data directory at {path}: `alaya new --data {path}` creates one"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  let lock? ← if write then some <$> Lock.acquire path else pure none
  try
    let store ← Store.create (path / "entries")
    let id := s!"{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}"
    let scratch := path / "tmp" / id
    Result.fromIO Error.storage (IO.FS.createDirAll scratch)
    try
      -- The entries and the model cache are as much the run as the repository is.
      let workspaces ← Workspaces.Restic.open (path / "restic") (scratch / "restic")
        (keep := #[store.dir, path / "cache"])
      f { path, store, workspaces, scratch }
    finally
      Workspaces.makeWritable scratch
      Result.fromIO Error.storage (IO.FS.removeDirAll scratch)
  finally
    if let some lock := lock? then lock.release

/-- `--data`, which every command but `config` takes, or `ALAYA_DATA`: there is no default, so a command run
from the wrong directory cannot quietly start a new data directory. -/
private def dataDir : Cli.Spec System.FilePath :=
  (Cli.flag? "data" (.path "DIR") "the data directory" (env? := some "ALAYA_DATA")).required
    "no data directory: give --data DIR, or set ALAYA_DATA"

private def entryArg (help : String := "an entry: its hash, any unambiguous prefix, or PREFIX:N for position N of its log") :
    Cli.Spec String :=
  Cli.arg "ENTRY" .string help

/-- The entry a reference names, and the forest. -/
private def resolve (data : DataDir) (reference : String) : Result (Forest × Hash) := do
  let forest ← data.store.forest
  let hash ← Result.fromExcept Error.input (forest.resolve reference)
  pure (forest, hash)

/-- The log at an entry, read whole. -/
private def entriesAt (data : DataDir) (reference : String) :
    Result (Forest × Hash × Array Entry) := do
  let (forest, hash) ← resolve data reference
  pure (forest, hash, ← data.store.entries forest hash)

/-- A new entry, as the commands that append print it: a line that begins with its full name,
or one JSON object. -/
private def entryRecord (out : Cli.Out) (hash : Hash) (position : Nat) (entry : Entry) : Result Unit :=
  out.record (.mkObj [("entry", hash.hex), ("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
      ("position", position), ("frame", (entry.event.frame?.map Frame.toJson).getD .null),
      ("summary", Render.eventSummary entry.event), ("event", eventToJson entry.event),
      ("elapsed_ms", entry.elapsedMs)])
    (Render.entryLine hash position entry.event)

/-- Exit status of `resume` when the last call failed, or was a grader whose verdict is a fail;
and when it was a grader whose verdict is an error. -/
private def exitFail : UInt32 := 1
private def exitError : UInt32 := 2

/-- Exit status when a call waits for a person: a reply, or a notice. -/
private def exitWaiting : UInt32 := 3

/-- Exit status when a run paused at a limit of this invocation: `resume` goes on from there. -/
private def exitPaused : UInt32 := 4

/-! ## Creating a run -/

/-- `PROGRAM`: a program the catalog has. -/
private def programName : Cli.Value String :=
  .enum "PROGRAM" (Agents.Catalog.all.map fun d => (d.name, d.name)).toList

/-- `--set PATH=VALUE` and `--set-file PATH=FILE`: the fields of a program's configuration over
its defaults, in the order given. -/
private def overrides : Cli.Spec (Array Settings.Given) :=
  Cli.interleaved #[
    ("set", ⟨"PATH=VALUE", fun text => Settings.Given.value <$> Settings.parse text⟩,
      "a field over the program's defaults, in order, e.g. model=gpt-6-luna, model.params.reasoning_effort=high, task='Fix the bug'"),
    ("set-file", ⟨"PATH=FILE", Settings.parseFile⟩,
      "a field set to a file's text, as it is, in order with --set, e.g. task=TASK.md; stdin is /dev/stdin")]

/-- What `new` takes: a project, or an image whose workdir the workspace is copied from. -/
private structure NewArgs where
  data : System.FilePath
  source : Sum System.FilePath (String × String)

private def NewArgs.cli : Cli.Spec NewArgs :=
  NewArgs.mk
    <$> dataDir
    <*> (Prod.mk <$> (Prod.mk
      <$> Cli.arg? "PROJECT" .path "the directory the workspace starts as"
      <*> Cli.flag? "image" (.string "IMAGE") "without PROJECT: an image whose workdir the workspace is copied from")
      <*> Cli.flag? "workdir" (.string "PATH") "with --image: the directory of the image to copy; by default its own workdir").refine
      fun
      | ((some project, none), none) => .ok (.inl project)
      | ((none, some image), workdir?) => .ok (.inr (image, workdir?.getD ""))
      | ((some _, some _), _) => .error "give PROJECT or --image IMAGE, not both"
      | ((none, none), _) => .error "the workspace is PROJECT, or the workdir of --image IMAGE"
      | ((some _, none), some _) => .error "--workdir is the directory of --image to copy"

/-- Creates a run: its root, the workspace, where the run waits for a program to be called. -/
private def newRun (a : NewArgs) (out : Cli.Out) : Result UInt32 := do
  -- Before the data directory is created: inside the project it would become part of it.
  if let .inl project := a.source then
    Workspaces.refuseOverlap "snapshot" project #[a.data]
  withData a.data (write := true) (create := true) fun data => do
    let project ← match a.source with
      | .inl project => pure project
      | .inr (image, workdir) =>
        let settings ← (← Executor.Docker.settingsOf {} image).pin
        let workdir ← if workdir.isEmpty then Executor.Docker.imageWorkdir settings else pure workdir
        let work := data.scratch / "project"
        Result.fromIO Error.storage (IO.FS.createDirAll work)
        Executor.Docker.copyOut settings workdir work
        pure work
    let (hash, entry) ← Notices.create data.store data.workspaces project
    entryRecord out hash 0 entry
    pure 0

/-! ## What a person appends -/

/-- Appends `event` after the entry a reference names, and prints the new entry. -/
private def appendTo (data : DataDir) (reference : String) (out : Cli.Out)
    (event : Log Agent → Next Agent → Result (Event Agent)) : Result UInt32 := do
  let (_, tip, entries) ← entriesAt data reference
  let log := entries.map (·.event)
  let event ← event log (next session log)
  let (hash, entry) ← Driver.append data.store session tip event
  entryRecord out hash entries.size entry
  pure 0

/-! ## Calling a program -/

private structure CallArgs where
  data : System.FilePath
  entry : String
  program : String
  image : String
  workdir : String
  settings : Array Settings.Given

private def CallArgs.cli : Cli.Spec CallArgs :=
  CallArgs.mk
    <$> dataDir
    <*> entryArg "the entry to call the program after; any unambiguous prefix, or PREFIX:N"
    <*> Cli.arg "PROGRAM" programName s!"the program: {Agents.Catalog.names}"
    <*> Cli.flag "image" (.string "IMAGE") "the container image the call's commands run in, pinned by digest"
    <*> Cli.flagD "workdir" (.string "PATH") Executor.Docker.defaultWorkdir
      "where the workspace is mounted in the image"
    <*> overrides

/-- Appends a call of a program after an entry, where no call is running: its configuration,
complete, with its image pinned. `resume` then drives it. -/
private def callRun (a : CallArgs) (out : Cli.Out) : Result UInt32 := do
  -- A configuration that is wrong is said so before anything is appended.
  let config ← Agents.Catalog.resolve a.program (← a.settings.mapM (·.read))
  if let .error problem := Agents.Catalog.check ⟨a.program, config⟩ then
    throw <| .input problem
  withData a.data (write := true) fun data => do
    Executor.Docker.checkWorkdir a.workdir #[Driver.outputsDir]
    let settings ← (← Executor.Docker.settingsOf {} a.image a.workdir).pin
    let environment : Environment := { image := settings.image, workdir := a.workdir }
    appendTo data a.entry out fun _ _ => pure (calling a.program config environment)

/-! ## Driving a run -/

/-- `--provider NAME`: who serves the models of the run's calls, for this invocation. -/
private def providerName : Cli.Value Provider.Provider :=
  .enum "NAME" (Provider.all.map fun p => (p.name, p)).toList

private structure ResumeArgs where
  data : System.FilePath
  entry : String
  provider? : Option Provider.Provider
  endpoint? : Option Provider.Dgx.Endpoint
  options : Executor.Docker.RunOptions
  samples : Nat
  budget : Nat

private def ResumeArgs.cli : Cli.Spec ResumeArgs :=
  ResumeArgs.mk
    <$> dataDir
    <*> entryArg "the entry to go on from; any unambiguous prefix, or PREFIX:N"
    <*> Cli.flag? "provider" providerName
      s!"who serves the models: {Provider.names}; needed only when a call samples"
    <*> Provider.endpointCli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "samples" .nat 0 "responses this invocation may sample; 0 is no limit"
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed along the log, after which no operation starts; 0 is no limit"

/-- Runs `k` with what a run is driven with: its work directory and outputs in the command's
scratch, a container of each call's image as `options` say, and the models `provider` serves,
each built once. -/
private def withRuntime (data : DataDir) (options : Executor.Docker.RunOptions)
    (provider? : Option Provider.Provider) (baseUrl? : Option String) (k : Runtime → Result α) : Result α := do
  let outputs := data.scratch / "outputs"
  let work := data.scratch / "work"
  Result.fromIO Error.storage do
    IO.FS.createDirAll outputs
    IO.FS.createDirAll work
  let outputsHost ← Result.fromIO Error.storage (IO.FS.realPath outputs)
  let models ← Result.fromIO Error.storage (IO.mkRef (#[] : Array (String × Model)))
  k { store := data.store, workspaces := data.workspaces, workDir := work, outputsDir := outputs
      executor := fun environment => do
        let settings ← Executor.Docker.settingsOf options environment.image environment.workdir
        let settings := { settings with
          mounts := #[{ host := outputsHost, container := Driver.outputsDir, readOnly := true }] }
        settings.ensurePresent
        Executor.Docker.executor settings
      model := fun spec => do
        let some provider := provider?
          | throw <| .input "a call samples its model: name a --provider"
        let key := spec.toJson.compress
        if let some (_, model) := (← Result.fromIO Error.storage models.get).find? (·.1 == key) then
          return model
        let model ← Driver.buildModel spec provider data.cache baseUrl?
        Result.fromIO Error.storage (models.modify (·.push (key, model)))
        pure model }

/-- How a driver stopped, as the last object of `--json`: its status, and, when no call runs,
how the last call ended. -/
private def stopJson (last : Hash) (log : Log Agent) : Stop → Json
  | .idle => match lastCall? log with
    | some (call, some ended) =>
      .mkObj ([("entry", (last.hex : Json)), ("call", (call.name : Json))] ++ match ended with
        | .returned value => [("status", "done"), ("value", value)]
        | .failed error => [("status", "failed"), ("error", .str error)]
        | .stopped reason => [("status", "stopped"), ("reason", .str reason)])
    | _ => .mkObj [("entry", last.hex), ("status", "idle")]
  | .waits frame question? =>
    .mkObj [("entry", last.hex), ("status", "waits"), ("frame", frame.toJson),
      ("question", question?.map (·.toJson) |>.getD .null)]
  | .paused reason => .mkObj [("entry", last.hex), ("status", "paused"), ("reason", .str reason)]

/-- How a driver stopped, for a person. -/
private def stopNote (last : Hash) (log : Log Agent) : Stop → String
  | .idle => match lastCall? log with
    | some (call, some ended) => s!"{call.name}: {Render.endingSummary ended}"
    | _ => s!"waits for a call: `alaya call {last.hex.take 12} PROGRAM …`"
  | .waits _ (some question) =>
    s!"waits for a reply to: {question.text}\nreply with `alaya reply {last.hex.take 12} ...`"
  | .waits _ none => s!"waits for a notice: `alaya tell {last.hex.take 12} TEXT`"
  | .paused reason => s!"paused: {reason}; `alaya resume {last.hex.take 12}` goes on"

/-- Prints how a driver stopped: the last object with `--json`, else a line on stderr, after
the entries on stdout. -/
private def reportStop (out : Cli.Out) (last : Hash) (log : Log Agent) (stop : Stop) : Result Unit :=
  if out.json then out.record (stopJson last log stop) "" else
    Result.fromIO Error.storage do
      (← IO.getStdout).flush
      (← IO.getStderr).putStrLn (stopNote last log stop)

/-- The exit status of a run that calls nothing: by the verdict when its last call was a
grader, 1 when it failed, 0 otherwise. -/
private def idleStatus (log : Log Agent) : UInt32 :=
  match lastCall? log with
  | some (call, some (.returned value)) =>
    if call.name != Agents.Catalog.grader.name then 0 else
    match Agents.Grader.verdictStatus value with
    | "pass" => 0
    | "fail" => exitFail
    | _ => exitError
  | some (_, some (.failed _)) => exitFail
  | _ => 0

private def resumeRun (a : ResumeArgs) (out : Cli.Out) : Result UInt32 := do
  if a.provider?.isNone && a.endpoint?.isSome then
    throw <| .input "--url and --port address a provider: name it with --provider"
  let baseUrl? ← match a.endpoint?, a.provider?.map (·.name) with
    | none, _ => pure none
    | some endpoint, some "dgx" => pure (some endpoint.baseUrl)
    | some _, other => throw <| .input s!"--url and --port address a dgx server, not {other.getD "none"}"
  withData a.data (write := true) fun data => do
    let (_, tip, entries) ← entriesAt data a.entry
    let limits : Limits := {
      samples? := if a.samples == 0 then none else some a.samples
      budgetMs? := if a.budget == 0 then none else some (a.budget * 1000) }
    let position ← IO.mkRef entries.size |> Result.fromIO Error.storage
    withRuntime data a.options a.provider? baseUrl? fun rt => do
      let (last, stop) ← Driver.drive rt session tip limits fun hash entry => do
        let at' ← Result.fromIO Error.storage (position.modifyGet fun p => (p, p + 1))
        entryRecord out hash at' entry
      let log ← data.store.log (← data.store.forest) last
      reportStop out last log stop
      pure <| match stop with
        | .idle => idleStatus log
        | .waits .. => exitWaiting
        | .paused _ => exitPaused

private def tellRun (data : System.FilePath) (reference text : String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data =>
    appendTo data reference out fun _ _ => pure (.arrived (.said text))

private def commitRun (data : System.FilePath) (reference : String) (dir : System.FilePath)
    (message? : Option String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data => do
    let (_, tip) ← resolve data reference
    let event ← Notices.changed data.store data.workspaces tip dir (message?.getD "")
    appendTo data reference out fun _ _ => pure event

/-- A person's reply: the answer's text, or `none` when they cannot answer. -/
private def replyAnswer : Cli.Spec (Option String) :=
  (Prod.mk
    <$> Cli.arg? "TEXT" .string "the answer, verbatim; put it after -- if it may begin with -"
    <*> Cli.switch "unavailable" "record that the person cannot answer, instead of an answer").refine
    fun
    | (some text, false) => .ok (some text)
    | (none, true) => .ok none
    | (some _, true) => .error "give the answer or --unavailable, not both"
    | (none, false) => .error "give the answer as TEXT, or --unavailable"

private def replyRun (data : System.FilePath) (reference : String) (answer? : Option String)
    (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data =>
    appendTo data reference out fun _ next => do
      let some (_, question) := questionOf? next
        | throw <| .input s!"no question waits for a reply at {reference}"
      let reply ← match answer? with
        | some text => Result.fromExcept Error.input (question.parseReply text)
        | none => pure .unavailable
      Result.fromExcept Error.input (replyTo next reply)

/-- Appends a person's comment after an entry. Nothing reads it, so nothing is checked: the log
need not even be one its run can still be built from. -/
private def commentRun (data : System.FilePath) (reference text : String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data => do
    let (forest, tip) ← resolve data reference
    let (hash, entry) ← Notices.comment data.store tip text
    entryRecord out hash (forest.path tip).size entry
    pure 0

private def stopRun (data : System.FilePath) (reference reason : String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data =>
    appendTo data reference out fun _ _ => pure (.stopped reason)

/-! ## Reading the forest -/

private def treeRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let forest ← data.store.forest
    let rows ← Render.rows data.store forest
    if out.json then
      for row in rows do
        out.record (.mkObj [("entry", row.hash.hex), ("parent", row.parent?.map (Json.str ·.hex) |>.getD .null),
          ("position", row.position), ("summary", row.summary),
          ("status", row.status?.map Json.str |>.getD .null)]) ""
    else emitLines (Render.treeLines rows)
    pure 0

private def waitingRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let forest ← data.store.forest
    walk data.store forest () fun _ visit => do
      let leaf := (forest.childrenOf visit.hash).isEmpty
      if let (true, some (.waits frame _), some question) := (leaf, visit.next?, visit.question?) then
        out.record (.mkObj [("entry", visit.hash.hex), ("frame", frame.toJson), ("question", question.text),
            ("question_type", question.form.name),
            ("options", .arr (question.form.options.map Json.str))])
          s!"{visit.hash.hex}  {question.render.quote}"
    pure 0

private def logRun (data : System.FilePath) (reference : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, _, entries) ← entriesAt data reference
    let log := entries.map (·.event)
    let mut spent := 0
    for (entry, position) in entries.zipIdx do
      spent := spent + entry.elapsedMs
      let frame := (entry.event.frame?.map Frame.render).getD "-"
      out.record (.mkObj [("entry", entry.hash.hex), ("position", position),
          ("frame", (entry.event.frame?.map Frame.toJson).getD .null),
          ("event", eventToJson entry.event), ("elapsed_ms", entry.elapsedMs)])
        s!"{position}  {Render.short entry.hash}  {frame}  {Render.eventSummary entry.event}  ({Render.seconds spent})"
    let next := next session log
    let status := Render.nextSummary ((questionOf? next).map (·.2)) ((lastCall? log).bind (·.2)) next
    out.record (.mkObj [("next", status)]) status
    pure 0

/-- The files an entry shows: the workspace the log has reached there. -/
private def snapshotAt (entries : Array Entry) : Result Snapshot := do
  match workspace? (entries.map (·.event)) with
  | some snapshot => pure snapshot
  | none => throw <| .storage "the log names no workspace"

private def showRun (data : System.FilePath) (reference : String) (request : Bool) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
    let (_, hash, entries) ← entriesAt data reference
    let log := entries.map (·.event)
    let some entry := entries.back? | throw <| .storage "an empty log"
    let position := entries.size - 1
    let spent := entries.foldl (fun ms e => ms + e.elapsedMs) (0 : Nat)
    let usage := log.foldl (init := ({} : Chat.TokenUsage)) fun usage event =>
      match event with
      | .answered _ _ (.ok (.response response)) => addUsage usage (response.usage?.getD {})
      | _ => usage
    let stack := log.zipIdx.foldl (init := #[]) fun stack (event, i) => OpenCall.after stack i event
    let before := Replayer.ofLog session (log.extract 0 position)
    let asked? := match before.next, entry.event with
      | .ask { op := .sample _ request, .. }, .answered .. => some request
      | _, _ => none
    let next := (before.feed entry.event).next
    let after := Render.nextSummary ((questionOf? next).map (·.2)) ((lastCall? log).bind (·.2)) next
    let requestJson := if request then (asked?.map (·.toJson)).getD .null else .null
    if out.json then
      out.record (.mkObj [("entry", hash.hex), ("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
        ("position", position), ("event", eventToJson entry.event), ("elapsed_ms", entry.elapsedMs),
        ("run_time_ms", spent), ("run_usage", usage.toStored),
        ("workspace", (workspace? log).map (Json.str ·.hex) |>.getD .null),
        ("calls", .arr (stack.map fun call => .mkObj [("frame", call.frame.toJson),
          ("routine", call.call.toJson), ("position", call.position)])),
        ("next", after), ("request", requestJson)]) ""
      return 0
    let mut lines : Array String := #[
      s!"entry      {hash.hex}",
      s!"parent     {(entry.parent?.map (·.hex)).getD "none: a root"}",
      s!"position   {position}, frame {(entry.event.frame?.map Frame.render).getD "-"}",
      s!"time       {Render.seconds entry.elapsedMs}; the run {Render.seconds spent}",
      s!"workspace  {((workspace? log).map (·.hex)).getD "none"}"]
    let spentTokens := Render.tokens usage
    if !spentTokens.isEmpty then lines := lines.push s!"tokens     the run: {spentTokens}"
    lines := lines.push s!"calls      {if stack.isEmpty then "none open" else " > ".intercalate (stack.map fun c => s!"{c.call.name} ({c.frame.render})").toList}"
    lines := lines.push s!"after it   {after}"
    lines := lines ++ #["", Render.eventSummary entry.event, (eventToJson entry.event).pretty]
    if request then
      match asked? with
      | some request => lines := lines ++ #["", "request:", request.toJson.pretty]
      | none => lines := lines ++ #["", "request: none — the entry answers no sample"]
    emitLines lines
    pure 0

private def lsRun (data : System.FilePath) (reference : String) (path? : Option String) (out : Cli.Out) :
    Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← entriesAt data reference
    let snapshot ← snapshotAt entries
    let path := path?.getD ""
    let listed ← data.workspaces.list snapshot path
    let lines := listed.map fun e =>
      let size := e.size.map toString |>.getD "-"
      let suffix := if e.kind == .directory then "/" else if e.kind == .symlink then "@" else ""
      s!"{"".pushn ' ' (10 - min 10 size.length)}{size}  {e.path}{suffix}"
    if out.json then
      out.record (.mkObj [("entry", hash.hex), ("snapshot", snapshot.hex), ("path", path),
        ("entries", .arr (listed.map fun e => .mkObj [("name", e.name), ("path", e.path),
          ("kind", e.kind.toString), ("size", e.size.map (fun n => (n : Json)) |>.getD .null)]))]) ""
    else emitLines lines
    pure 0

/-- The file's bytes, exactly; with `--json`, a preview of any entry: UTF-8 text up to 1 MiB,
and otherwise what it is. -/
private def catRun (data : System.FilePath) (reference path : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← entriesAt data reference
    let snapshot ← snapshotAt entries
    if out.json then
      let preview ← data.workspaces.preview snapshot path
      out.record (.mkObj [("entry", hash.hex), ("snapshot", snapshot.hex), ("path", path),
        ("kind", preview.kind), ("content", preview.content?.map Json.str |>.getD .null),
        ("size", preview.size?.map (fun n => (n : Json)) |>.getD .null)]) ""
    else
      let bytes ← data.workspaces.read snapshot path
      Result.fromIO Error.storage do
        let stdout ← IO.getStdout
        stdout.write bytes
        stdout.flush
    pure 0

private def checkoutRun (data : System.FilePath) (reference : String) (dir : System.FilePath)
    (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← entriesAt data reference
    let snapshot ← snapshotAt entries
    Workspaces.refuseOverlap "check out into" dir #[data.path]
    data.workspaces.materialize snapshot dir
    out.record (.mkObj [("entry", hash.hex), ("snapshot", snapshot.hex), ("directory", dir.toString)])
      s!"checked out {snapshot.hex} into {dir}"
    pure 0

private def diffRun (data : System.FilePath) (a b : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, _, before) ← entriesAt data a
    let (_, _, after) ← entriesAt data b
    let lines ← Notices.changedLines data.workspaces (← snapshotAt before) (← snapshotAt after)
    if out.json then out.record (.mkObj [("changes", .arr (lines.map Json.str))]) ""
    else emitLines lines
    pure 0

private def htmlRun (data : System.FilePath) (file : System.FilePath) (hide : Array String)
    (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    -- Each --hide may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := hide.foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    let forest ← data.store.forest
    if forest.entries.isEmpty then
      throw <| .input "nothing to report: the data directory holds no runs"
    let page ← Html.report data.store data.workspaces forest s!"alaya {data.path}" hidden
    Result.fromIO Error.storage (IO.FS.writeFile file page)
    out.record (.mkObj [("file", file.toString), ("bytes", page.length)])
      s!"wrote {file} ({page.length} bytes)"
    pure 0

private def rmRun (data : System.FilePath) (reference : String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data => do
    let (_, hash) ← resolve data reference
    let removed ← Notices.remove data.store data.workspaces hash
    out.record (.mkObj [("removed", removed)]) s!"removed {removed} entries"
    pure 0

/-! ## Rebasing a run -/

/-- Copies the run that ends at an entry into a new data directory, `target`, as the current
version of its agent makes it, with `settings` over its configuration (`Alaya.Rebase`). The source is only
read. The new directory is written beside `target` under another name and renamed into place
once complete, so a failure leaves none. -/
private def rebaseRun (data : System.FilePath) (reference : String) (target : System.FilePath)
    (settings : Array Settings.Given) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let settings ← settings.mapM (·.read)
    let io {α} (action : IO α) : Result α := Result.fromIO Error.storage action
    if ← io target.pathExists then
      throw <| .input s!"{target} exists: rebase makes a new data directory"
    let some name := target.fileName | throw <| .input s!"not a directory to create: {target}"
    let source ← io (IO.FS.realPath data.path)
    if Workspaces.overlap (← io (Workspaces.resolved target)) source then
      throw <| .input s!"{target} overlaps the data directory {data.path}: put the new one beside it"
    let (_, tip, entries) ← entriesAt data reference
    let log := entries.map (·.event)
    let log ← Rebase.reconfigure log settings
    do
      let rebased := rebase session log
      let summary := Rebase.summary rebased log.size
      let staging := target.withFileName
        s!".{name}.rebase-{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}"
      let written ← try
          let store ← Store.create (staging / "entries")
          let written ← Rebase.write rebased entries data.workspaces (staging / "restic") store
            s!"rebased from {tip.hex} in {source}: {summary}"
          Cache.link data.cache (staging / "cache")
          io (IO.FS.rename staging target)
          pure written
        catch error =>
          Workspaces.makeWritable staging
          io do if ← staging.pathExists then IO.FS.removeDirAll staging
          throw error
      for ((hash, entry), position) in written.zipIdx do entryRecord out hash position entry
      let some (last, _) := written.back? | throw <| .storage "a rebase wrote no entry"
      if out.json then
        out.record (.mkObj [("entry", last.hex), ("data", target.toString),
          ("held", (rebased.divergence?.map (·.position)).getD log.size), ("total", log.size),
          ("divergence", match rebased.divergence? with
            | none => .null
            | some divergence => .mkObj [("position", divergence.position),
                ("found", eventToJson divergence.found),
                ("expected", Rebase.expectedSummary divergence.expected)]),
          ("dropped", .arr (rebased.dropped.map fun (position, event) =>
            .mkObj [("position", position), ("event", eventToJson event)]))]) ""
      else io do
        (← IO.getStdout).flush
        let stderr ← IO.getStderr
        stderr.putStrLn summary
        for line in Rebase.droppedLines rebased do stderr.putStrLn line
        stderr.putStrLn s!"`alaya resume {Render.short last} --data {target}` goes on"
      pure 0

/-! ## Configuration -/

private def providerJson (provider : Provider.Provider) : Json :=
  .mkObj [("name", provider.name), ("base_url", provider.baseUrl),
    ("base_url_var", provider.baseUrlVar?.map Json.str |>.getD .null),
    ("key_var", provider.keyVar), ("any_model", provider.anyModel),
    ("routes", .arr (provider.routes.toArray.map fun (model, route) =>
      .mkObj [("model", model), ("name", route.name)]))]

private def providerText (provider : Provider.Provider) : String :=
  let serves := if !provider.anyModel then "only these models:"
    else if provider.routes.isEmpty then "any model, under its own name"
    else "any model under its own name, and these under others:"
  let routes := provider.routes.map fun (model, route) => s!"\n  {model} as {route.name}"
  s!"provider {provider.name}: {provider.baseUrl}, key {provider.keyVar}; serves {serves}" ++ String.join routes

/-- The programs, models and providers with their defaults, or the configuration `call` would
record for a program with these settings. -/
private def configRun (program? : Option String) (settings : Array Settings.Given)
    (out : Cli.Out) : Result UInt32 := do
  if program?.isNone && !settings.isEmpty then
    throw <| .input "--set needs --program NAME, the program it changes"
  let settings ← settings.mapM (·.read)
  if program?.isNone then
    for definition in Agents.Catalog.all do
      let config ← Agents.Catalog.resolve definition.name #[]
      out.record (.mkObj [("program", definition.name), ("config", config)])
        s!"program {definition.name} {config.pretty}"
    for spec in Models.all do
      out.record (.mkObj [("model", spec.toJson)]) s!"model {spec.toJson.pretty}"
    for provider in Provider.all do
      out.record (.mkObj [("provider", providerJson provider)]) (providerText provider)
    return 0
  let name := program?.getD ""
  let config ← Agents.Catalog.resolve name settings
  out.record (.mkObj [("program", name), ("config", config)]) config.pretty
  pure 0

/-! ## The table -/

private def commands : Array Cli.Command := #[
  { name := "new"
    summary := "Create a run: its root, the workspace, where it waits for a program to be called."
    examples := #["alaya new ./project", "alaya new --image swebench/sweb.eval.django-11099:latest --workdir /testbed"]
    spec := newRun <$> NewArgs.cli },
  { name := "call"
    summary := "Call a program after an entry where no call runs: an agent, or a grader; resume drives it."
    examples := #[
      "alaya call 4f2c8b mini-swe --set model=gpt-oss-120b --set task='Add a hello.py that prints hello' " ++
        "--image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya call 4f2c8b mini-vero --set model=deepseek-v4.1-flash --set mode=codeproof --set-file task=TASK.md " ++
        "--image my-task:1 --workdir /testbed",
      "alaya call 9a11c0 grader --image my-grader:1 --set command='python3 /grader/grade.py'"]
    spec := callRun <$> CallArgs.cli },
  { name := "config"
    summary := "The programs, models and providers, or the configuration call would record; creates nothing."
    examples := #["alaya config",
      "alaya config --program mini-vero --set model=deepseek-v4.1-flash --set model.params.reasoning_effort=high --set mode=codeproof"]
    spec := configRun <$> Cli.flag? "program" programName s!"the program: {Agents.Catalog.names}"
      <*> overrides },
  { name := "resume"
    summary := "Drive a run on from an entry until no call runs, a call waits for a person, or a limit is reached."
    examples := #["alaya resume 4f2c8b --provider apiyi --time-budget 3600",
      "alaya resume 4f2c8b --provider dgx --url spark.local:9000 --samples 1",
      "alaya resume 9a11c0"]
    spec := resumeRun <$> ResumeArgs.cli },
  { name := "tell"
    summary := "Append a person's message after an entry; the call running reads it at its next read of the inbox."
    examples := #["alaya tell 4f2c8b 'keep the old API'"]
    spec := tellRun <$> dataDir <*> entryArg <*> Cli.arg "TEXT" .string "the message" },
  { name := "commit"
    summary := "Append a change to the workspace after an entry: the files of DIR, and what changed."
    examples := #["alaya commit 4f2c8b ./fix --message 'I fixed the fixture; the parser bug is still yours.'"]
    spec := commitRun <$> dataDir <*> entryArg <*> Cli.arg "DIR" .path "the edited workspace"
      <*> Cli.flag? "message" .string "what to tell the agent of the change, after the list of what changed" },
  { name := "reply"
    summary := "Answer the question a log waits on, or record that the person cannot."
    examples := #["alaya reply c61754 -- 'yes, keep it'", "alaya reply c61754 --unavailable"]
    spec := replyRun <$> dataDir <*> entryArg "the entry whose log waits for a reply" <*> replyAnswer },
  { name := "stop"
    summary := "Stop the call running after an entry: the call is over there."
    examples := #["alaya stop 4f2c8b:120 --reason 'enough'"]
    spec := stopRun <$> dataDir <*> entryArg
      <*> Cli.flagD "reason" .string "stopped from outside" "why, as the log keeps it" },
  { name := "comment"
    summary := "Append a comment after an entry: for whoever reads the log, and ignored by everything else."
    examples := #["alaya comment 4f2c8b:140 'the parser goes wrong here'"]
    spec := commentRun <$> dataDir <*> entryArg <*> Cli.arg "TEXT" .string "the comment" },
  { name := "waiting"
    summary := "List every log that waits for a reply, with its question."
    examples := #["alaya waiting --json"]
    spec := waitingRun <$> dataDir },
  { name := "tree"
    summary := "Show the forest: each run, its stretches of entries, its forks, and how each log ends."
    spec := treeRun <$> dataDir },
  { name := "log"
    summary := "The log that ends at an entry, one event a line, and what the run does next."
    examples := #["alaya log 4f2c8b", "alaya log 4f2c8b --json"]
    spec := logRun <$> dataDir <*> entryArg },
  { name := "show"
    summary := "One entry in full: its event, time, tokens, open calls, and with --request the request it answers."
    examples := #["alaya show 4f2c8b:40 --request"]
    spec := showRun <$> dataDir <*> entryArg
      <*> Cli.switch "request" "also print the request the sample at this entry answers, as replay makes it" },
  { name := "ls"
    summary := "List a directory of the workspace at an entry, or of a grader's checkout."
    examples := #["alaya ls 7b19d4 .report"]
    spec := lsRun <$> dataDir <*> entryArg
      <*> Cli.arg? "PATH" .string "a directory relative to the workspace; by default its root" },
  { name := "cat"
    summary := "Print a file of the workspace at an entry, byte for byte; --json previews any entry."
    examples := #["alaya cat 7b19d4 .report/summary.json"]
    spec := catRun <$> dataDir <*> entryArg <*> Cli.arg "PATH" .string "a file relative to the workspace" },
  { name := "checkout"
    summary := "Write the workspace at an entry into a directory."
    spec := checkoutRun <$> dataDir <*> entryArg <*> Cli.arg "DIR" .path "where to write the files" },
  { name := "diff"
    summary := "The workspace changes between two entries, one path per line."
    spec := diffRun <$> dataDir <*> Cli.arg "A" .string "the earlier entry"
      <*> Cli.arg "B" .string "the later entry" },
  { name := "html"
    summary := "Write the forest as one self-contained page, for reading."
    examples := #["alaya html report.html --hide .venv --hide __pycache__,.pytest_cache"]
    spec := htmlRun <$> dataDir
      <*> Cli.arg "FILE" .path "where to write the page"
      <*> Cli.repeated "hide" (.string "DIRS") "directories to leave out of the page, comma-separated" },
  { name := "rm"
    summary := "Delete an entry, everything after it, and the snapshots only they named."
    spec := rmRun <$> dataDir <*> entryArg "the first entry to delete" },
  { name := "rebase"
    summary := "Copy the log at an entry into a new data directory, up to where a revised version of its agent differs, to go on with it there."
    examples := #["alaya rebase 4f2c8b ../v2", "alaya rebase 4f2c8b ../v2 --set context_reserve=16000"]
    spec := rebaseRun <$> dataDir <*> entryArg "the entry whose log is rebased"
      <*> Cli.arg "DIR" .path "the new data directory, which must not exist"
      <*> overrides }]

private def app : Cli.App where
  name := "alaya"
  summary := "Run agents as programs over a log: call them, drive, fork at any entry, intervene, and grade any point."
  commands := commands

/-- Exit 0 when a command succeeded. `resume` exits, when no call runs, 0 when the last call
returned or was stopped and 1 when it failed, or, when the last call was a grader, with its
verdict: 0 pass, 1 fail, 2 error; 3 when a call waits for a person (`exitWaiting`), and 4 when it
paused at a limit (`exitPaused`). A failure exits with its class's status, above all of these
(`Cli.exitFor`): 64 a command line that does not parse, 65 input, 69 environment, 74 storage, 75
transient, 76 model. -/
def main (argv : List String) : IO UInt32 :=
  app.run argv
