import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Test.Scripted
import Alaya

/-! Tests of the MiniVero port: the opening message it sends, and how it behaves on compiler
feedback, submission, and its limits. -/

namespace MiniVeroTests
open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Alaya.Agents
open Lean (Json)

private def config : MiniVero.Config := {}

private def contains (text needle : String) : Bool :=
  (text.splitOn needle).length > 1

private def machine : Uname := { system := "Linux", machine := "x86_64" }

private def openingText (task : String) (mode : MiniVero.Mode := .codeproof) : TestM String := do
  match (MiniVero.openingMessages { config with mode } task machine)[1]? with
  | some (Chat.Message.user text) => pure text
  | _ => fail "missing task"

/-- Runs `k` with MiniVero's run, configured by `config`. -/
private def withVero (config : MiniVero.Config) (k : Routine Agent → TestM Unit) : TestM Unit :=
  k (Scripted.runOf (MiniVero.computation config Scripted.testModelSpec)
    (Scope.of Tools.routines))

/-- The log after the world answered what the agent asked with `answers`, in order: settled at
what it asks next. -/
private def after (run : Routine Agent) (answers : Array Stored) : Log Agent :=
  answers.foldl (Scripted.answer run) (Scripted.settle run Scripted.opening)

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
    let dir : System.FilePath := "Alaya" / "Agents" / "MiniVero"
    for (file, compiled) in [
      ("framing.md", MiniVero.framing), ("rules.md", MiniVero.rules),
      ("grading-proof.md", MiniVero.gradingProof),
      ("grading-codeproof.md", MiniVero.gradingCodeproof),
      ("done.md", MiniVero.doneCondition), ("anti-cheating.md", MiniVero.antiCheating),
      ("checkpointing.md", MiniVero.checkpointing)] do
      let onDisk ← IO.FS.readFile (dir / file)
      check (onDisk.trimAsciiEnd.toString == compiled)
        s!"{file} changed after Alaya.Agents.MiniVero was built: touch the module and rebuild",
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
    withVero config fun run => do
      let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake lean Proof.lean")] }
      let asked := after run #[.response { toolCalls := #[call] }]
      match next run asked with
      | .ask { op := .exec "lake lean Proof.lean" { timeoutSeconds := 600, .. }, frame } =>
        assertEqual "in the call's frame" frame ⟪"agent", "bash"⟫
      | _ => fail "expected the command run, as the response's first call"
      let ran := after run #[.response { toolCalls := #[call] },
        .execution { output := { output := "Lean type mismatch", exitCode? := some 1 }, workspace := default }]
      match next run ran with
      | .ask { op := .sample _ request, .. } =>
        match request.messages.back? with
        | some (Chat.Message.tool "c" (Json.str text)) => check (contains text "\"exit_code\": 1") "exit code shown"
        | _ => fail "missing the output"
      | _ => fail "should continue after compiler feedback",
  test "submit is terminal but is not claimed to be a passing evaluation" do
    withVero config fun run => do
      let log := after run #[.response { toolCalls := #[{
        id := "s", name := "submit", arguments := .mkObj [("message", "done")] }] }]
      assertEqual "status" (Scripted.agentStatus log) "Submitted",
  test "long output stays in the raw log" do
    withVero config fun run => do
      let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake build")] }
      let raw := String.ofList (List.replicate 12000 'x')
      let log := after run #[.response { toolCalls := #[call] },
        .execution { output := { output := raw, exitCode? := some 0 }, workspace := default }]
      check (log.any fun | .answered _ _ (.ok (.execution e)) => e.output.output == raw | _ => false) "raw output kept"
      let history : MiniSwe.History := { items := #[.turn { toolCalls := #[call] } #[(call, Tools.Bash.result
        { output := { output := raw, exitCode? := some 0 }, workspace := default })]] }
      match (MiniSwe.view config.base history)[1]? with
      | some (Chat.Message.tool _ (Json.str text)) =>
        check ((text.splitOn "elided_chars").length > 1) "view should truncate"
        check (text.length < raw.length) "view should be smaller"
      | _ => fail "missing view observation",

]
private def call (id name : String) (arguments : Lean.Json := .mkObj []) : Chat.ToolCall :=
  { id, name, arguments }

private def turn (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

def timeSuite : Suite := Testing.suite "mini-vero.time" #[
  test "the opening asks the agent to pace itself by time_budget, not date, in Vero's place" do
    let text ← openingText "TASK_CODEPROOF"
    let offset (needle : String) : Nat := (text.splitOn needle)[0]!.length
    check (contains text "## Checkpointing — work within your time budget") "the section is there"
    check (contains text "Call the ``time_budget`` tool") "it names the tool"
    check (contains text "Do not use ``date``") "it says not to use date"
    check (offset "## Done condition" < offset "## Checkpointing" && offset "## Checkpointing" < offset "## Anti-cheating")
      "after the Done condition, before Anti-cheating, as in Vero"
    let off := MiniVero.openingMessages { config with base := { config.base with tools := #["bash", "submit"] } } "t" machine
    match off[1]? with
    | some (Chat.Message.user plain) =>
      check (!contains plain "## Checkpointing") "off, there is no such section"
    | _ => fail "missing task"
    assertEqual "tools" ((MiniSwe.tools config.base).map (·.name)) #["bash", "submit", "time_budget"],

  test "time_budget reads the clock and gives the seconds left, or that there is none" do
    withVero config fun run => do
      let asked := after run #[.response (turn #[call "t" "time_budget"])]
      match next run asked with
      | .ask { op := .time, frame } => assertEqual "in the tool's frame" frame ⟪"agent", "time_budget"⟫
      | _ => fail "expected the clock read"
      let gives (timing : Timing) : Option Json :=
        (Scripted.answer run asked (.timing timing)).findSome? fun
          | .returned ⟪"agent", "time_budget"⟫ value => some value
          | _ => none
      assertEqual "left" ((gives { spentMs := 60500, budgetMs? := some 3600000 }).bind (·.getObjVal? "seconds_left" |>.toOption) |>.map (·.compress)) (some "3539")
      check ((gives { spentMs := 60500 }).bind (·.getObjVal? "seconds_left" |>.toOption) == some .null) "no budget, no number",

  test "mini-swe neither offers time_budget nor accepts it in its configuration" do
    assertEqual "tools" ((MiniSwe.tools {}).map (·.name)) #["bash", "submit"]
    match MiniSwe.parseActions (turn #[call "t" "time_budget"]) with
    | .formatError message => check (contains message "Unknown tool 'time_budget'") "unknown"
    | .calls _ => fail "mini-swe must not accept time_budget"
    assertError "config" (Catalog.complete "mini-swe" (.mkObj [("time_budget", true)])) fun
      | .input m => contains m "unknown field 'time_budget'"
      | _ => false,

  test "each entry records its time, and the tool counts the run's against the budget" do
    withVero config fun run => do
      let executor ← containerExecutor
      try
        let model ← Scripted.scriptedModel #[turn #[call "c" "bash" (.mkObj [("command", "sleep 0.2")])],
          turn #[call "t" "time_budget"], turn #[call "s" "submit"]]
        let rt ← Scripted.runtime executor (some model)
        let (final, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run) { budgetMs? := some 3600000 }
        let forest ← assertOk rt.store.forest
        let entries ← assertOk <| rt.store.entries forest final
        let slept := entries.foldl (fun ms e => match e.event with
          | .answered _ (.exec "sleep 0.2" _) _ => ms + e.elapsedMs | _ => ms) 0
        check (slept >= 200) s!"the command's entry took the sleep, recorded {slept} ms"
        let some (timing, left) := entries.zipIdx.findSome? fun (e, i) => match e.event with
            | .answered _ .time (.ok (.timing t)) => (entries[i + 1]?).bind fun next => match next.event with
              | .returned _ value => some (t, (value.getObjVal? "seconds_left" >>= Json.getNat?).toOption.getD 0)
              | _ => none
            | _ => none
          | fail "expected the clock read and the answer"
        check (timing.spentMs >= slept) "the reading counts the run so far"
        assertEqual "the budget" timing.budgetMs? (some 3600000)
        check (left < 3600 && left + 5 >= 3600) s!"left {left} s of 3600 after {slept} ms"
      finally executor.close,

  test "a spent budget pauses the run before anything, and a later run goes on" do
    withVero config fun run => do
      let executor ← containerExecutor
      try
        let model ← Scripted.scriptedModel #[turn #[call "c" "bash" (.mkObj [("command", "sleep 0.2")])],
          turn #[call "s" "submit" (.mkObj [("message", "done")])]]
        let rt ← Scripted.runtime executor (some model)
        let limits : Driver.Limits := { budgetMs? := some 100 }
        let (paused, stop) ← assertOk <| Driver.drive rt run (← Scripted.start rt run) limits
        check (stop matches .paused _) "the budget paused it"
        let count := (← assertOk rt.store.forest).entries.size
        let (again, stop) ← assertOk <| Driver.drive rt run paused limits
        check ((stop matches .paused _) && again == paused) "spent: nothing more"
        assertEqual "no entry written" (← assertOk rt.store.forest).entries.size count
        let (final, stop) ← assertOk <| Driver.drive rt run paused
        check (stop matches .idle) "without a budget it runs on"
        assertEqual "submitted" (Scripted.agentStatus (← Scripted.logAt rt final)) "Submitted"
      finally executor.close
]

end MiniVeroTests
