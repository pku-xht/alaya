import Test.Framework
import Alaya

/-! Tests of the MiniVero port: the opening message it sends, and how it behaves on compiler
feedback, submission, and its limits. -/

namespace MiniVeroTests
open Testing Alaya
open Alaya.Agent

private def config : MiniVero.Config := { MiniVero.defaultConfig with task := "TASK_CODEPROOF" }

private def contains (text needle : String) : Bool :=
  (text.splitOn needle).length > 1

private def openingText (task : String) : TestM String := do
  let log := MiniVero.initialLog
    { config with task } { system := "Linux", release := "", version := "", machine := "x86_64" }
  match log[1]? with
  | some (Event.message (Chat.Message.user text)) => pure text
  | _ => fail "missing task"

def suite : Suite := Testing.suite "mini-vero" #[
  test "the opening message quotes Vero's framing and rule sections" do
    let text ← openingText "TASK_CODEPROOF"
    check (text.startsWith "You are an expert Lean 4 engineer in a self-contained sandbox")
      "Vero's framing should open the message"
    for needle in [
      "TASK_CODEPROOF",
      "Your edits are evaluated automatically — the grader reads the sandbox state after you stop.",
      "## Marker grammar (NON-NEGOTIABLE)",
      "**Only slot interiors are kept.**",
      "## Oracle commands",
      "## Grading (``proof`` mode)",
      "## Grading (``codeproof`` mode)",
      "## Done condition — non-negotiable",
      "## Anti-cheating — what the grader rejects",
      "## Scoring",
      "An unfilled slot scores the same as a wrong proof: zero.",
      "Every additional spec you close strictly increases the score.",
      "-- !benchmark @start",
      "-- !benchmark @end",
      "lake lean",
      "lake build",
      "Classical.choice",
      "propext",
      "Quot.sound",
      "submit tool"] do
      check (contains text needle) s!"missing {needle}",
  test "the instance and run facts are left to the task text" do
    let text ← openingText "TASK_CODEPROOF"
    for absent in [
      "INSTRUCTION.md",
      "MINIVERO_TASK.md",
      "## Benchmark scale",
      "## Project layout",
      "## Your task in ",
      "## Checkpointing",
      "## Reference — original upstream source",
      "upstream_source"] do
      check (!contains text absent) s!"the prompt should not carry {absent}",
  test "the scoring facts are kept and the advice is not" do
    let text ← openingText "TASK_CODEPROOF"
    for absent in [
      "## Persistence",
      "## Workflow",
      "## Proof strategy",
      "Never regress",
      "locked-in",
      "keep working",
      "keep iterating",
      "two genuinely distinct tactics",
      "Treat every spec as independently valuable",
      "The turn/budget cap is the only signal to stop before the Done condition is met.",
      "do not assume Mathlib"] do
      check (!contains text absent) s!"the prompt should not carry {absent}",
  test "a failed compile remains observable and the agent continues" do
    let executor : Executor := {
      exec := fun _ _ _ => pure { output := "Lean type mismatch", exitCode? := some 1 }
      uname := pure default }
    let agent := MiniVero.agent executor config
    let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake lean Proof.lean")] }
    let output ← assertOk <| agent.act { dir := "." } call
    check ((output.getObjVal? "exit_code").toOption == some 1) "wrong exit code"
    let log : Log := #[.response { toolCalls := #[call] }, .observation "c" output]
    match agent.next log with
    | .sample => pure ()
    | _ => fail "should continue after compiler feedback",
  test "submit is terminal but is not claimed to be a passing evaluation" do
    let agent := MiniVero.agent (Executor.onHost config.executor) config
    let log : Log := #[.response { toolCalls := #[{
      id := "s", name := "submit", arguments := .mkObj [("message", "done")] }] }]
    match agent.next log with
    | .done outcome => assertEqual "status" outcome.status "Submitted"
    | _ => fail "expected submission",
  test "the step limit is enforced and long output stays in the raw log" do
    let cfg : MiniVero.Config := { config with stepLimit := 1 }
    let agent := MiniVero.agent (Executor.onHost cfg.executor) cfg
    let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake build")] }
    let raw := String.ofList (List.replicate 12000 'x')
    let log : Log := #[.response { toolCalls := #[call] },
      .observation "c" (Output.toJson { output := raw, exitCode? := some 0 })]
    match agent.next log with
    | .done outcome => assertEqual "limit" outcome.status "LimitsExceeded"
    | _ => fail "missing limit"
    match (agent.view log)[1]? with
    | some (Chat.Message.tool _ (Lean.Json.str text)) =>
      check ((text.splitOn "elided_chars").length > 1) "view should truncate"
      check (text.length < raw.length) "view should be smaller"
    | _ => fail "missing view observation"
    match log[1]? with
    | some (Event.observation _ json) =>
      check ((json.getObjVal? "output").toOption == some (.str raw)) "raw output lost"
    | _ => fail "missing raw output",

]
end MiniVeroTests
