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

private def openData (args : Cli.Args) : Result DataDir := do
  let path : System.FilePath := ← args.valueD "data" ".alaya"
  refuseLegacy path
  let store ← Store.create (path / "states")
  -- The states and the model cache are as much the run as the repository is.
  let workspaces ← Workspaces.Restic.open (path / "restic") (keep := #[store.dir, path / "cache"])
  pure { path, store, workspaces }

/-- The work directory, always `DATA/work`: not configurable, so no path a user names can be
destroyed by a checkout, and the store and the cache are out of its reach by construction. -/
private structure WorkDir where
  path : System.FilePath

private def openWork (data : DataDir) : Result WorkDir := do
  let path := data.path / "work"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  pure { path }

/-- Where a run's commands go: the image and workdir the trajectory recorded, which a `--image`
that resolves to anything else must not override. -/
private def executorFor (args : Cli.Args) (state : State) (config : Executor.Config) :
    Result Executor := do
  let pinned := state.image
  let settings ← Executor.Docker.settingsFor args pinned state.workdir
  match ← Executor.Docker.settings? args with
  | none => settings.verifyPresent
  | some requested =>
    let requested ← requested.pin
    if requested.image != pinned then
      throw <| .configuration <|
        s!"--image resolves to {requested.image}, but this trajectory runs {pinned}; " ++
        "a continuation has to run the same bits its earlier turns did"
  Executor.Docker.executor settings config

/-- The agent of an existing run: what its root recorded. `--agent` is for `root`; given
again, it must describe the same agent, as `--image` must name the same image, or the command
refuses. -/
private def recordedAgent (store : Store) (args : Cli.Args) (hash : Hash) :
    Result Agent.Families.Instance := do
  let some recorded ← agentOf store hash
    | throw <| .configuration "this run's root records no agent: it is from an earlier alaya"
  let built ← Agent.Families.instanceOf recorded
  if args.isSet "agent" then
    let requested ← Agent.Families.fromFile (← args.require "agent" "a JSON file")
    if requested.config.compress != built.config.compress then
      throw <| .configuration <|
        "this run was created with another agent configuration; --agent is for `root`. " ++
        s!"It records: {built.config.compress}"
  pure built

/-- What `--time-budget SECONDS` gives this invocation, not recorded; 0 or absent is no limit. -/
private def budgetOf (args : Cli.Args) : Result (Option Nat) := do
  let seconds ← args.natD "time-budget" 0
  pure (if seconds == 0 then none else some (seconds * 1000))

private def runtimeFor (data : DataDir) (work : WorkDir) (args : Cli.Args) (start : Hash) :
    Result Runtime := do
  let spec ← recordedAgent data.store args start
  let modelSpec ← args.require "model" "e.g. --model yunwu:gpt-5.6-luna"
  let temperature ← args.floatD "temperature" 0.0
  let model ← buildModel modelSpec temperature data.cache (← Provider.Options.ofArgs args)
  let executor ← executorFor args (← getState data.store start) spec.executorConfig
  pure { store := data.store, workspaces := data.workspaces, workDir := work.path, executor, model
         agent := spec.build executor, budgetMs? := ← budgetOf args }

/-- Empties the work directory. Both a checkout and an extraction from an image need it to start
clean, and it is the one place holding nothing durable. -/
private def clearWork (data : DataDir) : Result WorkDir := do
  let work ← openWork data
  Workspaces.makeWritable work.path
  Result.fromIO Error.storage do
    IO.FS.removeDirAll work.path
    IO.FS.createDirAll work.path
  pure work

/-- The directory a new trajectory snapshots: a host `PROJECT`, or `--path` copied out of the
image — task images usually carry the project already, so there is nothing on the host to point
at. An extraction lands in the work directory, which is disposable by construction. -/
private def rootUsage : String :=
  "alaya root (--task TEXT | --task-file FILE) [PROJECT] --image IMAGE [--workdir PATH] --agent FILE"

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

private def modelSpecOf (args : Cli.Args) : String := args.getD "model" ""

/-- Exit status when a run stopped at a question rather than an outcome. -/
private def exitWaiting : UInt32 := 3

/-- Exit status of `eval` when no verdict was recorded: the state, the grader image, or the
input could not be had. A verdict exits 0 for pass, 1 for fail, 2 for error. -/
private def exitNoVerdict : UInt32 := 5

/-- Exit status when a run stopped because this invocation's time budget was spent: it has not
ended, and a later `resume` continues it. -/
private def exitOutOfTime : UInt32 := 4

/-- Says a continuation stopped for the time budget, with how much of it the run has used. -/
private def outOfTime (data : DataDir) (hash : Hash) (json : Bool) : Result UInt32 := do
  let used ← elapsedMs data.store hash
  if json then emit (Lean.Json.mkObj [("state", hash.hex), ("time_budget_spent", true), ("run_time_ms", used)]).compress
  else emit s!"time budget spent: {hash.hex} has run {seconds used}; resume it to continue"
  pure exitOutOfTime

/-- One line per new state: the hash with the outcome or the question it stopped at, or one
JSON object with `--json`. -/
private def stateLine (data : DataDir) (child : Hash) (json : Bool) : Result Unit := do
  let state ← getState data.store child
  if json then
    emit (Lean.Json.mkObj [
      ("state", child.hex), ("kind", state.kind.toString),
      ("outcome", state.outcome?.map (fun o => Lean.Json.str o.status) |>.getD .null),
      ("question", state.question?.map (fun q => Lean.Json.str q.text) |>.getD .null),
      ("question_type", state.question?.map (fun q => Lean.Json.str q.questionType.toString) |>.getD .null),
      ("options", state.question?.map (fun q => Lean.Json.arr (q.options.map Lean.Json.str)) |>.getD .null)]).compress
  else
    let mark := match state.outcome?, state.question? with
      | some o, _ => s!"  [{o.status}]"
      | none, some q => s!"  ask  {q.toQuestion.render.quote}  [Waiting]"
      | none, none => ""
    emit s!"{child.hex}{mark}"

/-- The exit status for the state a run stopped at. -/
private def exitFor (data : DataDir) (hash : Hash) : Result UInt32 := do
  pure (if (← getState data.store hash).question?.isSome then exitWaiting else 0)

private def dispatch (argv : List String) : Result UInt32 := do
  let args := Cli.parse argv (aliases := [("-m", "note")])
  let json := args.isSet "json"
  match args.positional.toList with
  | "root" :: rest =>
    if rest.length > 1 then throw <| .configuration rootUsage
    let task ← args.taskOf rootUsage
    -- Before the data directory is created: inside the project it would become part of it.
    if let some project := rest.head? then
      Workspaces.refuseOverlap "snapshot" project #[← args.valueD "data" ".alaya"]
    let data ← openData args
    -- Every command of a trajectory runs in its image, so a root must name one.
    let some settings ← Executor.Docker.settings? args
      | throw <| .configuration s!"--image is required: every run happens in a container. {rootUsage}"
    if args.isSet "path" then
      throw <| .configuration "--path is gone: --workdir PATH names where the workspace is mounted, and without a PROJECT the root copies it out of the image"
    let workdir ← args.valueD "workdir" Executor.Docker.defaultWorkdir
    Executor.Docker.checkWorkdir workdir #[graderInput]
    let settings ← ({ settings with workdir }).pin
    let uname ← Executor.Docker.uname settings
    let spec ← Agent.Families.fromFile (← args.require "agent"
      s!"a JSON configuration, e.g. agents/mini-swe-default.json; the families are {Agent.Families.names}")
    let log := spec.initialLog task uname
    let project ← rootProject data settings rest.head?
    let hash ← createRoot data.store data.workspaces log project settings.image (some task) spec.config
      workdir
    emit hash.hex
    pure 0
  | "resume" :: pfx :: _ =>
    let data ← openData args
    let start ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args start
    try
      let stopped ← resume rt (modelSpecOf args) start (stateLine data · json)
      if stopped.outOfTime then outOfTime data stopped.state json else
      if !json then
        match (← getState data.store stopped.state).outcome? with
        | some o => emit s!"done: {o.status}"
        | none => pure ()
      exitFor data stopped.state
    finally
      Result.fromIO Error.storage rt.executor.close
  | "step" :: pfx :: _ =>
    let data ← openData args
    let parent ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args parent
    try
      match ← stepOnce rt (modelSpecOf args) parent with
      | none => outOfTime data parent json
      | some child =>
        stateLine data child json
        exitFor data child
    finally
      Result.fromIO Error.storage rt.executor.close
  | ["tell", pfx, text] =>
    let data ← openData args
    emit (← tell data.store (← resolve data.store pfx) text).hex
    pure 0
  | ["reply", pfx, text] =>
    let data ← openData args
    emit (← reply data.store (← resolve data.store pfx) text).hex
    pure 0
  | ["reply-unavailable", pfx] =>
    let data ← openData args
    emit (← replyUnavailable data.store (← resolve data.store pfx)).hex
    pure 0
  | ["question-context", pfx] =>
    let data ← openData args
    emit (← QuestionContext.context data.store (← resolve data.store pfx)).compress
    pure 0
  | "ls" :: pfx :: rest =>
    if rest.length > 1 then throw <| .configuration "alaya ls HASH [PATH]"
    let data ← openData args
    let hash ← resolve data.store pfx
    let workspace := (← getState data.store hash).workspace
    let path := rest.head?.getD ""
    let entries ← data.workspaces.list workspace path
    if json then
      emit (Lean.Json.mkObj [("state", hash.hex), ("workspace", workspace.hex), ("path", path),
        ("entries", .arr (entries.map fun e => .mkObj [("name", e.name), ("path", e.path),
          ("kind", e.kind.toString), ("size", e.size.map (fun n => (n : Lean.Json)) |>.getD .null)]))]).compress
    else
      for e in entries do
        let size := e.size.map toString |>.getD "-"
        let suffix := if e.kind == .directory then "/" else if e.kind == .symlink then "@" else ""
        emit s!"{"".pushn ' ' (10 - min 10 size.length)}{size}  {e.path}{suffix}"
    pure 0
  | ["cat", pfx, path] =>
    let data ← openData args
    let workspace := (← getState data.store (← resolve data.store pfx)).workspace
    let bytes ← data.workspaces.read workspace path
    Result.fromIO Error.storage do
      let out ← IO.getStdout
      out.write bytes
      out.flush
    pure 0
  | ["question-files", pfx] =>
    let data ← openData args
    emit (← QuestionContext.directory data.store data.workspaces (← resolve data.store pfx)).compress
    pure 0
  | ["question-files", pfx, path] =>
    let data ← openData args
    emit (← QuestionContext.directory data.store data.workspaces (← resolve data.store pfx) path).compress
    pure 0
  | ["question-file", pfx, path] =>
    let data ← openData args
    emit (← QuestionContext.file data.store data.workspaces (← resolve data.store pfx) path).compress
    pure 0
  | ["waiting"] =>
    let data ← openData args
    for (hash, q) in ← waiting data.store do
      if json then emit (Lean.Json.mkObj [
        ("state", hash.hex), ("question", q.text),
        ("question_type", q.questionType.toString),
        ("options", .arr (q.options.map Lean.Json.str))]).compress
      else emit s!"{hash.hex}  {q.toQuestion.render.quote}"
    pure 0
  | "eval" :: pfx :: _ =>
    -- The exit status is the verdict's; an error before one is recorded has its own.
    try
      let data ← openData args
      let target ← resolve data.store pfx
      let grader ← args.require "grader"
        "a command that prints TAP on stdout, e.g. --grader 'python3 /grader/grade.py'"
      let timeout ← args.natD "timeout" 900
      let input? ← (args.get? "input").mapM fun _ => args.require "input" "a directory of trusted files"
      let graderImage? ← (args.get? "grader-image").mapM fun _ =>
        args.require "grader-image" "an image, e.g. --grader-image my-grader:1"
      let targetState ← getState data.store target
      let settings ← Executor.Docker.settingsFor args targetState.image targetState.workdir
      let node ← evaluate data.store data.workspaces (data.path / "eval") target grader
        settings.user? (input?.map System.FilePath.mk) graderImage? timeout
      let some e := (← getState data.store node).evaluation?
        | throw <| .storage "the evaluation was not recorded"
      if json then
        emit (Lean.Json.mkObj [("state", node.hex), ("status", e.status.toString),
          ("passed", e.score.1), ("total", e.score.2), ("reason", e.reason)]).compress
      else
        emit s!"{node.hex}  {e.verdict}  ({e.elapsedMs} ms)"
        if e.status == .error then emit s!"error: {e.reason}"
      pure (match e.status with | .pass => 0 | .fail => 1 | .error => 2)
    catch error =>
      Result.fromIO Error.storage (IO.eprintln s!"error: {error.describe}")
      pure exitNoVerdict
  | ["commit", pfx, dir] =>
    let data ← openData args
    let hash ← commit data.store data.workspaces (← resolve data.store pfx) dir
      ((args.get? "note").filter (!·.isEmpty)) (tell? := (args.get? "tell").filter (!·.isEmpty))
    emit hash.hex
    pure 0
  | ["checkout", pfx, dir] =>
    let data ← openData args
    let state ← getState data.store (← resolve data.store pfx)
    data.workspaces.materialize state.workspace dir
    emit s!"checked out {state.workspace.hex} into {dir}"
    pure 0
  | "html" :: rest =>
    let data ← openData args
    let out : System.FilePath := rest.head?.getD (data.path / "report.html").toString
    -- Repeatable, and each may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := (args.all "hide").foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    -- The page has one view and one tool list, so the forest's roots must agree on the agent.
    let roots ← (← allStates data.store).filterM fun h => do pure (← getState data.store h).parent?.isNone
    let some first := roots[0]? | throw <| .configuration "nothing to report: the data directory holds no states"
    let spec ← recordedAgent data.store args first
    for root in roots do
      if (← recordedAgent data.store args root).config.compress != spec.config.compress then
        throw <| .configuration <|
          s!"the roots of {data.path} were created with different agents; a report renders one " ++
          "agent's runs, so give each its own data directory"
    let page ← Html.report data.store data.workspaces s!"alaya {data.path}" spec.view spec.tools hidden
    Result.fromIO Error.storage (IO.FS.writeFile out page)
    emit s!"wrote {out} ({page.length} bytes)"
    pure 0
  | ["tree"] =>
    let data ← openData args
    emitLines (← treeLines data.store)
    pure 0
  | ["show", pfx] =>
    let data ← openData args
    let hash ← resolve data.store pfx
    let view? ← if args.isSet "view" then some <$> (·.view) <$> recordedAgent data.store args hash else pure none
    emitLines (← showLines data.store hash view?)
    pure 0
  | ["diff", a, b] =>
    let data ← openData args
    emitLines (← diffLines data.store data.workspaces (← resolve data.store a) (← resolve data.store b))
    pure 0
  | ["rm", pfx] =>
    let data ← openData args
    let n ← removeSubtree data.store data.workspaces (← resolve data.store pfx)
    emit s!"removed {n} state(s)"
    pure 0
  | _ =>
    throw <| .configuration <|
      "usage: alaya (root (--task TEXT | --task-file FILE) [PROJECT] --image I [--workdir P] --agent FILE | " ++
      "resume HASH --model P:M [--time-budget S] | step HASH --model P:M [--time-budget S] | " ++
      "eval HASH --grader CMD [--input DIR] [--grader-image IMAGE] [--timeout S] | commit HASH DIR [-m NOTE] [--tell TEXT] | tell HASH TEXT | " ++
      "reply HASH TEXT | reply-unavailable HASH | waiting | question-context HASH | " ++
      "question-files HASH [PATH] | question-file HASH PATH | ls HASH [PATH] | cat HASH PATH | " ++
      "checkout HASH DIR | tree | " ++
      "html [FILE] [--hide DIR] | " ++
      "show HASH [--view] | diff A B | rm HASH) " ++
      "[--data D] [--json] [--temperature T] [--url U] [--port N] [--echo-reasoning] [--image IMAGE] [--network N] " ++
      "[--timeout S]"

/-- Exit 0 on success, 3 when a run stopped at a question (`exitWaiting`), 4 when it stopped
because the time budget was spent (`exitOutOfTime`), 1 on error. `eval` exits with its verdict:
0 pass, 1 fail, 2 error, and 5 when it recorded none (`exitNoVerdict`). -/
def main (args : List String) : IO UInt32 := do
  match ← (dispatch args).toBaseIO with
  | .ok code => pure code
  | .error error =>
    IO.eprintln s!"error: {error.describe}"
    pure 1
