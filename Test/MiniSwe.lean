import Test.Framework
import Test.DirectoryWorkspaces
import Test.MiniSweFixtures
import Test.Scripted
import Test.Container
import Alaya

/-! Tests of the mini-SWE-agent port. The prompt fixtures (`Test/MiniSweFixtures.lean`) are
rendered by mini's own jinja templates, so the prompts are checked against upstream to the byte,
except where the port names its `submit` tool in place of mini's output sentinel, and requires a
tool call where mini requires a bash call. End-to-end cases
drive the real agent through the driver, over a snapshotted workspace, with a scripted model. -/

namespace MiniSweTests

open Testing
open Scripted
open Alaya
open Alaya.Agents.MiniSwe
open Alaya.Agents.Tools.Bash (observation)
open Lean (Json)

/-- Mini's instruction for ending a run, as it appears twice in its instance prompt with two
different continuation indents; the port names the `submit` tool there instead. -/
private def miniSubmitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n" ++
  indent ++ "Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>"

/-- A fixture rendered by mini's templates, with the port's three changes: the sentences that
name the submission sentinel name the `submit` tool, the one that requires a bash call requires
a tool call, and the machine line gives the system and the architecture, without the kernel's
release and version. Everything else must match to the byte. -/
private def portOf (miniText : String) : String :=
  let step1 := miniText.replace (miniSubmitInstruction "   ") (submitInstruction "   ")
  let step2 := step1.replace (miniSubmitInstruction "  ") (submitInstruction "  ")
  let step3 := step2.replace "MUST include AT LEAST ONE bash tool call" "MUST include AT LEAST ONE tool call"
  step3.replace "Darwin 23.5.0 Darwin Kernel Version 23.5.0 arm64" "Darwin arm64"

/-! ## Golden template fidelity -/

def goldenSuite : Suite := suite "mini-swe.golden" #[
  iotest "system message" do
    if systemMessage != "You are a helpful assistant that can interact with a computer." then
      throw <| IO.userError "system message drift",

  test "instance message (Darwin) is mini's, with the submit tool and a tool call in place of bash's" do
    assertStringEq "instance"
      (instanceMessage "Fix the bug in foo.py" "Darwin" "arm64")
      (portOf MiniSweFixtures.instanceDarwin)
    -- The replacement is real: the fixture and the prompt differ exactly there.
    check (contains MiniSweFixtures.instanceDarwin "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the fixture names the sentinel"
    check (!contains (instanceMessage "t" "Linux" "m") "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the prompt does not"
    check (contains MiniSweFixtures.instanceDarwin "AT LEAST ONE bash tool call") "the fixture requires bash"
    check (!contains (instanceMessage "t" "Linux" "m") "AT LEAST ONE bash tool call") "the prompt requires a tool call"
    -- The machine line: the fixture has the whole uname, the prompt the system and architecture.
    check (contains MiniSweFixtures.instanceDarwin "Darwin 23.5.0 Darwin Kernel Version 23.5.0 arm64")
      "the fixture names the kernel"
    check (!contains (instanceMessage "t" "Darwin" "arm64") "Kernel") "the prompt does not",


  iotest "an observation is the recorded output as JSON, cut when long" do
    let field (json : Lean.Json) (key : String) : Option Lean.Json := (json.getObjVal? key).toOption
    let short := observation { output := "hello\n", exitCode? := some 0 } outputLimit
    if field short "output" != some "hello\n" || field short "exit_code" != some 0 then
      throw <| IO.userError s!"short observation: {short.compress}"
    if (field short "error").isSome then throw <| IO.userError "no error field when nothing went wrong"
    let failed := observation { output := "partial", error? := some "'sleep 30' timed out after 1 seconds" } outputLimit
    if field failed "exit_code" != some .null || (field failed "error").isNone then
      throw <| IO.userError s!"failed observation: {failed.compress}"
    -- Unicode passes through as text, not as escapes.
    if field (observation { output := "café ✓ 😀", exitCode? := some 0 } outputLimit) "output" != some "café ✓ 😀" then
      throw <| IO.userError "unicode should be kept as is"
    -- At the limit the output is replaced by its head and tail and a count of the elision.
    let long := observation { output := String.ofList (List.replicate 12000 'z'), exitCode? := some 0 } outputLimit
    if (field long "output").isSome then throw <| IO.userError "long output must be cut"
    if field long "elided_chars" != some 2000 then throw <| IO.userError s!"elided: {long.compress}"
    match field long "output_head", field long "output_tail" with
    | some (.str h), some (.str t) =>
      if h.length != 5000 || t.length != 5000 then throw <| IO.userError "head and tail are 5000 each"
    | _, _ => throw <| IO.userError "expected output_head and output_tail"
    -- Just under the limit is shown whole.
    let under := observation { output := String.ofList (List.replicate 9999 'z'), exitCode? := some 0 } outputLimit
    if (field under "output").isNone then throw <| IO.userError "9999 characters are shown whole",

  iotest "a format error explains the problem, or the cut-off when the provider reports one" do
    let plain := formatErrorMessage "Unknown tool 'python'." true (some "stop")
    if !(contains plain "Unknown tool 'python'." && contains plain endHint) then
      throw <| IO.userError s!"format error text: {plain}"
    let cut := formatErrorMessage "irrelevant" false (some "length")
    if !(contains cut "output token limit (finish_reason=length)") then
      throw <| IO.userError "a length cut-off should be reported as such"
    let cut2 := formatErrorMessage "irrelevant" false (some "tool_calls")
    if !(contains cut2 "finish_reason=tool_calls") then
      throw <| IO.userError "tool_calls with no call is a cut-off"
    let notCut := formatErrorMessage "Unknown tool 'x'." true (some "tool_calls")
    if contains notCut "output token limit" then
      throw <| IO.userError "a response with calls was not cut off"
]

/-! ## Parsing and the tool schema -/

/-- The calls a response makes, by id and name, when it parses. -/
private def callsOf (response : Chat.Response) (config : Config := {}) : Option (Array (String × String)) :=
  match parseActions response config with
  | .calls calls => some (calls.map fun call => (call.id, call.name))
  | .formatError _ => none

/-- The opening task message of a conversation. -/
private def openingText (config : Config) : String :=
  match (openingMessages config "t" testUname)[1]? with
  | some (Chat.Message.user text) => text
  | _ => ""

/-- A history of one turn: a `bash` call whose command printed `output`, kept whole in `file?`. -/
private def oneTurn (output : String) (file? : Option String) : History :=
  { items := #[.turn (responseWith #[call "call_7" "bash" "make"])
      #[(call "call_7" "bash" "make", Agents.Tools.Bash.result
        { output := { output, exitCode? := some 0 }, workspace := default, file? })]] }

def parseSuite : Suite := suite "mini-swe.parse" #[
  test "recovery changes only a long output's warning" do
    let off : Config := {}
    let on : Config := { recoverOutput := true }
    assertEqual "tools off" ((tools off).map (·.name)) #["bash", "submit"]
    assertEqual "tools on" ((tools on).map (·.name)) #["bash", "submit"]
    assertStringEq "opening off" (openingText off)
      (instanceMessage "t" testUname.system testUname.machine)
    assertStringEq "opening on is unchanged" (openingText on) (openingText off)
    assertStringEq "repair on is unchanged" (formatErrorMessage "e" true (some "stop") on)
      (formatErrorMessage "e" true (some "stop"))
    -- On, a long output's warning names the file holding it; off, it is mini's.
    let long := oneTurn (String.ofList (List.replicate 20000 'x')) (some "/alaya/outputs/7.txt")
    let warning (config : Config) : String :=
      match (view config long).back? with
      | some (Chat.Message.tool _ (.str shown)) =>
        match Json.parse shown with
        | .ok json => (json.getObjVal? "warning" >>= Json.getStr?).toOption.getD ""
        | .error _ => ""
      | _ => ""
    assertStringEq "warning off" (warning off) "Output too long."
    assertStringEq "warning on" (warning on) "[output truncated; full output: /alaya/outputs/7.txt]"
    -- A command run without its outputs kept has no file to name, even with recovery on.
    let unkept := oneTurn (String.ofList (List.replicate 20000 'x')) none
    match (view on unkept).back? with
    | some (Chat.Message.tool _ (.str shown)) => check (contains shown "Output too long.") "mini's warning"
    | _ => fail "expected the observation"
    -- The tool is gone: unknown, as any other unlisted tool is.
    match parseActions (responseWith #[call "r" "read_output" "x"]) on with
    | .formatError message => check (contains message "Unknown tool 'read_output'") "unknown"
    | .calls _ => fail "read_output should be unknown",

  test "masking omits the outputs of old turns, naming their files" do
    let config : Config := { masking? := some { keepTurns := 1, block := 1 } }
    let turn (id : String) : Item :=
      .turn (responseWith #[call id "bash" "cat big"])
        #[(call id "bash" "cat big", Agents.Tools.Bash.result
          { output := { output := String.ofList (List.replicate 500 'y'), exitCode? := some 0 }
            workspace := default, file? := some s!"/alaya/outputs/{id}.txt" })]
    let history : History := { items := #[.told (.system "s"), turn "a", turn "b", turn "c"] }
    let shown := (view config history).filterMap fun
      | Chat.Message.tool id (.str text) => some (id, text)
      | _ => none
    assertEqual "three results" shown.size 3
    check (contains shown[0]!.2 "[output omitted; full output: /alaya/outputs/a.txt]") "the oldest is omitted"
    check (contains shown[1]!.2 "[output omitted") "so is the next"
    check (contains shown[2]!.2 "yyyy") "the last turn is whole",

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
    -- The pieces are cut where jinja substitutes, so the placeholders are exactly at the cuts.
    check (!contains rules "{{") "the rules piece should hold no placeholder"
    check (contains formatErrorTemplate "{{error}}") "the format-error piece keeps its placeholder",

  iotest "bash tool schema is mini's, in strict mode" do
    -- mini's BASH_TOOL plus the `additionalProperties: false` every strict object carries
    -- (Json.compress emits keys in sorted order).
    let expected := "{\"function\":{\"description\":\"Execute a bash command\",\"name\":\"bash\",\"parameters\":{\"additionalProperties\":false,\"properties\":{\"command\":{\"description\":\"The bash command to execute\",\"type\":\"string\"}},\"required\":[\"command\"],\"type\":\"object\"}},\"type\":\"function\"}"
    if Agents.Tools.Bash.definition.toJson.compress != expected then
      throw <| IO.userError s!"tool schema drift:\n{Agents.Tools.Bash.definition.toJson.compress}",

  test "no tool calls is a format error" do
    match parseActions { content? := some "just prose", finishReason? := some "stop" } with
    | .formatError msg => check (contains msg "No tool calls found") "expected no-toolcall error"
    | .calls _ => fail "expected a format error",

  test "unknown tool and missing command" do
    match parseActions (responseWith #[call "c1" "python" "x"]) with
    | .formatError msg => check (contains msg "Unknown tool 'python'.") "unknown tool text"
    | .calls _ => fail "expected format error for unknown tool"
    match parseActions (responseWith #[{ id := "c1", name := "bash", arguments := .mkObj [] }]) with
    | .formatError msg => check (contains msg "Missing 'command'") "missing command text"
    | .calls _ => fail "expected format error for missing command",

  test "valid single and multiple calls parse in order, a submit among them" do
    assertEqual "calls" (callsOf (responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"]))
      (some #[("a", "bash"), ("b", "bash")])
    assertEqual "with submit" (callsOf (responseWith #[call "a" "bash" "ls", submitCall "s" "all done"]))
      (some #[("a", "bash"), ("s", "submit")])
    assertEqual "a bare submit" (callsOf (responseWith #[{ id := "s", name := "submit", arguments := .mkObj [] }]))
      (some #[("s", "submit")])
    assertEqual "its message" (Agents.Tools.Submit.message (submitCall "s" "all done").arguments) "all done",

  test "invalid arguments JSON is a recoverable format error" do
    let bad : Chat.ToolCall := { id := "c1", name := "bash", arguments := .null,
                                 invalidArguments? := some "{\"command\": \"ls" }
    match parseActions (responseWith #[bad]) with
    | .formatError msg => check (contains msg "Error parsing tool call arguments: ") "parse error text"
    | .calls _ => fail "expected a format error"
    -- when the provider reports a length cut-off, the truncation notice renders instead
    match parseActions { toolCalls := #[bad], finishReason? := some "length" } with
    | .formatError msg =>
      check (contains msg "output token limit (finish_reason=length)") "truncation notice"
    | .calls _ => fail "expected a format error",

  test "a non-string command is a format error" do
    let numeric : Chat.ToolCall :=
      { id := "c1", name := "bash", arguments := .mkObj [("command", (42 : Json))] }
    match parseActions (responseWith #[numeric]) with
    | .formatError msg => check (contains msg "must be a string") "the message says what is wrong"
    | .calls _ => fail "expected a format error",

  test "an added tool is offered, only appends to the prompt, and checks its calls" do
    let plain : Config := {}
    let config : Config := { tools := #["bash", "submit", "ask_user"], questionTypes := Question.Kind.all }
    assertEqual "offered" ((tools config).map (·.name)) #["bash", "submit", "ask_user"]
    assertStringEq "appended" (openingText config)
      (openingText plain ++ "\n\n" ++ Agents.Tools.AskUser.instruction Question.Kind.all)
    match parseActions (responseWith #[askCall "q" "Keep it?"]) plain with
    | .formatError message => check (contains message "Unknown tool 'ask_user'") "unknown where not offered"
    | .calls _ => fail "a tool not offered is unknown"
    match parseActions (responseWith #[askCall "q" "Which?" "single_choice" #["only"]]) config with
    | .formatError message => check (contains message "at least two candidates") "its own refusal"
    | .calls _ => fail "a bad call is a format error"
    match parseActions (responseWith #[askCall "q" "Keep it?", call "c" "bash" "ls"]) config with
    | .formatError message => check (contains message "ask_user must be called alone") "alone"
    | .calls _ => fail "ask_user is called alone"
]

/-! ## End-to-end runs of the agent in a container -/

/-- Runs the mini agent with a scripted model through the driver, in a container. Returns what
its model saw last and said, the workspace the log reached, and how the agent ended. -/
private def runAgent (config : Config) (responses : Array Chat.Response) :
    TestM (Array Chat.Message × Hash × Json) := do
  match miniRun config with
  | .error problem => fail problem
  | .ok run =>
    let rt ← containerRuntime (some (← scriptedModel responses))
    let (last, _) ← assertOk <| Driver.drive rt run (← start rt run)
    let log ← logAt rt last
    let some (.ok outcome) := agentResult log | fail s!"the agent did not return: {agentStatus log}"
    pure (lastDialogue config run log, (workspace? log).getD default, outcome)

private def status (outcome : Json) : String := (outcome.getObjVal? "status" >>= Json.getStr?).toOption.getD ""

def runSuite : Suite := suite "mini-swe.run" #[
  test "subagent calls the agent itself on the model's task, in its own scope, in a frame of its own" do
    let config : Config := { tools := #["bash", "submit", "subagent"] }
    let delegated : Chat.ToolCall := { id := "d", name := "subagent", arguments := .mkObj [("task", "write b.txt")] }
    let .ok run := miniRun config | fail "mini-swe with subagent is a run"
    let rt ← containerRuntime (some (← scriptedModel #[
      responseWith #[delegated],
      responseWith #[call "c1" "bash" "echo b > b.txt"],
      responseWith #[submitCall "s1" "wrote it"],
      responseWith #[submitCall "s2" "delegated"]]))
    let (last, _) ← assertOk <| Driver.drive rt run (← start rt run)
    let log ← logAt rt last
    assertEqual "the agent's outcome" ((agentResult log).bind (·.toOption) |>.map (status ·)) (some "Submitted")
    assertEqual "the calls: each agent's uname, MiniSwe itself in the agent's frame, its bash in the sub-agent's"
      (log.filterMap fun | .opened frame opened => some (frame, opened.name) | _ => none)
      #[(⟪"agent"⟫, "agent"), (⟪"agent", "mini-swe"⟫, "mini-swe"), (⟪"agent", "mini-swe", "bash"⟫, "bash")]
    -- The sub-agent's call is the agent's own, with the model's task: its configuration, its model.
    check (log.any fun
        | .opened ⟪"agent", "mini-swe"⟫ { name := "mini-swe", arguments := delegated, environment? := none } =>
          taskOf delegated == some "write b.txt" &&
            (delegated.getObjVal? "tools").toOption == some (Lean.toJson config.tools)
        | _ => false)
      "the sub-agent's call is the agent's configuration, with the model's task, and no environment"
    -- The sub-agent's conversation is its own: its task, not the agent's, is what its model is told.
    let requests := samplesOf run log
    assertEqual "four samples" requests.size 4
    check (requests[1]!.1.messages.any fun | .user text => contains text "write b.txt" | _ => false)
      "the sub-agent was told the model's task"
    check (requests[3]!.1.messages.any fun
        | .tool "d" content => contains content.compress "wrote it" | _ => false)
      "the agent was shown how the sub-agent ended"
    assertEqual "the sub-agent's edit" (← IO.FS.readFile ((← scratch) / "work" / "b.txt")) "b\n",

  test "a two-step run edits the workspace and submits" do
    let (dialogue, env, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "echo hello > a.txt"],
      responseWith #[submitCall "c2" "my patch\n"]]
    assertEqual "outcome" outcome.compress (Agents.MiniSwe.outcome "Submitted" "my patch\n").compress
    -- Dialogue: system, instance, assistant#1, tool-obs#1, assistant#2 (no obs for the submit).
    assertEqual "dialogue length" dialogue.size 5
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" content) =>
      assertStringEq "observation content"
        (match content with | .str s => s | j => j.compress)
        (observation { output := "", exitCode? := some 0 } outputLimit).pretty
    | _ => fail "expected a tool observation at index 3"
    -- The live workspace and the snapshot both reflect the edit.
    assertEqual "workspace file" (← IO.FS.readFile ((← scratch) / "work" / "a.txt")) "hello\n"
    assertEqual "snapshot file"
      ((← assertOk <| (← workspaces).readFile? env "a.txt").map (String.fromUTF8? ·))
      (some (some "hello\n")),

  test "multiple tool calls in one turn run in order and both observe" do
    let (dialogue, _, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "mkdir sub", call "c2" "bash" "echo x > sub/f.txt"],
      responseWith #[submitCall "c3"]]
    assertEqual "submitted" (status outcome) "Submitted"
    -- system, instance, assistant#1, obs c1, obs c2, assistant#2
    assertEqual "dialogue length" dialogue.size 6
    assertEqual "nested file written" (← IO.FS.readFile ((← scratch) / "work" / "sub" / "f.txt")) "x\n",

  test "a submit ends the turn: calls after it in the same response never run" do
    let (_, env, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "echo a > a.txt", submitCall "s" "done",
                     call "c2" "bash" "echo b > b.txt"]]
    assertEqual "submitted" (status outcome) "Submitted"
    check (← assertOk ((← workspaces).readFile? env "a.txt")).isSome "the call before submit ran"
    check (← assertOk ((← workspaces).readFile? env "b.txt")).isNone "the call after submit did not",

  test "a format error is appended and the offending turn is dropped" do
    let (dialogue, _, outcome) ← runAgent {} #[
      { content? := some "I forgot to call a tool", finishReason? := some "stop" },
      responseWith #[submitCall "c1"]]
    assertEqual "submitted after recovery" (status outcome) "Submitted"
    -- system, instance, user(format error), assistant(submit). The bad assistant turn is not kept.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) => check (contains msg "Tool call error:") "format error text present"
    | _ => fail "expected a user format-error message at index 2",

  test "repeated format errors exit" do
    let bad : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    let (dialogue, _, outcome) ← runAgent { maxConsecutiveFormatErrors := 3 }
      #[bad, bad, bad, bad]
    assertEqual "exit status" (status outcome) "RepeatedFormatError"
    -- system, instance, then three user error messages.
    assertEqual "dialogue length" dialogue.size 5,

  test "a command timeout is reported as an exception observation" do
    let (dialogue, _, _) ← runAgent { executor := { defaultExecutor with timeoutSeconds := 1 } } #[
      responseWith #[call "c1" "bash" "sleep 30"],
      responseWith #[submitCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" content) =>
      let s := match content with | .str s => s | j => j.compress
      check (contains s "timed out after 1 seconds") "the timeout is reported as the error"
      check (contains s "\"exit_code\": null") "a timed-out command has no exit code"
    | _ => fail "expected a timeout observation",

  test "truncated tool arguments recover as a format error, like mini" do
    let bad : Chat.Response := {
      toolCalls := #[{ id := "c1", name := "bash", arguments := .null,
                       invalidArguments? := some "{\"command\": \"ls" }],
      finishReason? := some "length" }
    let (dialogue, _, outcome) ← runAgent {} #[bad, responseWith #[submitCall "c2"]]
    assertEqual "submitted after recovery" (status outcome) "Submitted"
    -- system, instance, user(truncation notice), assistant(submit); the bad turn is dropped.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) =>
      check (contains msg "output token limit (finish_reason=length)") "truncation message"
    | _ => fail "expected a format-error user turn at index 2",

  test "the view keeps the record whole and shows the model a truncation" do
    let long := String.ofList (List.replicate 12000 'x')
    let (dialogue, _, _) ← runAgent {} #[
      responseWith #[call "c1" "bash" s!"printf '%s' {long}"],
      responseWith #[submitCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" (.str shown)) =>
      match Json.parse shown with
      | .ok json => assertEqual "elided" (json.getObjVal? "elided_chars" >>= Json.getNat?).toOption (some 2000)
      | .error e => fail s!"the observation should be JSON: {e}"
      check (shown.length < 11000) "the model is shown about 10000 characters"
    | _ => fail "expected the truncated observation",

  test "with recovery on, a command finds the whole output of an earlier one" do
    let long := String.ofList (List.replicate 12000 'q')
    let (dialogue, _, _) ← runAgent { recoverOutput := true } #[
      responseWith #[call "c1" "bash" s!"printf '%s' {long}"],
      responseWith #[call "c2" "bash" "wc -c < $(ls /alaya/outputs/*.txt | head -n 1)"],
      responseWith #[submitCall "c3"]]
    match dialogue[5]? with
    | some (Chat.Message.tool "c2" (.str shown)) => check (contains shown "12000") s!"the file holds it all: {shown}"
    | _ => fail "expected the second observation"
]

/-! ## Command execution fidelity -/

/-- Runs `command` with mini's default settings in a container over `work`. -/
private def runIn (work : System.FilePath) (command : String) : TestM Output := do
  let executor ← containerExecutor
  try executor.bash defaultExecutor work command finally executor.close

/-- What the test image's own `/bin/sh -c command` prints on stdout and stderr, and its status. -/
private def imageShell (command : String) : TestM (String × UInt32) := do
  let out ← IO.Process.output { cmd := "docker", args := #["run", "--rm", "--network", "none",
    "--label", testLabel, "--entrypoint", "/bin/sh", ← testImage, "-c", command] }
  pure (out.stdout ++ out.stderr, out.exitCode)

def execSuite : Suite := suite "mini-swe.exec" #[
  iotest "invalid UTF-8 bytes are replaced and valid text survives" do
    let cases : Array (List UInt8 × String) := #[
      ([0xff], "�"),
      ([0xe2, 0x82, 0xac, 0x58], "€X"),
      ([0x61, 0xc2], "a�"),
      ([0xe2, 0x82], "��"),
      ([0xf0, 0x9f, 0x98, 0x80], "😀")]
    for (bytes, expected) in cases do
      let actual := Executor.lossyDecodeUtf8 ⟨bytes.toArray⟩
      if actual != expected then
        throw <| IO.userError s!"lossy decode {bytes}: got {repr actual}, want {repr expected}",

  test "stderr is merged into stdout at the fd level" do
    let out ← runIn (← workDir) "echo hi >&2"
    assertEqual "merged output" out.output "hi\n"
    assertEqual "exit code" out.exitCode? (some 0),

  test "shell diagnostics are the shell's own, with stderr merged" do
    -- The inner shell sees the script as `$1`, so its messages are what the image's
    -- `/bin/sh -c` prints; for commands whose output is all on one stream, concatenating the
    -- streams is exact.
    let work ← workDir
    for command in ["fi", "echo \"unterminated", "nosuchcmd_alaya_test"] do
      let out ← runIn work command
      let (output, code) ← imageShell command
      assertEqual s!"output of {repr command}" out.output output
      assertEqual s!"exit code of {repr command}" out.exitCode? (some code),

  test "non-UTF-8 command output is replaced, not dropped" do
    let out ← runIn (← workDir) "printf 'a\\377b'"
    assertEqual "replaced output" out.output "a�b"
    assertEqual "exit code" out.exitCode? (some 0),

  test "a command docker could not run tells the agent nothing of the machine" do
    let said := "Error response from daemon: container 3f9a1c is not running (/data/tmp/41-7/work)"
    let out := Executor.failed said
    assertEqual "no exit code" out.exitCode? none
    assertEqual "what the agent is told" out.error? (some Executor.couldNotRun)
    assertEqual "the detail, for a reader of the log" out.detail? (some said)
    -- What a model is shown of it holds nothing docker said.
    let shown := (observation out outputLimit).compress
    for leaked in ["3f9a1c", "/data/tmp", "daemon"] do
      check (!contains shown leaked) s!"the observation holds {leaked}: {shown}"
    check (contains shown Executor.couldNotRun) "and says the command could not be run",

  test "a container that cannot be started is the machine's failure, not a command's result" do
    -- A work directory that is not there: docker has nothing to mount.
    let missing := (← scratch) / "missing"
    let executor ← containerExecutor
    let ran ← (try some <$> executor.bash defaultExecutor missing "echo hi" catch _ => pure none : IO (Option Output))
    executor.close
    check ran.isNone s!"the command was given a result: {repr ran}"
    -- A user the image does not have, as a mistyped `--container-user` names.
    let settings := { (← testSettings) with user? := some "no-such-user-of-alaya" }
    let executor ← assertOk (Executor.Docker.executor settings)
    let work ← workDir
    let ran ← (try some <$> executor.bash defaultExecutor work "echo hi" catch _ => pure none : IO (Option Output))
    executor.close
    check ran.isNone s!"a command run as no user was given a result: {repr ran}",

  test "a command reads nothing from whoever runs alaya" do
    -- Its standard input is closed: a command that reads it gets the end at once.
    let out ← runIn (← workDir) "cat; echo read to the end"
    assertEqual "it went on past the read" out.output "read to the end\n"
    assertEqual "exit code" out.exitCode? (some 0)
]
def suites : Array Suite := #[goldenSuite, parseSuite, runSuite, execSuite]

end MiniSweTests
