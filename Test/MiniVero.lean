import Test.Framework
import Alaya

namespace MiniVeroTests
open Testing Alaya
open Alaya.Agent

private def config : MiniVero.Config := { MiniVero.defaultConfig with task := "TASK_CODEPROOF" }

def suite : Suite := Testing.suite "mini-vero" #[
  test "Vero task and both modes are in the opening log" do
    let log := MiniVero.initialLog config { system := "Linux", release := "", version := "", machine := "x86_64" }
    match log[1]? with
    | some (Event.message (Chat.Message.user text)) =>
      for needle in ["TASK_CODEPROOF", "-- !benchmark @start", "-- !benchmark @end", "proof or codeproof alternatives", "lake lean", "lake build", "Classical.choice", "propext", "Quot.sound", "submit tool"] do
        check ((text.splitOn needle).length > 1) s!"missing {needle}"
      check ((text.splitOn "INSTRUCTION.md").length == 1) "the agent should not be told to read INSTRUCTION.md"
      check ((text.splitOn "do not assume Mathlib").length == 1) "the prompt must not forbid an available library"
    | _ => fail "missing task",
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
