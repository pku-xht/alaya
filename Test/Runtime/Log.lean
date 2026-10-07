import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! The log of Alaya's agents, without running anything: every event reads back from its JSON as
itself, an entry's name is its event and its parent's, and replay reads notices, stops and
breaks the way the design says. The interpreter itself is checked against the sketch in
`Test/Core/Prototype.lean`. -/

namespace LogTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Lean (Json)

private def snapshot (c : Char) : Snapshot := ⟨String.ofList (List.replicate 64 c)⟩

/-- One event of every kind, and every answer. -/
private def events : Array (Event Agent) := #[
  .arrived (.changed (snapshot 'a') "the project"),
  .arrived (.said "the task\nwith a second line"),
  .arrived (.replied ⟪"session", "agent", "ask_user"⟫ (.choice 2)),
  .arrived (.replied ⟪"session", "agent", "ask_user"⟫ .noneOfAbove),
  .arrived (.replied ⟪"session", "agent", "ask_user"⟫ (.text "words")),
  .arrived (.replied ⟪"session", "agent", "ask_user"⟫ .unavailable),
  .arrived (.replied ⟪"session", "agent", "ask_user"⟫ .yes),
  .heard ⟪"session", "agent"⟫ #[2, 5],
  .heard ⟪"session", "agent", "bash"⟫ #[],
  .answered ⟪"session", "agent"⟫ (.sample testModelSpec.toJson (snapshot 'b')) (.ok (.response
    { content? := some "hi", toolCalls := #[call "c" "bash" "ls"], reasoning? := some "think"
      usage? := some { input? := some 10, output? := some 2, cached? := some 4 }
      finishReason? := some "tool_calls" })),
  .answered ⟪"session", "agent"⟫ (.sample testModelSpec.toJson (snapshot 'b')) (.error "context exceeded: too long"),
  .answered ⟪"session", "agent", "bash"⟫ (.exec "ls -la" { timeoutSeconds := 30, env := #[("A", "1")], outputs := true })
    (.ok (.execution { output := { output := "x\n", exitCode? := some 0 }, workspace := snapshot 'c'
                       file? := some "/alaya/outputs/7.txt" })),
  .answered ⟪"session", "agent", "bash#1"⟫ (.exec "sleep 9" {}) (.ok (.execution
    { output := { output := "", error? := some "timed out" }, workspace := snapshot 'c' })),
  .answered ⟪"session", "agent", "time_budget"⟫ .time (.ok (.timing { spentMs := 1200, budgetMs? := some 60000 })),
  .answered ⟪"session", "agent", "time_budget"⟫ .time (.ok (.timing { spentMs := 1200 })),
  .answered ⟪"session", "grader"⟫ (.exec "sh g.sh" { timeoutSeconds := 900, merge := false })
    (.ok (.execution { output := { output := "ok 1\n", stderr? := some "e", exitCode? := some 1 }, workspace := snapshot 'e' })),
  .opened ⟪"session", "agent", "bash"⟫ { name := "bash", arguments := .mkObj [("command", "ls")] },
  .returned ⟪"session", "agent", "bash"⟫ (.mkObj [("output", "x")]),
  .failed ⟪"session", "agent", "bash"⟫ "no routine named bash",
  .broke ⟪"session", "agent"⟫ "to grade this point",
  .commented "a comment\non two lines",
  (graderCall "sh /grader/g.sh").event,
  callAgent "the task"]

/-- The call of the agent of `runOf`'s runs. -/
private def agentCall : RoutineCall := { name := "agent", arguments := .null }

/-- A run whose call is of the agent itself, `computation`, with a tool `boom` that fails, and
ends with what the agent gave: no session, so that a log of one call ends where it does. -/
private def runOf (computation : Computation Agent Json) : Scope Agent :=
  Scope.fix fun scope => #[{ name := "agent", body := fun _ => computation, scope },
    { name := "boom", body := fun _ => throw "it broke", scope }]

/-- The start of a log of `runOf`'s runs: the workspace, and the call of the agent. -/
private def rootOnly : Log Agent := #[.arrived (.changed default "p"), agentCall.event]

def suite : Suite := Testing.suite "runtime/log" #[
  iotest "every event reads back from its JSON as itself" do
    for event in events do
      let json := eventToJson event
      match eventFromJson (← IO.ofExcept (Json.parse json.compress)) with
      | .ok again =>
        if (eventToJson again).compress != json.compress then
          throw <| IO.userError s!"{json.compress} reads back as {(eventToJson again).compress}"
      | .error problem => throw <| IO.userError s!"{json.compress}: {problem}",

  iotest "an entry is named by its event and its parent, not by when it happened" do
    let event := events[1]!
    let one : Entry := { parent? := some (snapshot '1'), event, elapsedMs := 5 }
    let two : Entry := { one with elapsedMs := 900 }
    if one.hash != two.hash then throw <| IO.userError "the time is part of the name"
    if one.hash == { one with parent? := some (snapshot '2') }.hash then
      throw <| IO.userError "the parent is not part of the name"
    match Entry.fromJson one.toJson with
    | .ok again => if again.hash != one.hash || again.elapsedMs != 5 then throw <| IO.userError "no round trip"
    | .error problem => throw <| IO.userError problem,

  iotest "the workspace of a log is the last version a command or a person left" do
    let log : Log Agent := #[events[0]!, events[11]!, .arrived (.changed (snapshot 'f') "edited"), events[7]!]
    if workspace? log != some (snapshot 'f') then throw <| IO.userError "wrong version"
    if workspace? (log.extract 0 2) != some (snapshot 'c') then throw <| IO.userError "wrong version after a command"
    let named := snapshots (events)
    for c in ['a', 'c', 'e'] do
      if !named.contains (snapshot c) then throw <| IO.userError s!"{c} is not kept"
    if named.contains (snapshot 'b') then throw <| IO.userError "a request's digest is no snapshot",

  iotest "an event of a kind this build does not know is refused, not guessed" do
    let frame : Json := .arr #[(0 : Json)]
    for json in [Json.mkObj [("type", "vanished")], .mkObj [("frame", frame)],
        .mkObj [("type", "arrived"), ("notice", .mkObj [("type", "shouted"), ("message", "x")])],
        .mkObj [("type", "arrived"), ("notice", .mkObj [("type", "changed"), ("workspace", "../x"), ("summary", "")])],
        .mkObj [("type", "arrived"), ("notice", .mkObj [("type", "replied"), ("to", frame),
          ("reply", .mkObj [("type", "maybe")])])],
        .mkObj [("type", "heard"), ("frame", "0"), ("notices", .arr #[])],
        .mkObj [("type", "answered"), ("frame", frame), ("op", .mkObj [("type", "teleport")]), ("answer", .null), ("error", .null)],
        .mkObj [("type", "answered"), ("frame", frame), ("op", .mkObj [("type", "time")]),
          ("answer", .mkObj [("output", "a command's answer")]), ("error", .null)],
        .mkObj [("type", "opened"), ("frame", frame), ("routine", .mkObj [("arguments", .null)])]] do
      if (eventFromJson json).toOption.isSome then throw <| IO.userError s!"read as an event: {json.compress}",

  test "an answer to another operation, or a mark that differs, is no trace of the program" do
    match veroRun with
    | .error problem => fail problem
    | .ok run =>
      let broken (label : String) (log : Log Agent) (event : Event Agent) : TestM Unit :=
        match next run (log.push event) with
        | .mismatch position => assertEqual label position log.size
        | _ => fail s!"{label}: taken for a trace"
      let log := settle run opening
      let .ask sampled := next run log | fail "the agent samples"
      let other : Chat.Response := {}
      broken "another request" log (.answered sampled.frame (.sample testModelSpec.toJson (Hash.ofBytes "other".toUTF8)) (.ok (.response other)))
      broken "another frame" log (.answered ⟪"session", "agent", "bash"⟫ sampled.op.key (.ok (.response other)))
      broken "an answer of another kind" log (.answered sampled.frame sampled.op.key (.ok (.timing { spentMs := 1 })))
      broken "an answer to another operation" log (.answered sampled.frame .time (.ok (.timing { spentMs := 1 })))
      broken "a mark where an answer is due" log (.heard ⟪"session", "agent"⟫ #[])
      let log := respond run log (responseWith #[call "c" "bash" "ls"])
      let .ask ran := next run log | fail "the command is asked for"
      broken "another command" log (.answered ran.frame (.exec "rm -rf /" {}) (.ok (.execution default)))
      let execution : Execution := { output := { output := "x\n", exitCode? := some 0 }, workspace := default }
      let log := log.push (.answered ran.frame ran.op.key (.ok (.execution execution)))
      let .mark (.returned frame value) := next run log | fail "the call returns"
      broken "another value" log (.returned frame (.str "x"))
      broken "another frame's return" log (.returned ⟪"session", "agent", "bash#1"⟫ value)
      broken "a failure where it returned" log (.failed frame "x")
      match next run (log.push (.returned frame value)) with
      | .mark (.heard ⟪"session", "agent"⟫ _) => pure ()
      | _ => fail "the log as the program makes it goes on",

  test "a frame's commands run where the nearest call on its path that names an environment says" do
    let unreadable (label : String) (log : Log Agent) (frame : Frame) : TestM Unit :=
      assertError label (environmentOf log frame) fun | .storage _ => true | _ => false
    unreadable "no opening" rootOnly ⟪"session", "agent"⟫
    unreadable "the outside" (opening "t") #[]
    unreadable "the session, which names none" (opening "t") ⟪"session"⟫
    unreadable "a call that names none, on a path where none does"
      (rootOnly.push (.opened ⟪"session", "agent"⟫ { testCall "t" with environment? := none })) ⟪"session", "agent"⟫
    -- A call inside the call that names none shares its caller's environment.
    let (named, environment) ← assertOk <| environmentOf (opening "t") ⟪"session", "agent", "bash"⟫
    assertEqual "the caller's" (named, environment.image) (⟪"session", "agent"⟫, testEnvironment.image)
    -- One that names its own runs there, and so do the calls inside it.
    let grading := (opening "t").push (.opened ⟪"session", "agent", "grader"⟫ (graderCall "sh g.sh" "grader:1"))
    let (named, environment) ← assertOk <| environmentOf grading ⟪"session", "agent", "grader", "bash"⟫
    assertEqual "its own" (named, environment.image) (⟪"session", "agent", "grader"⟫, "grader:1")

]

end LogTests
