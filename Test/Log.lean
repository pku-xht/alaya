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
  .arrived (.replied #[0, 3] (.choice 2)),
  .arrived (.replied #[0, 3] .noneOfAbove),
  .arrived (.replied #[0, 3] (.text "words")),
  .arrived (.replied #[0, 3] .unavailable),
  .arrived (.replied #[0, 3] .yes),
  .heard #[0] #[2, 5],
  .heard #[0, 1] #[],
  .answered #[0] (.sample (snapshot 'b')) (.ok (.response
    { content? := some "hi", toolCalls := #[call "c" "bash" "ls"], reasoning? := some "think"
      usage? := some { input? := some 10, output? := some 2, cached? := some 4 }
      finishReason? := some "tool_calls" })),
  .answered #[0] (.sample (snapshot 'b')) (.error "context exceeded: too long"),
  .answered #[0, 1] (.exec "ls -la" { timeoutSeconds := 30, env := #[("A", "1")], outputs := true })
    (.ok (.execution { output := { output := "x\n", exitCode? := some 0 }, workspace := snapshot 'c'
                       file? := some "/alaya/outputs/7.txt" })),
  .answered #[0, 1] (.exec "sleep 9" {}) (.ok (.execution
    { output := { output := "", error? := some "timed out" }, workspace := snapshot 'c' })),
  .answered #[0, 2] .time (.ok (.timing { spentMs := 1200, budgetMs? := some 60000 })),
  .answered #[0, 2] .time (.ok (.timing { spentMs := 1200 })),
  .answered #[1] (.external "sh /grader/g.sh" "img@sha256:1" (some (snapshot 'd')) 900)
    (.ok (.external { exitCode? := some 1, stdout := "ok 1\n", stderr := "e", checkout := snapshot 'e'
                      elapsedMs := 33 })),
  .answered #[1] (.external "sh" "img" none 0)
    (.ok (.external { stdout := "", stderr := "", checkout := snapshot 'e', elapsedMs := 0, error? := some "timed out" })),
  .opened #[0, 1] ⟨"bash", .mkObj [("command", "ls")]⟩,
  .returned #[0, 1] (.mkObj [("output", "x")]),
  .failed #[0, 1] "no tool named bash",
  .stopped "to grade this point",
  assignment { command := "sh /grader/g.sh", image := "img@sha256:1", input? := some (snapshot 'd'), timeoutSeconds := 60 }]

/-- A run with `program` as its agent, a tool `boom` that fails, and nothing after the agent. -/
private def runOf (program : Program Agent Json) : Run Agent :=
  { tools := fun name =>
      if name == agentTool then some fun _ => program
      else if name == "boom" then some fun _ => throw "it broke"
      else none
    call := ⟨agentTool, .null⟩
    after := fun
      | .ok value => pure value
      | .error error => throw error }

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
    | .error problem => throw <| IO.userError problem
    if (Entry.fromJson (one.toJson.setObjVal! "v" 2)).toOption.isSome then
      throw <| IO.userError "an entry of another schema is read",

  iotest "the workspace of a log is the last version a command or a person left" do
    let log : Log Agent := #[events[0]!, events[11]!, .arrived (.changed (snapshot 'f') "edited"), events[7]!]
    if workspace? log != some (snapshot 'f') then throw <| IO.userError "wrong version"
    if workspace? (log.extract 0 2) != some (snapshot 'c') then throw <| IO.userError "wrong version after a command"
    let named := snapshots (events)
    for c in ['a', 'c', 'd', 'e'] do
      if !named.contains (snapshot c) then throw <| IO.userError s!"{c} is not kept"
    if named.contains (snapshot 'b') then throw <| IO.userError "a request's digest is no snapshot"
    -- The input of a grader that is assigned and has not run yet is named by that notice alone.
    let assigned := assignment { command := "sh /grader/g.sh", image := "image", input? := some (snapshot '9') }
    if !(snapshots #[assigned]).contains (snapshot '9') then
      throw <| IO.userError "the input of an assigned grader is not kept",

  test "a waiting read takes what it is for, even what arrived before it was made" do
    -- The task arrives before the agent's call is opened: the agent's wait still takes it.
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let early : Log Agent := #[.arrived (.changed default "p"), .arrived (.said "the task")]
      match next run early with
      | .opens #[0] _ => pure ()
      | _ => fail "the agent is opened first"
      let log := settle run (early.push (.opened #[0] run.call))
      match next run log with
      | .ask { op := .sample request, .. } =>
        check (request.messages.any fun | .user text => contains text "the task" | _ => false) "the task is told"
      | _ => fail "the agent goes on to sample"
      check (log.any fun | .heard #[0] #[1] => true | _ => false) "the read takes the notice at 1",

  test "a stop ends the agent wherever it is, and has no place once it is over" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      -- Stopped before its agent was even opened, a run goes on to what follows: the wait for a
      -- grader.
      let stopped : Log Agent := #[.arrived (.changed default "p"), .stopped "now"]
      match next run stopped with
      | .waits #[] => pure ()
      | _ => fail "the run waits for a grader"
      -- Waiting for its task, the agent stops too.
      let waiting := settle run #[.arrived (.changed default "p"), .opened #[0] run.call]
      match next run waiting with
      | .waits #[0] => pure ()
      | _ => fail "the agent waits for its task"
      let ended := settle run (waiting.push (.stopped "no task"))
      match next run ended with
      | .waits #[] => pure ()
      | _ => fail "the agent is over, and the run waits for a grader"
      check ((agentEnd? ended) matches some (.stopped "no task")) "the log says how the agent ended"
      match next run (ended.push (.stopped "again")) with
      | .mismatch position => assertEqual "where" position ended.size
      | _ => fail "a stop after the end is no trace of the program",

  test "a log with no root waits, and one that starts otherwise is broken" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      match next run #[] with
      | .waits #[] => pure ()
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
        .mkObj [("type", "opened"), ("frame", frame), ("tool", .mkObj [("arguments", .null)])]] do
      if (eventFromJson json).toOption.isSome then throw <| IO.userError s!"read as an event: {json.compress}",

  test "an answer to another operation, or a mark that differs, is no trace of the program" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let broken (label : String) (log : Log Agent) (event : Event Agent) : TestM Unit :=
        match next run (log.push event) with
        | .mismatch position => assertEqual label position log.size
        | _ => fail s!"{label}: taken for a trace"
      let log := settle run (opening run)
      let .ask sampled := next run log | fail "the agent samples"
      let other : Chat.Response := {}
      broken "another request" log (.answered sampled.frame (.sample (Hash.ofBytes "other".toUTF8)) (.ok (.response other)))
      broken "another frame" log (.answered #[0, 0] sampled.op.key (.ok (.response other)))
      broken "an answer of another kind" log (.answered sampled.frame sampled.op.key (.ok (.timing { spentMs := 1 })))
      broken "an answer to another operation" log (.answered sampled.frame .time (.ok (.timing { spentMs := 1 })))
      broken "a mark where an answer is due" log (.heard #[0] #[])
      let log := respond run log (responseWith #[call "c" "bash" "ls"])
      let .ask ran := next run log | fail "the command is asked for"
      broken "another command" log (.answered ran.frame (.exec "rm -rf /" {}) (.ok (.execution default)))
      let execution : Execution := { output := { output := "x\n", exitCode? := some 0 }, workspace := default }
      let log := log.push (.answered ran.frame ran.op.key (.ok (.execution execution)))
      let .returns frame value := next run log | fail "the call returns"
      broken "another value" log (.returned frame (.str "x"))
      broken "another frame's return" log (.returned #[0, 1] value)
      broken "a failure where it returned" log (.failed frame "x")
      match next run (log.push (.returned frame value)) with
      | .hears #[0] _ => pure ()
      | _ => fail "the log as the program makes it goes on",

  test "a failure is caught around a loop, around a call, or by no one, and each try is in the log" do
    -- Three rounds, each reading the clock; the third gives up.
    let rounds : Program Agent Json := iter (fun (n : Nat) => do
      let timing ← time
      if n == 2 then throw s!"gave up at {timing.spentMs}" else pure (Sum.inl (n + 1))) 0
    let caught := runOf (try rounds catch error => pure (.str s!"caught: {error}"))
    let mut log := settle caught rootOnly
    for ms in [10, 20, 30] do
      log := answer caught log (.timing { spentMs := ms })
    match next caught log with
    | .done value => assertEqual "the handler's value" value.compress "\"caught: gave up at 30\""
    | _ => fail "the run ends with what the handler gave"
    assertEqual "three reads of the clock" (log.filter fun | .answered _ .time _ => true | _ => false).size 3
    -- A loop that ends inside a `try` gives its value, and the handler is not run.
    let ends := runOf (try iter (fun (n : Nat) => do
        let _ ← time
        pure (if n == 1 then Sum.inr (Json.str "ended") else Sum.inl (n + 1))) 0
      catch _ => pure "never")
    let ended := answer ends (answer ends (settle ends rootOnly) (.timing { spentMs := 1 })) (.timing { spentMs := 2 })
    match next ends ended with
    | .done value => assertEqual "the loop's value" value.compress "\"ended\""
    | _ => fail "the run ends with the loop's value"
    -- Uncaught, the failure ends the agent's call, and with nothing after it the run.
    let uncaught := runOf rounds
    let mut failing := settle uncaught rootOnly
    for ms in [10, 20, 30] do
      failing := answer uncaught failing (.timing { spentMs := ms })
    check (failing.any fun | .failed #[0] "gave up at 30" => true | _ => false) "the agent's call failed"
    match next uncaught failing with
    | .raised error => assertEqual "the run's error" error "gave up at 30"
    | _ => fail "the run ends with the error"
    -- A tool that fails ends its own call with the error; its caller catches it or fails too.
    let calls := runOf (try call "boom" .null catch error => pure (.str s!"the tool said: {error}"))
    let called := settle calls rootOnly
    check (called.any fun | .failed #[0, 0] "it broke" => true | _ => false) "the tool's call failed"
    check (called.any fun | .returned #[0] (.str "the tool said: it broke") => true | _ => false) "its caller went on"
    let missing := runOf (call "nowhere" .null)
    check ((settle missing rootOnly).any fun | .failed #[0, 0] "no tool named nowhere" => true | _ => false)
      "a tool the run does not have fails its call"
    -- A loop that reads no event in a round would never end, and is found out.
    let spins := runOf (iter (fun (n : Nat) => (pure (Sum.inl (n + 1)) : Program Agent (Nat ⊕ Json))) 0)
    match next spins (settle spins rootOnly) with
    | .unguarded #[0] => pure ()
    | _ => fail "a loop that reads nothing is reported",

  test "what follows the agent waits for its grader, calls it once, and ends with its verdict" do
    let grader (name : String) : Agents.Tools.Grade.Grader := { name, command := "true", image := "image" }
    let ran : External := { exitCode? := some 0, stdout := "1..1\nok 1\n", stderr := "", checkout := default, elapsedMs := 1 }
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      -- The agent ends, and the run waits: nothing follows until a grader is assigned.
      let log := respond run (settle run (opening run)) (responseWith #[submitCall "s" "done"])
      check ((next run log) matches .waits #[]) "the run waits for a grader"
      check ((agentEnd? log) matches some (.returned _)) "the agent returned"
      -- A grader: what follows the agent takes it, and calls it in the frame after the agent's.
      let assigned := log.size
      let log := settle run (log.push (assignment (grader "one")))
      check (log.any fun | .heard #[] notices => notices == #[assigned] | _ => false) "the run's own frame takes the grader"
      let .ask first := next run log | fail "the grader's program is asked for"
      assertEqual "its frame follows the agent's" first.frame #[1]
      -- Its verdict is the result of the run, which ends with it.
      let graded := answer run log (.external ran)
      check (graded.back? matches some (.returned #[] _)) "the run's own frame returns"
      match next run graded with
      | .done verdict => assertEqual "the verdict" (verdictStatus verdict) "pass"
      | _ => fail "the run is over, with its verdict"
      -- A grader whose program could not be run fails its call, and the run with it.
      let broken := settle run (log.push (.answered first.frame first.op.key (.error "the image cannot start")))
      check (broken.any fun | .failed #[1] "the image cannot start" => true | _ => false) "the grader's call failed"
      match next run broken with
      | .raised error => assertEqual "the run's error" error "the image cannot start"
      | _ => fail "the run ends with the failure"
      -- Stopped before its agent is opened, a run comes to its grader all the same.
      let stopped := settle run ((rootOnly.push (.stopped "grade")).push (assignment (grader "one")))
      check ((next run stopped) matches .ask { frame := #[1], op := .external .., .. }) "the grader runs on the root's workspace"
      check ((agentEnd? stopped) matches some (.stopped "grade")) "the agent was stopped",

  test "a run's configuration is read off the opening of its agent, or the log is refused" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let unreadable (label : String) (log : Log Agent) : TestM Unit :=
        assertError label (configOf log) fun | .storage _ => true | _ => false
      unreadable "no opening" rootOnly
      unreadable "a notice in its place" (rootOnly.push (.arrived (.said "t")))
      unreadable "another tool" (rootOnly.push (.opened #[0] ⟨"bash", run.call.arguments⟩))
      unreadable "another frame" (rootOnly.push (.opened #[1] run.call))
      unreadable "no configuration" (rootOnly.push (.opened #[0] ⟨agentTool, .mkObj [("agent", .null)]⟩))
      let config ← assertOk <| configOf (rootOnly.push (.opened #[0] run.call))
      assertEqual "the configuration" config.toJson.compress run.call.arguments.compress,

  iotest "frames render as paths, and a reference to an entry may name a position" do
    if Frame.render #[0, 2, 1] != "0.2.1" || Frame.render #[] != "-" then
      throw <| IO.userError "frames render as dotted paths"
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
