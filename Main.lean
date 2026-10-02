import Alaya

/-! `alaya` — the command line over a trajectory tree. See
`docs/cli.md` for the commands. -/

open Alaya
open Alaya.Agent (Outcome)
open Alaya.Trajectory
open Alaya.Driver

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM emit

/-- The data directory (`--data`, or `ALAYA_DATA`); its layout is in `docs/trajectory-schema.md`
§5. A command opens it with `withData`, which gives the command a scratch directory of its own. -/
private structure DataDir where
  path : System.FilePath
  store : Store
  workspaces : Workspaces
  /-- This command's scratch, `tmp/<id>`: its work directory, a grader's checkout, restic's
  restores. Nothing in it lasts past the command, and no other command shares it. -/
  scratch : System.FilePath

private def DataDir.cache (data : DataDir) : System.FilePath := data.path / "cache"

/-- Opens the data directory at `path` for one command and runs `f` on it. Only `root` creates
one (`create`): any other command needs one that exists, so a wrong path is an error rather than
an empty forest. A command that writes (`write`) holds the directory's lock throughout, so it is
the only writer, and is refused at once when another has it; one that only reads takes no lock.
The command's scratch directory is removed when it ends, however it ends. -/
private def withData (path : System.FilePath) (f : DataDir → Result α) (write := false)
    (create := false) : Result α := do
  if !create && !(← Result.fromIO Error.storage (path / "states").isDir) then
    throw <| .input s!"no data directory at {path}: `alaya root --data {path}` creates one"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  let lock? ← if write then some <$> Lock.acquire path else pure none
  try
    let store ← Store.create (path / "states")
    let id := s!"{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}"
    let scratch := path / "tmp" / id
    Result.fromIO Error.storage (IO.FS.createDirAll scratch)
    try
      -- The states and the model cache are as much the run as the repository is.
      let workspaces ← Workspaces.Restic.open (path / "restic") (scratch / "restic")
        (keep := #[store.dir, path / "cache"])
      f { path, store, workspaces, scratch }
    finally
      Workspaces.makeWritable scratch
      Result.fromIO Error.storage (IO.FS.removeDirAll scratch)
  finally
    if let some lock := lock? then lock.release

/-- `--data`, which every command takes, or `ALAYA_DATA`: there is no default, so a command run
from the wrong directory cannot quietly start a new data directory. -/
private def dataDir : Cli.Spec System.FilePath :=
  (Cli.flag? "data" (.path "DIR") "the data directory" (env? := some "ALAYA_DATA")).required
    "no data directory: give --data DIR, or set ALAYA_DATA"

/-- The work directory, in the command's scratch: not configurable, so no path a user names can
be destroyed by a checkout, and the store and the cache are out of its reach by construction. -/
private structure WorkDir where
  path : System.FilePath

private def openWork (data : DataDir) : Result WorkDir := do
  let path := data.scratch / "work"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  pure { path }

/-- Where a run's commands go: the image and workdir the trajectory recorded, pulled by its
digest when it is missing, with the branch's command outputs mounted read-only. -/
private def executorFor (run : Executor.Docker.RunOptions) (root : Root)
    (outputs : System.FilePath) : Result Executor := do
  let settings ← Executor.Docker.settingsOf run root.image root.workdir
  let settings := { settings with
    mounts := #[{ host := outputs, container := Agent.outputsDir, readOnly := true }] }
  settings.ensurePresent
  Executor.Docker.executor settings

/-- The agent of an existing run, for its model: what its root recorded. -/
private def recordedAgent (store : Store) (hash : Hash) : Result Agent.Agent := do
  Agent.Catalog.fromJson (← agentOf store hash) (← Models.fromJson (← modelOf store hash))

/-- `--provider NAME`: who serves the run's model, for this invocation. -/
private def providerName : Cli.Value Provider.Provider :=
  .enum "NAME" (Provider.all.map fun p => (p.name, p)).toList

/-- What `resume` takes: who serves the model, and this invocation's limits. The agent, the
model, the image and the workdir are the root's. -/
private structure ResumeArgs where
  data : System.FilePath
  state : String
  provider : Provider.Provider
  endpoint? : Option Provider.Dgx.Endpoint
  run : Executor.Docker.RunOptions
  /-- Seconds of run time, not recorded; 0 is no limit. -/
  budget : Nat
  /-- Steps this invocation may take; 0 is no limit. -/
  steps : Nat

private def ResumeArgs.cli : Cli.Spec ResumeArgs :=
  ResumeArgs.mk
    <$> dataDir
    <*> Cli.arg "HASH" .string "the state to continue from; any unambiguous prefix"
    <*> Cli.flag "provider" providerName s!"who serves the run's model: {Provider.names}"
    <*> Provider.endpointCli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed from the root, after which no step starts; 0 is no limit"
    <*> Cli.flagD "steps" .nat 0 "steps this invocation may take; 0 is no limit"

private def runtimeFor (data : DataDir) (work : WorkDir) (a : ResumeArgs) (start : Hash) :
    Result Runtime := do
  let spec ← recordedAgent data.store start
  let modelSpec ← Models.fromJson (← modelOf data.store start)
  let baseUrl? ← match a.endpoint?, a.provider.name with
    | none, _ => pure none
    | some endpoint, "dgx" => pure (some endpoint.baseUrl)
    | some _, other => throw <| .input s!"--url and --port address a dgx server, not {other}"
  let model ← buildModel modelSpec a.provider data.cache baseUrl?
  let outputsDir := data.scratch / "outputs"
  let executor ← executorFor a.run (← runOf data.store start) outputsDir
  pure { store := data.store, workspaces := data.workspaces, workDir := work.path, outputsDir
         executor, model, agent := spec }

/-- Empties the work directory. Both a checkout and an extraction from an image need it to start
clean, and it is the one place holding nothing durable. -/
private def clearWork (data : DataDir) : Result WorkDir := do
  let work ← openWork data
  Workspaces.makeWritable work.path
  Result.fromIO Error.storage do
    IO.FS.removeDirAll work.path
    IO.FS.createDirAll work.path
  pure work

/-- The directory a new trajectory snapshots: a host `PROJECT`, or else the image's own
`workdir`, copied out — task images usually carry the project already, at the path their tools
expect. An extraction lands in the work directory, which is disposable by construction. -/
private def rootProject (data : DataDir) (settings : Executor.Docker.Settings)
    (project? : Option String) : Result System.FilePath := do
  match project? with
  | some project => pure project
  | none =>
    let work ← clearWork data
    Executor.Docker.copyOut settings settings.workdir work.path
    pure work.path

/-- Exit status when a run stopped at a question rather than an outcome. -/
private def exitWaiting : UInt32 := 3

/-- Exit status when a run stopped at a limit of this invocation, its time budget or its steps:
it has not ended, and a later `resume` continues it. -/
private def exitStopped : UInt32 := 4

/-- What every command that prints a state says of it with `--json`. -/
private def stateJson (hash : Hash) (state : State) : Lean.Json :=
  .mkObj [
    ("state", hash.hex), ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("kind", state.kind.toString),
    ("outcome", state.outcome?.map (fun o => Lean.Json.str o.status) |>.getD .null),
    ("reason", (state.outcome?.bind (·.reason?)).map Lean.Json.str |>.getD .null),
    ("question", state.question?.map (fun q => Lean.Json.str q.text) |>.getD .null),
    ("question_type", state.question?.map (fun q => Lean.Json.str q.form.name) |>.getD .null),
    ("options", state.question?.map (fun q => Lean.Json.arr (q.form.options.map Lean.Json.str)) |>.getD .null)]

/-- A state a command created: the hash with the outcome or the question it stopped at, or one
JSON object with `--json`. -/
private def stateLine (data : DataDir) (out : Cli.Out) (child : Hash) : Result Unit := do
  let state ← getState data.store child
  let mark := match state.outcome?, state.question? with
    | some o, _ => s!"  [{o.status}]"
    | none, some q => s!"  ask  {q.render.quote}  [Waiting]"
    | none, none => ""
  out.record (stateJson child state) s!"{child.hex}{mark}"

/-- Readable lines, or one JSON object with `--json`. -/
private def report (out : Cli.Out) (json : Lean.Json) (lines : Array String) : Result Unit :=
  if out.json then out.record json "" else emitLines lines

/-! ## Commands

Each command declares what it takes (`Alaya.Cli`), and `main` runs the table. -/

private def hashArg (help : String := "the state; any unambiguous prefix") : Cli.Spec String :=
  Cli.arg "HASH" .string help

/-! ### Creating and growing a run -/

/-- `--agent NAME`: an agent the catalog has. -/
private def agentName : Cli.Value String :=
  .enum "NAME" (Agent.Catalog.all.map fun d => (d.name, d.name)).toList

/-- `--model NAME`: a model the table has. -/
private def modelName : Cli.Value String :=
  .enum "NAME" (Models.all.map fun m => (m.name, m.name)).toList

/-- `--set agent.PATH=VALUE` or `--set model.PATH=VALUE`: one field over the defaults. -/
private def setting : Cli.Value Settings.Setting := ⟨"agent|model.PATH=VALUE", Settings.parse⟩

private def overrides : Cli.Spec (Array Settings.Setting) :=
  Cli.repeated "set" setting
    "a field over the agent's or the model's defaults, e.g. agent.mode=codeproof, model.params.reasoning_effort=high"

/-- What `root` takes. -/
private structure RootArgs where
  data : System.FilePath
  task : Cli.TextSource
  project? : Option System.FilePath
  image : String
  workdir : String
  agent : String
  model : String
  settings : Array Settings.Setting

private def RootArgs.cli : Cli.Spec RootArgs :=
  RootArgs.mk
    <$> dataDir
    <*> (Cli.text "task" "the task, saved verbatim in the opening log").required
      "a root needs a task: --task TEXT or --task-file FILE"
    <*> Cli.arg? "PROJECT" .path
      "the directory to snapshot; without it, the image's own workdir is copied out"
    <*> Cli.flag "image" (.string "IMAGE") "the container image every command runs in, pinned by digest"
    <*> Cli.flagD "workdir" (.string "PATH") Executor.Docker.defaultWorkdir
      "where the workspace is mounted in the image"
    <*> Cli.flag "agent" agentName s!"the agent: {Agent.Catalog.names}"
    <*> Cli.flag "model" modelName s!"the model: {Models.names}"
    <*> overrides

private def rootRun (a : RootArgs) (out : Cli.Out) : Result UInt32 := do
  -- A configuration that is wrong is said so before anything is created.
  let model ← Models.resolve a.model a.settings
  let spec ← Agent.Catalog.resolve a.agent a.settings model
  let task ← a.task.read "task"
  -- Before the data directory is created: inside the project it would become part of it.
  if let some project := a.project? then
    Workspaces.refuseOverlap "snapshot" project #[a.data]
  withData a.data (write := true) (create := true) fun data => do
    Executor.Docker.checkWorkdir a.workdir #[graderInput, Agent.outputsDir]
    let settings ← (← Executor.Docker.settingsOf {} a.image a.workdir).pin
    let uname ← Executor.Docker.uname settings
    let log := spec.initialLog task uname
    let project ← rootProject data settings (a.project?.map (·.toString))
    let hash ← createRoot data.store data.workspaces log project settings.image (some task) spec.config
      model.toJson a.workdir
    stateLine data out hash
    pure 0

private def resumeRun (a : ResumeArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let start ← resolve data.store a.state
    let rt ← runtimeFor data (← openWork data) a start
    try
      let limits : Limits := {
        budgetMs? := if a.budget == 0 then none else some (a.budget * 1000)
        steps? := if a.steps == 0 then none else some a.steps }
      let (stopped, stop) ← resume rt start limits (stateLine data out)
      match stop with
      | .outOfTime =>
        let used ← elapsedMs data.store stopped
        out.record (Lean.Json.mkObj [("state", stopped.hex), ("time_budget_spent", true),
            ("run_time_ms", used)])
          s!"time budget spent: {stopped.hex} has run {seconds used}; resume it to continue"
        pure exitStopped
      | .outOfSteps =>
        out.record (Lean.Json.mkObj [("state", stopped.hex), ("steps_spent", true),
            ("steps", a.steps)])
          s!"{a.steps} step(s) taken: resume {stopped.hex} to continue"
        pure exitStopped
      | .question _ => pure exitWaiting
      | .outcome o =>
        out.note s!"done: {o.status}"
        pure 0
    finally
      Result.fromIO Error.storage rt.executor.close

/-! ### Configuration -/

private def providerJson (provider : Provider.Provider) : Lean.Json :=
  .mkObj [("name", provider.name), ("base_url", provider.baseUrl),
    ("base_url_var", provider.baseUrlVar?.map Lean.Json.str |>.getD .null),
    ("key_var", provider.keyVar), ("any_model", provider.anyModel),
    ("routes", .arr (provider.routes.toArray.map fun (model, route) =>
      .mkObj [("model", model), ("name", route.name)]))]

private def providerText (provider : Provider.Provider) : String :=
  let serves := if !provider.anyModel then "only these models:"
    else if provider.routes.isEmpty then "any model, under its own name"
    else "any model under its own name, and these under others:"
  let routes := provider.routes.map fun (model, route) => s!"\n  {model} as {route.name}"
  s!"provider {provider.name}: {provider.baseUrl}, key {provider.keyVar}; serves {serves}" ++ String.join routes

/-- The agents, models and providers with their defaults, or the configuration `root` would
record for these flags. -/
private def configRun (agent? model? : Option String) (settings : Array Settings.Setting)
    (out : Cli.Out) : Result UInt32 := do
  for setting in settings do
    if setting.target == .agent && agent?.isNone then
      throw <| .input "--set agent.… needs --agent NAME, the agent it changes"
    if setting.target == .model && model?.isNone then
      throw <| .input "--set model.… needs --model NAME, the model it changes"
  if agent?.isNone && model?.isNone then
    for definition in Agent.Catalog.all do
      let agent ← Agent.Catalog.resolve definition.name #[]
      out.record (.mkObj [("agent", agent.config)]) s!"agent {agent.config.pretty}"
    for spec in Models.all do
      out.record (.mkObj [("model", spec.toJson)]) s!"model {spec.toJson.pretty}"
    for provider in Provider.all do
      out.record (.mkObj [("provider", providerJson provider)]) (providerText provider)
    return 0
  let mut fields : List (String × Lean.Json) := []
  if let some name := agent? then fields := fields ++ [("agent", (← Agent.Catalog.resolve name settings).config)]
  if let some name := model? then fields := fields ++ [("model", (← Models.resolve name settings).toJson)]
  out.record (.mkObj fields) (Lean.Json.mkObj fields).pretty
  pure 0

/-! ### Grading -/

private structure EvalArgs where
  data : System.FilePath
  state : String
  grader : String
  input? : Option System.FilePath
  graderImage? : Option String
  timeout : Nat
  user? : Option String

private def EvalArgs.cli : Cli.Spec EvalArgs :=
  EvalArgs.mk
    <$> dataDir
    <*> hashArg "the state to grade"
    <*> Cli.flag "grader" (.string "CMD")
      "a command that prints TAP on stdout, e.g. 'python3 /grader/grade.py'"
    <*> Cli.flag? "input" (.path "DIR") "trusted files, snapshotted and mounted read-only at /grader"
    <*> Cli.flag? "grader-image" (.string "IMAGE")
      "the image the grader runs in, pinned by digest; by default the trajectory's"
    <*> Cli.flagD "timeout" (.nat "S") 900 "seconds after which the grader is stopped, an error"
    <*> Cli.flag? "container-user" (.string "UID:GID")
      "the user the grader runs as; by default the host user on Linux, the image's own on macOS"

/-- Exits with the verdict: 0 pass, 1 fail, 2 error. A failure before a verdict is recorded
exits with its class's status, as for any command, all of them above the verdict's. -/
private def evalRun (a : EvalArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let target ← resolve data.store a.state
    let run ← runOf data.store target
    let settings ← Executor.Docker.settingsOf { user? := a.user? } run.image run.workdir
    let node ← evaluate data.store data.workspaces (data.scratch / "eval") target a.grader
      settings.user? a.input? a.graderImage? a.timeout
    let some e := (← getState data.store node).evaluation?
      | throw <| .storage "the evaluation was not recorded"
    out.record (Lean.Json.mkObj [("state", node.hex), ("status", e.status.toString),
        ("passed", e.score.1), ("total", e.score.2), ("reason", e.reason)])
      s!"{node.hex}  {e.verdict}  ({e.elapsedMs} ms)"
    if e.status == .error then out.note s!"error: {e.reason}"
    pure (match e.status with | .pass => 0 | .fail => 1 | .error => 2)

/-! ### A person in the tree -/

private def commitRun (data : System.FilePath) (state : String) (dir : System.FilePath)
    (message? : Option String) (out : Cli.Out) : Result UInt32 := do
  withData data (write := true) fun data => do
    let hash ← commit data.store data.workspaces (← resolve data.store state) dir (message?.getD "")
    stateLine data out hash
    pure 0

private def tellRun (data : System.FilePath) (state text : String) (out : Cli.Out) : Result UInt32 := do
  withData data (write := true) fun data => do
    stateLine data out (← tell data.store (← resolve data.store state) text)
    pure 0

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

private def replyRun (data : System.FilePath) (state : String) (answer? : Option String)
    (out : Cli.Out) : Result UInt32 := do
  withData data (write := true) fun data => do
    let waiting ← resolve data.store state
    stateLine data out (← match answer? with
      | some text => replyText data.store waiting text
      | none => reply data.store waiting .unavailable)
    pure 0

private def waitingRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    for (hash, q) in ← waiting data.store do
      out.record (Lean.Json.mkObj [
          ("state", hash.hex), ("question", q.text),
          ("question_type", q.form.name),
          ("options", .arr (q.form.options.map Lean.Json.str))])
        s!"{hash.hex}  {q.render.quote}"
    pure 0

/-! ### Reading a run -/

private def lsRun (data : System.FilePath) (state : String) (path? : Option String) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let snapshot := (← getState data.store hash).snapshot
    let path := path?.getD ""
    let entries ← data.workspaces.list snapshot path
    let lines := entries.map fun e =>
      let size := e.size.map toString |>.getD "-"
      let suffix := if e.kind == .directory then "/" else if e.kind == .symlink then "@" else ""
      s!"{"".pushn ' ' (10 - min 10 size.length)}{size}  {e.path}{suffix}"
    report out (Lean.Json.mkObj [("state", hash.hex), ("snapshot", snapshot.hex), ("path", path),
        ("entries", .arr (entries.map fun e => .mkObj [("name", e.name), ("path", e.path),
          ("kind", e.kind.toString), ("size", e.size.map (fun n => (n : Lean.Json)) |>.getD .null)]))])
      lines
    pure 0

/-- The file's bytes, exactly; with `--json`, a preview of any entry: UTF-8 text up to 1 MiB,
and otherwise what it is. -/
private def catRun (data : System.FilePath) (state path : String) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let snapshot := (← getState data.store hash).snapshot
    if out.json then
      let preview ← data.workspaces.preview snapshot path
      out.record (Lean.Json.mkObj [("state", hash.hex), ("snapshot", snapshot.hex), ("path", path),
        ("kind", preview.kind), ("content", preview.content?.map Lean.Json.str |>.getD .null),
        ("size", preview.size?.map (fun n => (n : Lean.Json)) |>.getD .null)]) ""
    else
      let bytes ← data.workspaces.read snapshot path
      Result.fromIO Error.storage do
        let stdout ← IO.getStdout
        stdout.write bytes
        stdout.flush
    pure 0

private def checkoutRun (data : System.FilePath) (state : String) (dir : System.FilePath)
    (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let state ← getState data.store hash
    data.workspaces.materialize state.snapshot dir
    out.record (Lean.Json.mkObj [("state", hash.hex), ("snapshot", state.snapshot.hex),
        ("directory", dir.toString)])
      s!"checked out {state.snapshot.hex} into {dir}"
    pure 0

private def treeRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    if out.json then
      for hash in ← allStates data.store do
        out.record (stateJson hash (← getState data.store hash)) ""
    else emitLines (← treeLines data.store)
    pure 0

private def showRun (data : System.FilePath) (state : String) (request : Bool) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let request? ← if request then
        some <$> stepRequest? data.store (← recordedAgent data.store hash) hash
      else pure none
    if out.json then
      let branch ← ancestors data.store hash
      let some (_, state) := branch.back? | throw <| .storage s!"no state {hash.hex}"
      let history := branch.map fun (h, s) => Lean.Json.mkObj [("state", h.hex),
        ("kind", s.kind.toString), ("events", .arr (s.appended.map eventToJson))]
      let json := state.toJson |>.setObjVal! "state" hash.hex
        |>.setObjVal! "run_time_ms" (← elapsedMs data.store hash)
        |>.setObjVal! "usage" (state.usage?.map (·.toStored) |>.getD .null)
        |>.setObjVal! "run_usage" (← runUsage data.store hash).toStored
        |>.setObjVal! "history" (.arr history)
      let json := match request? with
        | some request? => json.setObjVal! "request" (request?.map (·.toJson) |>.getD .null)
        | none => json
      out.record json ""
    else emitLines (← showLines data.store hash request?)
    pure 0

private def diffRun (data : System.FilePath) (a b : String) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    let a ← resolve data.store a
    let b ← resolve data.store b
    let lines ← diffLines data.store data.workspaces a b
    report out (Lean.Json.mkObj [("a", a.hex), ("b", b.hex), ("changes", .arr (lines.map Lean.Json.str))])
      lines
    pure 0

private def htmlRun (data : System.FilePath) (file : System.FilePath) (hide : Array String)
    (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    -- Each --hide may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := hide.foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    if (← allStates data.store).isEmpty then
      throw <| .input "nothing to report: the data directory holds no states"
    let page ← Html.report data.store data.workspaces s!"alaya {data.path}" (recordedAgent data.store) hidden
    Result.fromIO Error.storage (IO.FS.writeFile file page)
    out.record (Lean.Json.mkObj [("file", file.toString), ("bytes", page.length)])
      s!"wrote {file} ({page.length} bytes)"
    pure 0

private def rmRun (data : System.FilePath) (state : String) (out : Cli.Out) : Result UInt32 := do
  withData data (write := true) fun data => do
    let n ← removeSubtree data.store data.workspaces (← resolve data.store state)
    out.record (Lean.Json.mkObj [("removed", n)]) s!"removed {n} state(s)"
    pure 0

/-! ### The table -/

private def commands : Array Cli.Command := #[
  { name := "root"
    summary := "Create a root: the agent's opening prompts for a task, and a snapshot of the project."
    examples := #[
      "alaya root --task 'Add a hello.py that prints hello' ./project " ++
        "--agent mini-swe --model gpt-oss-120b --image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya root --task-file TASK.md --agent mini-vero --model deepseek-v4.1-flash --set agent.mode=codeproof " ++
        "--set model.params.reasoning_effort=high --image my-task:1 --workdir /testbed"]
    spec := rootRun <$> RootArgs.cli },
  { name := "config"
    summary := "The agents, models and providers, or the configuration root would record; creates nothing."
    examples := #["alaya config",
      "alaya config --agent mini-vero --model deepseek-v4.1-flash --set agent.mode=codeproof --set model.params.reasoning_effort=high"]
    spec := configRun <$> Cli.flag? "agent" agentName s!"the agent: {Agent.Catalog.names}"
      <*> Cli.flag? "model" modelName s!"the model: {Models.names}"
      <*> overrides },
  { name := "resume"
    summary := "Grow one continuation until the run ends, asks a question, or reaches a limit."
    examples := #["alaya resume 4f2c8b --provider apiyi --time-budget 3600 --json",
      "alaya resume 4f2c8b --provider dgx --url spark.local:9000 --steps 1"]
    spec := resumeRun <$> ResumeArgs.cli },
  { name := "eval"
    summary := "Grade a state: run a grader over a fresh copy and record its TAP verdict as a leaf."
    examples := #[
      "alaya eval e5a1c3 --input ./hidden --grader 'cp -R /grader/tests . && pytest -q -p tap --tap-stream'",
      "alaya eval e5a1c3 --grader-image my-grader:1 --input ./benchmark --grader 'grade-project /grader'"]
    spec := evalRun <$> EvalArgs.cli },
  { name := "commit"
    summary := "Record a hand-edited workspace as a child; the agent is told what changed."
    examples := #["alaya commit 4f2c8b ./fix --message 'I fixed the fixture; the parser bug is still yours.'"]
    spec := commitRun <$> dataDir <*> hashArg <*> Cli.arg "DIR" .path "the edited workspace"
      <*> Cli.flag? "message" .string "what to tell the agent of the change, after the list of what changed" },
  { name := "tell"
    summary := "Send the agent a message, as a child."
    examples := #["alaya tell 4f2c8b 'keep the old API'"]
    spec := tellRun <$> dataDir <*> hashArg <*> Cli.arg "TEXT" .string "the message" },
  { name := "reply"
    summary := "Answer the question a state is waiting on, or record that the person cannot."
    examples := #["alaya reply c61754 -- 'yes, keep it'", "alaya reply c61754 --unavailable"]
    spec := replyRun <$> dataDir <*> hashArg "the waiting state" <*> replyAnswer },
  { name := "waiting"
    summary := "List every unanswered question."
    examples := #["alaya waiting --json"]
    spec := waitingRun <$> dataDir },
  { name := "ls"
    summary := "List a directory of a state's workspace snapshot."
    examples := #["alaya ls 7b19d4 .report"]
    spec := lsRun <$> dataDir <*> hashArg
      <*> Cli.arg? "PATH" .string "a directory relative to the workspace; by default its root" },
  { name := "cat"
    summary := "Print a file from a state's workspace snapshot, byte for byte; --json previews any entry."
    examples := #["alaya cat 7b19d4 .report/summary.json"]
    spec := catRun <$> dataDir <*> hashArg <*> Cli.arg "PATH" .string "a file relative to the workspace" },
  { name := "checkout"
    summary := "Materialize a state's workspace into a directory."
    spec := checkoutRun <$> dataDir <*> hashArg <*> Cli.arg "DIR" .path "where to write the files" },
  { name := "tree"
    summary := "Show the whole forest; with --json, one object per state."
    spec := treeRun <$> dataDir },
  { name := "show"
    summary := "A state's metadata and log, and with --request the request its step was sampled from."
    examples := #["alaya show 4f2c8b --request"]
    spec := showRun <$> dataDir <*> hashArg
      <*> Cli.switch "request" "also print the request the state's step was sampled from, as the run's agent makes it" },
  { name := "diff"
    summary := "The workspace changes between two states, one path per line."
    spec := diffRun <$> dataDir <*> Cli.arg "A" .string "the earlier state"
      <*> Cli.arg "B" .string "the later state" },
  { name := "html"
    summary := "Write the forest as one self-contained page."
    examples := #["alaya html report.html --hide .venv --hide __pycache__,.pytest_cache"]
    spec := htmlRun <$> dataDir
      <*> Cli.arg "FILE" .path "where to write the page"
      <*> Cli.repeated "hide" (.string "DIRS") "directories to leave out of the page, comma-separated" },
  { name := "rm"
    summary := "Delete a subtree and the snapshots only it used."
    spec := rmRun <$> dataDir <*> hashArg "the root of the subtree to delete" }]

private def app : Cli.App where
  name := "alaya"
  summary := "Record agent runs as trees of content-addressed states: branch, replay, grade, intervene."
  commands := commands

/-- Exit 0 on success, 3 when a run stopped at a question (`exitWaiting`), 4 when it stopped at
a limit of the invocation, its time budget or its steps (`exitStopped`); `eval` exits with its
verdict, 0 pass, 1 fail, 2 error. A failure exits with its class's status, above all of these
(`Cli.exitFor`): 64 a command line that does not parse, 65 input, 69 environment, 74 storage,
75 transient, 76 model. -/
def main (argv : List String) : IO UInt32 :=
  app.run argv
