import Test.Support.Framework
import Test.Support.Scripted
import Test.Support.Container
import Alaya

/-! Tests of the basic agent: how a command's output is cut to its end and noted, as pi does it;
that every tool call is answered, a call with a problem by the problem; that a response with no
call is answered with a reminder; and that only `submit` and a provider's refusal end it. -/

namespace BasicTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Alaya.Agents
open Lean (Json)

private def config : Basic.Config := {}

private def run : Except String (Scope Agent) := runOfConfig "basic" config.toJson

/-- What a run of the basic agent did with `responses`: its log, and the requests it sent. -/
private def driven (responses : Array Chat.Response) (executor : Executor := echoingCommands) :
    TestM (Log Agent × Array Chat.Request) := do
  let .ok run := run | fail "basic is a run"
  let (rt, last, _) ← drive run executor (← scriptedModel responses)
  let log ← logAt rt last
  pure (log, (samplesOf run log).map (·.1))

/-- What the model was told in answer to the call `id`, in `request`. -/
private def answerTo (request : Chat.Request) (id : String) : Option String :=
  request.messages.findSome? fun
    | .tool callId (.str text) => if callId == id then some text else none
    | _ => none

private def numbered (n : Nat) : String :=
  String.join ((List.range n).map fun i => s!"{i + 1}\n")

def suite : Suite := Testing.suite "agents/basic" #[
  test "an output within the limits is shown whole; past them, its last lines and a note" do
    check (Basic.tail (numbered 2000)).isNone "2000 lines fit"
    let some t := Basic.tail (numbered 3000) | fail "3000 lines do not"
    assertEqual "the last 2000 lines" (t.shown, t.total, t.byBytes) (2000, 3000, false)
    check (t.text.startsWith "1001\n" && t.text.endsWith "\n3000") s!"from 1001 to 3000: {t.text.take 20}"
    assertStringEq "the note" (Basic.observation { output := numbered 3000, exitCode? := some 0 } (some "/alaya/outputs/a.txt")
      |>.splitOn "\n\n" |>.getLast!) "[Showing lines 1001-3000 of 3000. Full output: /alaya/outputs/a.txt]"
    -- 100 lines of 1000 bytes: the byte limit holds before the line limit.
    let wide := String.join (List.replicate 100 (String.ofList (List.replicate 999 'w') ++ "\n"))
    let some t := Basic.tail wide | fail "100 KB does not fit"
    check (t.byBytes && t.text.utf8ByteSize ≤ Basic.maxBytes && t.shown == 51) s!"by bytes: {t.shown} lines"
    assertContains "the note says so" (Basic.observation { output := wide, exitCode? := some 0 } none)
      "[Showing lines 50-100 of 100 (50KB limit).]",

  test "a last line too long to show whole is shown as its end, in whole characters" do
    let line := String.ofList (List.replicate 40000 'é')
    let some t := Basic.tail line | fail "80 KB in one line does not fit"
    check (t.partialLine && t.text.utf8ByteSize ≤ Basic.maxBytes && t.text.all (· == 'é'))
      s!"its end: {t.text.utf8ByteSize} bytes"
    assertContains "the note" (Basic.observation { output := line, exitCode? := some 0 } (some "/f"))
      "[Showing the end of line 1, which is too long to show whole. Full output: /f]",

  test "how a command ended is said after its output when it did not end well" do
    let shown (output : String) (exitCode? : Option UInt32) (error? : Option String := none) :=
      Basic.observation { output, exitCode?, error? } none
    assertStringEq "well" (shown "hi\n" (some 0)) "hi\n"
    assertStringEq "nothing printed" (shown "" (some 0)) "(no output)"
    assertStringEq "an exit code" (shown "boom\n" (some 2)) "boom\n\n\nCommand exited with code 2"
    assertStringEq "an exit code alone" (shown "" (some 1)) "Command exited with code 1"
    assertStringEq "a timeout" (shown "partial\n" none (some "'sleep 9' timed out after 5 seconds"))
      "partial\n\n\n'sleep 9' timed out after 5 seconds",

  test "a call with a problem is answered with it, and not made" do
    let tools := Basic.tools config.executor
    let problem (response : Chat.Response) : List (Option String) :=
      response.toolCalls.toList.map (Basic.problem? tools response)
    assertEqual "fine" (problem (responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"])) [none, none]
    check ((problem (responseWith #[call "a" "python" "ls"])).head!.any (contains · "Unknown tool 'python'")) "unknown"
    check ((problem (responseWith #[{ (Scripted.call "a" "bash" "ls") with invalidArguments? := some "{\"command\":" }])).head!.any
      (contains · "Error parsing tool call arguments")) "not JSON"
    check ((problem (responseWith #[{ id := "a", name := "bash", arguments := .mkObj [] }])).head!.any
      (contains · "Missing 'command'")) "no command"
    let mixed := problem (responseWith #[call "a" "bash" "ls", submitCall "s"])
    check (mixed.all (·.any (contains · "submit must be called alone"))) s!"submit beside another: {mixed}"
    let cut := problem (responseWith #[call "a" "bash" "ls"] (finish := "length"))
    check (cut.all (·.any (contains · "hit the output token limit"))) "a response cut off",

  test "a run goes on past every problem, and ends where the model submits" do
    let prose : Chat.Response := { content? := some "Let me look.", finishReason? := some "stop" }
    let (log, requests) ← driven #[prose, responseWith #[call "a" "python" "ls", call "b" "bash" "echo hi"],
      responseWith #[call "c" "bash" "ls", submitCall "s"], responseWith #[submitCall "s" "done"]]
    assertEqual "submitted" (agentResult log |>.bind (·.toOption) |>.map (·.compress))
      (some (Agents.Basic.outcome "Submitted" "done").compress)
    assertEqual "four requests" requests.size 4
    check (requests[0]!.messages.any fun
        | .system text => contains text s!"The commands run on {testUname.system} {testUname.machine}." | _ => false)
      "the opening names the machine, as uname reads it"
    check (requests[1]!.messages.any fun | .user text => text == Basic.reminder prose | _ => false) "the reminder"
    check (requests[1]!.messages.any fun | .assistant (some "Let me look.") .. => true | _ => false) "what it said is kept"
    assertEqual "the unknown tool" ((answerTo requests[2]! "a").map (contains · "Unknown tool")) (some true)
    assertEqual "the call beside it is made" (answerTo requests[2]! "b") (some "hi\n")
    assertEqual "nothing of a mixed response is made" ((answerTo requests[3]! "c").map (contains · "alone")) (some true),

  test "only basic's own fields configure it" do
    let complete ← assertOk <| Catalog.complete "basic" (.mkObj [])
    assertEqual "its fields" (match complete with | .obj kvs => kvs.toList.map (·.1) | _ => [])
      ["executor", "model", "task"]
    for field in ["max_consecutive_format_errors", "question_types", "mode"] do
      assertError s!"no {field}" (Catalog.complete "basic" (.mkObj [(field, 1)])) fun
        | .input m => contains m s!"unknown field '{field}'"
        | _ => false
    check (Basic.tools config.executor |>.any fun tool => tool.name == "bash" &&
      ((tool.call (.mkObj [("command", "ls")])).arguments.getObjVal? "executor" |>.toOption
        |>.any fun executor => (executor.getObjVal? "outputs").toOption == some (.bool true)))
      "every command keeps its output as a file"
]

/-- A run whose commands run in the test container. -/
def containerSuite : Suite := Testing.suite "agents/basic.container" #[
  test "a command reads the whole of a cut output in the file its note names" do
    let .ok run := run | fail "basic is a run"
    let rt ← containerRuntime (some (← scriptedModel #[
      responseWith #[call "c1" "bash" "seq 1 3000"],
      responseWith #[call "c2" "bash" "head -n 2 $(ls /alaya/outputs/*.txt | head -n 1)"],
      responseWith #[submitCall "s"]]))
    let (last, _) ← assertOk <| Driver.drive rt run (← start rt run)
    let requests := (samplesOf run (← logAt rt last)).map (·.1)
    assertContains "the note" ((answerTo requests[1]! "c1").getD "") "[Showing lines 1001-3000 of 3000. Full output: /alaya/outputs/"
    assertEqual "the start, read back" (answerTo requests[2]! "c2") (some "1\n2\n")
]

end BasicTests
