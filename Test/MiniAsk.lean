import Test.Framework
import Alaya

namespace MiniAskTests
open Testing Alaya Alaya.Agent Alaya.Trajectory
open Alaya.Agent.MiniAsk

private def question : Chat.ToolCall :=
  { id := "q", name := "ask_user", arguments := .mkObj [("question", "Which lemma applies?")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def config : MiniSwe.Config := { task := "test" }

def suite : Suite := Testing.suite "mini-ask" #[
  test "valid question pauses and a tool reply resumes with the answer visible" do
    let log : Log := #[.response (response #[question])]
    match next config log with
    | .ask "q" "Which lemma applies?" => pure ()
    | _ => fail "expected question directive"
    let answered := log.push (.observation "q" (.str "Try induction."))
    match next config answered with
    | .sample => pure ()
    | _ => fail "expected a new sample after the reply"
    match (MiniAsk.view answered)[0]?, (MiniAsk.view answered)[1]? with
    | some (Chat.Message.assistant _ calls _), some (Chat.Message.tool "q" (.str answer)) =>
      check (calls.size == 1 && (answer.splitOn "Try induction.").length > 1) "tool pairing lost"
    | _, _ => fail "question or answer was dropped from context",

  test "mixed, empty, wrong-type and invalid-JSON questions run no tools" do
    let bash : Chat.ToolCall :=
      { id := "b", name := "bash", arguments := .mkObj [("command", "touch forbidden")] }
    let bad : Array (Array Chat.ToolCall) := #[
      #[bash, question], #[question, bash],
      #[{ question with arguments := .mkObj [("question", "  \n")] }],
      #[{ question with arguments := .mkObj [("question", (3 : Lean.Json))] }],
      #[{ question with invalidArguments? := some "{" }]]
    for calls in bad do
      let log : Log := #[.response (response calls)]
      match next config log, (MiniAsk.view log)[0]? with
      | .sample, some (Chat.Message.user _) => pure ()
      | _, _ => fail "malformed turn should be a recoverable error, never an action",

  test "format errors are bounded and answer respects model-turn limit" do
    let bad : Event := .response (response #[{ question with arguments := .null }])
    match next config #[bad, bad, bad] with
    | .done o => check (o.status == "RepeatedFormatError") "wrong error stop"
    | _ => fail "repeated errors were not bounded"
    match next { config with stepLimit := 1 }
        #[.response (response #[question]), .observation "q" (.str "answer")] with
    | .done o => check (o.status == "LimitsExceeded") "wrong limit stop"
    | _ => fail "answer must not bypass step limit",

  test "a real persisted question forks into two independent reply histories" do
    let base ← scratch
    let project := base / "source"
    IO.FS.createDirAll project
    IO.FS.writeFile (project / "input.txt") "unchanged"
    let store ← assertOk <| Cas.Store.create (base / "store")
    let executor := Executor.onHost MiniSwe.defaultExecutor
    let model : Model := {
      identity := .mkObj [("test", "question")]
      sample := fun _ => pure (.ofNext (pure (response #[question]))) }
    let rt : Runtime := { store, workDir := base / "work", executor, model,
                          agent := agent executor config }
    let root ← assertOk <| createRoot store #[] project
    let asked ← assertOk <| stepOnce rt "scripted:test" root
    let q ← assertOk <| getState store asked
    check (q.kind == .question) "question wasn't persisted"
    assertError "cannot sample while waiting" (stepOnce rt "scripted:test" asked) (fun _ => true)
    let a ← assertOk <| reply store asked "No answer."
    let b ← assertOk <| reply store asked "Try induction."
    check (a != b) "replies must be distinct states"
    for child in #[a, b] do
      let state ← assertOk <| getState store child
      check (state.parent? == some asked && state.workspace == q.workspace) "fork changed workspace"
      match next config (← assertOk (logOf store child)) with
      | .sample => pure ()
      | _ => fail "reply didn't resume"
    let submit : Chat.ToolCall :=
      { id := "s", name := "submit", arguments := .mkObj [("message", "done")] }
    let finishModel : Model := { model with sample := fun _ => pure (.ofNext (pure (response #[submit]))) }
    let final ← assertOk <| stepOnce { rt with model := finishModel } "scripted:test" b
    check ((← assertOk (getState store final)).outcome?.map (·.status) == some "Submitted")
      "submit parity lost"
]
end MiniAskTests
