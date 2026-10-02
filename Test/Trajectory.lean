import Test.Framework
import Test.DirectoryWorkspaces
import Test.Scripted
import Test.Container
import Alaya

/-! Tests of the trajectory tree: tell, commit, questions and replies, the report, images, forks,
evaluation, resume and replay. The mini-SWE agent drives it, with a scripted model behind the
persistent cache. -/

namespace TrajectoryTests

open Testing
open Scripted
open Alaya
open Alaya.Agent (Dialogue Outcome Event Log)
open Alaya.Agent.MiniSwe
open Alaya.Trajectory
open Alaya.Driver

/-- A scripted model wrapped in the persistent cache, so draw indexing and replay behave exactly
as the real stack does — the mechanism `resume`/fork rely on — driving the mini agent. -/
private def cachedRuntime (responses : Array Chat.Response) (config : Config := {}) :
    TestM Runtime := do
  let model ← scriptedModel responses
  let cached ← assertOk <| Cache.persistent model { directory := (← scratch) / "cache" }
  let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
  let work ← workDir
  let executor ← containerExecutor
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir := work.withFileName "outputs", executor, model := cached
         agent := agent config }

/-- A root for the test task over `project`. -/
private def mkRoot (rt : Runtime) (project : System.FilePath) (image? : Option String := none) :
    TestM Hash := do
  let image ← match image? with
    | some image => pure image
    | none => testImage
  assertOk <| createRoot rt.store rt.workspaces (initialLog {} "t" testUname) project image (some "t")
    (agent := ({} : Config).toJson) (model := testModel)

/-- A directory standing in for a grader's trusted input: a hidden test set. -/
private def testsDir : TestM System.FilePath := do
  let dir := (← scratch) / "tests-src"
  assertOk <| Result.fromIO Error.storage do
    IO.FS.createDirAll (dir / "tests")
    IO.FS.writeFile (dir / "tests" / "extra.txt") "hidden\n"
  pure dir

private def emptyProject : TestM System.FilePath := do
  let proj := (← scratch) / "proj"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll proj)
  pure proj

/-- An agent that can ask a person: mini's `bash`, plus `ask_user`, which stops the run to wait.
Mini itself does not offer the tool, so this is what exercises the trajectory's question and
reply path; it shows an agent needs nothing from the trajectory but its effects. -/
private def askTool : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask the person supervising the run"
  parameters := .object #[("message", .string)]
}

private def askingView (log : Log) : Dialogue :=
  let index := log.index
  log.filterMap fun
    | .told m => some m
    | .sampled _ _ r => some r.message
    | .recorded call content => (index.callId? call).map (.tool · content)
    | .executed call _ _ output _ => (index.callId? call).map (.tool · output.toJson)
    | .placed _ | .timed .. => none

private def askingTools : Array Chat.ToolDefinition := #[Alaya.Agent.Tools.Bash.definition, askTool]

private def askingAgent : Agent.Agent := {
  config := .mkObj [("agent", "asking-test-agent")]
  initialLog := fun _ _ => #[]
  next := fun log =>
    match log.pending[0]? with
    | none => .inl (.sample .turn { messages := askingView log, tools := askingTools })
    | some ({ ref, call, .. } : Agent.Call) =>
      if call.name == "ask_user" then
        .inl (.ask ref { text := ((call.arguments.getObjVal? "message" >>= Lean.Json.getStr?).toOption.getD "?") })
      else if call.name == "submit" then .inr { status := "Submitted" }
      else match Alaya.Agent.Tools.Bash.command call.arguments with
        | .ok command => .inl (.exec ref command {})
        | .error _ => .inr { status := "Malformed" }
}

private def askingRuntime (responses : Array Chat.Response) : TestM Runtime := do
  let rt ← cachedRuntime responses
  pure { rt with agent := askingAgent }

def suite : Suite := Testing.suite "trajectory" #[
  test "a continuation stops after the turns it was allowed, and a later one goes on" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo 1"],
      responseWith #[call "b" "bash" "echo 2"], responseWith #[call "c" "bash" "echo 3"]]
    let root ← mkRoot rt (← emptyProject)
    let seen ← IO.mkRef #[]
    let (first, halt) ← assertOk <| resume rt root { steps? := some 2 } (fun h => seen.modify (·.push h))
    check (halt == .outOfSteps) "stopped for its turns, not for time"
    assertEqual "two turns, the last is where it stopped" (← seen.get).back? (some first)
    assertEqual "two turns" (← seen.get).size 2
    let (second, halt) ← assertOk <| resume rt first { steps? := some 1 }
    check (halt == .outOfSteps) "one more turn"
    assertEqual "from where the first stopped" (← assertOk (getState rt.store second)).parent?
      (some first),

  test "tell records a notice the model sees, and the run continues from it" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo ok"]]
    let root ← mkRoot rt (← emptyProject)
    let told ← assertOk <| tell rt.store root "Please re-run your checks."
    let state ← assertOk (getState rt.store told)
    check (state.intervention?.map (·.changed.isEmpty) == some true)
      "a tell is an intervention with no change"
    check (state.workspace == (← assertOk (getState rt.store root)).workspace) "a tell keeps the workspace"
    match (view {} (← assertOk (logOf rt.store told))).back? with
    | some (.user notice) =>
      check (contains notice "Please re-run your checks.") "the notice carries the message verbatim"
      check (contains notice "<intervention>") "the notice is enveloped"
    | _ => fail "expected the notice as the last user turn"
    let next ← stepped <| step rt told
    check ((← assertOk (getState rt.store next)).kind matches .step ..) "the run continues after a tell",

  test "the report gives a file replaced by a directory, or the reverse, no text on the directory row" do
    let rt ← cachedRuntime #[]
    let project ← emptyProject
    writeSpec project #[("toDir", "was a file"), ("toFile/inner.txt", "inner")]
    let root ← mkRoot rt project
    IO.FS.removeFile (project / "toDir")
    writeSpec project #[("toDir/new.txt", "new")]
    IO.FS.removeDirAll (project / "toFile")
    IO.FS.writeFile (project / "toFile") "now a file"
    let child ← assertOk <| commit rt.store rt.workspaces root project
    let page ← assertOk <| Html.dataJson rt.store rt.workspaces (fun _ => pure rt.agent)
    let states ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "states" >>= Lean.Json.getArr?)
    let some state := states.find? fun s =>
        (s.getObjVal? "hash" >>= Lean.Json.getStr?).toOption == some child.hex
      | fail "the commit is missing from the report"
    -- A commit samples nothing, so it has no request, and the page shows no context for it.
    check ((state.getObjValAs? Bool "sampled").toOption == some false) "a commit sampled nothing"
    check ((state.getObjVal? "contextTokens").toOption == some .null) "no request, no size"
    assertEqual "context size" (state.getObjValAs? Nat "contextSize").toOption (some 131072)
    let some rootJson := states.find? fun s => (s.getObjVal? "parent").toOption == some .null
      | fail "the root is missing from the report"
    assertEqual "the root's model" ((rootJson.getObjVal? "model").toOption.map (·.compress)) (some testModel.compress)
    let changes ← assertOk <| Result.fromExcept Error.storage (state.getObjVal? "changes" >>= Lean.Json.getArr?)
    let rows := changes.map fun c =>
      ((c.getObjVal? "path" >>= Lean.Json.getStr?).toOption.getD "",
       (c.getObjVal? "kind" >>= Lean.Json.getStr?).toOption.getD "",
       (c.getObjVal? "old" >>= Lean.Json.getStr?).toOption,
       (c.getObjVal? "new" >>= Lean.Json.getStr?).toOption)
    assertEqual "rows" rows #[
      ("toDir", "removed", some "was a file", none), ("toDir", "added", none, none),
      ("toFile", "removed", none, none), ("toFile", "added", none, some "now a file")],

  test "a commit always tells the agent what changed, and refuses a directory with no change" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let unchanged ← emptyProject
    assertError "no change" (commit rt.store rt.workspaces root unchanged "nothing") fun
      | .input m => (m.splitOn "use `tell`").length > 1
      | _ => false
    let edited := (← scratch) / "edited"
    assertOk <| Result.fromIO Error.storage do
      IO.FS.createDirAll edited
      IO.FS.writeFile (edited / "fix.txt") "fixed\n"
    let child ← assertOk <| commit rt.store rt.workspaces root edited
    let state ← assertOk (getState rt.store child)
    check (state.kind matches .intervention _) "an intervention"
    match state.intervention? with
    | some i => assertEqual "changed paths" i.changed #["+ fix.txt"]
    | none => fail "expected the intervention record"
    match state.appended with
    | #[.placed _, .told (.user notice)] =>
      assertEqual "the notice" notice
        "<intervention>\nA person changed the workspace while you were paused:\n  + fix.txt\n</intervention>"
    | _ => fail "expected exactly the notice"
    -- With a message, the same notice says what the person says of the change, after the list;
    -- the tree labels the commit by it, and by what changed when there is none.
    let said ← assertOk <| commit rt.store rt.workspaces root edited "The fixture was wrong.\nThe parser is yours."
    match (← assertOk (getState rt.store said)).appended with
    | #[.placed _, .told (.user notice)] =>
      assertEqual "the notice, with the message" notice
        ("<intervention>\nA person changed the workspace while you were paused:\n  + fix.txt\n" ++
          "The fixture was wrong.\nThe parser is yours.\n</intervention>")
    | _ => fail "expected exactly the notice"
    assertEqual "its message is recorded" ((← assertOk (getState rt.store said)).intervention?.map (·.message))
      (some "The fixture was wrong.\nThe parser is yours.")
    let tree ← assertOk <| treeLines rt.store
    check (tree.any (contains · "commit  The fixture was wrong.")) s!"a commit is labelled by its message: {tree}"
    check (tree.any (contains · "commit  + fix.txt")) s!"or by what it changed: {tree}",

  test "an ask_user call stops the run at a question, and a reply continues it" do
    let ask : Chat.ToolCall :=
      { id := "q1", name := "ask_user", arguments := .mkObj [("message", "Exact wording or mine?")] }
    let rt ← askingRuntime #[
      responseWith #[call "a" "bash" "echo before > before.txt", ask,
                     call "b" "bash" "echo after > after.txt"],
      responseWith #[submitCall "c"]]
    let root ← mkRoot rt (← emptyProject)
    let stopped := (← assertOk <| resume rt root).1
    let state ← assertOk (getState rt.store stopped)
    check state.question?.isSome "the run stops at a question"
    -- The asking call is the second of the turn's response, after the root's opening and workspace.
    assertEqual "question" state.asked?
      (some { call := { response := 3, index := 1 }, question := { text := "Exact wording or mine?" } })
    check (← assertOk (rt.workspaces.readFile? state.workspace "before.txt")).isSome
      "the call before the question ran"
    check (← assertOk (rt.workspaces.readFile? state.workspace "after.txt")).isNone
      "the call after the question did not run"
    check ((← assertOk (waiting rt.store)).size == 1) "the question is open"
    match ← (step rt stopped).toBaseIO with
    | .ok _ => fail "a waiting state must not be continued without a reply"
    | .error _ => pure ()
    let answered ← assertOk <| replyText rt.store stopped "Exact wording."
    check ((← assertOk (getState rt.store answered)).kind matches .reply) "a reply state"
    match (← assertOk (logOf rt.store answered)).back? with
    | some (.recorded { response := 3, index := 1 } (.str "Exact wording.")) => pure ()
    | _ => fail "the reply is the observation of the asking call, verbatim"
    check (← assertOk (waiting rt.store)).isEmpty "an answered question is not open"
    let final := (← assertOk <| resume rt answered).1
    check ((← assertOk (getState rt.store final)).outcome?.isSome)
      "the run continues to its outcome after the reply",

  test "the report carries the request each turn was sent, exactly" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo one", call "b" "bash" "echo two"],
      responseWith #[],   -- a format error: the view substitutes a user turn, and the wire has it
      responseWith #[submitCall "s"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← stepped <| step rt root
    let second ← stepped <| step rt first
    let third ← stepped <| step rt second
    let page ← assertOk <| Html.dataJson rt.store rt.workspaces (fun _ => pure rt.agent)
    let states ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "states" >>= Lean.Json.getArr?)
    let stateOf (hash : Hash) : TestM Lean.Json := do
      match states.find? (fun s => (s.getObjVal? "hash" >>= Lean.Json.getStr?).toOption == some hash.hex) with
      | some s => pure s
      | none => fail s!"state {hash.hex} missing from the report"
    let wireOf (hash : Hash) : TestM (Array Lean.Json) := do
      assertOk <| Result.fromExcept Error.storage ((← stateOf hash).getObjVal? "wire" >>= Lean.Json.getArr?)
    check (((← stateOf root).getObjValAs? Bool "sampled").toOption == some false) "a root sampled nothing"
    -- Assemble the third turn's request as the page does: each turn's `wire` from the first down.
    let index ← assertOk <| Result.fromExcept Error.storage ((← stateOf third).getObjValAs? Nat "envelope")
    let some envelope := ((page.getObjVal? "envelopes").toOption.bind (·.getArrVal? index |>.toOption))
      | fail "the third turn's envelope is missing"
    let assembled := envelope.setObjVal! "messages"
      (.arr ((← wireOf first) ++ (← wireOf second) ++ (← wireOf third)))
    -- What the third turn was sent: the request of the log before its response.
    let sent := request {} (← assertOk (logOf rt.store second))
    assertStringEq "request" assembled.compress sent.toJson.compress
    check ((← wireOf third).size == 1) "the turn after a format error adds exactly the correction",

  test "a state holds only what its kind may, or it is not written" do
    let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
    let w : Hash := ⟨"".pushn 'a' 64⟩
    let root ← assertOk <| putState store {
      parent? := none, workspace := w, kind := testRoot
      appended := #[.told (.user "task"), .placed w] }
    -- After the root's opening and workspace, a step's response is at log position 2.
    let answer : Event := .recorded { response := 2, index := 0 } (.str "x")
    let turn : Event := .sampled default .turn (responseWith #[call "c" "bash" "ls"])
    let refused (label : String) (state : State) : TestM Unit :=
      assertError label (putState store state) fun
        | .storage m => contains m "refusing a malformed"
        | _ => false
    let other : Hash := ⟨"".pushn 'b' 64⟩
    let base : State := { parent? := some root, workspace := w, kind := .step, appended := #[] }
    refused "a step with a message" { base with appended := #[turn, .told (.user "hi")] }
    refused "a step with a workspace" { base with appended := #[.placed w] }
    refused "a step sampling twice" { base with appended := #[turn, answer, turn] }
    refused "a step sampling after an answer" { base with appended := #[answer, turn] }
    refused "a root without its workspace" { base with parent? := none, kind := testRoot, appended := #[.told (.user "t")] }
    refused "a root with history" { base with parent? := none, kind := testRoot, appended := #[turn, .placed w] }
    refused "a root at another workspace" { base with parent? := none, kind := testRoot, appended := #[.placed other] }
    refused "a reply of two answers" { base with kind := .reply, appended := #[answer, answer] }
    refused "an evaluation with events" { base with kind := .evaluation default, appended := #[answer] }
    refused "a tell that changes files" { base with kind := .intervention { message := "m", changed := #["+ f"] }
                                                    appended := #[.told (.user "m")] }
    -- What each kind may hold is written.
    let answered ← assertOk <| putState store { base with appended := #[turn, answer, .timed 1 none] }
    let _ ← assertOk <| putState store base
    -- A state agrees with the branch it grows, or it is not written: its answers name calls made
    -- before them that nothing has answered.
    refused "an answer to no call" { base with appended := #[answer, .timed 1 none] }
    refused "an answer to a call that is not there" { base with appended :=
      #[turn, .recorded { response := 2, index := 1 } (.str "x")] }
    refused "a second answer in the step" { base with appended := #[turn, answer, answer] }
    refused "a second answer in a later step" { base with parent? := some answered, appended := #[answer] }
    -- Its workspace is the latest snapshot its log names.
    refused "a workspace the log does not name" { base with workspace := other }
    let ran : Event := .executed { response := 2, index := 0 } "ls" {} { output := "" } other
    refused "the workspace its command left behind" { base with appended := #[turn, ran] }
    let _ ← assertOk <| putState store { base with workspace := other, appended := #[turn, ran] }
    -- Nothing grows from an evaluation; a state that waits grows only by a reply, which answers
    -- its question, and an evaluation is a verdict on any state.
    refused "an evaluation at another workspace" { base with kind := .evaluation default, workspace := other }
    let verdict ← assertOk <| putState store { base with kind := .evaluation { (default : Evaluation) with checkout := other } }
    assertEqual "an evaluation shows the grader's checkout" (← assertOk <| getState store verdict).snapshot other
    assertEqual "and leaves the run's workspace" (← assertOk <| getState store verdict).workspace w
    refused "a step from an evaluation" { base with parent? := some verdict }
    let question : Asked := { call := { response := 2, index := 0 }, question := { text := "which?" } }
    let waits ← assertOk <| putState store { base with appended := #[turn], kind := .step none (some (.inr question)) }
    refused "a step from a state that waits" { base with parent? := some waits }
    refused "a reply to another call" { base with parent? := some waits, kind := .reply
                                                  appended := #[.recorded { response := 2, index := 1 } (.str "x")] }
    refused "a reply where nothing is asked" { base with kind := .reply, appended := #[answer] }
    let yesNo : Asked := { call := question.call, question := { text := "keep it?", form := .yesNo } }
    let asks ← assertOk <| putState store { base with appended := #[turn], kind := .step none (some (.inr yesNo)) }
    let said (answer : String) : State :=
      { base with parent? := some asks, kind := .reply, appended := #[.recorded { response := 2, index := 0 } (.str answer)] }
    refused "a reply the question's form does not accept" (said "maybe")
    let _ ← assertOk <| putState store (said "yes")
    let _ ← assertOk <| putState store { base with parent? := some waits, kind := .reply, appended := #[answer] }
    let _ ← assertOk <| putState store { base with parent? := some waits, kind := .evaluation default },

  test "a state is stored as it is held, and reads back as its kind" do
    let w : Hash := ⟨"".pushn 'a' 64⟩
    let question : Asked := { call := { response := 2, index := 0 }, question := { text := "which?" } }
    let stored (kind : Kind) (parent? : Option Hash := some w) : TestM Lean.Json := do
      let state : State := { parent?, workspace := w, appended := #[], kind }
      let back ← assertOk <| Result.fromExcept Error.storage (State.fromJson state.toJson)
      assertEqual s!"{kind.toString} reads back the same" back.toJson.compress state.toJson.compress
      pure state.toJson
    -- A state is its parent, its workspace, its events and its kind; nothing else is written.
    let step ← stored (.step (some 5) (some (.inl { status := "Submitted", submission := "s" })))
    assertEqual "a state's fields" ((step.getObj?.toOption.map (·.toArray.map (·.1))).getD #[])
      #["appended", "kind", "parent", "v", "workspace"]
    assertEqual "a step that ended the run" (step.getObjVal? "kind" |>.toOption |>.map (·.compress))
      (some "{\"elapsed_ms\":5,\"stop\":{\"outcome\":{\"reason\":null,\"status\":\"Submitted\",\"submission\":\"s\"}},\"type\":\"step\"}")
    let waits ← stored (.step none (some (.inr question)))
    assertEqual "a step that waits" (waits.getObjVal? "kind" |>.toOption |>.map (·.compress))
      (some "{\"elapsed_ms\":null,\"stop\":{\"asked\":{\"call\":{\"index\":0,\"response\":2},\"question\":{\"form\":{\"type\":\"open_ended\"},\"text\":\"which?\"}}},\"type\":\"step\"}")
    let choice ← stored (.step none (some (.inr { call := question.call, question := { text := "which?", form := .singleChoice #["a", "b"] } })))
    assertEqual "a choice keeps its candidates in its form"
      (choice.getObjVal? "kind" >>= (·.getObjVal? "stop") >>= (·.getObjVal? "asked") >>= (·.getObjVal? "question")
        >>= (·.getObjVal? "form") |>.toOption |>.map (·.compress))
      (some "{\"options\":[\"a\",\"b\"],\"type\":\"single_choice\"}")
    let root ← stored testRoot none
    assertEqual "a root's record" (root.getObjVal? "kind" >>= (·.getObjVal? "root") |>.toOption |>.map (·.compress))
      (some s!"\{\"agent\":{testAgent.compress},\"image\":\"{recordedImage}\",\"model\":{testModel.compress},\"task\":null,\"workdir\":\"{recordedWorkdir}\"}")
    let _ ← stored (.intervention { message := "m", changed := #["+ f"] })
    let _ ← stored (.evaluation { (default : Evaluation) with checkout := w, input? := some w, returncode? := some 1 })
    let reply ← stored .reply
    assertEqual "a reply holds nothing of its own" (reply.getObjVal? "kind" |>.toOption |>.map (·.compress))
      (some "{\"type\":\"reply\"}")
    -- What is read is what the kind holds: a missing field is refused, and so is another version.
    let refusedRead (label : String) (json : Lean.Json) : TestM Unit :=
      match State.fromJson json with
      | .error _ => pure ()
      | .ok _ => fail s!"{label}: read"
    refusedRead "a step without its stop" (step.setObjVal! "kind" (.mkObj [("type", "step"), ("elapsed_ms", .null)]))
    refusedRead "a stop that is neither" (step.setObjVal! "kind"
      (.mkObj [("type", "step"), ("elapsed_ms", .null), ("stop", .mkObj [])]))
    refusedRead "a root without its record" (root.setObjVal! "kind" (.mkObj [("type", "root")]))
    refusedRead "an unknown kind" (step.setObjVal! "kind" (.mkObj [("type", "turn")]))
    refusedRead "the earlier schema" (step.setObjVal! "v" 1),

  iotest "events round-trip through storage" do
    let events : Array Event := #[
      .told (.system "sys"), .told (.user "task text"),
      .sampled default .turn {
        content? := some "thinking", reasoning? := some "trace", finishReason? := some "tool_calls",
        usage? := some { input? := some 10, output? := some 5 },
        toolCalls := #[
          { id := "c1", name := "bash", arguments := .mkObj [("command", ("ls" : Lean.Json))] },
          { id := "c2", name := "bash", arguments := .null, invalidArguments? := some "{\"command\": \"x" }] },
      .recorded { response := 2, index := 0 } (.mkObj [("output", "a\n"), ("returncode", (0 : Lean.Json))]),
      .recorded { response := 2, index := 1 } (.str "plain text"),
      .sampled default (.other "summary") { content? := some "a summary" },
      .placed ⟨"before"⟩,
      .executed { response := 2, index := 2 } "ls" {} { output := "a\n", exitCode? := some 0 } ⟨"after"⟩,
      .executed { response := 2, index := 3 } "sleep 9" { timeoutSeconds := 5, env := #[("A", "b")] } { output := "", error? := some "timed out" } ⟨"after2"⟩,
      .timed 1500 (some 3600000), .timed 0 none]
    for event in events do
      match eventFromJson (eventToJson event) with
      | .error e => throw <| IO.userError s!"round-trip failed: {e}"
      | .ok back =>
        if (eventToJson back).compress != (eventToJson event).compress then
          throw <| IO.userError s!"round-trip mismatch: {(eventToJson back).compress}",

  test "the image is recorded at the root alone, and every state of the run reads it there" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let pinned := "example.test/img@sha256:0123456789abcdef"
    let root ← mkRoot rt (← emptyProject) (some pinned)
    assertEqual "root" ((← assertOk (getState rt.store root)).root?.map (·.image)) (some pinned)
    let child ← stepped <| step rt root
    check (← assertOk (getState rt.store child)).root?.isNone "a step records no image"
    assertEqual "turn" (← assertOk <| runOf rt.store child).image pinned
    let edited ← emptyProject
    IO.FS.writeFile (edited / "by-hand.txt") "by hand"
    let intervention ← assertOk <| commit rt.store rt.workspaces child edited "by hand"
    assertEqual "intervention" (← assertOk <| runOf rt.store intervention).image pinned
    assertEqual "its message is the commit's" ((← assertOk (getState rt.store intervention)).intervention?.map (·.message))
      (some "by hand")
    assertEqual "the task is the root's" (← assertOk <| runOf rt.store intervention).task? (some "t"),

  test "a fork does not inherit the abandoned branch's files" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo junk > junk.txt"],
      responseWith #[call "b" "bash" "echo other > other.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← stepped <| step rt root
    check (← assertOk (rt.workspaces.readFile? (← assertOk (getState rt.store first)).workspace "junk.txt")).isSome
      "the first branch should have written junk.txt"
    -- Forking checks the root's workspace out again: the first branch's file must be gone.
    let second ← stepped <| step rt root
    let state ← assertOk (getState rt.store second)
    check (← assertOk (rt.workspaces.readFile? state.workspace "other.txt")).isSome
      "the second branch should have written other.txt"
    check (← assertOk (rt.workspaces.readFile? state.workspace "junk.txt")).isNone
      "a fork must not start from the abandoned branch's workspace",

  test "a grader runs against a checkout with its input at /grader, and its files never reach a later turn" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo hi > after.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let tests ← testsDir
    let scratch := (← scratch) / "eval"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root
      "cp -R /grader/tests . && test -f tests/extra.txt && printf '1..1\\nok 1 - hidden tests in place\\n'"
      (← testUser?) (input? := some tests)
    let state ← assertOk (getState rt.store node)
    assertEqual "kind" state.kind.toString "evaluation"
    let some e := state.evaluation? | fail "expected an evaluation"
    assertEqual "status" e.status .pass
    assertEqual "checks" e.checks #[{ ok := true, name := "hidden tests in place" }]
    assertEqual "grader image" e.graderImage (← assertOk <| runOf rt.store node).image
    -- The input is recorded as the snapshot the grader saw.
    let some input := e.input? | fail "expected the input snapshot"
    assertEqual "input" (String.fromUTF8? (← assertOk (rt.workspaces.read input "tests/extra.txt")))
      (some "hidden\n")
    -- The evaluation keeps the checkout as the grader left it, apart from the run's workspace,
    -- and the next turn from the root does not see the tests.
    check (← assertOk (rt.workspaces.readFile? e.checkout "tests/extra.txt")).isSome
      "the evaluation's checkout holds what the grader did"
    check (← assertOk (rt.workspaces.readFile? state.workspace "tests/extra.txt")).isNone
      "the run's workspace does not"
    let child ← stepped <| step rt root
    check (← assertOk (rt.workspaces.readFile? (← assertOk (getState rt.store child)).workspace "tests/extra.txt")).isNone
      "a grader's files must never reach a state the agent continues from"
    -- Nothing may continue from the evaluation.
    assertError "step" (step rt node) fun
      | .input m => (m.splitOn "cannot continue from an evaluation").length > 1
      | _ => false
    assertError "commit" (commit rt.store rt.workspaces node (← emptyProject)) fun
      | .input m => (m.splitOn "cannot build on an evaluation").length > 1
      | _ => false,

  test "a failing check is a failing verdict, and re-evaluating adds a new evaluation" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let scratch := (← scratch) / "eval"
    let grader := "printf '1..2\\nok 1 - a\\nnot ok 2 - b\\n'; exit 3"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root grader (← testUser?)
    let some e := (← assertOk (getState rt.store node)).evaluation? | fail "expected an evaluation"
    assertEqual "status" e.status .fail
    assertEqual "returncode" e.returncode? (some 3)
    assertEqual "checks" e.checks #[{ ok := true, name := "a" }, { ok := false, name := "b" }]
    assertEqual "reason" e.reason "failed: b"
    assertEqual "verdict" e.verdict "fail 1/2"
    let again ← assertOk <| evaluate rt.store rt.workspaces scratch root grader (← testUser?)
    check (again != node) "expected the same grader to run again as a new evaluation"
    assertEqual "two children" (← assertOk (children rt.store root)).size 2
    -- A different grader is another evaluation of the same state.
    let other ← assertOk <| evaluate rt.store rt.workspaces scratch root "printf '1..1\\nok\\n'" (← testUser?)
    check (other != node && other != again) "expected a distinct node for a distinct grader"
    assertEqual "three children" (← assertOk (children rt.store root)).size 3,

  test "the exit status decides nothing: TAP does, and reports stay in the workspace" do
    let rt ← cachedRuntime #[]
    let project ← emptyProject
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "app.txt") "code\n")
    let root ← mkRoot rt project
    let scratch := (← scratch) / "eval"
    -- Complete, passing TAP and exit 1: a pass. The report is where the grader left it.
    let grader := "test -f app.txt && mkdir -p .report && echo detail > .report/report.txt && " ++
      "printf '1..1\\nok 1 - app\\n' && exit 1"
    let node ← assertOk <| evaluate rt.store rt.workspaces scratch root grader (← testUser?)
    let state ← assertOk (getState rt.store node)
    let some e := state.evaluation? | fail "expected an evaluation"
    assertEqual "status" e.status .pass
    assertEqual "returncode" e.returncode? (some 1)
    assertEqual "verdict line" e.verdict "pass 1/1"
    assertEqual "report" (String.fromUTF8? (← assertOk (rt.workspaces.read state.snapshot ".report/report.txt")))
      (some "detail\n")
    -- Exit 0 with a stream cut short: an error, not a fail.
    let crashed ← assertOk <| evaluate rt.store rt.workspaces scratch root
      "printf '1..3\\nok 1\\n'" (← testUser?)
    let some c := (← assertOk (getState rt.store crashed)).evaluation? | fail "expected an evaluation"
    assertEqual "crashed" c.status .error
    assertEqual "crash reason" c.reason "planned 3 test points, but found 1"
    -- The checkout is gone afterwards; only the store holds what was tested.
    check (!(← (scratch / "checkout").pathExists)) "the checkout is discarded",

  test "resume drives to submission and records a chain of turns" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[submitCall "c2" "done"]]
    let root ← mkRoot rt (← emptyProject)
    let final := (← assertOk <| resume rt root).1
    let fstate ← assertOk <| getState rt.store final
    assertEqual "submitted" (fstate.outcome?.map (·.status)) (some "Submitted")
    assertEqual "submission" (fstate.outcome?.map (·.submission)) (some "done")
    -- root → turn(edit) → turn(submit): the submit turn records the response and no observation.
    let middle ← match fstate.parent? with
      | some p => pure p
      | none => fail "the final state has a parent"
    let mstate ← assertOk <| getState rt.store middle
    assertEqual "middle kind" mstate.kind.toString "step"
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
    let first ← stepped <| step rt root
    -- A second continuation from the root asks for draw 1: the scripted model's next response.
    let sibling ← stepped <| step rt root
    check (first != sibling) "a new continuation is a fresh sibling"
    assertEqual "two turn children" (← assertOk (children rt.store root)).size 2
    -- The scripted model is exhausted now, so any further sample would fail; a reply, tell, or
    -- commit child does not consume a draw and does not ask.
    let told ← assertOk <| tell rt.store root "note"
    check ((← assertOk (getState rt.store told)).kind matches .intervention _) "a tell is recorded without a sample"
]

end TrajectoryTests
