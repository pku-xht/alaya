import Alaya

/-! `alaya` — the command line over a trajectory tree. See
`docs/cli.md` for the commands. -/

open Alaya
open Alaya.Agent (Outcome)
open Alaya.Trajectory

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
digest when it is missing. -/
private def executorFor (run : Executor.Docker.RunOptions) (state : State) (config : Executor.Config) :
    Result Executor := do
  let settings ← Executor.Docker.settingsOf run state.image state.workdir
  settings.ensurePresent
  Executor.Docker.executor settings config

/-- The agent of an existing run: what its root recorded. -/
private def recordedAgent (store : Store) (hash : Hash) : Result Agent.Families.Instance := do
  Agent.Families.instanceOf (← agentOf store hash)

/-- What `resume` takes: what this invocation samples from, and its limits. The image, the
workdir and the agent are the root's. -/
private structure ResumeArgs where
  data : System.FilePath
  state : String
  model : Provider.Choice
  run : Executor.Docker.RunOptions
  /-- Seconds of run time, not recorded; 0 is no limit. -/
  budget : Nat
  /-- Turns this invocation may take; 0 is no limit. -/
  turns : Nat

private def ResumeArgs.cli : Cli.Spec ResumeArgs :=
  ResumeArgs.mk
    <$> dataDir
    <*> Cli.arg "HASH" .string "the state to continue from; any unambiguous prefix"
    <*> Provider.Choice.cli
    <*> Executor.Docker.RunOptions.cli
    <*> Cli.flagD "time-budget" (.nat "S") 0
      "seconds of run time, summed from the root, after which no turn starts; 0 is no limit"
    <*> Cli.flagD "turns" .nat 0 "turns this invocation may take; 0 is no limit, 1 is one step"

private def runtimeFor (data : DataDir) (work : WorkDir) (a : ResumeArgs) (start : Hash) :
    Result Runtime := do
  let spec ← recordedAgent data.store start
  let model ← buildModel a.model.spec a.model.temperature data.cache a.model.options
  let executor ← executorFor a.run (← getState data.store start) spec.executorConfig
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

/-- Exit status when a run stopped at a limit of this invocation, its time budget or its turns:
it has not ended, and a later `resume` continues it. -/
private def exitStopped : UInt32 := 4

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

private def rootRun (a : RootArgs) (out : Cli.Out) : Result UInt32 := do
  let task ← a.task.read "task"
  -- Before the data directory is created: inside the project it would become part of it.
  if let some project := a.project? then
    Workspaces.refuseOverlap "snapshot" project #[a.data]
  withData a.data (write := true) (create := true) fun data => do
    Executor.Docker.checkWorkdir a.workdir #[graderInput]
    let settings ← (← Executor.Docker.settingsOf {} a.image a.workdir).pin
    let uname ← Executor.Docker.uname settings
    let spec ← Agent.Families.fromFile a.agent
    let log := spec.initialLog task uname
    let project ← rootProject data settings (a.project?.map (·.toString))
    let hash ← createRoot data.store data.workspaces log project settings.image (some task) spec.config
      a.workdir
    stateLine data out hash
    pure 0

private def resumeRun (a : ResumeArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let start ← resolve data.store a.state
    let rt ← runtimeFor data (← openWork data) a start
    try
      let stopped ← resume rt a.model.spec start (stateLine data out)
        (turns? := if a.turns == 0 then none else some a.turns)
      if stopped.outOfTime then
        let used ← elapsedMs data.store stopped.state
        out.record (Lean.Json.mkObj [("state", stopped.state.hex), ("time_budget_spent", true),
            ("run_time_ms", used)])
          s!"time budget spent: {stopped.state.hex} has run {seconds used}; resume it to continue"
        return exitStopped
      if stopped.outOfTurns then
        out.record (Lean.Json.mkObj [("state", stopped.state.hex), ("turns_spent", true),
            ("turns", a.turns)])
          s!"{a.turns} turn(s) taken: resume {stopped.state.hex} to continue"
        return exitStopped
      if let some o := (← getState data.store stopped.state).outcome? then
        out.note s!"done: {o.status}"
      exitFor data stopped.state
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

/-- Exits with the verdict: 0 pass, 1 fail, 2 error. A failure before a verdict is recorded
exits with its class's status, as for any command, all of them above the verdict's. -/
private def evalRun (a : EvalArgs) (out : Cli.Out) : Result UInt32 := do
  withData a.data (write := true) fun data => do
    let target ← resolve data.store a.state
    let targetState ← getState data.store target
    let settings ← Executor.Docker.settingsOf { user? := a.user? } targetState.image targetState.workdir
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
    (note? : Option String) (out : Cli.Out) : Result UInt32 := do
  withData data (write := true) fun data => do
    let hash ← commit data.store data.workspaces (← resolve data.store state) dir note?
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
      | some text => reply data.store waiting text
      | none => replyUnavailable data.store waiting)
    pure 0

private def waitingRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    for (hash, q) in ← waiting data.store do
      out.record (Lean.Json.mkObj [
          ("state", hash.hex), ("question", q.text),
          ("question_type", q.questionType.toString),
          ("options", .arr (q.options.map Lean.Json.str))])
        s!"{hash.hex}  {q.toQuestion.render.quote}"
    pure 0

/-! ### Reading a run -/

private def lsRun (data : System.FilePath) (state : String) (path? : Option String) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
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

/-- The file's bytes, exactly; with `--json`, a preview of any entry: UTF-8 text up to 1 MiB,
and otherwise what it is. -/
private def catRun (data : System.FilePath) (state path : String) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let workspace := (← getState data.store hash).workspace
    if out.json then
      let preview ← data.workspaces.preview workspace path
      out.record (Lean.Json.mkObj [("state", hash.hex), ("workspace", workspace.hex), ("path", path),
        ("kind", preview.kind), ("content", preview.content?.map Lean.Json.str |>.getD .null),
        ("size", preview.size?.map (fun n => (n : Lean.Json)) |>.getD .null)]) ""
    else
      let bytes ← data.workspaces.read workspace path
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
    data.workspaces.materialize state.workspace dir
    out.record (Lean.Json.mkObj [("state", hash.hex), ("workspace", state.workspace.hex),
        ("directory", dir.toString)])
      s!"checked out {state.workspace.hex} into {dir}"
    pure 0

private def treeRun (data : System.FilePath) (out : Cli.Out) : Result UInt32 := do
  withData data fun data => do
    if out.json then
      for hash in ← allStates data.store do
        out.record (stateJson hash (← getState data.store hash)) ""
    else emitLines (← treeLines data.store)
    pure 0

private def showRun (data : System.FilePath) (state : String) (view : Bool) (out : Cli.Out) :
    Result UInt32 := do
  withData data fun data => do
    let hash ← resolve data.store state
    let view? ← if view then some <$> (·.view) <$> recordedAgent data.store hash else pure none
    if out.json then
      let branch ← branchOf data.store hash
      let some (_, state) := branch.back? | throw <| .storage s!"no state {hash.hex}"
      let history := branch.map fun (h, s) => Lean.Json.mkObj [("state", h.hex),
        ("kind", s.kind.toString), ("events", .arr (s.appended.map eventToJson))]
      let json := state.toJson |>.setObjVal! "state" hash.hex
        |>.setObjVal! "run_time_ms" (← elapsedMs data.store hash)
        |>.setObjVal! "history" (.arr history)
      let json := match view? with
        | some view =>
          let log := branch.foldl (fun log (_, s) => log ++ s.appended) #[]
          json.setObjVal! "view" (.arr ((view log).map Chat.Message.toJson))
        | none => json
      out.record json ""
    else emitLines (← showLines data.store hash view?)
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
    -- The page has one view and one tool list, so the forest's roots must agree on the agent.
    let roots ← (← allStates data.store).filterM fun h => do pure (← getState data.store h).parent?.isNone
    let some first := roots[0]? | throw <| .input "nothing to report: the data directory holds no states"
    let spec ← recordedAgent data.store first
    for root in roots do
      if (← recordedAgent data.store root).config.compress != spec.config.compress then
        throw <| .input <|
          s!"the roots of {data.path} were created with different agents; a report renders one " ++
          "agent's runs, so give each its own data directory"
    let page ← Html.report data.store data.workspaces s!"alaya {data.path}" spec.view spec.tools hidden
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
        "--agent agents/mini-swe-default.json --image ghcr.io/astral-sh/uv:python3.12-bookworm-slim",
      "alaya root --task-file TASK.md --agent agents/mini-vero-default.json --image my-task:1 --workdir /testbed"]
    spec := rootRun <$> RootArgs.cli },
  { name := "resume"
    summary := "Grow one continuation until the run ends, asks a question, or reaches a limit."
    examples := #["alaya resume 4f2c8b --model xmcp:ds/deepseek-v4-flash --time-budget 3600 --json",
      "alaya resume 4f2c8b --model xmcp:ds/deepseek-v4-flash --turns 1"]
    spec := resumeRun <$> ResumeArgs.cli },
  { name := "eval"
    summary := "Grade a state: run a grader over a fresh copy and record its TAP verdict as a leaf."
    examples := #[
      "alaya eval e5a1c3 --input ./hidden --grader 'cp -R /grader/tests . && pytest -q -p tap --tap-stream'",
      "alaya eval e5a1c3 --grader-image my-grader:1 --input ./benchmark --grader 'grade-project /grader'"]
    spec := evalRun <$> EvalArgs.cli },
  { name := "commit"
    summary := "Record a hand-edited workspace as a child; the agent is told what changed."
    examples := #["alaya commit 4f2c8b ./fix --note 'fixed the fixture'"]
    spec := commitRun <$> dataDir <*> hashArg <*> Cli.arg "DIR" .path "the edited workspace"
      <*> Cli.flag? "note" .string "provenance for the tree, not shown to the agent" },
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
a limit of the invocation, its time budget or its turns (`exitStopped`); `eval` exits with its
verdict, 0 pass, 1 fail, 2 error. A failure exits with its class's status, above all of these
(`Cli.exitFor`): 64 a command line that does not parse, 65 input, 69 environment, 74 storage,
75 transient, 76 model. -/
def main (argv : List String) : IO UInt32 :=
  app.run argv
