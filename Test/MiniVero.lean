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

private def openingText (task : String) (mode : MiniVero.Mode := .codeproof) : TestM String := do
  let log := MiniVero.initialLog { config with task } mode
    { system := "Linux", release := "", version := "", machine := "x86_64" }
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
      "submit tool"] do
      check (contains text needle) s!"missing {needle}",
  test "a run is sent the grading rules of its own mode only" do
    let proofOnly := ["## Grading (``proof`` mode)", "disprove_<S>", "Classical.choice"]
    let codeproofOnly := ["## Grading (``codeproof`` mode)", "unsat_<S>", "unpaired_sat", "Part A"]
    let proof ← openingText "TASK_PROOF" .proof
    let codeproof ← openingText "TASK_CODEPROOF" .codeproof
    for needle in proofOnly do
      check (contains proof needle) s!"proof mode is missing {needle}"
      check (!contains codeproof needle) s!"codeproof mode should not carry {needle}"
    for needle in codeproofOnly do
      check (contains codeproof needle) s!"codeproof mode is missing {needle}"
      check (!contains proof needle) s!"proof mode should not carry {needle}"
    -- Everything else is the same message.
    assertEqual "the rest" (proof.replace MiniVero.gradingProof "" |>.replace "TASK_PROOF" "")
      (codeproof.replace MiniVero.gradingCodeproof "" |>.replace "TASK_CODEPROOF" ""),
  test "sections are separated by one blank line, with no template syntax left" do
    let text ← openingText "TASK_CODEPROOF"
    for absent in ["\n\n\n", "{%", "{{"] do
      check (!contains text absent) s!"the prompt should not carry {absent.quote}"
    check (contains text "stop.\n\nSolve this Vero task:\n\nTASK_CODEPROOF\n\n## Marker grammar")
      "the task should sit between the framing and the rules",
  test "the compiled sections are the files in the source tree" do
    -- Lake does not rebuild a module when a file it takes with `include_str` changes.
    let dir : System.FilePath := "Alaya" / "Agent" / "MiniVero"
    for (file, compiled) in [
      ("framing.md", MiniVero.framing), ("rules.md", MiniVero.rules),
      ("grading-proof.md", MiniVero.gradingProof),
      ("grading-codeproof.md", MiniVero.gradingCodeproof),
      ("done.md", MiniVero.doneCondition), ("anti-cheating.md", MiniVero.antiCheating)] do
      let onDisk ← IO.FS.readFile (dir / file)
      check (onDisk.trimAsciiEnd.toString == compiled)
        s!"{file} changed after Alaya.Agent.MiniVero was built: touch the module and rebuild",
  test "a mode is named as Vero names it" do
    assertEqual "proof" (MiniVero.Mode.ofString? "proof") (some .proof)
    assertEqual "codeproof" (MiniVero.Mode.ofString? "codeproof") (some .codeproof)
    assertEqual "unknown" (MiniVero.Mode.ofString? "Proof") none
    assertEqual "round trip" (MiniVero.Mode.all.map (MiniVero.Mode.ofString? ·.toString))
      (MiniVero.Mode.all.map some),
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
