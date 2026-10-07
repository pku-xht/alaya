import Alaya.App.Builtin
import Alaya.App.Html
import Alaya.App.Options
import Alaya.App.Rebase
import Alaya.App.Render
import Alaya.App.Session
import Alaya.Runtime.Commands
import Alaya.Runtime.Driver

/-! The command line of an application over a forest of logs: Alaya's commands, each over a
catalog of programs, models and providers, and what they are built from, for commands of an
application's own. `app` puts them together; Alaya's `main` is `app` over `Builtin.catalog`. See
`docs/cli.md` for the commands. -/

namespace Alaya.App.Commands

open Lean (Json)
open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime
open Alaya.Runtime.Driver (Runtime Limits Stop)

def emitLines (lines : Array String) : Result Unit :=
  lines.forM Cli.emit

/-- Opens the data directory for one command (`Data.with`); one that is not there is said to be
made by `new`. -/
def withData (path : System.FilePath) (f : Data → Result α) (write := false) : Result α := do
  if !(← Result.fromIO Error.storage (path / "entries").isDir) then
    throw <| .input s!"no data directory at {path}: `alaya new --data {path}` creates one"
  Data.with path f (write := write)

/-- `--data`, which every command but `config` takes, or `ALAYA_DATA`: there is no default, so a command run
from the wrong directory cannot quietly start a new data directory. -/
def dataDir : Cli.Spec System.FilePath :=
  (Cli.flag? "data" (.path "DIR") "the data directory" (env? := some "ALAYA_DATA")).required
    "no data directory: give --data DIR, or set ALAYA_DATA"

def entryArg (help : String := "an entry: its hash, any unambiguous prefix, or PREFIX:N for position N of its log") :
    Cli.Spec String :=
  Cli.arg "ENTRY" .string help

/-- A new entry, as the commands that append print it: a line that begins with its full name,
or one JSON object. -/
def entryRecord (out : Cli.Out) (appended : Appended) : Result Unit :=
  let { hash, position, entry } := appended
  out.record (.mkObj [("entry", hash.hex), ("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
      ("position", position), ("frame", (entry.event.frame?.map Frame.toJson).getD .null),
      ("summary", Render.eventSummary entry.event), ("event", eventToJson entry.event),
      ("elapsed_ms", entry.elapsedMs)])
    (Render.entryLine hash position entry.event)

/-- Exit status of `resume` when the last call failed. -/
def exitFail : UInt32 := 1

/-- Exit status when a call waits for a person: a reply, or a notice. -/
def exitWaiting : UInt32 := 3

/-- Exit status when a run paused at a limit of this invocation: `resume` goes on from there. -/
def exitPaused : UInt32 := 4

/-! ## Creating a run -/

/-- `PROGRAM`: a program the catalog has. -/
def programName (catalog : Catalog) : Cli.Value String :=
  .enum "PROGRAM" (catalog.programs.map fun d => (d.name, d.name)).toList

/-- `--set PATH=VALUE` and `--set-file PATH=FILE`: the fields of a program's configuration over
its defaults, in the order given. -/
def overrides : Cli.Spec (Array Settings.Given) :=
  Cli.interleaved #[
    ("set", ⟨"PATH=VALUE", fun text => Settings.Given.value <$> Settings.parse text⟩,
      "a field over the program's defaults, in order, e.g. model=gpt-6-luna, model.params.reasoning_effort=high, task='Fix the bug'"),
    ("set-file", ⟨"PATH=FILE", Settings.parseFile⟩,
      "a field set to a file's text, as it is, in order with --set, e.g. task=TASK.md; stdin is /dev/stdin")]

/-- What `new` takes: a project, or an image whose workdir the workspace is copied from. -/
structure NewArgs where
  data : System.FilePath
  source : Sum System.FilePath (String × String)

def NewArgs.cli : Cli.Spec NewArgs :=
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

/-- Creates a run: its root, the workspace, and its call, the session, which waits for a program
to be called once it is resumed. -/
def newRun (catalog : Catalog) (a : NewArgs) (out : Cli.Out) : Result UInt32 := do
  let source := match a.source with
    | .inl project => .directory project
    | .inr (image, workdir) => .image image workdir
  for appended in ← Data.create a.data source (Session.scope catalog) Session.call do
    entryRecord out appended
  pure 0

/-! ## What a person appends -/

/-- Appends with `append` in the data directory at `path`, and prints the new entry. -/
def appendIn (path : System.FilePath) (out : Cli.Out) (append : Data → Result Appended) :
    Result UInt32 :=
  withData path (write := true) fun data => do
    entryRecord out (← append data)
    pure 0

/-! ## Calling a program -/

structure CallArgs where
  data : System.FilePath
  entry : String
  program : String
  image : String
  workdir : String
  settings : Array Settings.Given

def CallArgs.cli (catalog : Catalog) : Cli.Spec CallArgs :=
  CallArgs.mk
    <$> dataDir
    <*> entryArg "the entry to call the program after; any unambiguous prefix, or PREFIX:N"
    <*> Cli.arg "PROGRAM" (programName catalog) s!"the program: {catalog.programNames}"
    <*> Cli.flag "image" (.string "IMAGE") "the container image the call's commands run in, pinned by digest"
    <*> Cli.flagD "workdir" (.string "PATH") Executor.Docker.defaultWorkdir
      "where the workspace is mounted in the image"
    <*> overrides

/-- Appends a call of a program after an entry, where no call is running: its configuration,
complete, with its image pinned. `resume` then drives it. -/
def callRun (catalog : Catalog) (a : CallArgs) (out : Cli.Out) : Result UInt32 := do
  -- A configuration that is wrong is said so before anything is appended.
  let config ← catalog.resolve a.program (← a.settings.mapM (·.read))
  if let .error problem := catalog.check { name := a.program, arguments := config } then
    throw <| .input problem
  appendIn a.data out fun data => do
    let environment ← Environment.pinned a.image a.workdir
    data.call (Session.scope catalog) a.entry
      { name := a.program, arguments := config, environment? := some environment.toJson }
      (admit := Session.admitsCall)

/-! ## Driving a run -/

/-- `--provider NAME`: who serves the models of the run's calls, for this invocation. -/
def providerName (catalog : Catalog) : Cli.Value Provider.Provider :=
  .enum "NAME" (catalog.providers.map fun p => (p.name, p)).toList

structure ResumeArgs where
  data : System.FilePath
  entry : String
  provider? : Option Provider.Provider
  endpoint? : Option Provider.Dgx.Endpoint
  options : Executor.Docker.RunOptions
  samples : Nat
  budget : Nat

def ResumeArgs.cli (catalog : Catalog) : Cli.Spec ResumeArgs :=
  ResumeArgs.mk
    <$> dataDir
    <*> entryArg "the entry to go on from; any unambiguous prefix, or PREFIX:N"
    <*> Cli.flag? "provider" (providerName catalog)
      s!"who serves the models: {catalog.providerNames}; needed only when a call samples"
    <*> Provider.endpointCli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "samples" .nat 0 "responses this invocation may sample; 0 is no limit"
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed along the log, after which no operation starts; 0 is no limit"

/-- Whether the driver stopped where the session waits for a person to call a program. -/
def idle : Stop → Bool
  | .waits frame none => frame == Session.frame
  | _ => false

/-- How a driver stopped, as the last object of `--json`: its status, and, when no call runs,
how the last call ended. -/
def stopJson (last : Hash) (log : Log Agent) (stop : Stop) : Json :=
  if idle stop then match lastCall? log with
    | some (call, some ended) =>
      .mkObj ([("entry", (last.hex : Json)), ("call", (call.name : Json))] ++ match ended with
        | .returned value => [("status", "done"), ("value", value)]
        | .failed failure => [("status", "failed"), ("kind", .str failure.kind), ("error", .str failure.reason)]
        | .stopped reason => [("status", "stopped"), ("reason", .str reason)])
    | _ => .mkObj [("entry", last.hex), ("status", "idle")]
  else match stop with
  | .ended (.ok value) => .mkObj [("entry", last.hex), ("status", "ended"), ("value", value)]
  | .ended (.error failure) =>
    .mkObj [("entry", last.hex), ("status", "ended"), ("kind", failure.kind), ("error", .str failure.reason)]
  | .waits frame question? =>
    .mkObj [("entry", last.hex), ("status", "waits"), ("frame", frame.toJson),
      ("question", question?.map (·.toJson) |>.getD .null)]
  | .paused reason => .mkObj [("entry", last.hex), ("status", "paused"), ("reason", .str reason)]

/-- How a driver stopped, for a person. -/
def stopNote (last : Hash) (log : Log Agent) (stop : Stop) : String :=
  if idle stop then match lastCall? log with
    | some (call, some ended) => s!"{call.name}: {Render.endingSummary ended}"
    | _ => s!"waits for a call: `alaya call {last.hex.take 12} PROGRAM …`"
  else match stop with
  | .ended (.ok value) => s!"the run is over: {Render.valueSummary value}"
  | .ended (.error failure) => s!"the run is over: {failure.render}"
  | .waits _ (some question) =>
    s!"waits for a reply to: {question.text}\nreply with `alaya reply {last.hex.take 12} ...`"
  | .waits _ none => s!"waits for a notice: `alaya tell {last.hex.take 12} TEXT`"
  | .paused reason => s!"paused: {reason}; `alaya resume {last.hex.take 12}` goes on"

/-- Prints how a driver stopped: the last object with `--json`, else a line on stderr, after
the entries on stdout. -/
def reportStop (out : Cli.Out) (last : Hash) (log : Log Agent) (stop : Stop) : Result Unit :=
  if out.json then out.record (stopJson last log stop) "" else
    Result.fromIO Error.storage do
      (← IO.getStdout).flush
      (← IO.getStderr).putStrLn (stopNote last log stop)

/-- The exit status of a run that calls nothing: 1 when its last call failed, 0 otherwise. What
a call returned is its value, which `resume --json` and `show` give: a grader's verdict among them. -/
def idleStatus (log : Log Agent) : UInt32 :=
  match lastCall? log with
  | some (_, some (.failed _)) => exitFail
  | _ => 0

def resumeRun (catalog : Catalog) (a : ResumeArgs) (out : Cli.Out) : Result UInt32 := do
  if a.provider?.isNone && a.endpoint?.isSome then
    throw <| .input "--url and --port address a provider: name it with --provider"
  let baseUrl? ← match a.endpoint?, a.provider?.map (·.name) with
    | none, _ => pure none
    | some endpoint, some "dgx" => pure (some endpoint.baseUrl)
    | some _, other => throw <| .input s!"--url and --port address a dgx server, not {other.getD "none"}"
  withData a.data (write := true) fun data => do
    let limits : Limits := {
      samples? := if a.samples == 0 then none else some a.samples
      budgetMs? := if a.budget == 0 then none else some (a.budget * 1000) }
    data.withRuntime a.options a.provider? baseUrl? (unserved := .input "a call samples its model: name a --provider") fun rt => do
      let (last, stop, log) ← data.resume (Session.scope catalog) a.entry rt limits (entryRecord out)
      reportStop out last log stop
      pure <| if idle stop then idleStatus log else match stop with
        | .ended (.ok _) => 0
        | .ended (.error _) => exitFail
        | .waits .. => exitWaiting
        | .paused _ => exitPaused

def tellRun (catalog : Catalog) (data : System.FilePath) (reference text : String) (out : Cli.Out) : Result UInt32 :=
  appendIn data out (·.tell (Session.scope catalog) reference text (admit := Session.admitsNotice))

/-- A change to the workspace, and then a message that says what changed, with what the person
adds: the change itself reaches no read, so the message is how the call running hears of it. -/
def commitRun (catalog : Catalog) (data : System.FilePath) (reference : String) (dir : System.FilePath)
    (message? : Option String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data => do
    let changed ← tryCatch (data.commit (Session.scope catalog) reference dir (admit := Session.admitsNotice)) fun
      | .input message => throw <| .input s!"{message}: to send a message alone, use `tell`"
      | error => throw error
    entryRecord out changed
    let summary := match changed.entry.event with
      | .arrived (.changed _ summary) => summary
      | _ => ""
    let lines := (summary.splitOn "\n").map ("  " ++ ·) ++ (message?.toList)
    let text := "\n".intercalate ("I changed the workspace:" :: lines)
    entryRecord out (← data.tell (Session.scope catalog) changed.hash.hex text)
    pure 0

/-- A person's reply: the answer's text, or `none` when they cannot answer. -/
def replyAnswer : Cli.Spec (Option String) :=
  (Prod.mk
    <$> Cli.arg? "TEXT" .string "the answer, verbatim; put it after -- if it may begin with -"
    <*> Cli.switch "unavailable" "record that the person cannot answer, instead of an answer").refine
    fun
    | (some text, false) => .ok (some text)
    | (none, true) => .ok none
    | (some _, true) => .error "give the answer or --unavailable, not both"
    | (none, false) => .error "give the answer as TEXT, or --unavailable"

def replyRun (catalog : Catalog) (data : System.FilePath) (reference : String) (answer? : Option String)
    (out : Cli.Out) : Result UInt32 :=
  appendIn data out (·.reply (Session.scope catalog) reference answer?)

/-- Appends a person's comment after an entry. -/
def commentRun (data : System.FilePath) (reference text : String) (out : Cli.Out) : Result UInt32 :=
  appendIn data out (·.comment reference text)

/-- Breaks the call open in `frame?`, or, by default, the session's call running after an entry. -/
def stopRun (catalog : Catalog) (data : System.FilePath) (reference : String) (frame? : Option String) (reason : String)
    (out : Cli.Out) : Result UInt32 :=
  appendIn data out fun data => do
    let frame ← match frame? with
      | some text => Result.fromExcept Error.input (Frame.parse text)
      | none => Session.callToStop (← data.visitAt (Session.scope catalog) reference).stack
    data.stop (Session.scope catalog) reference frame reason

/-! ## Reading the forest -/

def treeRun (catalog : Catalog) (data : System.FilePath) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let forest ← data.store.forest
    let rows ← Render.rows data.store forest (Session.scope catalog)
    if out.json then
      for row in rows do
        out.record (.mkObj [("entry", row.hash.hex), ("parent", row.parent?.map (Json.str ·.hex) |>.getD .null),
          ("position", row.position), ("summary", row.summary),
          ("status", row.status?.map Json.str |>.getD .null)]) ""
    else emitLines (Render.treeLines rows)
    pure 0

def waitingRun (catalog : Catalog) (data : System.FilePath) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    for (hash, frame, question) in ← data.waiting (Session.scope catalog) do
      out.record (.mkObj [("entry", hash.hex), ("frame", frame.toJson), ("question", question.text),
          ("question_type", question.form.name),
          ("options", .arr (question.form.options.map Json.str))])
        s!"{hash.hex}  {question.render.quote}"
    pure 0

/-- What the run does next after a visit, for a person. -/
def statusOf (visit : Visit) : String :=
  (visit.next?.map (Render.nextSummary visit.question? (visit.last?.bind (·.2)))).getD "the run cannot be read"

def logRun (catalog : Catalog) (data : System.FilePath) (reference : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let visits ← data.visitsAt (Session.scope catalog) reference
    for visit in visits do
      let entry := visit.entry
      let frame := (entry.event.frame?.map Frame.render).getD "-"
      out.record (.mkObj [("entry", visit.hash.hex), ("position", visit.position),
          ("frame", (entry.event.frame?.map Frame.toJson).getD .null),
          ("event", eventToJson entry.event), ("elapsed_ms", entry.elapsedMs)])
        s!"{visit.position}  {Render.short visit.hash}  {frame}  {Render.eventSummary entry.event}  ({Render.seconds visit.spentMs})"
    let some last := visits.back? | throw <| .storage "an empty log"
    let status := statusOf last
    out.record (.mkObj [("next", status)]) status
    pure 0

def showRun (catalog : Catalog) (data : System.FilePath) (reference : String) (request : Bool) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
    let visit ← data.visitAt (Session.scope catalog) reference
    let { hash, entry, position, spentMs := spent, usage, stack, .. } := visit
    let asked? := match visit.asked? with
      | some { op := .sample _ request, .. } => some request
      | _ => none
    let after := statusOf visit
    let requestJson := if request then (asked?.map (·.toJson)).getD .null else .null
    if out.json then
      out.record (.mkObj [("entry", hash.hex), ("parent", entry.parent?.map (Json.str ·.hex) |>.getD .null),
        ("position", position), ("event", eventToJson entry.event), ("elapsed_ms", entry.elapsedMs),
        ("run_time_ms", spent), ("run_usage", usage.toStored),
        ("workspace", visit.workspace?.map (Json.str ·.hex) |>.getD .null),
        ("calls", .arr (stack.map fun call => .mkObj [("frame", call.frame.toJson),
          ("routine", call.call.toJson), ("position", call.position)])),
        ("next", after), ("request", requestJson)]) ""
      return 0
    let mut lines : Array String := #[
      s!"entry      {hash.hex}",
      s!"parent     {(entry.parent?.map (·.hex)).getD "none: a root"}",
      s!"position   {position}, frame {(entry.event.frame?.map Frame.render).getD "-"}",
      s!"time       {Render.seconds entry.elapsedMs}; the run {Render.seconds spent}",
      s!"workspace  {(visit.workspace?.map (·.hex)).getD "none"}"]
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

def lsRun (data : System.FilePath) (reference : String) (path? : Option String) (out : Cli.Out) :
    Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← data.entriesAt reference
    let snapshot ← Data.snapshotOf entries
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
def catRun (data : System.FilePath) (reference path : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← data.entriesAt reference
    let snapshot ← Data.snapshotOf entries
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

def checkoutRun (data : System.FilePath) (reference : String) (dir : System.FilePath)
    (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let (_, hash, entries) ← data.entriesAt reference
    let snapshot ← Data.snapshotOf entries
    Workspaces.refuseOverlap "check out into" dir #[data.path]
    data.workspaces.materialize snapshot dir
    out.record (.mkObj [("entry", hash.hex), ("snapshot", snapshot.hex), ("directory", dir.toString)])
      s!"checked out {snapshot.hex} into {dir}"
    pure 0

def diffRun (data : System.FilePath) (a b : String) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let lines := (← data.changes a b).map (·.line)
    if out.json then out.record (.mkObj [("changes", .arr (lines.map Json.str))]) ""
    else emitLines lines
    pure 0

def htmlRun (catalog : Catalog) (data : System.FilePath) (file : System.FilePath) (hide : Array String)
    (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    -- Each --hide may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := hide.foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    let forest ← data.store.forest
    if forest.entries.isEmpty then
      throw <| .input "nothing to report: the data directory holds no runs"
    let page ← Html.report data.store data.workspaces forest s!"alaya {data.path}" hidden (Session.scope catalog)
    Result.fromIO Error.storage (IO.FS.writeFile file page)
    out.record (.mkObj [("file", file.toString), ("bytes", page.length)])
      s!"wrote {file} ({page.length} bytes)"
    pure 0

def rmRun (data : System.FilePath) (reference : String) (out : Cli.Out) : Result UInt32 :=
  withData data (write := true) fun data => do
    let removed ← data.remove reference
    out.record (.mkObj [("removed", removed)]) s!"removed {removed} entries"
    pure 0

/-! ## Rebasing a run -/

/-- Copies the run that ends at an entry into a new data directory, `target`, as the current
version of its agent makes it, with `settings` over its configuration (`Alaya.App.Rebase`). The source is only
read. The new directory is written beside `target` under another name and renamed into place
once complete, so a failure leaves none. -/
def rebaseRun (catalog : Catalog) (data : System.FilePath) (reference : String) (target : System.FilePath)
    (settings : Array Settings.Given) (out : Cli.Out) : Result UInt32 :=
  withData data fun data => do
    let settings ← settings.mapM (·.read)
    let (_, tip, entries) ← data.entriesAt reference
    let log ← Rebase.reconfigure catalog (entries.map (·.event)) settings
    let rebased := rebase (Session.scope catalog) log
    let summary := Rebase.summary rebased log.size
    let source ← Result.fromIO Error.storage (IO.FS.realPath data.path)
    let written ← data.rebase entries rebased target s!"rebased from {tip.hex} in {source}: {summary}"
    for appended in written do entryRecord out appended
    let some last := written.back? | throw <| .storage "a rebase wrote no entry"
    if out.json then
      out.record (.mkObj [("entry", last.hash.hex), ("data", target.toString),
        ("held", (rebased.divergence?.map (·.position)).getD log.size), ("total", log.size),
        ("divergence", match rebased.divergence? with
          | none => .null
          | some divergence => .mkObj [("position", divergence.position),
              ("found", eventToJson divergence.found),
              ("expected", Rebase.expectedSummary divergence.expected)]),
        ("dropped", .arr (rebased.dropped.map fun (position, event) =>
          .mkObj [("position", position), ("event", eventToJson event)]))]) ""
    else Result.fromIO Error.storage do
      (← IO.getStdout).flush
      let stderr ← IO.getStderr
      stderr.putStrLn summary
      for line in Rebase.droppedLines rebased do stderr.putStrLn line
      stderr.putStrLn s!"`alaya resume {Render.short last.hash} --data {target}` goes on"
    pure 0

/-! ## Configuration -/

def providerJson (provider : Provider.Provider) : Json :=
  .mkObj [("name", provider.name), ("base_url", provider.baseUrl),
    ("base_url_var", provider.baseUrlVar?.map Json.str |>.getD .null),
    ("key_var", provider.keyVar), ("any_model", provider.anyModel),
    ("routes", .arr (provider.routes.toArray.map fun (model, route) =>
      .mkObj [("model", model), ("name", route.name)]))]

def providerText (provider : Provider.Provider) : String :=
  let serves := if !provider.anyModel then "only these models:"
    else if provider.routes.isEmpty then "any model, under its own name"
    else "any model under its own name, and these under others:"
  let routes := provider.routes.map fun (model, route) => s!"\n  {model} as {route.name}"
  s!"provider {provider.name}: {provider.baseUrl}, key {provider.keyVar}; serves {serves}" ++ String.join routes

/-- The programs, models and providers with their defaults, or the configuration `call` would
record for a program with these settings. -/
def configRun (catalog : Catalog) (program? : Option String) (settings : Array Settings.Given)
    (out : Cli.Out) : Result UInt32 := do
  if program?.isNone && !settings.isEmpty then
    throw <| .input "--set needs --program NAME, the program it changes"
  let settings ← settings.mapM (·.read)
  if program?.isNone then
    for definition in catalog.programs do
      let config ← catalog.resolve definition.name #[]
      out.record (.mkObj [("program", definition.name), ("config", config)])
        s!"program {definition.name} {config.pretty}"
    for spec in catalog.models do
      out.record (.mkObj [("model", spec.toJson)]) s!"model {spec.toJson.pretty}"
    for provider in catalog.providers do
      out.record (.mkObj [("provider", providerJson provider)]) (providerText provider)
    return 0
  let name := program?.getD ""
  let config ← catalog.resolve name settings
  out.record (.mkObj [("program", name), ("config", config)]) config.pretty
  pure 0

/-! ## The table -/

/-- Alaya's commands, over `catalog`. -/
def all (catalog : Catalog) : Array Cli.Command := #[
  { name := "new"
    summary := "Create a run: its root, the workspace, where it waits for a program to be called."
    examples := #["alaya new ./project", "alaya new --image swebench/sweb.eval.django-11099:latest --workdir /testbed"]
    spec := (newRun catalog) <$> NewArgs.cli },
  { name := "call"
    summary := "Call a program after an entry where no call runs: an agent, or a grader; resume drives it."
    examples := #[
      "alaya call 4f2c8b mini-swe --set model=gpt-oss-120b --set task='Add a hello.py that prints hello' " ++
        "--image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya call 4f2c8b mini-vero --set model=deepseek-v4.1-flash --set mode=codeproof --set-file task=TASK.md " ++
        "--image my-task:1 --workdir /testbed",
      "alaya call 9a11c0 grader --image my-grader:1 --set command='python3 /grader/grade.py'"]
    spec := (callRun catalog) <$> (CallArgs.cli catalog) },
  { name := "config"
    summary := "The programs, models and providers, or the configuration call would record; creates nothing."
    examples := #["alaya config",
      "alaya config --program mini-vero --set model=deepseek-v4.1-flash --set model.params.reasoning_effort=high --set mode=codeproof"]
    spec := (configRun catalog) <$> Cli.flag? "program" (programName catalog) s!"the program: {catalog.programNames}"
      <*> overrides },
  { name := "resume"
    summary := "Drive a run on from an entry until no call runs, a call waits for a person, or a limit is reached."
    examples := #["alaya resume 4f2c8b --provider apiyi --time-budget 3600",
      "alaya resume 4f2c8b --provider dgx --url spark.local:9000 --samples 1",
      "alaya resume 9a11c0"]
    spec := (resumeRun catalog) <$> (ResumeArgs.cli catalog) },
  { name := "tell"
    summary := "Append a person's message after an entry; the call running reads it at its next read of the inbox."
    examples := #["alaya tell 4f2c8b 'keep the old API'"]
    spec := (tellRun catalog) <$> dataDir <*> entryArg <*> Cli.arg "TEXT" .string "the message" },
  { name := "commit"
    summary := "Append a change to the workspace after an entry, the files of DIR, and a message that says what changed."
    examples := #["alaya commit 4f2c8b ./fix --message 'I fixed the fixture; the parser bug is still yours.'"]
    spec := (commitRun catalog) <$> dataDir <*> entryArg <*> Cli.arg "DIR" .path "the edited workspace"
      <*> Cli.flag? "message" .string "what to tell the call running of the change, after the list of what changed" },
  { name := "reply"
    summary := "Answer the question a log waits on, or record that the person cannot."
    examples := #["alaya reply c61754 -- 'yes, keep it'", "alaya reply c61754 --unavailable"]
    spec := (replyRun catalog) <$> dataDir <*> entryArg "the entry whose log waits for a reply" <*> replyAnswer },
  { name := "stop"
    summary := "Stop the call running after an entry, or the call open in --frame, and every call inside it."
    examples := #["alaya stop 4f2c8b:120 --reason 'enough'", "alaya stop 4f2c8b:120 --frame session/mini-swe/subagent"]
    spec := (stopRun catalog) <$> dataDir <*> entryArg
      <*> Cli.flag? "frame" (.string "FRAME") "the frame of the call to stop; by default the program the session runs"
      <*> Cli.flagD "reason" .string "stopped from outside" "why, as the log keeps it" },
  { name := "comment"
    summary := "Append a comment after an entry: for whoever reads the log, and ignored by everything else."
    examples := #["alaya comment 4f2c8b:140 'the parser goes wrong here'"]
    spec := commentRun <$> dataDir <*> entryArg <*> Cli.arg "TEXT" .string "the comment" },
  { name := "waiting"
    summary := "List every log that waits for a reply, with its question."
    examples := #["alaya waiting --json"]
    spec := (waitingRun catalog) <$> dataDir },
  { name := "tree"
    summary := "Show the forest: each run, its stretches of entries, its forks, and how each log ends."
    spec := (treeRun catalog) <$> dataDir },
  { name := "log"
    summary := "The log that ends at an entry, one event a line, and what the run does next."
    examples := #["alaya log 4f2c8b", "alaya log 4f2c8b --json"]
    spec := (logRun catalog) <$> dataDir <*> entryArg },
  { name := "show"
    summary := "One entry in full: its event, time, tokens, open calls, and with --request the request it answers."
    examples := #["alaya show 4f2c8b:40 --request"]
    spec := (showRun catalog) <$> dataDir <*> entryArg
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
    spec := (htmlRun catalog) <$> dataDir
      <*> Cli.arg "FILE" .path "where to write the page"
      <*> Cli.repeated "hide" (.string "DIRS") "directories to leave out of the page, comma-separated" },
  { name := "rm"
    summary := "Delete an entry, everything after it, and the snapshots only they named."
    spec := rmRun <$> dataDir <*> entryArg "the first entry to delete" },
  { name := "rebase"
    summary := "Copy the log at an entry into a new data directory, up to where a revised version of its agent differs, to go on with it there."
    examples := #["alaya rebase 4f2c8b ../v2", "alaya rebase 4f2c8b ../v2 --set context_reserve=16000"]
    spec := (rebaseRun catalog) <$> dataDir <*> entryArg "the entry whose log is rebased"
      <*> Cli.arg "DIR" .path "the new data directory, which must not exist"
      <*> overrides }]


/-- An application: `name`, Alaya's commands over `catalog`, and `extra`, commands of its own. -/
def app (name : String) (catalog : Catalog) (extra : Array Cli.Command := #[])
    (summary := "Run agents as programs over a log: call them, drive, fork at any entry, intervene, and grade any point.") :
    Cli.App where
  name
  summary
  commands := all catalog ++ extra

end Alaya.App.Commands
