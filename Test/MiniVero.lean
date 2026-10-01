import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! Tests of the MiniVero port: the opening message it sends, and how it behaves on compiler
feedback, submission, and its limits. -/

namespace MiniVeroTests
open Testing Alaya
open Alaya.Agent

private def config : MiniVero.Config := {}

private def contains (text needle : String) : Bool :=
  (text.splitOn needle).length > 1

private def openingText (task : String) (mode : MiniVero.Mode := .codeproof) : TestM String := do
  let log := MiniVero.initialLog { config with mode } task
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
      ("done.md", MiniVero.doneCondition), ("anti-cheating.md", MiniVero.antiCheating),
      ("checkpointing.md", MiniVero.checkpointing)] do
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
      "-minute work chunk",
      "You can check elapsed time with ``date``",
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
    match agent.next {} log with
    | .sample => pure ()
    | _ => fail "should continue after compiler feedback",
  test "submit is terminal but is not claimed to be a passing evaluation" do
    let agent := MiniVero.agent noCommands config
    let log : Log := #[.response { toolCalls := #[{
      id := "s", name := "submit", arguments := .mkObj [("message", "done")] }] }]
    match agent.next {} log with
    | .done outcome => assertEqual "status" outcome.status "Submitted"
    | _ => fail "expected submission",
  test "the step limit is enforced and long output stays in the raw log" do
    let cfg : MiniVero.Config := { config with base := { config.base with stepLimit := 1 } }
    let agent := MiniVero.agent noCommands cfg
    let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake build")] }
    let raw := String.ofList (List.replicate 12000 'x')
    let log : Log := #[.response { toolCalls := #[call] },
      .observation "c" (Output.toJson { output := raw, exitCode? := some 0 })]
    match agent.next {} log with
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
private def call (id name : String) (arguments : Lean.Json := .mkObj []) : Chat.ToolCall :=
  { id, name, arguments }

private def turn (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def scripted (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| Error.protocol "scripted model exhausted" } }

/-- A MiniVero run over the given model responses, with a root over an empty project. -/
private def runtime (responses : Array Chat.Response) (budgetMs? : Option Nat) :
    TestM (Trajectory.Runtime × Hash) := do
  let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
  let workspaces ← Testing.workspaces
  let project := (← scratch) / "proj"
  IO.FS.createDirAll project
  let work := (← scratch) / "work"
  IO.FS.createDirAll work
  let executor ← containerExecutor config.base.executor
  let rt : Trajectory.Runtime := { store, workspaces, workDir := work, executor, model := ← scripted responses
                                   agent := MiniVero.agent executor config, budgetMs? }
  let uname : Uname := { system := "Linux", release := "", version := "", machine := "x86_64" }
  let root ← assertOk <| Trajectory.createRoot store workspaces (MiniVero.initialLog config "t" uname)
    project (← testImage) (some "t") (agent := config.toJson)
  pure (rt, root)

def timeSuite : Suite := Testing.suite "mini-vero.time" #[
  test "the opening asks the agent to pace itself by time_budget, not date, in Vero's place" do
    let text ← openingText "TASK_CODEPROOF"
    let offset (needle : String) : Nat := (text.splitOn needle)[0]!.length
    check (contains text "## Checkpointing — work within your time budget") "the section is there"
    check (contains text "Call the ``time_budget`` tool") "it names the tool"
    check (contains text "Do not use ``date``") "it says not to use date"
    check (offset "## Done condition" < offset "## Checkpointing" && offset "## Checkpointing" < offset "## Anti-cheating")
      "after the Done condition, before Anti-cheating, as in Vero"
    let off := MiniVero.initialLog { config with base := { config.base with timeBudget := false } } "t"
      { system := "Linux", release := "", version := "", machine := "x86_64" }
    match off[1]? with
    | some (Event.message (Chat.Message.user plain)) =>
      check (!contains plain "## Checkpointing") "off, there is no such section"
    | _ => fail "missing task"
    assertEqual "tools" ((MiniVero.tools config).map (·.name)) #["bash", "submit", "time_budget"],

  test "time_budget records the seconds left, or that there is none, and runs nothing" do
    let agent := MiniVero.agent noCommands config
    let log : Log := #[.response (turn #[call "t" "time_budget"])]
    match agent.next { elapsedMs := 60500, budgetMs? := some 3600000 } log with
    | .record "t" json => assertEqual "left" (json.getObjVal? "seconds_left" |>.toOption |>.map (·.compress)) (some "3539")
    | _ => fail "expected the answer recorded"
    match agent.next {} log with
    | .record "t" json => check ((json.getObjVal? "seconds_left").toOption == some .null) "no budget, no number"
    | _ => fail "expected the answer recorded",

  test "mini-swe neither offers time_budget nor accepts it in its configuration" do
    assertEqual "tools" ((MiniSwe.tools {}).map (·.name)) #["bash", "submit"]
    match MiniSwe.parseActions (turn #[call "t" "time_budget"]) with
    | .formatError message => check (contains message "Unknown tool 'time_budget'") "unknown"
    | .actions _ => fail "mini-swe must not accept time_budget"
    assertError "config" (Agent.Families.instanceOf (.mkObj [("family", "mini-swe"), ("time_budget", true)])) fun
      | .input m => contains m "unknown field 'time_budget'"
      | _ => false,

  test "each step records its time, and the tool counts it against the budget" do
    let (rt, root) ← runtime #[turn #[call "c" "bash" (.mkObj [("command", "sleep 0.2")])],
      turn #[call "t" "time_budget"], turn #[call "s" "submit"]] (some 3600000)
    let first ← stepped <| Trajectory.stepOnce rt "m" root
    let slept := (← assertOk <| Trajectory.getState rt.store first).elapsedMs?.getD 0
    check (slept >= 200) s!"the step took the sleep, recorded {slept} ms"
    let second ← stepped <| Trajectory.stepOnce rt "m" first
    match (← assertOk <| Trajectory.getState rt.store second).appended.back? with
    | some (.observation "t" json) =>
      let left := (json.getObjVal? "seconds_left" >>= Lean.Json.getNat?).toOption.getD 0
      check (left < 3600 && left + 5 >= 3600) s!"left {left} s of 3600 after {slept} ms"
    | _ => fail "expected the answer as the last event"
    check ((← assertOk <| Trajectory.elapsedMs rt.store second) >= slept) "the run's time adds up",

  test "a spent budget stops resume before a step, writes nothing, and a later resume continues" do
    let (rt, root) ← runtime #[turn #[call "c" "bash" (.mkObj [("command", "sleep 0.2")])],
      turn #[call "s" "submit" (.mkObj [("message", "done")])]] (some 100)
    let stopped ← assertOk <| Trajectory.resume rt "m" root (fun _ => pure ())
    check stopped.outOfTime "the budget stopped it"
    check ((← assertOk <| Trajectory.getState rt.store stopped.state).outcome?.isNone) "the run has not ended"
    let count := (← assertOk <| Trajectory.allStates rt.store).size
    let again ← assertOk <| Trajectory.resume rt "m" stopped.state (fun _ => pure ())
    check (again.outOfTime && again.state == stopped.state) "spent before a step: nothing more"
    assertEqual "no state written" (← assertOk <| Trajectory.allStates rt.store).size count
    assertEqual "step says so too" (← assertOk <| Trajectory.stepOnce rt "m" stopped.state) none
    let final ← assertOk <| Trajectory.resume { rt with budgetMs? := none } "m" stopped.state (fun _ => pure ())
    check (!final.outOfTime) "without a budget it runs on"
    assertEqual "submitted" ((← assertOk <| Trajectory.getState rt.store final.state).outcome?.map (·.status)) (some "Submitted")
]

end MiniVeroTests
