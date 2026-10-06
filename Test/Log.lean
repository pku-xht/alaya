import Test.Framework
import Test.Scripted
import Alaya

/-! The log of Alaya's agents, without running anything: every event reads back from its JSON as
itself, an entry's name is its event and its parent's, and replay reads notices, stops and
breaks the way the design says. The interpreter itself is checked against the sketch in
`Test/Prototype.lean`. -/

namespace LogTests

open Testing Alaya Scripted
open Lean (Json)

private def snapshot (c : Char) : Snapshot := ⟨String.ofList (List.replicate 64 c)⟩

/-- One event of every kind, and every answer. -/
private def events : Array (Event Agent) := #[
  .arrived (.changed (snapshot 'a') "the project"),
  .arrived (.said "the task\nwith a second line"),
  .arrived (.replied ⟪"agent", "ask_user"⟫ (.choice 2)),
  .arrived (.replied ⟪"agent", "ask_user"⟫ .noneOfAbove),
  .arrived (.replied ⟪"agent", "ask_user"⟫ (.text "words")),
  .arrived (.replied ⟪"agent", "ask_user"⟫ .unavailable),
  .arrived (.replied ⟪"agent", "ask_user"⟫ .yes),
  .heard ⟪"agent"⟫ #[2, 5],
  .heard ⟪"agent", "bash"⟫ #[],
  .answered ⟪"agent"⟫ (.sample testModelSpec.toJson (snapshot 'b')) (.ok (.response
    { content? := some "hi", toolCalls := #[call "c" "bash" "ls"], reasoning? := some "think"
      usage? := some { input? := some 10, output? := some 2, cached? := some 4 }
      finishReason? := some "tool_calls" })),
  .answered ⟪"agent"⟫ (.sample testModelSpec.toJson (snapshot 'b')) (.error "context exceeded: too long"),
  .answered ⟪"agent", "bash"⟫ (.exec "ls -la" { timeoutSeconds := 30, env := #[("A", "1")], outputs := true })
    (.ok (.execution { output := { output := "x\n", exitCode? := some 0 }, workspace := snapshot 'c'
                       file? := some "/alaya/outputs/7.txt" })),
  .answered ⟪"agent", "bash#1"⟫ (.exec "sleep 9" {}) (.ok (.execution
    { output := { output := "", error? := some "timed out" }, workspace := snapshot 'c' })),
  .answered ⟪"agent", "time_budget"⟫ .time (.ok (.timing { spentMs := 1200, budgetMs? := some 60000 })),
  .answered ⟪"agent", "time_budget"⟫ .time (.ok (.timing { spentMs := 1200 })),
  .answered ⟪"grader"⟫ (.exec "sh g.sh" { timeoutSeconds := 900, merge := false })
    (.ok (.execution { output := { output := "ok 1\n", stderr? := some "e", exitCode? := some 1 }, workspace := snapshot 'e' })),
  .opened ⟪"agent", "bash"⟫ ⟨"bash", .mkObj [("command", "ls")]⟩,
  .returned ⟪"agent", "bash"⟫ (.mkObj [("output", "x")]),
  .failed ⟪"agent", "bash"⟫ "no routine named bash",
  .stopped "to grade this point",
  .commented "a comment\non two lines",
  (graderCall "sh /grader/g.sh").event,
  callAgent "the task"]

/-- The call of the agent of `runOf`'s runs. -/
private def agentCall : RoutineCall := ⟨"agent", .null⟩

/-- A run whose routine calls `computation` as its agent at once, with a tool `boom` that fails,
and ends with what the agent gave: no session, so that a log of one call ends where it does. -/
private def runOf (computation : Computation Agent Json) : Routine Agent :=
  { name := "run"
    body := fun _ => .call agentCall fun
      | .ok value => pure value
      | .error error => throw error
    scope := Scope.fix fun scope => #[{ name := "agent", body := fun _ => computation, scope },
      { name := "boom", body := fun _ => throw "it broke", scope }] }

private def rootOnly : Log Agent := #[.arrived (.changed default "p")]

def suite : Suite := Testing.suite "log" #[
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

  test "a read takes what it is for, even what arrived before it was made" do
    -- A message arrives before the agent is called: the run's wait for a call passes it over, and
    -- the agent's first read takes it.
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let early : Log Agent := #[.arrived (.changed default "p"), .arrived (.said "a hint"), callAgent "the task"]
      match next run early with
      | .mark (.heard #[] notices) => assertEqual "the run takes the call alone" notices #[2]
      | _ => fail "the run reads its call first"
      let log := settle run early
      match next run log with
      | .ask { op := .sample _ request, .. } =>
        check (request.messages.any fun | .user text => contains text "the task" | _ => false) "the task is told"
        check (request.messages.any fun | .user text => contains text "a hint" | _ => false) "and the message"
      | _ => fail "the agent goes on to sample"
      check (log.any fun | .heard ⟪"agent"⟫ #[1] => true | _ => false) "the agent's read takes the message at 1",

  test "a stop ends the call wherever it is, and has no place where no call runs" do
    -- An agent that waits for a message.
    let run := Scripted.runOf fun _ => do
      let _ ← await fun _ notice => notice matches .said _
      return "done"
    -- Where no call runs there is nothing to stop.
    match next run #[.arrived (.changed default "p"), .stopped "now"] with
    | .mismatch 1 => pure ()
    | _ => fail "a stop before any call is no trace of the run"
    let waiting := settle run opening
    match next run waiting with
    | .waits ⟪"agent"⟫ _ => pure ()
    | _ => fail "the agent waits for a message"
    let ended := settle run (waiting.push (.stopped "no message"))
    match next run ended with
    | .waits #[] none => pure ()
    | _ => fail "the agent is over, and the run waits for a call"
    check (((lastCall? ended).bind (·.2)) matches some (.stopped "no message")) "the log says how the call ended"
    match next run (ended.push (.stopped "again")) with
    | .mismatch position => assertEqual "where" position ended.size
    | _ => fail "a stop after the end is no trace of the program",

  test "a log with no root waits, and one that starts otherwise is broken" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      match next run #[] with
      | .waits #[] _ => pure ()
      | _ => fail "an empty log waits for its workspace"
      match next run #[.arrived (.said "hello")] with
      | .mismatch 0 => pure ()
      | _ => fail "a log that starts with no workspace is broken",

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
    match miniRun with
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
      broken "another frame" log (.answered ⟪"agent", "bash"⟫ sampled.op.key (.ok (.response other)))
      broken "an answer of another kind" log (.answered sampled.frame sampled.op.key (.ok (.timing { spentMs := 1 })))
      broken "an answer to another operation" log (.answered sampled.frame .time (.ok (.timing { spentMs := 1 })))
      broken "a mark where an answer is due" log (.heard ⟪"agent"⟫ #[])
      let log := respond run log (responseWith #[call "c" "bash" "ls"])
      let .ask ran := next run log | fail "the command is asked for"
      broken "another command" log (.answered ran.frame (.exec "rm -rf /" {}) (.ok (.execution default)))
      let execution : Execution := { output := { output := "x\n", exitCode? := some 0 }, workspace := default }
      let log := log.push (.answered ran.frame ran.op.key (.ok (.execution execution)))
      let .mark (.returned frame value) := next run log | fail "the call returns"
      broken "another value" log (.returned frame (.str "x"))
      broken "another frame's return" log (.returned ⟪"agent", "bash#1"⟫ value)
      broken "a failure where it returned" log (.failed frame "x")
      match next run (log.push (.returned frame value)) with
      | .mark (.heard ⟪"agent"⟫ _) => pure ()
      | _ => fail "the log as the program makes it goes on",

  test "a failure is caught around a loop, around a call, or by no one, and each try is in the log" do
    -- Three rounds, each reading the clock; the third gives up.
    let rounds : Computation Agent Json := iter (fun (n : Nat) => do
      let timing ← time
      if n == 2 then throw s!"gave up at {timing.spentMs}" else pure (Sum.inl (n + 1))) 0
    let caught := runOf (try rounds catch error => pure (.str s!"caught: {error}"))
    let mut log := settle caught rootOnly
    for ms in [10, 20, 30] do
      log := answer caught log (.timing { spentMs := ms })
    match next caught log with
    | .ended (.ok value) => assertEqual "the handler's value" value.compress "\"caught: gave up at 30\""
    | _ => fail "the run ends with what the handler gave"
    assertEqual "three reads of the clock" (log.filter fun | .answered _ .time _ => true | _ => false).size 3
    -- A loop that ends inside a `try` gives its value, and the handler is not run.
    let ends := runOf (try iter (fun (n : Nat) => do
        let _ ← time
        pure (if n == 1 then Sum.inr (Json.str "ended") else Sum.inl (n + 1))) 0
      catch _ => pure "never")
    let ended := answer ends (answer ends (settle ends rootOnly) (.timing { spentMs := 1 })) (.timing { spentMs := 2 })
    match next ends ended with
    | .ended (.ok value) => assertEqual "the loop's value" value.compress "\"ended\""
    | _ => fail "the run ends with the loop's value"
    -- Uncaught, the failure ends the agent's call, and with nothing after it the run.
    let uncaught := runOf rounds
    let mut failing := settle uncaught rootOnly
    for ms in [10, 20, 30] do
      failing := answer uncaught failing (.timing { spentMs := ms })
    check (failing.any fun | .failed ⟪"agent"⟫ "gave up at 30" => true | _ => false) "the agent's call failed"
    match next uncaught failing with
    | .ended (.error error) => assertEqual "the run's error" error "gave up at 30"
    | _ => fail "the run ends with the error"
    -- A tool that fails ends its own call with the error; its caller catches it or fails too.
    let calls := runOf (try call "boom" .null catch error => pure (.str s!"the tool said: {error}"))
    let called := settle calls rootOnly
    check (called.any fun | .failed ⟪"agent", "boom"⟫ "it broke" => true | _ => false) "the tool's call failed"
    check (called.any fun | .returned ⟪"agent"⟫ (.str "the tool said: it broke") => true | _ => false) "its caller went on"
    let missing := runOf (call "nowhere" .null)
    check ((settle missing rootOnly).any fun | .failed ⟪"agent", "nowhere"⟫ "no routine named nowhere" => true | _ => false)
      "a tool the run does not have fails its call"
    -- A loop that reads no event in a round would never end, and is found out.
    let spins := runOf (iter (fun (n : Nat) => (pure (Sum.inl (n + 1)) : Computation Agent (Nat ⊕ Json))) 0)
    match next spins (settle spins rootOnly) with
    | .unguarded ⟪"agent"⟫ => pure ()
    | _ => fail "a loop that reads nothing is reported",

  test "a comment is written where the driver reaches it, and replay passes over every one" do
    let commenting : Computation Agent Json := do
      comment "starting"
      let timing ← time
      comment s!"the clock says {timing.spentMs}"
      return "done"
    let quiet : Computation Agent Json := do
      let _ ← time
      return "done"
    let run := runOf commenting
    let over (label : String) (run : Routine Agent) (log : Log Agent) : TestM Unit :=
      check ((next run log) matches .ended (.ok _)) s!"{label}: the run is not over"
    -- At the end of a log, the program's comments since its last event wait for the next event:
    -- what comes next is the operation.
    let opened := rootOnly.push (.opened ⟪"agent"⟫ agentCall)
    check ((next run opened) matches .ask { op := .time, .. }) "the operation is next"
    assertEqual "the comment before it" (Replayer.ofLog run opened).comments #["starting"]
    -- Settled as the driver settles it, the log holds each comment once, before the event it precedes.
    let log := answer run (settle run rootOnly) (.timing { spentMs := 7 })
    assertEqual "the comments" (log.filterMap fun | .commented text => some text | _ => none)
      #["starting", "the clock says 7"]
    check (log[2]! matches .commented "starting") "the first, before the clock"
    over "with its comments" run log
    -- Replay needs none of them: without them, reworded, or with others among them, the log is
    -- the same trace; and a program whose comments were taken out reads the old log.
    over "without them" run (log.filter fun | .commented .. => false | _ => true)
    over "reworded" run (log.map fun | .commented _ => .commented "reworded" | event => event)
    for i in [1:log.size + 1] do
      over s!"another at {i}" run ((log.extract 0 i).push (.commented "by hand") ++ log.extract i log.size)
    over "a program without comments" (runOf quiet) log
    -- A comment of the log is never taken for the program's, even with its very words: the
    -- program's is still to be written.
    assertEqual "the same words in the log" (Replayer.ofLog run (opened.push (.commented "starting"))).comments
      #["starting"]
    -- A comment takes a position like any event, so the positions a read marks count it.
    match miniRun with
    | .error problem => fail problem
    | .ok mini =>
      let early : Log Agent := #[.arrived (.changed default "p"), .commented "before the call",
        callAgent "the task", .commented "after the call"]
      check ((next mini early) matches .mark (.heard #[] #[2])) "the call is at 2, the comments around it"
    -- A comment reads no event: a loop that only comments is as unguarded as one that does nothing.
    let spins := runOf (iter (fun (n : Nat) => (do
      comment s!"round {n}"
      pure (Sum.inl (n + 1)) : Computation Agent (Nat ⊕ Json))) 0)
    check ((next spins (settle spins rootOnly)) matches .unguarded ⟪"agent"⟫) "a loop that only comments is reported",

  test "a grader is a call like any: the run waits for it, opens it in a frame of its own, and it gives the verdict" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      -- The agent ends, and the run waits for the next call.
      let log := respond run (settle run opening) (responseWith #[submitCall "s" "done"])
      check ((next run log) matches .waits #[] none) "the run waits for a call"
      check (((lastCall? log).bind (·.2)) matches some (.returned _)) "the agent returned"
      -- The grader: the run takes the call, opens it in `grader`, and its command is asked for there,
      -- with its stderr apart.
      let called := log.size
      let log := settle run (log.push (graderCall "sh g.sh").event)
      check (log.any fun | .heard #[] notices => notices == #[called] | _ => false) "the run's own frame takes the call"
      check (log.any fun | .opened ⟪"grader"⟫ ⟨"grader", _⟩ => true | _ => false) "the grader opens in a frame of its own"
      let .ask first := next run log | fail "the grader's command is asked for"
      assertEqual "in its frame" first.frame ⟪"grader"⟫
      check (first.op matches .exec "sh g.sh" { merge := false, .. }) "the command, its stderr apart"
      -- Its verdict is the value of its call, and the run waits again.
      let graded := answer run log (.execution { output := { output := "1..1\nok 1\n", stderr? := some "", exitCode? := some 0 }, workspace := default })
      check ((next run graded) matches .waits #[] none) "the run waits for the next call"
      match lastCall? graded with
      | some (opened, some (.returned verdict)) =>
        assertEqual "the grader's verdict" (opened.name, Agents.Grader.verdictStatus verdict) ("grader", "pass")
      | _ => fail "the grader returned its verdict",

  test "a call's environment is the person's call's, which the run took before it opened the call" do
    let unreadable (label : String) (log : Log Agent) (frame : Frame) : TestM Unit :=
      assertError label (environmentOf log frame) fun | .storage _ => true | _ => false
    unreadable "no opening" rootOnly ⟪"agent"⟫
    unreadable "the run's own frame" (rootOnly.push (.opened ⟪"agent"⟫ (testCall "t"))) #[]
    unreadable "no person's call" (rootOnly.push (.opened ⟪"agent"⟫ (testCall "t"))) ⟪"agent"⟫
    -- A call inside the call shares its environment.
    let environment ← assertOk <| environmentOf (opening "t") ⟪"agent", "bash"⟫
    assertEqual "the environment" environment.toJson.compress testEnvironment.toJson.compress,

  iotest "frames render as paths of routines, read back, and a reference to an entry may name a position" do
    if Frame.render ⟪"agent", "bash#2", "x"⟫ != "agent/bash#2/x" || Frame.render ⟪⟫ != "-" then
      throw <| IO.userError "frames render as paths of routines"
    if (Frame.parse "agent/bash#2/x").toOption != some ⟪"agent", "bash#2", "x"⟫ || (Frame.parse "-").toOption != some ⟪⟫ then
      throw <| IO.userError "frames read back as they render"
    if (Frame.parse "agent/bash#x").toOption.isSome || (Frame.parse "agent//x").toOption.isSome then
      throw <| IO.userError "a malformed frame is refused"
    let a : Hash := snapshot 'a'
    let b : Hash := ⟨"ab" ++ String.ofList (List.replicate 62 '1')⟩
    let c : Hash := ⟨"ab" ++ String.ofList (List.replicate 62 '2')⟩
    let forest := ((({} : Forest).add a none).add b (some a)).add c (some b)
    if (forest.resolve "ab1").toOption != some b then throw <| IO.userError "a prefix"
    if (forest.resolve "ab2:0").toOption != some a then throw <| IO.userError "position 0 of a log is its root"
    if (forest.resolve "ab2:1").toOption != some b then throw <| IO.userError "a position"
    if (forest.resolve "ab").toOption.isSome then throw <| IO.userError "an ambiguous prefix"
    if (forest.resolve "ab2:3").toOption.isSome then throw <| IO.userError "a position past the end"
    if forest.leaves != #[c] then throw <| IO.userError "the leaves"
    if forest.subtree b != #[b, c] then throw <| IO.userError "the subtree"
]

end LogTests
