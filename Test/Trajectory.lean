import Test.Framework
import Test.DirectoryWorkspaces
import Test.Scripted
import Alaya

/-! Tests of the trajectory tree: tell, commit, questions and replies, the report, images, forks,
evaluation, resume and replay. The mini-SWE agent drives it, with a scripted model behind the
persistent cache. -/

namespace TrajectoryTests

open Testing
open Scripted
open Alaya
open Alaya.Agent (Dialogue Outcome Event Log Stop)
open Alaya.Agent.MiniSwe
open Alaya.Trajectory

/-- A scripted model wrapped in the persistent cache, so draw indexing and replay behave exactly
as the real stack does — the mechanism `resume`/fork rely on — driving the mini agent. -/
private def cachedRuntime (responses : Array Chat.Response) (config : Config := {}) :
    TestM Runtime := do
  let model ← scriptedModel responses
  let cached ← assertOk <| Cache.persistent model { directory := (← scratch) / "cache" }
  let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
  let work ← workDir
  let executor := Executor.onHost config.executor
  pure { store, workspaces := ← workspaces, workDir := work, executor, model := cached
         agent := agent executor config }

/-- A root for the test task over `project`. -/
private def mkRoot (rt : Runtime) (project : System.FilePath) (image? : Option String := none) :
    TestM Hash :=
  assertOk <| createRoot rt.store rt.workspaces (initialLog {} "t" testUname) project (some "t") image? (agent := ({} : Config).toJson)

/-- A directory standing in for a hidden test set. -/
private def testsDir : TestM System.FilePath := do
  let dir := (← scratch) / "tests-src"
  assertOk <| Result.fromIO Error.storage do
    IO.FS.createDirAll (dir / "tests")
    IO.FS.writeFile (dir / "tests" / "extra.txt") "hidden\n"
  -- Absolute: a grader runs inside the checkout, where a relative path would not resolve.
  assertOk <| Result.fromIO Error.storage (IO.FS.realPath dir)

private def emptyProject : TestM System.FilePath := do
  let proj := (← scratch) / "proj"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll proj)
  pure proj

/-- An agent that can ask a person: mini's `bash`, plus `ask_user`, which stops the run to wait.
Mini itself does not offer the tool, so this is what exercises the trajectory's question and
reply path; it shows an agent needs nothing from the trajectory but the four operations. -/
private def askTool : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask the person supervising the run"
  parameters := .object #[("message", .string)]
}

private def askingAgent (executor : Executor) : Agent.Agent := {
  identity := .mkObj [("agent", "asking-test-agent")]
  tools := #[Alaya.Agent.Tools.Bash.definition, askTool]
  view := fun log => log.map fun
    | .message m => m
    | .response r => .assistant r.content? r.toolCalls r.reasoning?
    | .observation id content => .tool id content
  next := fun _ log =>
    match log.pending[0]? with
    | none => .sample
    | some call =>
      if call.name == "ask_user" then
        .ask call.id { text := ((call.arguments.getObjVal? "message" >>= Lean.Json.getStr?).toOption.getD "?") }
      else if call.name == "submit" then .done { status := "Submitted" }
      else .act call
  act := act executor
}

private def askingRuntime (responses : Array Chat.Response) : TestM Runtime := do
  let rt ← cachedRuntime responses
  pure { rt with agent := askingAgent rt.executor }

def suite : Suite := Testing.suite "trajectory" #[
  test "tell records a notice the model sees, and the run continues from it" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo ok"]]
    let root ← mkRoot rt (← emptyProject)
    let told ← assertOk <| tell rt.store root "Please re-run your checks."
    let state ← assertOk (getState rt.store told)
    check (state.kind == .message) "a tell is a message state"
    check (state.workspace == (← assertOk (getState rt.store root)).workspace) "a tell keeps the workspace"
    match (view {} (← assertOk (logOf rt.store told))).back? with
    | some (.user notice) =>
      check (contains notice "Please re-run your checks.") "the notice carries the message verbatim"
      check (contains notice "<intervention>") "the notice is enveloped"
    | _ => fail "expected the notice as the last user turn"
    let next ← stepped <| stepOnce rt "test:model" told
    check ((← assertOk (getState rt.store next)).kind == .turn) "the run continues after a tell",

  test "the report gives a file replaced by a directory, or the reverse, no text on the directory row" do
    let rt ← cachedRuntime #[]
    let project ← emptyProject
    writeSpec project #[("toDir", "was a file"), ("toFile/inner.txt", "inner")]
    let root ← mkRoot rt project
    IO.FS.removeFile (project / "toDir")
    writeSpec project #[("toDir/new.txt", "new")]
    IO.FS.removeDirAll (project / "toFile")
    IO.FS.writeFile (project / "toFile") "now a file"
    let child ← assertOk <| commit rt.store rt.workspaces root project (some "retyped")
    let page ← assertOk <| Html.dataJson rt.store rt.workspaces (view {}) (tools {})
    let states ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "states" >>= Lean.Json.getArr?)
    let some state := states.find? fun s =>
        (s.getObjVal? "hash" >>= Lean.Json.getStr?).toOption == some child.hex
      | fail "the commit is missing from the report"
    let changes ← assertOk <| Result.fromExcept Error.storage (state.getObjVal? "changes" >>= Lean.Json.getArr?)
    let rows := changes.map fun c =>
      ((c.getObjVal? "path" >>= Lean.Json.getStr?).toOption.getD "",
       (c.getObjVal? "kind" >>= Lean.Json.getStr?).toOption.getD "",
       (c.getObjVal? "old" >>= Lean.Json.getStr?).toOption,
       (c.getObjVal? "new" >>= Lean.Json.getStr?).toOption)
    assertEqual "rows" rows #[
      ("toDir", "removed", some "was a file", none), ("toDir", "added", none, none),
      ("toFile", "removed", none, none), ("toFile", "added", none, some "now a file")],

  test "commit --tell lists the changed paths in the notice" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let edited := (← scratch) / "edited"
    assertOk <| Result.fromIO Error.storage do
      IO.FS.createDirAll edited
      IO.FS.writeFile (edited / "fix.txt") "fixed\n"
    let silent ← assertOk <| commit rt.store rt.workspaces root edited (some "fix")
    check (← assertOk (getState rt.store silent)).appended.isEmpty "without --tell a commit stays silent"
    let child ← assertOk <| commit rt.store rt.workspaces root edited (some "fix") (tell? := some "I added a file.")
    let state ← assertOk (getState rt.store child)
    check (state.kind == .intervention) "still an intervention"
    match state.intervention? with
    | some i => assertEqual "changed paths" i.changed #["+ fix.txt"]
    | none => fail "expected the intervention record"
    match state.appended.back? with
    | some (.message (.user notice)) =>
      check (contains notice "+ fix.txt" && contains notice "I added a file.")
        "the notice lists the added path and the message"
    | _ => fail "expected a notice",

  test "an ask_user call stops the run at a question, and a reply continues it" do
    let ask : Chat.ToolCall :=
      { id := "q1", name := "ask_user", arguments := .mkObj [("message", "Exact wording or mine?")] }
    let rt ← askingRuntime #[
      responseWith #[call "a" "bash" "echo before > before.txt", ask,
                     call "b" "bash" "echo after > after.txt"],
      responseWith #[submitCall "c"]]
    let root ← mkRoot rt (← emptyProject)
    let stopped := (← assertOk <| resume rt "test:model" root (fun _ => pure ())).state
    let state ← assertOk (getState rt.store stopped)
    check (state.kind == .question) "the run stops at a question"
    assertEqual "question" state.question? (some { callId := "q1", text := "Exact wording or mine?" })
    check (← assertOk (rt.workspaces.readFile? state.workspace "before.txt")).isSome
      "the call before the question ran"
    check (← assertOk (rt.workspaces.readFile? state.workspace "after.txt")).isNone
      "the call after the question did not run"
    check ((← assertOk (waiting rt.store)).size == 1) "the question is open"
    match ← (stepOnce rt "test:model" stopped).toBaseIO with
    | .ok _ => fail "a waiting state must not be continued without a reply"
    | .error _ => pure ()
    let answered ← assertOk <| reply rt.store stopped "Exact wording."
    check ((← assertOk (getState rt.store answered)).kind == .reply) "a reply state"
    match (← assertOk (logOf rt.store answered)).back? with
    | some (.observation "q1" (.str "Exact wording.")) => pure ()
    | _ => fail "the reply is the observation of the asking call, verbatim"
    check (← assertOk (waiting rt.store)).isEmpty "an answered question is not open"
    let final := (← assertOk <| resume rt "test:model" answered (fun _ => pure ())).state
    check ((← assertOk (getState rt.store final)).outcome?.isSome)
      "the run continues to its outcome after the reply",

  test "the report carries each state's context exactly as the model is sent it" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo one", call "b" "bash" "echo two"],
      responseWith #[]]   -- a format error: the view substitutes a user turn, and the wire has it
    let root ← mkRoot rt (← emptyProject)
    let first ← stepped <| stepOnce rt "test:model" root
    let second ← stepped <| stepOnce rt "test:model" first
    let page ← assertOk <| Html.dataJson rt.store rt.workspaces (view {}) (tools {})
    let states ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "states" >>= Lean.Json.getArr?)
    let envelope ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "request")
    -- Assemble the context as the page does: every state's `wire` from the root down.
    let wireOf (hash : Hash) : TestM (Array Lean.Json) := do
      match states.find? (fun s => (s.getObjVal? "hash" >>= Lean.Json.getStr?).toOption == some hash.hex) with
      | some s => assertOk <| Result.fromExcept Error.storage (s.getObjVal? "wire" >>= Lean.Json.getArr?)
      | none => fail s!"state {hash.hex} missing from the report"
    let assembled := envelope.setObjVal! "messages"
      (.arr ((← wireOf root) ++ (← wireOf first) ++ (← wireOf second)))
    let sent : Chat.Request := { messages := view {} (← assertOk (logOf rt.store second)), tools := tools {} }
    assertStringEq "request" assembled.compress sent.toJson.compress
    check ((← wireOf second).size == 1) "the format-error state adds exactly one wire message",

  iotest "events round-trip through storage" do
    let events : Array Event := #[
      .message (.system "sys"), .message (.user "task text"),
      .response {
        content? := some "thinking", reasoning? := some "trace", finishReason? := some "tool_calls",
        usage? := some { input? := some 10, output? := some 5 },
        toolCalls := #[
          { id := "c1", name := "bash", arguments := .mkObj [("command", ("ls" : Lean.Json))] },
          { id := "c2", name := "bash", arguments := .null, invalidArguments? := some "{\"command\": \"x" }] },
      .observation "c1" (.mkObj [("output", "a\n"), ("returncode", (0 : Lean.Json))]),
      .observation "c2" (.str "plain text")]
    for event in events do
      match eventFromJson (eventToJson event) with
      | .error e => throw <| IO.userError s!"round-trip failed: {e}"
      | .ok back =>
        if (eventToJson back).compress != (eventToJson event).compress then
          throw <| IO.userError s!"round-trip mismatch: {(eventToJson back).compress}",

  test "the image is recorded at the root and inherited by every child" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let pinned := "example.test/img@sha256:0123456789abcdef"
    let root ← mkRoot rt (← emptyProject) (some pinned)
    assertEqual "root" (← assertOk (getState rt.store root)).image? (some pinned)
    let child ← stepped <| stepOnce rt "test:model" root
    assertEqual "turn" (← assertOk (getState rt.store child)).image? (some pinned)
    let edited ← emptyProject
    let intervention ← assertOk <| commit rt.store rt.workspaces child edited (some "by hand")
    assertEqual "intervention" (← assertOk (getState rt.store intervention)).image? (some pinned)
    -- A trajectory created without an image keeps running on the host.
    let hostRoot ← mkRoot rt (← emptyProject)
    assertEqual "host root" (← assertOk (getState rt.store hostRoot)).image? none,

  test "a fork does not inherit the abandoned branch's files" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo junk > junk.txt"],
      responseWith #[call "b" "bash" "echo other > other.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← stepped <| stepOnce rt "test:model" root
    check (← assertOk (rt.workspaces.readFile? (← assertOk (getState rt.store first)).workspace "junk.txt")).isSome
      "the first branch should have written junk.txt"
    -- Forking checks the root's workspace out again: the first branch's file must be gone.
    let second ← stepped <| stepOnce rt "test:model" root
    let state ← assertOk (getState rt.store second)
    check (← assertOk (rt.workspaces.readFile? state.workspace "other.txt")).isSome
      "the second branch should have written other.txt"
    check (← assertOk (rt.workspaces.readFile? state.workspace "junk.txt")).isNone
      "a fork must not start from the abandoned branch's workspace",

  test "a grader runs on the host against a checkout, and its files never reach a later turn" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo hi > after.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let tests ← testsDir
    let scratch := (← scratch) / "eval"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root
      ("cp -R " ++ tests.toString ++ "/. {checkout}/ && test -f {checkout}/tests/extra.txt")
    let state ← assertOk (getState rt.store node)
    assertEqual "kind" state.kind Kind.evaluation
    assertEqual "verdict" (state.evaluation?.map (·.passed)) (some true)
    -- The evaluation's workspace is the checkout as the grader left it, and the next turn from
    -- the root does not see the tests.
    check (← assertOk (rt.workspaces.readFile? state.workspace "tests/extra.txt")).isSome
      "the evaluation's workspace holds what the grader did"
    let child ← stepped <| stepOnce rt "test:model" root
    check (← assertOk (rt.workspaces.readFile? (← assertOk (getState rt.store child)).workspace "tests/extra.txt")).isNone
      "a grader's files must never reach a state the agent continues from"
    -- Nothing may continue from the evaluation.
    assertError "step" (stepOnce rt "test:model" node) fun
      | .configuration m => (m.splitOn "cannot continue from an evaluation").length > 1
      | _ => false
    assertError "commit" (commit rt.store rt.workspaces node (← emptyProject) none) fun
      | .configuration m => (m.splitOn "cannot build on an evaluation").length > 1
      | _ => false,

  test "a failing grader is a failing verdict, and re-evaluating adds a new evaluation" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let scratch := (← scratch) / "eval"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root "exit 3"
    let state ← assertOk (getState rt.store node)
    assertEqual "returncode" (state.evaluation?.map (·.returncode)) (some 3)
    assertEqual "passed" (state.evaluation?.map (·.passed)) (some false)
    assertEqual "no evidence" (state.evaluation?.bind (·.evidence?)) none
    let again ← assertOk <| evaluate rt.store rt.workspaces scratch root "exit 3"
    check (again != node) "expected the same grader to run again as a new evaluation"
    assertEqual "two children" (← assertOk (children rt.store root)).size 2
    -- A different grader is another evaluation of the same state.
    let other ← assertOk <| evaluate rt.store rt.workspaces scratch root "true"
    check (other != node && other != again) "expected a distinct node for a distinct grader"
    assertEqual "three children" (← assertOk (children rt.store root)).size 3,

  test "a grader's verdict.json decides, and its output directory is kept as evidence" do
    let rt ← cachedRuntime #[]
    let project ← emptyProject
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "app.txt") "code\n")
    let root ← mkRoot rt project
    let scratch := (← scratch) / "eval"
    -- Exit status 1, but the verdict says passed: the verdict wins. The report beside it is kept.
    let grader := "test -f {checkout}/app.txt && " ++
      "printf '{\"passed\": true, \"score\": {\"passed\": 3, \"total\": 4}}' > {out}/verdict.json && " ++
      "echo detail > {out}/report.txt && exit 1"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root grader
    let state ← assertOk (getState rt.store node)
    let some e := state.evaluation? | fail "expected an evaluation"
    assertEqual "returncode" e.returncode 1
    check e.passed "verdict.json says passed"
    assertEqual "score" e.score? (some (3, 4))
    assertEqual "verdict line" e.verdict "pass 3/4"
    let some evidence := e.evidence? | fail "expected the output directory as evidence"
    assertEqual "report kept"
      ((← assertOk (rt.workspaces.readFile? evidence "report.txt")).map (String.fromUTF8? ·))
      (some (some "detail\n"))
    check (← assertOk (rt.workspaces.readFile? evidence "verdict.json")).isSome "verdict.json is in the evidence"
    -- The checkout is gone afterwards; only the store holds what was tested.
    check (!(← (scratch / "checkout").pathExists)) "the checkout is discarded",

  test "resume drives to submission and records a chain of turns" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[submitCall "c2" "done"]]
    let root ← mkRoot rt (← emptyProject)
    let final := (← assertOk <| resume rt "test:model" root (fun _ => pure ())).state
    let fstate ← assertOk <| getState rt.store final
    assertEqual "submitted" (fstate.outcome?.map (·.status)) (some "Submitted")
    assertEqual "submission" (fstate.outcome?.map (·.submission)) (some "done")
    -- root → turn(edit) → turn(submit): the submit turn records the response and no observation.
    let middle ← match fstate.parent? with
      | some p => pure p
      | none => fail "the final state has a parent"
    let mstate ← assertOk <| getState rt.store middle
    assertEqual "middle kind" mstate.kind Kind.turn
    assertEqual "middle parent" mstate.parent? (some root)
    assertEqual "middle events" mstate.appended.size 2
    assertEqual "final events" fstate.appended.size 1
    check (← assertOk (rt.workspaces.readFile? fstate.workspace "a.txt")).isSome "the edit is in the final workspace"
    -- The tree shows the calls by name and argument.
    let lines ← assertOk <| treeLines rt.store
    check (lines.any fun line => contains line "bash  echo hi > a.txt") "the tree labels a turn by its call"
    check (lines.any fun line => contains line "[Submitted]") "the tree marks the outcome",

  test "replaying a branch from the cache does not ask the model again" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[submitCall "c2"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← stepped <| stepOnce rt "test:model" root
    -- A second continuation from the root asks for draw 1: the scripted model's next response.
    let sibling ← stepped <| stepOnce rt "test:model" root
    check (first != sibling) "a new continuation is a fresh sibling"
    assertEqual "two turn children" (← assertOk (children rt.store root)).size 2
    -- The scripted model is exhausted now, so any further sample would fail; a reply, tell, or
    -- commit child does not consume a draw and does not ask.
    let told ← assertOk <| tell rt.store root "note"
    check ((← assertOk (getState rt.store told)).kind == .message) "a tell is recorded without a sample"
]

end TrajectoryTests
