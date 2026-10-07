import Test.Support.Framework
import Test.Support.DirectoryWorkspaces
import Test.Support.Container
import Test.Support.Scripted
import Alaya

/-! Tests of MiniVero: the opening message it sends, the extensions it always has — the `submit`,
`time_budget` and `subagent` tools, `ask_user` when its configuration names kinds of question,
and outputs kept as files — and how it behaves on compiler feedback, submission, and its time
budget. Masking and the context limit are `Test/Agents/Context.lean`'s. -/

namespace MiniVeroTests
open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Alaya.Agents
open Lean (Json)

private def config : MiniVero.Config := {}

private def machine : Uname := { system := "Linux", machine := "x86_64" }

private def openingText (task : String) (mode : MiniVero.Mode := .codeproof) : TestM String := do
  match (MiniVero.openingMessages { config with mode } task machine)[1]? with
  | some (Chat.Message.user text) => pure text
  | _ => fail "missing task"

/-- Runs `k` with MiniVero's run, configured by `config`. -/
private def withVero (config : MiniVero.Config) (k : Scope Agent → TestM Unit) : TestM Unit :=
  k (Scripted.runOf (MiniVero.computation config Scripted.testModelSpec)
    (Scope.of Tools.routines))

/-- The log after the world answered what the agent asked with `answers`, in order: settled at
what it asks next. -/
private def after (run : Scope Agent) (answers : Array Stored) : Log Agent :=
  answers.foldl (Scripted.answer run) (Scripted.settle run Scripted.opening)

def suite : Suite := Testing.suite "agents/mini-vero" #[
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
      "## Persistence — keep working until done",
      "An unfilled slot scores the same as a wrong proof: zero.",
      "Every additional spec you close strictly increases the score.",
      "-- !benchmark @start",
      "-- !benchmark @end",
      "lake lean",
      "lake build",
      "submit tool"] do
      check (contains text needle) s!"missing {needle}",
  test "a run is sent the grading rules of its own mode only" do
    -- Vero's `Persistence`, sent in both modes, names `disprove_<S>` too.
    let proofOnly := ["## Grading (``proof`` mode)", "Classical.choice"]
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
      ("done.md", MiniVero.doneCondition), ("persistence.md", MiniVero.persistence), ("anti-cheating.md", MiniVero.antiCheating),
      ("checkpointing.md", MiniVero.checkpointing)] do
      let onDisk ← IO.FS.readFile (dir / file)
      check (onDisk.trimAsciiEnd.toString == compiled)
        s!"{file} changed after Alaya.Agents.MiniVero was built: touch the module and rebuild",
  test "a mode is named as Vero names it" do
    let mode : Codec MiniVero.Mode := .enum toString MiniVero.Mode.all
    assertEqual "proof" (mode.read "proof").toOption (some MiniVero.Mode.proof)
    assertEqual "codeproof" (mode.read "codeproof").toOption (some MiniVero.Mode.codeproof)
    assertEqual "unknown" (mode.read "Proof").toOption none
    assertEqual "round trip" (MiniVero.Mode.all.map fun m => (mode.read (mode.write m)).toOption)
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
  test "Vero's Persistence is sent up to its advice, and its Workflow and Proof strategy are not" do
    let text ← openingText "TASK_CODEPROOF"
    assertContains "Vero's Persistence, to the byte" text MiniVero.persistence
    for present in ["keep iterating", "The turn/budget cap is the only valid stop signal.", "Progress matters"] do
      assertContains "its first paragraphs" text present
    for absent in ["Never regress", "When progress stalls", "The ONLY signal to stop", "## Workflow",
        "## Proof strategy", "## Scoring"] do
      check (!contains text absent) s!"the prompt should not carry {absent}",
  test "a failed compile remains observable and the agent continues" do
    withVero config fun run => do
      let call : Chat.ToolCall := { id := "c", name := "bash", arguments := .mkObj [("command", "lake lean Proof.lean")] }
      let asked := after run #[.response { toolCalls := #[call] }]
      match next run asked with
      | .ask { op := .exec "lake lean Proof.lean" { timeoutSeconds := 300, .. }, frame } =>
        assertEqual "in the call's frame" frame ⟪"session", "agent", "bash"⟫
      | _ => fail "expected the command run, as the response's first call"
      let ran := after run #[.response { toolCalls := #[call] },
        .execution { output := { output := "Lean type mismatch", exitCode? := some 1 }, workspace := default }]
      match next run ran with
      | .ask { op := .sample _ request, .. } =>
        match request.messages.back? with
        | some (Chat.Message.tool "c" (Json.str text)) => assertStringEq "exit code shown" text "Lean type mismatch\n\nCommand exited with code 1"
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
      let raw := String.join (List.replicate 3000 "x\n")
      let log := after run #[.response { toolCalls := #[call] },
        .execution { output := { output := raw, exitCode? := some 0 }, workspace := default }]
      check (log.any fun | .answered _ _ (.ok (.execution e)) => e.output.output == raw | _ => false) "raw output kept"
      let history : MiniVero.History := { items := #[.turn { toolCalls := #[call] } #[(call, .ok (Tools.Bash.result
        { output := { output := raw, exitCode? := some 0 }, workspace := default }))]] }
      match (MiniVero.view history)[1]? with
      | some (Chat.Message.tool _ (Json.str text)) =>
        assertContains "view should show the end" text "[Showing lines 1001-3000 of 3000.]"
        check (text.length < raw.length) "view should be smaller"
      | _ => fail "missing view observation",

  test "its tools are bash, submit and subagent, with ask_user only for the kinds its configuration names" do
    assertEqual "by default" (config.tools.map (·.name)) #["bash", "submit", "subagent"]
    let asking : MiniVero.Config := { questionTypes := #[.yesNo, .singleChoice] }
    assertEqual "asking" (asking.tools.map (·.name)) #["bash", "submit", "ask_user", "subagent"]
    let opening (config : MiniVero.Config) : String :=
      match (MiniVero.openingMessages config "t" machine)[1]? with
      | some (Chat.Message.user text) => text
      | _ => ""
    assertContains "ask_user's instruction" (opening asking) (Tools.AskUser.instruction #[.yesNo, .singleChoice])
    check (!contains (opening config) "ask_user") "no ask_user without kinds of question"
    assertContains "subagent's instruction" (opening config) Tools.Subagent.instruction
    -- Refused by the agent, or by the routine of the call its tool makes.
    let parse (config : MiniVero.Config) (response : Chat.Response) : String :=
      (response.toolCalls.findSome? fun call =>
        (Basic.problem? config.tools response call).orElse fun _ =>
          (config.tools.find? (·.name == call.name)).bind fun tool =>
            match Tools.AskUser.read (tool.arguments call.arguments) with
            | .ok _ => none
            | .error problem => some problem).getD ""
    assertContains "not offered" (parse config (Scripted.responseWith #[Scripted.askCall "q" "Keep it?"])) "Unknown tool 'ask_user'"
    assertContains "its own refusal" (parse asking (Scripted.responseWith #[Scripted.askCall "q" "Which?" "single_choice" #["only"]]))
      "at least two options"
    assertContains "alone" (parse asking (Scripted.responseWith #[Scripted.askCall "q" "Keep it?", Scripted.call "c" "bash" "ls"]))
      "ask_user must be called alone"
    assertError "an unknown kind" (Builtin.catalog.complete "mini-vero" (.mkObj [("question_types", .arr #["multiple_choice"])])) fun
      | .input m => contains m "must be yes_no or single_choice or open_ended, not multiple_choice"
      | _ => false,

  test "a long output's note names the file that holds it, and an old one is that file alone" do
    let long := String.join (List.replicate 3000 "x\n")
    let shown (file? : Option String) (omitted := false) : String :=
      MiniVero.observe { output := long, exitCode? := some 1 } file? omitted
    assertContains "with its file" (shown (some "/alaya/outputs/7.txt")) "Full output: /alaya/outputs/7.txt]"
    check (!contains (shown none) "Full output") "with none, no file"
    assertStringEq "omitted" (shown (some "/alaya/outputs/7.txt") true)
      "[output omitted; full output: /alaya/outputs/7.txt]\n\nCommand exited with code 1"
    check (config.tools.any fun tool => tool.name == "bash" &&
      ((tool.arguments (.mkObj [("command", "ls")])).getObjVal? "executor" |>.toOption
        |>.any fun executor => (executor.getObjVal? "outputs").toOption == some (.bool true))) "every command keeps its output as a file"
]
private def call (id name : String) (arguments : Lean.Json := .mkObj []) : Chat.ToolCall :=
  { id, name, arguments }

private def turn (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

def timeSuite : Suite := Testing.suite "agents/mini-vero.time" #[
  test "the opening tells the agent it is told the time left, and not to use date" do
    let text ← openingText "TASK_CODEPROOF"
    let offset (needle : String) : Nat := (text.splitOn needle)[0]!.length
    check (contains text "## Checkpointing — work within your time budget") "the section is there"
    check (contains text "you are told how much is left") "it says the time comes to it"
    check (contains text "Do not use ``date``") "it says not to use date"
    check (!contains text "time_budget") "it names no tool"
    check (offset "## Done condition" < offset "## Persistence" && offset "## Persistence" < offset "## Checkpointing"
        && offset "## Checkpointing" < offset "## Anti-cheating")
      "Done condition, Persistence, Checkpointing, Anti-cheating, as in Vero",

  test "the model is told the time left once each tenth of the budget is spent" do
    let budget := 90 * 60000
    let after (minutes : Nat) : Timing := { spentMs := minutes * 60000, budgetMs? := some budget }
    assertEqual "none at the start" (MiniVero.notice? (0, 0) (after 0)) none
    assertEqual "none within the first tenth" (MiniVero.notice? (0, 0) (after 8)) none
    assertEqual "one past it" (MiniVero.notice? (0, 0) (after 9)) (some ("[time] 81 of 90 minutes remain.", (budget, 1)))
    assertEqual "none again in that tenth" (MiniVero.notice? (budget, 1) (after 17)) none
    assertEqual "one past the next" ((MiniVero.notice? (budget, 1) (after 18)).map (·.1)) (some "[time] 72 of 90 minutes remain.")
    assertEqual "none without a budget" (MiniVero.notice? (0, 0) { spentMs := 600000 }) none
    -- A later run with another budget is told afresh.
    let longer := 180 * 60000
    assertEqual "another budget" ((MiniVero.notice? (budget, 9) { spentMs := 81 * 60000, budgetMs? := some longer }).map (·.1))
      (some "[time] 99 of 180 minutes remain."),

  test "a submit before the last tenth runs the Done check: refused while it fails, taken once it passes" do
    let checks ← IO.mkRef 0
    let executor : Executor := { exec := fun _ _ argv _ => do
      if argv[0]? != some MiniVero.doneCheck then
        return { output := "ok", exitCode? := some 0 }
      checks.modify (· + 1)
      if (← checks.get) == 1 then
        return { output := "warning: Base58/Proof/Spec.lean:12:8: declaration uses 'sorry'", exitCode? := some 1 }
      return { output := "Build completed successfully.", exitCode? := some 0 } }
    let submitCall : Chat.ToolCall := { id := "s", name := "submit", arguments := .mkObj [("message", "done")] }
    let again : Chat.ToolCall := { submitCall with id := "t" }
    let model ← Scripted.scriptedModel #[turn #[submitCall], turn #[again]]
    withVero config fun run => do
      let rt ← Scripted.runtime executor (some model)
      let (final, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run) { budgetMs? := some 3600000 }
      let log ← Scripted.logAt rt final
      assertEqual "the second is taken" (Scripted.agentStatus log) "Submitted"
      assertEqual "each ran the check" (← checks.get) 2
      let some (request, _) := (Scripted.samplesOf run log)[1]? | fail "a second request"
      let told := request.messages.findSome? fun
        | .tool "s" (.str text) => some text
        | _ => none
      check (told.any fun text => contains text "Not done" && contains text "uses 'sorry'" && contains text "minutes remain")
        s!"the first was answered with why, and the time left: {told}",

  test "mini-swe neither offers time_budget nor accepts it in its configuration" do
    assertEqual "tools" ((MiniSwe.tools {}).map (·.name)) #["bash"]
    match MiniSwe.formatError? {} (turn #[call "t" "time_budget"]) with
    | some message => check (contains message "Unknown tool 'time_budget'") "unknown"
    | none => fail "mini-swe must not accept time_budget"
    assertError "config" (Builtin.catalog.complete "mini-swe" (.mkObj [("time_budget", true)])) fun
      | .input m => contains m "unknown field 'time_budget'"
      | _ => false,

  test "each entry records its time, and each round times the run against the budget" do
    withVero config fun run => do
      let executor ← containerExecutor
      try
        let model ← Scripted.scriptedModel #[turn #[call "c" "bash" (.mkObj [("command", "sleep 0.2")])],
          turn #[call "s" "submit" (.mkObj [("message", "")])]]
        let rt ← Scripted.runtime executor (some model)
        let limits : Driver.Limits := { budgetMs? := some 3600000, samples? := some 2 }
        let (final, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run) limits
        let forest ← assertOk rt.store.forest
        let entries ← assertOk <| rt.store.entries forest final
        let slept := entries.foldl (fun ms e => match e.event with
          | .answered _ (.exec "sleep 0.2" _) _ => ms + e.elapsedMs | _ => ms) 0
        check (slept >= 200) s!"the command's entry took the sleep, recorded {slept} ms"
        let timings := entries.filterMap fun e => match e.event with
          | .answered ⟪"session", "agent"⟫ .time (.ok (.timing t)) => some t
          | _ => none
        check (timings.size ≥ 2) s!"each round times the run: {timings.size}"
        check (timings.all (·.budgetMs? == some 3600000)) "against the budget"
        check ((timings.back?.map (·.spentMs)).any (· ≥ slept)) "the reading counts the run so far"
        -- The test image has no Lean: its Done check fails, and the early submit is refused.
        let log := entries.map (·.event)
        check (log.any fun | .answered _ (.exec command _) _ => command == MiniVero.doneCheck | _ => false)
          "the submit ran the Done check"
        assertEqual "and the run went on" (Scripted.agentStatus log) "running"
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
        check (Scripted.isIdle stop) "without a budget it runs on"
        assertEqual "submitted" (Scripted.agentStatus (← Scripted.logAt rt final)) "Submitted"
      finally executor.close
]


/-- Runs whose commands do matter, in the test container. -/
def containerSuite : Suite := Testing.suite "agents/mini-vero.container" #[
  test "subagent calls the agent itself on the model's task, in its own scope, in a frame of its own" do
    let delegated : Chat.ToolCall := { id := "d", name := "subagent", arguments := .mkObj [("task", "write b.txt")] }
    let .ok run := Scripted.veroRun config | fail "mini-vero is a run"
    let rt ← Scripted.containerRuntime (some (← Scripted.scriptedModel #[
      Scripted.responseWith #[delegated],
      Scripted.responseWith #[Scripted.call "c1" "bash" "echo b > b.txt"],
      Scripted.responseWith #[Scripted.submitCall "s1" "wrote it"],
      Scripted.responseWith #[Scripted.submitCall "s2" "delegated"]]))
    let (last, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run)
    let log ← Scripted.logAt rt last
    assertEqual "the agent's outcome" (Scripted.agentStatus log) "Submitted"
    assertEqual "the calls: the session, the agent, MiniVero itself in its frame, its bash in the sub-agent's"
      (log.filterMap fun | .opened frame opened => some (frame, opened.name) | _ => none)
      #[(⟪"session"⟫, "session"), (⟪"session", "agent"⟫, "agent"), (⟪"session", "agent", "subagent"⟫, "subagent"),
        (⟪"session", "agent", "subagent", "mini-vero"⟫, "mini-vero"),
        (⟪"session", "agent", "subagent", "mini-vero", "bash"⟫, "bash")]
    check (log.any fun
        | .opened ⟪"session", "agent", "subagent", "mini-vero"⟫ { name := "mini-vero", arguments := delegated, environment? := none } =>
          Scripted.taskOf delegated == some "write b.txt"
        | _ => false)
      "the sub-agent's call is the agent's configuration, with the model's task, and no environment"
    let requests := Scripted.samplesOf run log
    check (requests[1]!.1.messages.any fun | .user text => contains text "write b.txt" | _ => false)
      "the sub-agent was told the model's task"
    check (requests[3]!.1.messages.any fun | .tool "d" content => contains content.compress "wrote it" | _ => false)
      "the agent was shown how the sub-agent ended"
    assertEqual "the sub-agent's edit" (← IO.FS.readFile ((← scratch) / "work" / "b.txt")) "b\n",

  test "a command finds the whole output of an earlier one, in the file its warning names" do
    let long := String.ofList (List.replicate 12000 'q')
    let .ok run := Scripted.veroRun config | fail "mini-vero is a run"
    let rt ← Scripted.containerRuntime (some (← Scripted.scriptedModel #[
      Scripted.responseWith #[Scripted.call "c1" "bash" s!"printf '%s' {long}"],
      Scripted.responseWith #[Scripted.call "c2" "bash" "wc -c < $(ls /alaya/outputs/*.txt | head -n 1)"],
      Scripted.responseWith #[Scripted.submitCall "c3"]]))
    let (last, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run)
    let log ← Scripted.logAt rt last
    check (log.any fun | .answered _ (.exec cmd _) (.ok (.execution e)) => contains cmd "wc -c" && contains e.output.output "12000" | _ => false)
      "the file holds it all"
]
end MiniVeroTests
