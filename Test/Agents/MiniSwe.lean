import Test.Support.Framework
import Test.Support.DirectoryWorkspaces
import Test.Agents.MiniSweFixtures
import Test.Support.Scripted
import Test.Support.Container
import Alaya

/-! Tests of the mini-SWE-agent port. The prompt fixtures (`Test/Agents/MiniSweFixtures.lean`)
are rendered by mini's own jinja templates, so the prompts are checked against upstream to the
byte, but for the machine line. The observations, the format errors and the sentinel that ends a
run are mini's. End-to-end cases drive the agent through the driver, with a scripted model. -/

namespace MiniSweTests

open Testing
open Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Alaya.Agents.MiniSwe
open Lean (Json)

/-- A fixture rendered by mini's templates, with the port's one change: the machine line gives
the system and the architecture, without the kernel's release and version. -/
private def portOf (miniText : String) : String :=
  miniText.replace "Darwin 23.5.0 Darwin Kernel Version 23.5.0 arm64" "Darwin arm64"

/-- The calls a response makes, by id and name, when it parses. -/
private def callsOf (response : Chat.Response) : Option (Array (String × String)) :=
  match formatError? {} response with
  | none => some (response.toolCalls.map fun call => (call.id, call.name))
  | some _ => none

private def formatErrorOf (response : Chat.Response) : String :=
  (formatError? {} response).getD ""

/-! ## Mini's texts -/

def goldenSuite : Suite := suite "agents/mini-swe.golden" #[
  test "the system message and the instance message are mini's, but for the machine line" do
    assertStringEq "system" systemMessage "You are a helpful assistant that can interact with a computer."
    assertStringEq "instance" (instanceMessage "Fix the bug in foo.py" "Darwin" "arm64")
      (portOf MiniSweFixtures.instanceDarwin)
    check (contains (instanceMessage "t" "Linux" "m") "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT") "it ends with mini's sentinel"
    check (contains (instanceMessage "t" "Linux" "m") "AT LEAST ONE bash tool call") "it asks for a bash call"
    check (!contains (instanceMessage "t" "Darwin" "arm64") "Kernel") "the machine line has no kernel"
    assertEqual "the opening is the two messages, and nothing added"
      ((openingMessages "t" testUname).map (·.toStored.compress))
      #[(Chat.Message.system systemMessage).toStored.compress,
        (Chat.Message.user (instanceMessage "t" testUname.system testUname.machine)).toStored.compress],

  test "an observation is mini's observation_template" do
    assertStringEq "a short output" (observation { output := "hello\n", exitCode? := some 0 })
      "{\n  \"returncode\": 0,\n  \"output\": \"hello\\n\"\n}"
    assertStringEq "a command that did not end on its own"
      (observation { output := "partial", error? := some "'sleep 30' timed out after 1 seconds" })
      "{\n  \"returncode\": -1,\n  \"output\": \"partial\", \"exception_info\": \"'sleep 30' timed out after 1 seconds\"\n}"
    let long := observation { output := String.ofList (List.replicate 6000 'a' ++ List.replicate 6000 'z'), exitCode? := some 1 }
    let some json := (Json.parse long).toOption | fail "a long observation is JSON"
    assertEqual "its fields, in mini's order" (match json with | .obj fields => fields.toArray.map (·.1) | _ => #[])
      #["elided_chars", "output_head", "output_tail", "returncode", "warning"]
    check (long.startsWith "{\n  \"returncode\": 1,\n  \"output_head\": ") "returncode first, then the head"
    assertEqual "head, tail and what was left out"
      ((json.getObjVal? "output_head" >>= Json.getStr?).toOption.map (·.length),
       (json.getObjVal? "output_tail" >>= Json.getStr?).toOption.map (·.length),
       (json.getObjVal? "elided_chars" >>= Json.getNat?).toOption,
       (json.getObjVal? "warning" >>= Json.getStr?).toOption)
      (some 5000, some 5000, some 2000, some "Output too long.")
    check (contains (observation { output := String.ofList (List.replicate 9999 'z'), exitCode? := some 0 }) "\"output\":")
      "9999 characters are shown whole",

  test "a format error is mini's, naming the sentinel, or the cut-off when the provider reports one" do
    let plain := formatErrorMessage "Unknown tool 'python'." true (some "stop")
    assertContains "the problem" plain "<error>\nUnknown tool 'python'.\n</error>"
    assertContains "a bash call" plain "Every response needs to use the 'bash' tool at least once to execute commands."
    assertContains "the sentinel" plain "please issue the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`"
    assertContains "a length cut-off" (formatErrorMessage "x" false (some "length")) "output token limit (finish_reason=length)"
    assertContains "a cut-off before any call" (formatErrorMessage "x" false (some "tool_calls")) "finish_reason=tool_calls"
    check (!contains (formatErrorMessage "x" true (some "tool_calls")) "output token limit") "a response with calls was not cut off",

  test "every prompt piece is in mini.yaml, byte for byte, and is the file on disk" do
    -- The templates are block scalars indented four spaces; dedented, each piece is a substring.
    let yaml ← IO.FS.readFile ("Alaya" / "Agents" / "MiniSwe" / "mini.yaml")
    let dedented := "\n".intercalate ((yaml.splitOn "\n").map fun line =>
      if line.startsWith "    " then (line.drop 4).toString else line)
    for (file, piece) in pieces do
      check (!piece.isEmpty) s!"{file} is empty"
      check (contains dedented piece) s!"{file} is not a piece of mini.yaml"
      -- Lake does not rebuild a module when a file it takes with `include_str` changes.
      let onDisk ← IO.FS.readFile ("Alaya" / "Agents" / "MiniSwe" / file)
      check (onDisk == piece) s!"{file} changed after Alaya.Agents.MiniSwe was built: touch the module and rebuild"
    check (!contains rules "{{") "the rules piece should hold no placeholder"
    check (contains formatErrorTemplate "{{error}}") "the format-error piece keeps its placeholder"
]

/-! ## Reading a response -/

def parseSuite : Suite := suite "agents/mini-swe.parse" #[
  test "its one tool is mini's bash, in strict mode" do
    assertEqual "offered" ((tools {}).map (·.name)) #["bash"]
    -- mini's BASH_TOOL plus the `additionalProperties: false` every strict object carries.
    assertStringEq "schema" Agents.Tools.Bash.definition.toJson.compress
      "{\"function\":{\"description\":\"Execute a bash command\",\"name\":\"bash\",\"parameters\":{\"additionalProperties\":false,\"properties\":{\"command\":{\"description\":\"The bash command to execute\",\"type\":\"string\"}},\"required\":[\"command\"],\"type\":\"object\"}},\"type\":\"function\"}",

  test "a response without a well-formed bash call is a format error, the first problem named" do
    assertContains "no call" (formatErrorOf { content? := some "just prose", finishReason? := some "stop" }) "No tool calls found"
    assertContains "a tool mini does not have" (formatErrorOf (responseWith #[submitCall "s" "done"])) "Unknown tool 'submit'."
    assertContains "no command" (formatErrorOf (responseWith #[{ id := "c", name := "bash", arguments := .mkObj [] }]))
      "Missing 'command'"
    assertContains "a command that is no string"
      (formatErrorOf (responseWith #[{ id := "c", name := "bash", arguments := .mkObj [("command", (42 : Json))] }])) "must be a string"
    let bad : Chat.ToolCall := { id := "c", name := "bash", arguments := .null, invalidArguments? := some "{\"command\": \"ls" }
    assertContains "arguments that are no JSON" (formatErrorOf (responseWith #[bad])) "Error parsing tool call arguments: "
    assertContains "cut off by the provider" (formatErrorOf { toolCalls := #[bad], finishReason? := some "length" })
      "output token limit (finish_reason=length)"
    assertEqual "calls, in order" (callsOf (responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"]))
      (some #[("a", "bash"), ("b", "bash")]),

  test "a command that prints the sentinel first ends the run, and what follows it is the submission" do
    let result (output : String) : Json :=
      Agents.Tools.Bash.result { output := { output, exitCode? := some 0 }, workspace := default }
    let submitted := submitted? sentinel
    assertEqual "the sentinel alone" (submitted (result "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT\n")) (some "")
    assertEqual "with what follows" (submitted (result "\n  COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT  \nmy patch\n")) (some "my patch\n")
    assertEqual "not first" (submitted (result "done\nCOMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT\n")) none
    assertEqual "not alone on its line" (submitted (result "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT now\n")) none,

  test "a person's message is told to the model as an intervention, and nothing else is" do
    let told (notice : Notice) : String :=
      ((Agents.Basic.noticeMessage notice).map (·.toStored.compress)).getD "nothing"
    assertStringEq "a message" (told (.said "keep the old API"))
      (Chat.Message.user "<intervention>\nA person sent you a message while you were paused.\nkeep the old API\n</intervention>").toStored.compress
    assertStringEq "a change is no one's to read" (told (.changed default "M a.txt")) "nothing"
    assertStringEq "a reply is the asking call's" (told (.replied ⟪"session", "agent", "ask_user"⟫ .yes)) "nothing"
    assertStringEq "nor a call" (told (.called { name := "grader", arguments := .null })) "nothing"
]

/-! ## Runs -/

/-- Runs the mini agent with a scripted model through the driver, in a container, or, for a run
whose commands do not matter, with an executor that only echoes. Returns what its model saw last
and said, the workspace the log reached, and how the agent ended. -/
private def runAgent (config : Config) (responses : Array Chat.Response) (inContainer := true) :
    TestM (Array Chat.Message × Hash × Json) := do
  match miniRun config with
  | .error problem => fail problem
  | .ok run =>
    let model ← scriptedModel responses
    let rt ← if inContainer then containerRuntime (some model) else runtime echoingCommands (some model)
    let (last, _) ← assertOk <| Driver.drive rt run (← start rt run)
    let log ← logAt rt last
    let some (.ok outcome) := agentResult log | fail s!"the agent did not return: {agentStatus log}"
    pure (lastDialogue (formatError? config) run log, (workspace? log).getD default, outcome)

private def status (outcome : Json) : String := (outcome.getObjVal? "status" >>= Json.getStr?).toOption.getD ""

/-- Runs whose commands do not matter: what the model is told when it answers badly. -/
def dialogueSuite : Suite := suite "agents/mini-swe.dialogue" #[
  test "a format error is appended and the offending turn is dropped" do
    let (dialogue, _, outcome) ← runAgent (inContainer := false) {} #[
      { content? := some "I forgot to call a tool", finishReason? := some "stop" },
      responseWith #[sentinelCall "c1"]]
    assertEqual "submitted after recovery" (status outcome) "Submitted"
    -- system, instance, user(format error), assistant(sentinel). The bad assistant turn is not kept.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) => assertContains "format error text" msg "Tool call error:"
    | _ => fail "expected a user format-error message at index 2",

  test "repeated format errors exit" do
    let bad : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    let (dialogue, _, outcome) ← runAgent (inContainer := false) { maxConsecutiveFormatErrors := 3 } #[bad, bad, bad, bad]
    assertEqual "exit status" (status outcome) "RepeatedFormatError"
    assertEqual "system, instance, then three format errors" dialogue.size 5,

  test "the sentinel ends the run where it is printed: calls after it in the same turn never run" do
    let (_, _, outcome) ← runAgent (inContainer := false) {} #[
      responseWith #[call "a" "bash" "echo first", sentinelCall "s", call "b" "bash" "echo never"]]
    assertEqual "submitted, with nothing after the sentinel" outcome.compress
      (Agents.Basic.outcome "Submitted" "").compress
]

/-- Runs whose commands do matter, in the test container. -/
def runSuite : Suite := suite "agents/mini-swe.container" #[
  test "a run edits the workspace and submits what the sentinel's command printed after it" do
    let (dialogue, env, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "echo hello > a.txt"],
      responseWith #[call "c2" "bash" "printf 'COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT\\nmy patch\\n'"]]
    assertEqual "outcome" outcome.compress (Agents.Basic.outcome "Submitted" "my patch\n").compress
    -- system, instance, assistant#1, observation#1, assistant#2: the sentinel's command is not observed.
    assertEqual "dialogue length" dialogue.size 5
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" (.str shown)) =>
      assertStringEq "mini's observation" shown (observation { output := "", exitCode? := some 0 })
    | _ => fail "expected a tool observation at index 3"
    assertEqual "workspace file" (← IO.FS.readFile ((← scratch) / "work" / "a.txt")) "hello\n"
    assertEqual "snapshot file" ((← assertOk <| (← workspaces).readFile? env "a.txt").map (String.fromUTF8? ·))
      (some (some "hello\n")),

  test "multiple tool calls in one turn run in order and both observe" do
    let (dialogue, _, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "mkdir sub", call "c2" "bash" "echo x > sub/f.txt"],
      responseWith #[sentinelCall "c3"]]
    assertEqual "submitted" (status outcome) "Submitted"
    assertEqual "system, instance, assistant, two observations, assistant" dialogue.size 6
    assertEqual "nested file written" (← IO.FS.readFile ((← scratch) / "work" / "sub" / "f.txt")) "x\n",

  test "a command timeout is an observation with mini's exception_info" do
    let (dialogue, _, _) ← runAgent { executor := { defaultExecutor with timeoutSeconds := 1 } } #[
      responseWith #[call "c1" "bash" "sleep 30"], responseWith #[sentinelCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" (.str shown)) =>
      assertContains "no return code" shown "\"returncode\": -1"
      assertContains "what went wrong" shown "\"exception_info\": "
      assertContains "the timeout" shown "timed out after 1 seconds"
    | _ => fail "expected a timeout observation",

  test "a long output is shown as its head and tail, and the log keeps all of it" do
    let long := String.ofList (List.replicate 12000 'x')
    let (dialogue, _, _) ← runAgent {} #[
      responseWith #[call "c1" "bash" s!"printf '%s' {long}"], responseWith #[sentinelCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" (.str shown)) =>
      assertEqual "elided" ((Json.parse shown).toOption.bind fun json => (json.getObjVal? "elided_chars" >>= Json.getNat?).toOption) (some 2000)
      check (shown.length < 11000) "the model is shown about 10000 characters"
    | _ => fail "expected the truncated observation"
]

def suites : Array Suite := #[goldenSuite, parseSuite, dialogueSuite, runSuite]

end MiniSweTests
