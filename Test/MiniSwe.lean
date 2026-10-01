import Test.Framework
import Test.DirectoryWorkspaces
import Test.MiniSweFixtures
import Test.Scripted
import Test.Container
import Alaya

/-! Tests of the mini-SWE-agent port. The prompt fixtures (`Test/MiniSweFixtures.lean`) are
rendered by mini's own jinja templates, so the prompts are checked against upstream to the byte,
except where the port names its `submit` tool in place of mini's output sentinel. End-to-end cases
drive the real agent over a snapshotted workspace with a scripted model. The trajectory tree it
drives is tested in `Test/Trajectory.lean`. -/

namespace MiniSweTests

open Testing
open Scripted
open Alaya
open Alaya.Agent (Dialogue Outcome Event Log)
open Alaya.Agent.MiniSwe
open Alaya.Agent.Tools.Bash (observation)
open Alaya.Trajectory

/-- Mini's instruction for ending a run, as it appears twice in its instance prompt with two
different continuation indents; the port names the `submit` tool there instead. -/
private def miniSubmitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n" ++
  indent ++ "Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>"

/-- A fixture rendered by mini's templates, with the sentences that name the submission sentinel
replaced by the port's, which name the `submit` tool. Everything else must match to the byte. -/
private def portOf (miniText : String) : String :=
  let step1 := miniText.replace (miniSubmitInstruction "   ") (submitInstruction "   ")
  step1.replace (miniSubmitInstruction "  ") (submitInstruction "  ")

/-! ## Golden template fidelity -/

def goldenSuite : Suite := suite "mini-swe.golden" #[
  iotest "system message" do
    if systemMessage != "You are a helpful assistant that can interact with a computer." then
      throw <| IO.userError "system message drift",

  test "instance message (Darwin) is mini's, with the submit tool in place of the sentinel" do
    assertStringEq "instance"
      (instanceMessage "Fix the bug in foo.py" "Darwin" "23.5.0" "Darwin Kernel Version 23.5.0" "arm64")
      (portOf MiniSweFixtures.instanceDarwin)
    -- The replacement is real: the fixture and the prompt differ exactly there.
    check (contains MiniSweFixtures.instanceDarwin "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the fixture names the sentinel"
    check (!contains (instanceMessage "t" "Linux" "r" "v" "m") "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the prompt does not",


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


private def actionSummary : Action -> String × String
  | .bash id command => (id, command)
  | .readOutput id _ => (id, "read_output")
  | .ask id question => (id, "ask_user:" ++ question.render)
  | .timeBudget id => (id, "time_budget")
  | .submit id message => (id, "submit:" ++ message)

def parseSuite : Suite := suite "mini-swe.parse" #[
  test "with recovery off the agent is mini to the byte; on, two sentences and a tool differ" do
    let off : Config := {}
    let on : Config := { recoverOutput := true }
    assertEqual "tools off" ((tools off).map (·.name)) #["bash", "submit"]
    assertEqual "tools on" ((tools on).map (·.name)) #["bash", "submit", "read_output"]
    let opening (config : Config) : String :=
      match (initialLog config "t" testUname)[1]? with
      | some (Event.message (Chat.Message.user text)) => text
      | _ => ""
    assertStringEq "opening off" (opening off)
      (instanceMessage "t" testUname.system testUname.release testUname.version testUname.machine)
    let delta := (opening on).replace
      "Your response MUST include AT LEAST ONE tool call: bash, or read_output to see more of an earlier command's output"
      "Your response MUST include AT LEAST ONE bash tool call"
    assertStringEq "opening on differs in one sentence" delta (opening off)
    check (contains (formatErrorMessage "e" true (some "stop") { recoverOutput := true }) "'read_output'") "the repair text names it"
    assertStringEq "repair off is unchanged" (formatErrorMessage "e" true (some "stop") {})
      (formatErrorMessage "e" true (some "stop"))
    -- On, a long output's warning names the call to read it back by; off, it is mini's.
    let long := Output.toJson { output := String.ofList (List.replicate 20000 'x'), exitCode? := some 0 }
    let warning (config : Config) : String :=
      match (view config #[.observation "call_7" long]).back? with
      | some (Chat.Message.tool _ (.str shown)) =>
        match Lean.Json.parse shown with
        | .ok json => (json.getObjVal? "warning" >>= Lean.Json.getStr?).toOption.getD ""
        | .error _ => ""
      | _ => ""
    assertStringEq "warning off" (warning off) "Output too long."
    check (contains (warning on) "this call's id is call_7") s!"the warning should name the call: {warning on}"
    -- Off, the tool is unknown, as any other unlisted tool is.
    match parseActions (responseWith #[call "r" "read_output" "x"]) with
    | .formatError message => check (contains message "Unknown tool 'read_output'") "unknown when off"
    | .actions _ => fail "read_output should be unknown when recovery is off",

  test "every prompt piece is in mini.yaml, byte for byte, and is the file on disk" do
    -- The templates are block scalars indented four spaces; dedented, each piece is a substring.
    let yaml ← IO.FS.readFile ("Alaya" / "Agent" / "MiniSwe" / "mini.yaml")
    let dedented := "\n".intercalate ((yaml.splitOn "\n").map fun line =>
      if line.startsWith "    " then (line.drop 4).toString else line)
    for (file, piece) in pieces do
      check (!piece.isEmpty) s!"{file} is empty"
      check (contains dedented piece) s!"{file} is not a piece of mini.yaml"
      -- Lake does not rebuild a module when a file it takes with `include_str` changes.
      let onDisk ← IO.FS.readFile ("Alaya" / "Agent" / "MiniSwe" / file)
      check (onDisk == piece) s!"{file} changed after Alaya.Agent.MiniSwe was built: touch the module and rebuild"
    -- The pieces are cut where jinja substitutes, so the placeholders are exactly at the cuts.
    check (!contains rules "{{") "the rules piece should hold no placeholder"
    check (contains formatErrorTemplate "{{error}}") "the format-error piece keeps its placeholder",

  iotest "bash tool schema is mini's, in strict mode" do
    -- mini's BASH_TOOL plus the `additionalProperties: false` every strict object carries
    -- (Json.compress emits keys in sorted order).
    let expected := "{\"function\":{\"description\":\"Execute a bash command\",\"name\":\"bash\",\"parameters\":{\"additionalProperties\":false,\"properties\":{\"command\":{\"description\":\"The bash command to execute\",\"type\":\"string\"}},\"required\":[\"command\"],\"type\":\"object\"}},\"type\":\"function\"}"
    if Alaya.Agent.Tools.Bash.definition.toJson.compress != expected then
      throw <| IO.userError s!"tool schema drift:\n{Alaya.Agent.Tools.Bash.definition.toJson.compress}",

  test "no tool calls is a format error" do
    match parseActions { content? := some "just prose", finishReason? := some "stop" } with
    | .formatError msg => check (contains msg "No tool calls found") "expected no-toolcall error"
    | .actions _ => fail "expected a format error",

  test "unknown tool and missing command" do
    match parseActions (responseWith #[call "c1" "python" "x"]) with
    | .formatError msg => check (contains msg "Unknown tool 'python'.") "unknown tool text"
    | .actions _ => fail "expected format error for unknown tool"
    match parseActions (responseWith #[{ id := "c1", name := "bash", arguments := .mkObj [] }]) with
    | .formatError msg => check (contains msg "Missing 'command'") "missing command text"
    | .actions _ => fail "expected format error for missing command",

  test "valid single and multiple calls parse in order" do
    match parseActions (responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"]) with
    | .actions cs => assertEqual "actions" (cs.map actionSummary) #[("a", "ls"), ("b", "pwd")]
    | .formatError _ => fail "expected actions",

  test "a submit call parses as a submit action carrying its message" do
    match parseActions (responseWith #[call "a" "bash" "ls", submitCall "s" "all done"]) with
    | .actions cs =>
      assertEqual "actions" (cs.map actionSummary) #[("a", "ls"), ("s", "submit:all done")]
    | .formatError _ => fail "expected actions"
    match parseActions (responseWith #[{ id := "s", name := "submit", arguments := .mkObj [] }]) with
    | .actions cs => assertEqual "bare submit" (cs.map actionSummary) #[("s", "submit:")]
    | .formatError _ => fail "a submit without a message is still a submit",

  test "invalid arguments JSON is a recoverable format error" do
    let bad : Chat.ToolCall := { id := "c1", name := "bash", arguments := .null,
                                 invalidArguments? := some "{\"command\": \"ls" }
    match parseActions (responseWith #[bad]) with
    | .formatError msg => check (contains msg "Error parsing tool call arguments: ") "parse error text"
    | .actions _ => fail "expected a format error"
    -- when the provider reports a length cut-off, the truncation notice renders instead
    match parseActions { toolCalls := #[bad], finishReason? := some "length" } with
    | .formatError msg =>
      check (contains msg "output token limit (finish_reason=length)") "truncation notice"
    | .actions _ => fail "expected a format error",

  test "a non-string command is a format error" do
    let numeric : Chat.ToolCall :=
      { id := "c1", name := "bash", arguments := .mkObj [("command", (42 : Lean.Json))] }
    match parseActions (responseWith #[numeric]) with
    | .formatError msg => check (contains msg "must be a string") "the message says what is wrong"
    | .actions _ => fail "expected a format error"
]

/-! ## End-to-end runs of the agent in a container -/


/-- Runs the mini agent with a scripted model through the trajectory's loop, in a container.
Returns the view of the final log, the final workspace, and the outcome. -/
private def runAgent (config : Config) (responses : Array Chat.Response) :
    TestM (Dialogue × Hash × Outcome) := do
  let model ← scriptedModel responses
  let executor ← containerExecutor config.executor
  let (rt, state, halt) ← try drive (agent config) executor model (initialLog config "t" testUname)
    finally executor.close
  let log ← assertOk <| Trajectory.logOf rt.store state
  let env := (← assertOk <| Trajectory.getState rt.store state).workspace
  match halt with
  | .outcome outcome => pure (view config log, env, outcome)
  | .question q => fail s!"unexpected question: {q.text}"
  | _ => fail "the run neither ended nor asked"

def runSuite : Suite := suite "mini-swe.run" #[
  test "a two-step run edits the workspace and submits" do
    let (dialogue, env, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "echo hello > a.txt"],
      responseWith #[submitCall "c2" "my patch\n"]]
    assertEqual "outcome" outcome { status := "Submitted", submission := "my patch\n" }
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
    assertEqual "submitted" outcome.status "Submitted"
    -- system, instance, assistant#1, obs c1, obs c2, assistant#2
    assertEqual "dialogue length" dialogue.size 6
    assertEqual "nested file written" (← IO.FS.readFile ((← scratch) / "work" / "sub" / "f.txt")) "x\n",

  test "a submit ends the turn: calls after it in the same response never run" do
    let (_, env, outcome) ← runAgent {} #[
      responseWith #[call "c1" "bash" "echo a > a.txt", submitCall "s" "done",
                     call "c2" "bash" "echo b > b.txt"]]
    assertEqual "submitted" outcome.status "Submitted"
    check (← assertOk ((← workspaces).readFile? env "a.txt")).isSome "the call before submit ran"
    check (← assertOk ((← workspaces).readFile? env "b.txt")).isNone "the call after submit did not",

  test "a format error is appended and the offending turn is dropped" do
    let (dialogue, _, outcome) ← runAgent {} #[
      { content? := some "I forgot to call a tool", finishReason? := some "stop" },
      responseWith #[submitCall "c1"]]
    assertEqual "submitted after recovery" outcome.status "Submitted"
    -- system, instance, user(format error), assistant(submit). The bad assistant turn is not kept.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) => check (contains msg "Tool call error:") "format error text present"
    | _ => fail "expected a user format-error message at index 2",

  test "repeated format errors exit" do
    let bad : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    let (dialogue, _, outcome) ← runAgent { maxConsecutiveFormatErrors := 3 }
      #[bad, bad, bad, bad]
    assertEqual "exit status" outcome.status "RepeatedFormatError"
    -- system, instance, then three user error messages.
    assertEqual "dialogue length" dialogue.size 5,

  test "the step limit stops the run" do
    let loopCmd := responseWith #[call "c" "bash" "echo working"]
    let (_, _, outcome) ← runAgent { stepLimit := 2 }
      #[loopCmd, loopCmd, loopCmd, loopCmd]
    assertEqual "exit status" outcome.status "LimitsExceeded",

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
    assertEqual "submitted after recovery" outcome.status "Submitted"
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
      match Lean.Json.parse shown with
      | .ok json => assertEqual "elided" (json.getObjVal? "elided_chars" >>= Lean.Json.getNat?).toOption (some 2000)
      | .error e => fail s!"the observation should be JSON: {e}"
      check (shown.length < 11000) "the model is shown about 10000 characters"
    | _ => fail "expected the truncated observation"
]

/-! ## Command execution fidelity -/

/-- Runs `command` with mini's default settings in a container over `work`. -/
private def runIn (work : System.FilePath) (command : String) : TestM Output := do
  let executor ← containerExecutor defaultExecutor
  try executor.bash work command finally executor.close

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

  test "a command that cannot run is an error observation, not an aborted run" do
    let missing := (← scratch) / "missing"
    let out ← runIn missing "echo hi"
    assertEqual "no exit code" out.exitCode? none
    check (((out.error?.getD "").splitOn missing.toString).length > 1) "the error names the directory"
]
def suites : Array Suite := #[goldenSuite, parseSuite, runSuite, execSuite]

end MiniSweTests
