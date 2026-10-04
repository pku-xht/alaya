import Alaya

/-! `alaya` — the command line over a forest of logs. See `docs/cli.md` for the commands. -/

open Lean (Json)
open Alaya
open Alaya.Driver (Runtime Limits Stop)

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM emit

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

/-- The configuration of a log's run and its model. -/
private def configured (log : Log Agent) : Result (RunConfig × Models.Spec) := do
  let config ← configOf log
  pure (config, ← Models.fromJson config.model)

/-- A new entry, as the commands that append print it: a line that begins with its full name,
or one JSON object. -/
private def entryRecord (out : Cli.Out) (hash : Hash) (position : Nat) (entry : Entry) : Result Unit :=
  out.record (.mkObj [("entry", hash.hex), ("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
      ("position", position), ("frame", (entry.event.frame?.map Frame.toJson).getD .null),
      ("summary", Render.eventSummary entry.event), ("event", eventToJson entry.event),
      ("elapsed_ms", entry.elapsedMs)])
    (Render.entryLine hash position entry.event)

/-- Exit status of `grade` when the verdict is a fail, and when it is an error. -/
private def exitFail : UInt32 := 1
private def exitError : UInt32 := 2

/-- Exit status when a run waits for a person: a reply, or a task. -/
private def exitWaiting : UInt32 := 3

/-- Exit status when a run paused at a limit of this invocation: `run` goes on from there. -/
private def exitPaused : UInt32 := 4

/-! ## Creating a run -/

/-- `--agent NAME`: an agent the catalog has. -/
private def agentName : Cli.Value String :=
  .enum "NAME" (Agents.Catalog.all.map fun d => (d.name, d.name)).toList

/-- `--model NAME`: a model the table has. -/
private def modelName : Cli.Value String :=
  .enum "NAME" (Models.all.map fun m => (m.name, m.name)).toList

/-- `--set agent.PATH=VALUE` or `--set model.PATH=VALUE`: one field over the defaults. -/
private def setting : Cli.Value Settings.Setting := ⟨"agent|model.PATH=VALUE", Settings.parse⟩

private def overrides : Cli.Spec (Array Settings.Setting) :=
  Cli.repeated "set" setting
    "a field over the agent's or the model's defaults, e.g. agent.mode=codeproof, model.params.reasoning_effort=high"

/-- What `new` takes. -/
private structure NewArgs where
  data : System.FilePath
  task : Cli.TextSource
  project? : Option System.FilePath
  image : String
  workdir : String
  agent : String
  model : String
  settings : Array Settings.Setting

private def NewArgs.cli : Cli.Spec NewArgs :=
  NewArgs.mk
    <$> dataDir
    <*> (Cli.text "task" "the task: the notice the agent starts from, saved verbatim").required
      "a run needs a task: --task TEXT or --task-file FILE"
    <*> Cli.arg? "PROJECT" .path
      "the directory the workspace starts as; without it, the image's own workdir is copied out"
    <*> Cli.flag "image" (.string "IMAGE") "the container image every command runs in, pinned by digest"
    <*> Cli.flagD "workdir" (.string "PATH") Executor.Docker.defaultWorkdir
      "where the workspace is mounted in the image"
    <*> Cli.flag "agent" agentName s!"the agent: {Agents.Catalog.names}"
    <*> Cli.flag "model" modelName s!"the model: {Models.names}"
    <*> overrides

/-- The directory a new run starts from: a host `PROJECT`, or else the image's own `workdir`,
copied out into the command's scratch. -/
private def startingWorkspace (data : DataDir) (settings : Executor.Docker.Settings)
    (project? : Option System.FilePath) : Result System.FilePath := do
  match project? with
  | some project => pure project
  | none =>
    let work := data.scratch / "project"
    Result.fromIO Error.storage (IO.FS.createDirAll work)
    Executor.Docker.copyOut settings settings.workdir work
    pure work

private def newRun (a : NewArgs) (out : Cli.Out) : Result UInt32 := do
  -- A configuration that is wrong is said so before anything is created.
  let model ← Models.resolve a.model a.settings
  let agent ← Agents.Catalog.resolve a.agent a.settings
  let task ← a.task.read "task"
  -- Before the data directory is created: inside the project it would become part of it.
  if let some project := a.project? then
    Workspaces.refuseOverlap "snapshot" project #[a.data]
  withData a.data (write := true) (create := true) fun data => do
    Executor.Docker.checkWorkdir a.workdir #[Driver.graderInput, Driver.outputsDir]
    let settings ← (← Executor.Docker.settingsOf {} a.image a.workdir).pin
    let uname ← Executor.Docker.uname settings
    let config : RunConfig := {
      agent, model := model.toJson
      environment := { image := settings.image, workdir := a.workdir, uname } }
    match config.run model with
    | .error problem => throw <| .input problem
    | .ok run =>
      let project ← startingWorkspace data settings a.project?
      let made ← Notices.create data.store data.workspaces run project task
      for ((hash, entry), position) in made.zipIdx do entryRecord out hash position entry
      pure 0

/-! ## Driving a run -/

/-- `--provider NAME`: who serves the run's model, for this invocation. -/
private def providerName : Cli.Value Provider.Provider :=
  .enum "NAME" (Provider.all.map fun p => (p.name, p)).toList

private structure RunArgs where
  data : System.FilePath
  entry : String
  provider? : Option Provider.Provider
  endpoint? : Option Provider.Dgx.Endpoint
  options : Executor.Docker.RunOptions
  samples : Nat
  budget : Nat

private def RunArgs.cli : Cli.Spec RunArgs :=
  RunArgs.mk
    <$> dataDir
    <*> entryArg "the entry to go on from; any unambiguous prefix, or PREFIX:N"
    <*> Cli.flag? "provider" providerName
      s!"who serves the run's model: {Provider.names}; needed only when the run samples"
    <*> Provider.endpointCli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "samples" .nat 0 "responses this invocation may sample; 0 is no limit"
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed along the log, after which no operation starts; 0 is no limit"

/-- Runs `k` with what a run of `config` is driven with: its work directory and outputs in the
command's scratch, and the container its commands run in, closed when `k` ends. -/
private def withRuntime (data : DataDir) (config : RunConfig) (options : Executor.Docker.RunOptions)
    (model? : Option Model) (k : Runtime → Result α) : Result α := do
  let outputs := data.scratch / "outputs"
  let work := data.scratch / "work"
  Result.fromIO Error.storage do
    IO.FS.createDirAll outputs
    IO.FS.createDirAll work
  let settings ← Executor.Docker.settingsOf options config.environment.image config.environment.workdir
  let settings := { settings with
    mounts := #[{ host := ← Result.fromIO Error.storage (IO.FS.realPath outputs)
                  container := Driver.outputsDir, readOnly := true }] }
  settings.ensurePresent
  let executor ← Executor.Docker.executor settings
  try
    k { store := data.store, workspaces := data.workspaces, workDir := work, outputsDir := outputs
        scratch := data.scratch / "external", executor, workdir := config.environment.workdir
        model?, graderUser? := settings.user? }
  finally
    Result.fromIO Error.storage executor.close

/-- How a driver stopped, as the last object of `--json`: its status, what goes with it, and the
verdict, once the run is graded. -/
private def stopJson (last : Hash) : Stop → Json
  | .over agent verdict? =>
    .mkObj ([("entry", (last.hex : Json)), ("verdict", verdict?.getD .null)] ++ match agent with
      | .returned value => [("status", "done"), ("value", value)]
      | .failed error => [("status", "failed"), ("error", .str error)]
      | .stopped reason => [("status", "stopped"), ("reason", .str reason)])
  | .waits frame question? =>
    .mkObj [("entry", last.hex), ("status", "waits"), ("frame", frame.toJson),
      ("question", question?.map (·.toJson) |>.getD .null)]
  | .paused reason => .mkObj [("entry", last.hex), ("status", "paused"), ("reason", .str reason)]

/-- How a driver stopped, for a person. -/
private def stopNote (last : Hash) : Stop → String
  | .over agent verdict? => Render.endingSummary agent verdict?
  | .waits _ (some question) =>
    s!"waits for a reply to: {question.text}\nreply with `alaya reply {last.hex.take 12} ...`"
  | .waits _ none => s!"waits for a notice: `alaya tell {last.hex.take 12} TEXT`"
  | .paused reason => s!"paused: {reason}; `alaya run {last.hex.take 12}` goes on"

/-- Prints how a driver stopped: the last object with `--json`, else a line on stderr, after
the entries on stdout. -/
private def reportStop (out : Cli.Out) (last : Hash) (stop : Stop) : Result Unit :=
  if out.json then out.record (stopJson last stop) "" else
    Result.fromIO Error.storage do
      (← IO.getStdout).flush
      (← IO.getStderr).putStrLn (stopNote last stop)

private def runRun (a : RunArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let (_, tip, entries) ← entriesAt data a.entry
    let log := entries.map (·.event)
    let (config, modelSpec) ← configured log
    let model? ← a.provider?.mapM fun provider => do
      let baseUrl? ← match a.endpoint?, provider.name with
        | none, _ => pure none
        | some endpoint, "dgx" => pure (some endpoint.baseUrl)
        | some _, other => throw <| .input s!"--url and --port address a dgx server, not {other}"
      Driver.buildModel modelSpec provider data.cache baseUrl?
    if a.provider?.isNone && a.endpoint?.isSome then
      throw <| .input "--url and --port address a provider: name it with --provider"
    let limits : Limits := {
      samples? := if a.samples == 0 then none else some a.samples
      budgetMs? := if a.budget == 0 then none else some (a.budget * 1000) }
    let position ← IO.mkRef entries.size |> Result.fromIO Error.storage
    match config.run modelSpec with
    | .error problem => throw <| .input problem
    | .ok run =>
      withRuntime data config a.options model? fun rt => do
        let (last, stop) ← Driver.drive rt run tip limits fun hash entry => do
          let at' ← Result.fromIO Error.storage (position.modifyGet fun p => (p, p + 1))
          entryRecord out hash at' entry
        reportStop out last stop
        pure <| match stop with
          | .over (.failed _) _ => 1
          | .over .. => 0
          | .waits .. => exitWaiting
          | .paused _ => exitPaused

/-! ## Grading a point of a run -/

private structure GradeArgs where
  data : System.FilePath
  entry : String
  /-- The grader: a command that prints TAP. -/
  command : String
  input? : Option System.FilePath
  image? : Option String
  timeout : Nat
  options : Executor.Docker.RunOptions

private def GradeArgs.cli : Cli.Spec GradeArgs :=
  GradeArgs.mk
    <$> dataDir
    <*> entryArg "the entry to grade the run at; any unambiguous prefix, or PREFIX:N"
    <*> Cli.flag "grader" (.string "CMD")
      "the grader: a command that prints TAP, e.g. 'python3 /grader/grade.py'"
    <*> Cli.flag? "grader-input" (.path "DIR") "trusted files for the grader, snapshotted, at /grader"
    <*> Cli.flag? "grader-image" (.string "IMAGE")
      "the image the grader runs in, pinned by digest; by default the run's"
    <*> Cli.flagD "grader-timeout" (.nat "S") 900 "seconds after which the grader is stopped; 0 is none"
    <*> Executor.Docker.RunOptions.cli

/-- The grader the arguments describe, for a run in `runImage`: its image pinned, its input
snapshotted. -/
private def GradeArgs.grader (a : GradeArgs) (workspaces : Workspaces) (runImage : String) :
    Result Grader := do
  let image ← match a.image? with
    | some reference => pure (← Executor.Docker.Settings.pin { image := reference }).image
    | none => pure runImage
  let input? ← a.input?.mapM fun dir => do
    if !(← Result.fromIO Error.storage dir.isDir) then
      throw <| .input s!"--grader-input must be a directory: {dir}"
    workspaces.snapshot dir
  pure { command := a.command, image, input?, timeoutSeconds := a.timeout }

/-- Grades a point of a run with a grader: stops the agent there if it is still running, assigns
the grader, and drives the run to its verdict. A log has one grader, so a point that has one
already, graded or not, is graded on a fork, from the entry before that grader was assigned.
Exits with the verdict: 0 pass, 1 fail, 2 error. -/
private def gradeRun (a : GradeArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let (forest, tip, entries) ← entriesAt data a.entry
    -- The point graded: the entry named, or, where the log has a grader already, the entry
    -- before that grader was assigned.
    let assignedAt? := entries.findIdx? fun entry => entry.event matches .arrived (.assigned _)
    let (tip, entries) := match assignedAt? with
      | some position => ((forest.path tip)[position - 1]!, entries.extract 0 position)
      | none => (tip, entries)
    let log := entries.map (·.event)
    let (config, modelSpec) ← configured log
    match config.run modelSpec with
    | .error problem => throw <| .input problem
    | .ok run =>
      -- What is wrong with the grader is said before anything is appended.
      let grader ← a.grader data.workspaces config.environment.image
      let mut tip := tip
      let mut position := entries.size
      let stop : Array (Event Agent) :=
        if Driver.running (next run log) then #[.stopped "to grade this point"] else #[]
      for event in stop.push (assignment grader) do
        let (hash, entry) ← Driver.append data.store run tip event
        entryRecord out hash position entry
        tip := hash
        position := position + 1
      let counter ← IO.mkRef position |> Result.fromIO Error.storage
      withRuntime data config a.options none fun rt => do
        let (last, stop) ← Driver.drive rt run tip {} fun hash entry => do
          let at' ← Result.fromIO Error.storage (counter.modifyGet fun p => (p, p + 1))
          entryRecord out hash at' entry
        reportStop out last stop
        let .over _ (some verdict) := stop
          | throw <| .storage "the run did not come to its verdict"
        pure <| match verdictStatus verdict with
          | "pass" => 0
          | "fail" => exitFail
          | _ => exitError

/-! ## What a person appends -/

/-- Appends `event` after the entry a reference names, and prints the new entry. -/
private def appendTo (data : DataDir) (reference : String) (out : Cli.Out)
    (event : Log Agent → Next Agent → Result (Event Agent)) : Result UInt32 := do
  let (_, tip, entries) ← entriesAt data reference
  let log := entries.map (·.event)
  let (config, model) ← configured log
  match config.run model with
  | .error problem => throw <| .input problem
  | .ok run =>
    let event ← event log (next run log)
    let (hash, entry) ← Driver.append data.store run tip event
    entryRecord out hash entries.size entry
    pure 0

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
    appendTo data reference out fun log next => do
      let some (_, question) := questionOf? log next
        | throw <| .input s!"no question waits for a reply at {reference}"
      let reply ← match answer? with
        | some text => Result.fromExcept Error.input (question.parseReply text)
        | none => pure .unavailable
      Result.fromExcept Error.input (replyTo log next reply)

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
      if let (true, some (.waits frame), some question) := (leaf, visit.next?, visit.question?) then
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
    let status ← match ← tryCatch (some <$> configured log) fun _ => pure none with
      | none => pure "the run cannot be read"
      | some (config, model) => pure <| match config.run model with
        | .ok run =>
          let next := next run log
          Render.nextSummary ((questionOf? log next).map (·.2)) (agentEnd? log) next
        | .error problem => s!"the run cannot be built: {problem}"
    out.record (.mkObj [("next", status)]) status
    pure 0

/-- The files an entry shows: a grader's checkout as it left it, on the answer of an external
program; the workspace the log has reached, on any other. -/
private def snapshotAt (entries : Array Entry) : Result Snapshot := do
  let last : Option (Event Agent) := entries.back?.map (·.event)
  match last with
  | some (.answered _ _ (.ok (.external ran))) => pure ran.checkout
  | _ =>
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
    let spent := entries.foldl (fun ms e => ms + e.elapsedMs) 0
    let usage := log.foldl (init := ({} : Chat.TokenUsage)) fun usage event =>
      match event with
      | .answered _ _ (.ok (.response response)) => addUsage usage (response.usage?.getD {})
      | _ => usage
    let stack := log.zipIdx.foldl (init := #[]) fun stack (event, i) => OpenCall.after stack i event
    let (asked?, after) ← match ← tryCatch (some <$> configured log) fun _ => pure none with
      | none => pure (none, "the run cannot be read")
      | some (config, model) => pure <| match config.run model with
        | .ok run =>
          let before := Replayer.ofLog run (log.extract 0 position)
          let asked? := match before.next, entry.event with
            | .ask { op := .sample request, .. }, .answered .. => some request
            | _, _ => none
          let after := (before.feed entry.event).next
          (asked?, Render.nextSummary ((questionOf? log after).map (·.2)) (agentEnd? log) after)
        | .error problem => (none, s!"the run cannot be built: {problem}")
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

/-- The agents, models and providers with their defaults, or the configuration `new` would
record for these flags. -/
private def configRun (agent? model? : Option String) (settings : Array Settings.Setting)
    (out : Cli.Out) : Result UInt32 := do
  for setting in settings do
    if setting.target == .agent && agent?.isNone then
      throw <| .input "--set agent.… needs --agent NAME, the agent it changes"
    if setting.target == .model && model?.isNone then
      throw <| .input "--set model.… needs --model NAME, the model it changes"
  if agent?.isNone && model?.isNone then
    for definition in Agents.Catalog.all do
      let agent ← Agents.Catalog.resolve definition.name #[]
      out.record (.mkObj [("agent", agent)]) s!"agent {agent.pretty}"
    for spec in Models.all do
      out.record (.mkObj [("model", spec.toJson)]) s!"model {spec.toJson.pretty}"
    for provider in Provider.all do
      out.record (.mkObj [("provider", providerJson provider)]) (providerText provider)
    return 0
  let mut fields : List (String × Json) := []
  if let some name := agent? then fields := fields ++ [("agent", ← Agents.Catalog.resolve name settings)]
  if let some name := model? then fields := fields ++ [("model", (← Models.resolve name settings).toJson)]
  out.record (.mkObj fields) (Json.mkObj fields).pretty
  pure 0

/-! ## The table -/

private def commands : Array Cli.Command := #[
  { name := "new"
    summary := "Create a run: its workspace, the agent's call with the run's configuration, and the task."
    examples := #[
      "alaya new --task 'Add a hello.py that prints hello' ./project " ++
        "--agent mini-swe --model gpt-oss-120b --image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya new --task-file TASK.md --agent mini-vero --model deepseek-v4.1-flash --set agent.mode=codeproof " ++
        "--image my-task:1 --workdir /testbed"]
    spec := newRun <$> NewArgs.cli },
  { name := "config"
    summary := "The agents, models and providers, or the configuration new would record; creates nothing."
    examples := #["alaya config",
      "alaya config --agent mini-vero --model deepseek-v4.1-flash --set agent.mode=codeproof --set model.params.reasoning_effort=high"]
    spec := configRun <$> Cli.flag? "agent" agentName s!"the agent: {Agents.Catalog.names}"
      <*> Cli.flag? "model" modelName s!"the model: {Models.names}"
      <*> overrides },
  { name := "run"
    summary := "Drive a run on from an entry until it is over, waits for a person, or reaches a limit."
    examples := #["alaya run 4f2c8b --provider apiyi --time-budget 3600",
      "alaya run 4f2c8b --provider dgx --url spark.local:9000 --samples 1",
      "alaya run 4f2c8b --provider apiyi --samples 1"]
    spec := runRun <$> RunArgs.cli },
  { name := "tell"
    summary := "Append a person's message after an entry; the agent reads it at its next read of the inbox."
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
  { name := "grade"
    summary := "Grade a run at an entry: stop the agent there, assign the grader, and run it; exits with the verdict."
    examples := #["alaya grade 4f2c8b --grader 'python3 /grader/grade.py' --grader-input ./hidden",
      "alaya grade 4f2c8b:120 --grader 'sh /grader/check.sh' --grader-input ./hidden --grader-image checker:1"]
    spec := gradeRun <$> GradeArgs.cli },
  { name := "stop"
    summary := "Stop the agent after an entry: the run is over there."
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
    spec := rmRun <$> dataDir <*> entryArg "the first entry to delete" }]

private def app : Cli.App where
  name := "alaya"
  summary := "Run agents as programs over a log: drive, fork at any entry, intervene, and grade any point."
  commands := commands

/-- Exit 0 when a command succeeded. `run` exits 0 when the agent is over, returned or stopped,
1 when the agent failed, 3 when the run waits for a person (`exitWaiting`), and 4 when it paused
at a limit (`exitPaused`); `grade` exits with the verdict, 0 pass, 1 fail, 2 error. A failure exits with its class's status, above all of these
(`Cli.exitFor`): 64 a command line that does not parse, 65 input, 69 environment, 74 storage, 75
transient, 76 model. -/
def main (argv : List String) : IO UInt32 :=
  app.run argv
