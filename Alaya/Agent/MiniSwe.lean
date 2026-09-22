import Alaya.Agent
import Alaya.Executor
import Alaya.Agent.Tools
import Alaya.Agent.Config

/-! A port of mini-SWE-agent's default tool-calling agent as an `Alaya.Agent.Agent`. See
`docs/miniswe.md`. -/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error Output Executor Uname)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive)

/-! ## Configuration -/

/-- How mini runs a command: a 30-second limit, and its environment overrides. -/
def defaultExecutor : Executor.Config := {
  timeoutSeconds := 30
  env := #[("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
           ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")] }

structure Config where
  /-- Maximum model calls; 0 disables the limit (as in mini.yaml). -/
  stepLimit : Nat := 0
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  /-- Offer `read_output`, which shows any lines of a long output the view cut to its head and
  tail. Off, the agent is mini to the byte: its tools, its prompts, its observations. On, the
  tool is offered and the two sentences that require a bash call in every response say "a
  tool call" instead (`withRecovery`). -/
  recoverOutput : Bool := false
  /-- Offer a choice question with an always-available custom answer. -/
  askUser : Bool := false
  deriving Inhabited

/-- The configuration as JSON: the shape of `agents/mini-swe-default.json`, and what a root
records. -/
def Config.toJson (config : Config) : Lean.Json :=
  let fields : List (String × Lean.Json) := [
    ("family", "mini-swe"),
    ("step_limit", (config.stepLimit : Lean.Json)),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("executor", .mkObj [
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json)),
      ("env", .arr (config.executor.env.map fun (name, value) => .arr #[.str name, .str value]))]),
    ("recover_output", (config.recoverOutput : Lean.Json))]
  -- Keep the canonical identity of existing question-disabled roots unchanged.
  .mkObj <| fields ++ (if config.askUser then [("ask_user", Lean.Json.bool true)] else [])

/-- Reads a configuration; a field left out is `defaults`', and an unknown one is an error. -/
def Config.fromJson (json : Lean.Json) (defaults : Config := {}) : Except String Config := do
  let object ← ConfigJson.object json
    #["family", "step_limit", "max_consecutive_format_errors", "executor", "recover_output", "ask_user"]
  let executor ← match ← object.field? "executor" with
    | none => pure defaults.executor
    | some json => do
      let object ← ConfigJson.object json #["timeout_seconds", "env"]
      let env ← match ← object.field? "env" with
        | none => pure defaults.executor.env
        | some json => ConfigJson.pairs json
      pure { timeoutSeconds := ← object.nat "timeout_seconds" defaults.executor.timeoutSeconds, env }
  pure {
    stepLimit := ← object.nat "step_limit" defaults.stepLimit
    maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors
    executor
    recoverOutput := ← object.bool "recover_output" defaults.recoverOutput
    askUser := ← object.bool "ask_user" defaults.askUser }

/-! ## Prompts

The files in `MiniSwe/` are mini's templates from `mini.yaml` (vendored beside them, from
SWE-agent/mini-swe-agent `04d809c`), cut where jinja substitutes or branches, byte for byte;
`Test/Mini.lean` checks each against the vendored copy. Assembly does what jinja does: puts
the task and the `uname` in, keeps the MacOS note when `system == "Darwin"` with the
whitespace its `{%-`/`-%}` tags strip, and drops one trailing newline from a rendering. The
one change of text is the port's: the sentences that name mini's submission sentinel say the
`submit` tool (`sentinelToSubmit`). -/

def systemTemplate : String := include_str "MiniSwe/system.md"
def opening : String := include_str "MiniSwe/instance-opening.md"
def rules : String := include_str "MiniSwe/instance-rules.md"
def examples : String := include_str "MiniSwe/instance-examples.md"
def darwinNote : String := include_str "MiniSwe/instance-darwin.md"
def sedExamples : String := include_str "MiniSwe/instance-sed.md"
def formatErrorCut : String := include_str "MiniSwe/format-error-cut.md"
def formatErrorTemplate : String := include_str "MiniSwe/format-error.md"

/-- The pieces by file name, for the check against `mini.yaml`. -/
def pieces : Array (String × String) := #[
  ("system.md", systemTemplate), ("instance-opening.md", opening),
  ("instance-rules.md", rules), ("instance-examples.md", examples),
  ("instance-darwin.md", darwinNote), ("instance-sed.md", sedExamples),
  ("format-error-cut.md", formatErrorCut), ("format-error.md", formatErrorTemplate)]

/-- What jinja does to a rendering: one trailing newline goes. -/
private def rendered (text : String) : String :=
  if text.endsWith "\n" then (text.dropEnd 1).toString else text

/-- Mini's instruction for ending a run, as it appears twice in the instance prompt with two
different continuation indents, and the port's. -/
def sentinelInstruction (indent : String) : String :=
  "Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n" ++
  indent ++ "Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>"

def submitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by calling the `submit` tool.\n" ++
  indent ++ "Do not combine it with any other tool call. <important>After this call, you cannot continue working on this task.</important>"

/-- The last line of mini's format-error message, and the port's. -/
def sentinelHint : String :=
  "If you want to end the task, please issue the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`\nwithout any other command."

def endHint : String :=
  "If you want to end the task, call the `submit` tool\nwithout any other tool call."

/-- The port's one change to mini's texts. -/
def sentinelToSubmit (text : String) : String :=
  let text := text.replace (sentinelInstruction "   ") (submitInstruction "   ")
  let text := text.replace (sentinelInstruction "  ") (submitInstruction "  ")
  text.replace sentinelHint endHint

def systemMessage : String := rendered systemTemplate

/-- The rendered instance (task) message. `system`/`release`/`version`/`machine` are the
`uname` fields; the MacOS `sed` note is included exactly when `system == "Darwin"`. -/
def instanceMessage (task system release version machine : String) : String :=
  let note := if system == "Darwin" then darwinNote.trimAscii.toString else ""
  rendered <| sentinelToSubmit <|
    opening ++ task ++ rules ++ system ++ " " ++ release ++ " " ++ version ++ " " ++ machine ++
    examples.trimAsciiEnd.toString ++ note ++ sedExamples.trimAsciiStart.toString

/-- The one thing recovery changes in mini's texts: a response must hold a tool call, not a
bash call, since it may be a `read_output` alone. -/
def withRecovery (recover : Bool) (text : String) : String :=
  if !recover then text else
    let text := text.replace "Your response MUST include AT LEAST ONE bash tool call"
      "Your response MUST include AT LEAST ONE tool call: bash, or read_output to see more of an earlier command's output"
    text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
      "Every response needs at least one tool call: 'bash' to execute commands, or 'read_output' to see more of an earlier command's output."

/-- Allow a question turn in the opening and format-error prompts when the tool is offered. -/
def withAsk (enabled : Bool) (text : String) : String :=
  if !enabled then text else
    let text := text.replace "Your response MUST include AT LEAST ONE bash tool call"
      "Your response MUST include AT LEAST ONE tool call"
    let text := text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
      "Every response needs at least one tool call."
    let text := text.replace "Your response MUST include AT LEAST ONE tool call: bash, or read_output to see more of an earlier command's output"
      "Your response MUST include AT LEAST ONE tool call"
    let text := text.replace "Every response needs at least one tool call: 'bash' to execute commands, or 'read_output' to see more of an earlier command's output."
      "Every response needs at least one tool call."
    let text := text.replace "exactly one bash tool call" "exactly one tool call"
    text ++ "\n\n" ++ Tools.AskUser.instruction

/-- The opening log of a run: the system prompt and the task. -/
def initialLog (config : Config) (task : String) (uname : Uname) : Log :=
  #[.message (.system systemMessage),
    .message (.user (withAsk config.askUser (withRecovery config.recoverOutput
      (instanceMessage task uname.system uname.release uname.version uname.machine))))]

/-- The user turn a malformed response is answered with: mini's `format_error_template`. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String)
    (recover : Bool := false) (askUser : Bool := false) : String :=
  withAsk askUser <|
  withRecovery recover <|
  let truncated := match finishReason? with
    | some "length" => true
    | some "tool_calls" => !hasToolCalls
    | _ => false
  if truncated then formatErrorCut.replace "{{ finish_reason }}" (finishReason?.getD "")
  else sentinelToSubmit (formatErrorTemplate.replace "{{error}}" error)

/-! ## Tools -/

/-- How much of a command's output the model is shown; longer outputs show their head and tail. -/
def outputLimit : Nat := 10000

/-- The tools offered on every sample. -/
def tools (config : Config) : Array Chat.ToolDefinition :=
  #[Tools.Bash.definition, Tools.Submit.definition] ++
    (if config.recoverOutput then #[Tools.ReadOutput.definition] else #[]) ++
    (if config.askUser then #[Tools.AskUser.definition] else #[])

/-! ## Reading a response -/

/-- One parsed tool call: a command to run, a read answered from the log, or the call that
ends the run. -/
inductive Action where
  | bash (id : String) (command : String)
  | readOutput (id : String) (arguments : Lean.Json)
  | ask (id : String) (question : String)
  | submit (id : String) (message : String)
  deriving Inhabited

def Action.id : Action -> String
  | .bash id _ => id
  | .readOutput id _ => id
  | .ask id _ => id
  | .submit id _ => id

/-- A parsed model turn: its actions, or a format-error message to send back as a user turn. -/
inductive Parsed where
  | actions (actions : Array Action)
  | formatError (message : String)

/-- Reads a response's tool calls; the first call with a problem makes the turn a format error.
`read_output` is a known tool only when it is offered. -/
def parseActions (response : Chat.Response) (recover : Bool := false)
    (askUser : Bool := false) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason? recover askUser
  if askUser && response.toolCalls.any (·.name == "ask_user") && response.toolCalls.size != 1 then
    return .formatError <| formatErrorMessage "ask_user must be called alone."
      true response.finishReason? recover askUser
  let mut actions : Array Action := #[]
  for call in response.toolCalls do
    let action : Except String Action :=
      if let some raw := call.invalidArguments? then
        .error ("Error parsing tool call arguments: " ++
          (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
      else match call.name with
        | "submit" => .ok (.submit call.id (Tools.Submit.message call.arguments))
        | "bash" => (Tools.Bash.command call.arguments).map (.bash call.id ·)
        | "read_output" =>
          if !recover then .error "Unknown tool 'read_output'."
          else (Tools.ReadOutput.parse call.arguments).map fun _ => .readOutput call.id call.arguments
        | "ask_user" =>
          if !askUser then .error "Unknown tool 'ask_user'."
          else (Tools.AskUser.question call.arguments).map (.ask call.id ·)
        | other => .error s!"Unknown tool '{other}'."
    match action with
    | .error problem =>
      return .formatError (formatErrorMessage problem true response.finishReason? recover askUser)
    | .ok action => actions := actions.push action
  return .actions actions

/-! ## The agent: view, control, action -/

/-- The view: a malformed response is shown as the format error, as a user turn; an observation
as `Tools.Bash.observation` of the recorded `Output`. A page of `read_output` is not an
`Output` and is shown as recorded. -/
def view (config : Config) (log : Log) : Dialogue :=
  log.map fun
    | .message m => m
    | .response r =>
      match parseActions r config.recoverOutput config.askUser with
      | .actions _ => .assistant r.content? r.toolCalls r.reasoning?
      | .formatError message => .user message
    | .observation id content =>
      let json := match Output.fromJson? content with
        | some output => Tools.Bash.observation output outputLimit
            (if config.recoverOutput then some id else none)
        | none => content
      .tool id (.str json.pretty)

/-- How many format-error responses end the log with no clean turn between them. A person's
message in between does not reset the count; an observation does, since it means a turn ran. -/
private def trailingFormatErrors (config : Config) (log : Log) : Nat := Id.run do
  let mut count := 0
  for event in log.reverse do
    match event with
    | .response r =>
      match parseActions r config.recoverOutput config.askUser with
      | .formatError _ => count := count + 1
      | .actions _ => return count
    | .observation _ _ => return count
    | .message _ => pure ()
  return count

/-- Mini's control flow (`DefaultAgent.run`), decided from the log. -/
def next (config : Config) (log : Log) : Directive :=
  let sampleOrStop : Directive :=
    if config.stepLimit > 0 && log.responses >= config.stepLimit
    then .done { status := "LimitsExceeded" } else .sample
  match log.lastResponse? with
  | none => sampleOrStop
  | some response =>
    match parseActions response config.recoverOutput config.askUser with
    | .formatError _ =>
      if config.maxConsecutiveFormatErrors > 0 &&
          trailingFormatErrors config log >= config.maxConsecutiveFormatErrors
      then .done { status := "RepeatedFormatError" }
      else sampleOrStop
    | .actions actions =>
      let pending := log.pending
      match actions.find? (fun action => pending.any (·.id == action.id)) with
      | none => sampleOrStop
      | some (.submit _ message) => .done { status := "Submitted", submission := message }
      | some (.readOutput id arguments) =>
        .observe id (Tools.ReadOutput.read log arguments outputLimit)
      | some (.ask id question) => .ask id question
      | some (.bash id _) =>
        match pending.find? (·.id == id) with
        | some call => .act call
        | none => sampleOrStop

/-- Runs one `bash` call in the workspace through the executor and records the `Output`. -/
def act (executor : Executor) (workspace : Agent.Workspace) (call : Chat.ToolCall) :
    Result Lean.Json := do
  match call.name, Tools.Bash.command call.arguments with
  | "bash", .ok command => Tools.Bash.act executor workspace command
  | _, _ => throw <| .configuration s!"not a runnable bash call: {call.name}"

/-- The mini agent over an executor. -/
def agent (executor : Executor) (config : Config) : Agent := {
  identity := config.toJson
  tools := tools config
  view := view config
  next := next config
  act := act executor
}

end Alaya.Agent.MiniSwe
