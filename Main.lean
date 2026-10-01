import Alaya

/-! `alaya` — the command-line driver for the mini-SWE-agent port over a trajectory tree. See
`docs/trajectory-schema.md` for the commands. -/

open Alaya
open Alaya.Agent (Outcome)
open Alaya.Trajectory

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM emit

/-- The data directory (`--data`, default `.alaya`); its layout is in `docs/trajectory-schema.md` §5. -/
private structure DataDir where
  path : System.FilePath
  store : Store
  workspaces : Workspaces

private def DataDir.cache (data : DataDir) : System.FilePath := data.path / "cache"

/-- A data directory with a `store/` is from before states became files under `states/` and
workspaces moved to restic; its states name snapshots nothing can read any more. -/
private def refuseLegacy (path : System.FilePath) : Result Unit := do
  if ← Result.fromIO Error.storage (path / "store").isDir then
    throw <| .configuration <|
      s!"{path} has the layout of an earlier alaya (`store/`), which this one does not read: " ++
      "convert it with a build from before the change, or start a new data directory"

private def openDataAt (path : System.FilePath) : Result DataDir := do
  refuseLegacy path
  let store ← Store.create (path / "states")
  -- The states and the model cache are as much the run as the repository is.
  let workspaces ← Workspaces.Restic.open (path / "restic") (keep := #[store.dir, path / "cache"])
  pure { path, store, workspaces }

/-- `--data`, which every command takes. -/
private def dataDir : Cli.Spec System.FilePath :=
  Cli.flagD "data" (.path "DIR") ".alaya" "the data directory"

/-- The work directory, always `DATA/work`: not configurable, so no path a user names can be
destroyed by a checkout, and the store and the cache are out of its reach by construction. -/
private structure WorkDir where
  path : System.FilePath

private def openWork (data : DataDir) : Result WorkDir := do
  let path := data.path / "work"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  pure { path }

/-- Where a run's commands go: the image and workdir the trajectory recorded, which an `--image`
or `--workdir` given again must not override. -/
private def executorFor (run : Executor.Docker.RunOptions) (image? workdir? : Option String)
    (state : State) (config : Executor.Config) : Result Executor := do
  if let some requested := workdir? then Executor.Docker.checkSameWorkdir requested state.workdir
  let settings ← Executor.Docker.settingsOf run state.image state.workdir
  match image? with
  | none => settings.verifyPresent
  | some requested =>
    let requested ← ({ settings with image := requested } : Executor.Docker.Settings).pin
    if requested.image != state.image then
      throw <| .configuration <|
        s!"--image resolves to {requested.image}, but this trajectory runs {state.image}; " ++
        "a continuation has to run the same bits its earlier turns did"
  Executor.Docker.executor settings config

/-- The agent of an existing run: what its root recorded. `--agent` is for `root`; given
again, it must describe the same agent, as `--image` must name the same image, or the command
refuses. -/
private def recordedAgentAs (store : Store) (agent? : Option System.FilePath) (hash : Hash) :
    Result Agent.Families.Instance := do
  let some recorded ← agentOf store hash
    | throw <| .configuration "this run's root records no agent: it is from an earlier alaya"
  let built ← Agent.Families.instanceOf recorded
  if let some file := agent? then
    let requested ← Agent.Families.fromFile file
    if requested.config.compress != built.config.compress then
      throw <| .configuration <|
        "this run was created with another agent configuration; --agent is for `root`. " ++
        s!"It records: {built.config.compress}"
  pure built

/-- What `resume` and `step` take. `--image`, `--workdir` and `--agent` are fixed at `root`;
given again, each must name what the root recorded. -/
private structure ContinueArgs where
  data : System.FilePath
  state : String
  model : Provider.Choice
  run : Executor.Docker.RunOptions
  /-- Seconds this invocation may spend, not recorded; 0 is no limit. -/
  budget : Nat
  image? : Option String
  workdir? : Option String
  agent? : Option System.FilePath

private def ContinueArgs.cli : Cli.Spec ContinueArgs :=
  ContinueArgs.mk
    <$> dataDir
    <*> Cli.arg "HASH" .string "the state to continue from; any unambiguous prefix"
    <*> Provider.Choice.cli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed from the root, after which no step starts; 0 is no limit"
    <*> Cli.flag? "image" (.string "IMAGE") "must resolve to the image the root recorded"
    <*> Cli.flag? "workdir" (.string "PATH") "must be the workdir the root recorded"
    <*> Cli.flag? "agent" (.path "FILE") "must describe the agent the root recorded"

private def runtimeFor (data : DataDir) (work : WorkDir) (a : ContinueArgs) (start : Hash) :
    Result Runtime := do
  let spec ← recordedAgentAs data.store a.agent? start
  let model ← buildModel a.model.spec a.model.temperature data.cache a.model.options
  let executor ← executorFor a.run a.image? a.workdir? (← getState data.store start) spec.executorConfig
  pure { store := data.store, workspaces := data.workspaces, workDir := work.path, executor, model
         agent := spec.build executor
         budgetMs? := if a.budget == 0 then none else some (a.budget * 1000) }

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

/-- Exit status of `eval` when no verdict was recorded: the state, the grader image, or the
input could not be had. A verdict exits 0 for pass, 1 for fail, 2 for error. -/
private def exitNoVerdict : UInt32 := 5

/-- Exit status when a run stopped because this invocation's time budget was spent: it has not
ended, and a later `resume` continues it. -/
private def exitOutOfTime : UInt32 := 4

/-- Says a continuation stopped for the time budget, with how much of it the run has used. -/
private def outOfTime (data : DataDir) (hash : Hash) (out : Cli.Out) : Result UInt32 := do
  let used ← elapsedMs data.store hash
  out.record (Lean.Json.mkObj [("state", hash.hex), ("time_budget_spent", true), ("run_time_ms", used)])
    s!"time budget spent: {hash.hex} has run {seconds used}; resume it to continue"
  pure exitOutOfTime

/-- What every command that prints a state says of it with `--json`. -/
private def stateJson (hash : Hash) (state : State) : Lean.Json :=
  .mkObj [
    ("state", hash.hex), ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("kind", state.kind.toString), ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("outcome", state.outcome?.map (fun o => Lean.Json.str o.status) |>.getD .null),
    ("question", state.question?.map (fun q => Lean.Json.str q.text) |>.getD .null),
    ("question_type", state.question?.map (fun q => Lean.Json.str q.questionType.toString) |>.getD .null),
    ("options", state.question?.map (fun q => Lean.Json.arr (q.options.map Lean.Json.str)) |>.getD .null)]

/-- A state a command created: the hash with the outcome or the question it stopped at, or one
JSON object with `--json`. -/
private def stateLine (data : DataDir) (out : Cli.Out) (child : Hash) : Result Unit := do
  let state ← getState data.store child
  let mark := match state.outcome?, state.question? with
    | some o, _ => s!"  [{o.status}]"
    | none, some q => s!"  ask  {q.toQuestion.render.quote}  [Waiting]"
    | none, none => ""
  out.record (stateJson child state) s!"{child.hex}{mark}"

/-- Readable lines, or one JSON object with `--json`. -/
private def report (out : Cli.Out) (json : Lean.Json) (lines : Array String) : Result Unit :=
  if out.json then out.record json "" else emitLines lines

/-- The exit status for the state a run stopped at. -/
private def exitFor (data : DataDir) (hash : Hash) : Result UInt32 := do
  pure (if (← getState data.store hash).question?.isSome then exitWaiting else 0)

/-! ## Commands

Each command declares what it takes (`Alaya.Cli`), and `main` runs the table. -/

private def hashArg (help : String := "the state; any unambiguous prefix") : Cli.Spec String :=
  Cli.arg "HASH" .string help

/-! ### Creating and growing a run -/

/-- What `root` takes. -/
private structure RootArgs where
  data : System.FilePath
  task : Cli.TextSource
  project? : Option System.FilePath
  image : String
  workdir : String
  agent : System.FilePath
  run : Executor.Docker.RunOptions

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
    <*> Cli.flag "agent" (.path "FILE")
      s!"the agent configuration, e.g. agents/mini-swe-default.json; families: {Agent.Families.names}"
    <*> Executor.Docker.RunOptions.cli
    <* Cli.removed "path" ("--workdir PATH names where the workspace is mounted, and without a " ++
      "PROJECT the root copies it out of the image")

private def rootRun (a : RootArgs) (out : Cli.Out) : Result UInt32 := do
  let task ← a.task.read "task"
  -- Before the data directory is created: inside the project it would become part of it.
  if let some project := a.project? then
    Workspaces.refuseOverlap "snapshot" project #[a.data]
  let data ← openDataAt a.data
  Executor.Docker.checkWorkdir a.workdir #[graderInput]
  let settings ← (← Executor.Docker.settingsOf a.run a.image a.workdir).pin
  let uname ← Executor.Docker.uname settings
  let spec ← Agent.Families.fromFile a.agent
  let log := spec.initialLog task uname
  let project ← rootProject data settings (a.project?.map (·.toString))
  let hash ← createRoot data.store data.workspaces log project settings.image (some task) spec.config
    a.workdir
  stateLine data out hash
  pure 0

private def resumeRun (a : ContinueArgs) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt a.data
  let start ← resolve data.store a.state
  let rt ← runtimeFor data (← openWork data) a start
  try
    let stopped ← resume rt a.model.spec start (stateLine data out)
    if stopped.outOfTime then outOfTime data stopped.state out else
    if let some o := (← getState data.store stopped.state).outcome? then
      out.note s!"done: {o.status}"
    exitFor data stopped.state
  finally
    Result.fromIO Error.storage rt.executor.close

private def stepRun (a : ContinueArgs) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt a.data
  let parent ← resolve data.store a.state
  let rt ← runtimeFor data (← openWork data) a parent
  try
    match ← stepOnce rt a.model.spec parent with
    | none => outOfTime data parent out
    | some child =>
      stateLine data out child
      exitFor data child
  finally
    Result.fromIO Error.storage rt.executor.close

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

private def evalRun (a : EvalArgs) (out : Cli.Out) : Result UInt32 := do
  -- The exit status is the verdict's; an error before one is recorded has its own.
  try
    let data ← openDataAt a.data
    let target ← resolve data.store a.state
    let targetState ← getState data.store target
    let settings ← Executor.Docker.settingsOf { user? := a.user? } targetState.image targetState.workdir
    let node ← evaluate data.store data.workspaces (data.path / "eval") target a.grader
      settings.user? a.input? a.graderImage? a.timeout
    let some e := (← getState data.store node).evaluation?
      | throw <| .storage "the evaluation was not recorded"
    out.record (Lean.Json.mkObj [("state", node.hex), ("status", e.status.toString),
        ("passed", e.score.1), ("total", e.score.2), ("reason", e.reason)])
      s!"{node.hex}  {e.verdict}  ({e.elapsedMs} ms)"
    if e.status == .error then out.note s!"error: {e.reason}"
    pure (match e.status with | .pass => 0 | .fail => 1 | .error => 2)
  catch error =>
    out.fail error
    pure exitNoVerdict

/-! ### A person in the tree -/

private def commitRun (data : System.FilePath) (state : String) (dir : System.FilePath)
    (note? tell? : Option String) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let hash ← commit data.store data.workspaces (← resolve data.store state) dir note? (tell? := tell?)
  stateLine data out hash
  pure 0

private def tellRun (data : System.FilePath) (state text : String) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  stateLine data out (← tell data.store (← resolve data.store state) text)
  pure 0

private def replyRun (data : System.FilePath) (state text : String) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  stateLine data out (← reply data.store (← resolve data.store state) text)
  pure 0

private def replyUnavailableRun (data : System.FilePath) (state : String) (out : Cli.Out) :
    Result UInt32 := do
  let data ← openDataAt data
  stateLine data out (← replyUnavailable data.store (← resolve data.store state))
  pure 0

private def waitingRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  for (hash, q) in ← waiting data.store do
    out.record (Lean.Json.mkObj [
        ("state", hash.hex), ("question", q.text),
        ("question_type", q.questionType.toString),
        ("options", .arr (q.options.map Lean.Json.str))])
      s!"{hash.hex}  {q.toQuestion.render.quote}"
  pure 0

/-- The question commands print JSON whether or not `--json` is given. -/
private def questionRun (data : System.FilePath) (state : String)
    (read : DataDir → Hash → Result Lean.Json) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let json ← read data (← resolve data.store state)
  out.record json json.compress
  pure 0

/-! ### Reading a run -/

private def lsRun (data : System.FilePath) (state : String) (path? : Option String) (out : Cli.Out) :
    Result UInt32 := do
  let data ← openDataAt data
  let hash ← resolve data.store state
  let workspace := (← getState data.store hash).workspace
  let path := path?.getD ""
  let entries ← data.workspaces.list workspace path
  let lines := entries.map fun e =>
    let size := e.size.map toString |>.getD "-"
    let suffix := if e.kind == .directory then "/" else if e.kind == .symlink then "@" else ""
    s!"{"".pushn ' ' (10 - min 10 size.length)}{size}  {e.path}{suffix}"
  report out (Lean.Json.mkObj [("state", hash.hex), ("workspace", workspace.hex), ("path", path),
      ("entries", .arr (entries.map fun e => .mkObj [("name", e.name), ("path", e.path),
        ("kind", e.kind.toString), ("size", e.size.map (fun n => (n : Lean.Json)) |>.getD .null)]))])
    lines
  pure 0

/-- The file's bytes, exactly, with or without `--json`, which changes only how errors print. -/
private def catRun (data : System.FilePath) (state path : String) (_ : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let workspace := (← getState data.store (← resolve data.store state)).workspace
  let bytes ← data.workspaces.read workspace path
  Result.fromIO Error.storage do
    let out ← IO.getStdout
    out.write bytes
    out.flush
  pure 0

private def checkoutRun (data : System.FilePath) (state : String) (dir : System.FilePath)
    (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let hash ← resolve data.store state
  let state ← getState data.store hash
  data.workspaces.materialize state.workspace dir
  out.record (Lean.Json.mkObj [("state", hash.hex), ("workspace", state.workspace.hex),
      ("directory", dir.toString)])
    s!"checked out {state.workspace.hex} into {dir}"
  pure 0

private def treeRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  if out.json then
    for hash in ← allStates data.store do
      out.record (stateJson hash (← getState data.store hash)) ""
  else emitLines (← treeLines data.store)
  pure 0

private def showRun (data : System.FilePath) (state : String) (view : Bool) (out : Cli.Out) :
    Result UInt32 := do
  let data ← openDataAt data
  let hash ← resolve data.store state
  let view? ← if view then some <$> (·.view) <$> recordedAgentAs data.store none hash else pure none
  if out.json then
    let state ← getState data.store hash
    let log ← logOf data.store hash
    let json := state.toJson |>.setObjVal! "state" hash.hex
      |>.setObjVal! "run_time_ms" (← elapsedMs data.store hash)
      |>.setObjVal! "log" (.arr (log.map eventToJson))
    let json := match view? with
      | some view => json.setObjVal! "view" (.arr ((view log).map Chat.Message.toJson))
      | none => json
    out.record json ""
  else emitLines (← showLines data.store hash view?)
  pure 0

private def diffRun (data : System.FilePath) (a b : String) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let a ← resolve data.store a
  let b ← resolve data.store b
  let lines ← diffLines data.store data.workspaces a b
  report out (Lean.Json.mkObj [("a", a.hex), ("b", b.hex), ("changes", .arr (lines.map Lean.Json.str))])
    lines
  pure 0

private def htmlRun (data : System.FilePath) (file? : Option System.FilePath) (hide : Array String)
    (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let file := file?.getD (data.path / "report.html")
  -- Each --hide may list several: --hide .venv --hide __pycache__,.pytest_cache
  let hidden := hide.foldl (init := #[]) fun paths value =>
    paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
  -- The page has one view and one tool list, so the forest's roots must agree on the agent.
  let roots ← (← allStates data.store).filterM fun h => do pure (← getState data.store h).parent?.isNone
  let some first := roots[0]? | throw <| .configuration "nothing to report: the data directory holds no states"
  let spec ← recordedAgentAs data.store none first
  for root in roots do
    if (← recordedAgentAs data.store none root).config.compress != spec.config.compress then
      throw <| .configuration <|
        s!"the roots of {data.path} were created with different agents; a report renders one " ++
        "agent's runs, so give each its own data directory"
  let page ← Html.report data.store data.workspaces s!"alaya {data.path}" spec.view spec.tools hidden
  Result.fromIO Error.storage (IO.FS.writeFile file page)
  out.record (Lean.Json.mkObj [("file", file.toString), ("bytes", page.length)])
    s!"wrote {file} ({page.length} bytes)"
  pure 0

private def rmRun (data : System.FilePath) (state : String) (out : Cli.Out) : Result UInt32 := do
  let data ← openDataAt data
  let n ← removeSubtree data.store data.workspaces (← resolve data.store state)
  out.record (Lean.Json.mkObj [("removed", n)]) s!"removed {n} state(s)"
  pure 0

/-! ### The table -/

private def commands : Array Cli.Command := #[
  { name := "root"
    summary := "Create a root: the agent's opening prompts for a task, and a snapshot of the project."
    examples := #[
      "alaya root --task 'Add a hello.py that prints hello' ./project " ++
        "--agent agents/mini-swe-default.json --image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya root --task-file TASK.md --agent agents/mini-vero-default.json --image my-task:1 --workdir /testbed"]
    spec := rootRun <$> RootArgs.cli },
  { name := "resume"
    summary := "Grow one continuation until the run ends, asks a question, or spends its time budget."
    examples := #["alaya resume 4f2c8b --model xmcp:ds/deepseek-v4-flash --time-budget 3600 --json"]
    spec := resumeRun <$> ContinueArgs.cli },
  { name := "step"
    summary := "Advance exactly one turn."
    examples := #["alaya step 4f2c8b --model xmcp:ds/deepseek-v4-flash"]
    spec := stepRun <$> ContinueArgs.cli },
  { name := "eval"
    summary := "Grade a state: run a grader over a fresh copy and record its TAP verdict as a leaf."
    examples := #[
      "alaya eval e5a1c3 --input ./hidden --grader 'cp -R /grader/tests . && pytest -q -p tap --tap-stream'",
      "alaya eval e5a1c3 --grader-image my-grader:1 --input ./benchmark --grader 'grade-project /grader'"]
    spec := evalRun <$> EvalArgs.cli
    -- Exit 1 is a failing verdict, so a command line that does not parse records none.
    usageExit? := some exitNoVerdict },
  { name := "commit"
    summary := "Record a hand-edited workspace as a child, optionally with a notice to the agent."
    examples := #["alaya commit 4f2c8b ./fix --note 'fixed the fixture' --tell 'I fixed the fixture'"]
    spec := commitRun <$> dataDir <*> hashArg <*> Cli.arg "DIR" .path "the edited workspace"
      <*> Cli.flag? "note" .string "provenance for the tree, not shown to the agent"
      <*> Cli.flag? "tell" .string "a notice the agent sees, with the files that changed" },
  { name := "tell"
    summary := "Send the agent a message, as a child."
    examples := #["alaya tell 4f2c8b 'keep the old API'"]
    spec := tellRun <$> dataDir <*> hashArg <*> Cli.arg "TEXT" .string "the message" },
  { name := "reply"
    summary := "Answer the question a state is waiting on."
    examples := #["alaya reply c61754 -- 'yes, keep it'"]
    spec := replyRun <$> dataDir <*> hashArg "the waiting state"
      <*> Cli.arg "TEXT" .string "the answer, verbatim; put it after -- if it may begin with -" },
  { name := "reply-unavailable"
    summary := "Record that the person cannot answer the question a state is waiting on."
    spec := replyUnavailableRun <$> dataDir <*> hashArg "the waiting state" },
  { name := "waiting"
    summary := "List every unanswered question."
    examples := #["alaya waiting --json"]
    spec := waitingRun <$> dataDir },
  { name := "question-context"
    summary := "The task and the root-to-question history of a question, as JSON."
    spec := (fun data state => questionRun data state fun d h => QuestionContext.context d.store h)
      <$> dataDir <*> hashArg "the question state" },
  { name := "question-files"
    summary := "List a directory of a question's snapshot, as JSON."
    spec := (fun data state path? => questionRun data state fun d h =>
        match path? with
        | some path => QuestionContext.directory d.store d.workspaces h path
        | none => QuestionContext.directory d.store d.workspaces h)
      <$> dataDir <*> hashArg "the question state"
      <*> Cli.arg? "PATH" .string "a directory relative to the workspace; by default its root" },
  { name := "question-file"
    summary := "Preview a file of a question's snapshot, as JSON."
    spec := (fun data state path => questionRun data state fun d h =>
        QuestionContext.file d.store d.workspaces h path)
      <$> dataDir <*> hashArg "the question state"
      <*> Cli.arg "PATH" .string "a file relative to the workspace" },
  { name := "ls"
    summary := "List a directory of a state's workspace snapshot."
    examples := #["alaya ls 7b19d4 .report"]
    spec := lsRun <$> dataDir <*> hashArg
      <*> Cli.arg? "PATH" .string "a directory relative to the workspace; by default its root" },
  { name := "cat"
    summary := "Print a file from a state's workspace snapshot, byte for byte."
    examples := #["alaya cat 7b19d4 .report/summary.json"]
    spec := catRun <$> dataDir <*> hashArg <*> Cli.arg "PATH" .string "a file relative to the workspace" },
  { name := "checkout"
    summary := "Materialize a state's workspace into a directory."
    spec := checkoutRun <$> dataDir <*> hashArg <*> Cli.arg "DIR" .path "where to write the files" },
  { name := "tree"
    summary := "Show the whole forest; with --json, one object per state."
    spec := treeRun <$> dataDir },
  { name := "show"
    summary := "A state's metadata and log, and with --view the dialogue the model is sent from it."
    examples := #["alaya show 4f2c8b --view"]
    spec := showRun <$> dataDir <*> hashArg
      <*> Cli.switch "view" "also print the dialogue the run's agent makes of the log" },
  { name := "diff"
    summary := "The workspace changes between two states, one path per line."
    spec := diffRun <$> dataDir <*> Cli.arg "A" .string "the earlier state"
      <*> Cli.arg "B" .string "the later state" },
  { name := "html"
    summary := "Write the forest as one self-contained page."
    examples := #["alaya html --hide .venv --hide __pycache__,.pytest_cache"]
    spec := htmlRun <$> dataDir
      <*> Cli.arg? "FILE" .path "where to write the page; by default DATA/report.html"
      <*> Cli.repeated "hide" (.string "DIRS") "directories to leave out of the page, comma-separated" },
  { name := "rm"
    summary := "Delete a subtree and the snapshots only it used."
    spec := rmRun <$> dataDir <*> hashArg "the root of the subtree to delete" }]

private def app : Cli.App where
  name := "alaya"
  summary := "Record agent runs as trees of content-addressed states: branch, replay, grade, intervene."
  commands := commands

/-- Exit 0 on success, 3 when a run stopped at a question (`exitWaiting`), 4 when it stopped
because the time budget was spent (`exitOutOfTime`), 1 on an error or a command line that does
not parse. `eval` exits with its verdict: 0 pass, 1 fail, 2 error, and 5 when it recorded none
(`exitNoVerdict`), a command line that does not parse included. -/
def main (argv : List String) : IO UInt32 :=
  app.run argv
