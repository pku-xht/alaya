import Alaya.Agents.Tools
import Alaya.LLM.Models
import Alaya.Base.ConfigJson

/-! A port of mini-SWE-agent's default tool-calling agent: mini's prompts, its one `bash` tool,
its sentinel that ends a run, its observations, and its loop, whose context keeps every turn.
The pieces of the loop that do not depend on mini's terms are public, for an agent built on it.
See `docs/agents.md` §4. -/

namespace Alaya.Agents.MiniSwe

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-! ## Configuration -/

/-- How mini runs a command: a 30-second limit, and its environment overrides. -/
def defaultExecutor : Executor.Config := {
  timeoutSeconds := 30
  env := #[("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
           ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")] }

structure Config where
  /-- The model it samples: its complete spec. There is no default: whoever calls the agent
  names one. -/
  model? : Option Models.Spec := none
  /-- The task, verbatim. There is no default: whoever calls the agent gives one. -/
  task? : Option String := none
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  deriving Inhabited

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Json :=
  .mkObj [
    ("model", config.model?.map (·.toJson) |>.getD .null),
    ("task", config.task?.map Json.str |>.getD .null),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Json)),
    ("executor", .mkObj [
      ("timeout_seconds", (config.executor.timeoutSeconds : Json)),
      ("env", .arr (config.executor.env.map fun (name, value) => .arr #[.str name, .str value]))])]

/-- The executor settings a configuration's `executor` field gives, over `defaults`. -/
def executorFromJson (json : Json) (defaults : Executor.Config) : Except String Executor.Config := do
  let object ← ConfigJson.object json #["timeout_seconds", "env"]
  let env ← match ← object.field? "env" with
    | none => pure defaults.env
    | some json => ConfigJson.pairs json
  pure { timeoutSeconds := ← object.nat "timeout_seconds" defaults.timeoutSeconds, env }

/-- A model a configuration names: its complete spec, or none. -/
def modelFromJson : Json → Except String (Option Models.Spec)
  | .null => pure none
  | json => match Models.Spec.read json with
    | .ok spec => pure (some spec)
    | .error problem => throw s!"'model': {problem}"

/-- A task a configuration gives, or none. -/
def taskFromJson : Json → Except String (Option String)
  | .null => pure none
  | .str task => pure (some task)
  | other => throw s!"'task' must be a string, not {other.compress}"

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Json) : Except String Config := do
  let object ← ConfigJson.object json #["model", "task", "max_consecutive_format_errors", "executor"]
  let defaults : Config := {}
  let model? ← match ← object.field? "model" with
    | none => pure defaults.model?
    | some json => modelFromJson json
  let task? ← match ← object.field? "task" with
    | none => pure defaults.task?
    | some json => taskFromJson json
  let executor ← match ← object.field? "executor" with
    | none => pure defaults.executor
    | some json => executorFromJson json defaults.executor
  pure { model?, task?, executor
         maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors }

/-! ## Prompts

The files in `MiniSwe/` are mini's templates from `mini.yaml` (vendored beside them, from
SWE-agent/mini-swe-agent `04d809c`), cut where jinja substitutes or branches, byte for byte;
`Test/Agents/MiniSwe.lean` checks each against the vendored copy. Assembly does what jinja does:
puts the task and the `uname` in, keeps the MacOS note when `system == "Darwin"` with the
whitespace its `{%-`/`-%}` tags strip, and drops one trailing newline from a rendering. The one
change of text is the machine line, which has no kernel release or version (`instanceMessage`). -/

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
def rendered (text : String) : String :=
  if text.endsWith "\n" then (text.dropEnd 1).toString else text

/-- The line a command prints first to end the run, the rest of its output being the
submission: mini's sentinel. -/
def sentinel : String := "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"

def systemMessage : String := rendered systemTemplate

/-- The rendered instance (task) message. Where mini's template has the whole `uname`, it has
the `system` and the `machine` alone: under docker the kernel's release and version are the
host's, and a prompt should not say which machine a run was created on. The MacOS `sed` note is
included exactly when `system == "Darwin"`. -/
def instanceMessage (task system machine : String) : String :=
  let note := if system == "Darwin" then darwinNote.trimAscii.toString else ""
  rendered <|
    opening ++ task ++ rules ++ system ++ " " ++ machine ++
    examples.trimAsciiEnd.toString ++ note ++ sedExamples.trimAsciiStart.toString

/-- The opening of a conversation: the system prompt and the task. -/
def openingMessages (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system systemMessage, .user (instanceMessage task uname.system uname.machine)]

/-- Whether the provider cut the response off before a tool call: mini's test in its
`format_error_template`. -/
def truncated (hasToolCalls : Bool) (finishReason? : Option String) : Bool :=
  match finishReason? with
  | some "length" => true
  | some "tool_calls" => !hasToolCalls
  | _ => false

/-- The user turn a malformed response is answered with: mini's `format_error_template`. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String) : String :=
  if truncated hasToolCalls finishReason? then
    formatErrorCut.replace "{{ finish_reason }}" (finishReason?.getD "")
  else rendered (formatErrorTemplate.replace "{{error}}" error)

/-! ## Observations -/

/-- How much of a command's output the model is shown; longer outputs show their head and tail. -/
def outputLimit : Nat := 10000

/-- A text as jinja's `tojson` writes it. -/
private def quoted (text : String) : String := (Json.str text).compress

/-- How the model sees a command: mini's `observation_template`, its output whole under
`outputLimit` characters, and its first and last half of that beyond, with what went wrong
when the command did not end on its own. A command with no exit status has `returncode` -1. -/
def observation (o : Output) : String :=
  let returncode := match o.exitCode? with
    | some code => toString code
    | none => "-1"
  let exception := match o.error? with
    | some error => s!", \"exception_info\": {quoted error}"
    | none => ""
  let length := o.output.length
  if length < outputLimit then
    "{\n  \"returncode\": " ++ returncode ++ ",\n  \"output\": " ++ quoted o.output ++ exception ++ "\n}"
  else
    let half := outputLimit / 2
    "{\n  \"returncode\": " ++ returncode ++
      ",\n  \"output_head\": " ++ quoted (String.ofList (o.output.toList.take half)) ++
      ",\n  \"output_tail\": " ++ quoted (String.ofList (o.output.toList.drop (length - half))) ++
      ",\n  \"elided_chars\": " ++ toString (length - outputLimit) ++
      ",\n  \"warning\": \"Output too long.\"" ++ exception ++ "\n}"

/-! ## The loop

Mini's `DefaultAgent`: each round reads what a person said, samples a response, answers a
malformed one with the format error, and otherwise makes each of its tool calls in order, until a
command prints the sentinel first. -/

/-- The context a sample is conditioned on. -/
abbrev Dialogue := Array Chat.Message

/-- The tools it offers: mini's `bash`, alone. -/
def tools (config : Config) : Array Tool := #[Tools.Bash.tool config.executor]

/-- A parsed model turn: the calls to make, in order, or a format-error message to send back as
a user turn. -/
inductive Parsed where
  | calls (calls : Array Chat.ToolCall)
  | formatError (message : String)

/-- Reads a response's tool calls against `tools`: the first problem makes the turn a format
error, as `formatError` words it. -/
def parse (tools : Array Tool) (formatError : String → Bool → Option String → String)
    (response : Chat.Response) : Parsed :=
  match Tools.problem? tools response with
  | some problem => .formatError (formatError problem (!response.toolCalls.isEmpty) response.finishReason?)
  | none => .calls response.toolCalls

/-- Mini's `parse_actions`, on its tools and in its format error. -/
def parseActions (config : Config) (response : Chat.Response) : Parsed :=
  parse (tools config) formatErrorMessage response

/-- One thing a conversation holds: a message told, the model's turn with each of its calls and
what the call gave, or a malformed response, which the model is shown as the format error. -/
inductive Item where
  | told (message : Chat.Message)
  | turn (response : Chat.Response) (results : Array (Chat.ToolCall × Json))
  | malformed (message : String)

/-- The state of the loop: the conversation, and the malformed responses since the last
well-formed one. A person's message in between does not reset the count. -/
structure History where
  items : Array Item := #[]
  formatErrors : Nat := 0

/-- The conversation with a malformed response, counted. -/
def History.malformed (history : History) (message : String) : History :=
  { history with items := history.items.push (.malformed message), formatErrors := history.formatErrors + 1 }

/-- The messages of a conversation: what is told as it is, a turn as the response and a tool
message for each call, its result as `shown` gives it with the turn's number, from 1, and a
malformed response as the format error, as a user turn. -/
def viewWith (shown : Nat → Chat.ToolCall → Json → String) (items : Array Item) : Dialogue := Id.run do
  let mut messages : Dialogue := #[]
  let mut turn := 0
  for item in items do
    match item with
    | .told message => messages := messages.push message
    | .malformed message =>
      turn := turn + 1
      messages := messages.push (.user message)
    | .turn response results =>
      turn := turn + 1
      messages := messages.push response.message
      for (call, result) in results do
        messages := messages.push (.tool call.id (.str (shown turn call result)))
  return messages

/-- Mini's linear context: every turn, a command as its observation, and a tool that failed as
its error. -/
def view (history : History) : Dialogue :=
  viewWith (items := history.items) fun _ _ result => match Tools.Bash.ofResult? result with
    | some (output, _) => observation output
    | none => result.pretty

/-- How the agent ends: a status, what it submitted, and, where the status alone does not say,
why. -/
def outcome (status : String) (submission : String := "") (reason? : Option String := none) : Json :=
  .mkObj ([("status", (status : Json)), ("submission", (submission : Json))] ++
    (reason?.map fun reason => ("reason", (reason : Json))).toList)

/-- How the agent ends when the provider refuses a request as too long: the one failure of a
sample the driver answers with. -/
def refused (refusal : String) : Json :=
  outcome "ContextExceeded" (reason? := some s!"the provider refused the request: {refusal}")

/-- What a notice tells the model: a person's message, in an envelope that says it came from a
person while the agent was paused. No other notice reaches a read of the agent's. -/
def noticeMessage : Notice → Option Chat.Message
  | .said message =>
    some (.user s!"<intervention>\nA person sent you a message while you were paused.\n{message}\n</intervention>")
  | _ => none

/-- The conversation with what has arrived since the last read of the inbox. -/
def listen (items : Array Item) : Computation Agent (Array Item) := do
  let heard ← inbox
  return items ++ (heard.toArray.filterMap noticeMessage).map .told

/-- What a command printed after the sentinel `line`, when it printed the line first: mini's
`has_finished`. -/
def submitted? (line : String) (result : Json) : Option String := do
  let (output, _) ← Tools.Bash.ofResult? result
  match (output.output.trimAsciiStart.toString.splitOn "\n") with
  | first :: rest => if first.trimAscii.toString == line then some ("\n".intercalate rest) else none
  | [] => none

/-- One round of mini's `DefaultAgent.run`: read the inbox, so that what a person said while the
run was paused reaches the model in this round's request; sample, and end when the provider
refuses the request as too long; answer a malformed response with the format error, and end
after too many in a row; otherwise make each call in order, until a command prints the
sentinel first. -/
def round (config : Config) (model : Models.Spec) (history : History) : Computation Agent (History ⊕ Json) := do
  let history := { history with items := ← listen history.items }
  let request : Chat.Request := { messages := view history, tools := (tools config).map (·.definition) }
  let response ← try sample model request catch refusal => return .inr (refused refusal)
  match parseActions config response with
  | .formatError message =>
    let history := history.malformed message
    let limit := config.maxConsecutiveFormatErrors
    if limit > 0 && history.formatErrors >= limit then return .inr (outcome "RepeatedFormatError")
    return .inl history
  | .calls calls =>
    let mut results : Array (Chat.ToolCall × Json) := #[]
    for asked in calls do
      let result ← Tools.make (tools config) asked
      if let some submission := submitted? sentinel result then
        return .inr (outcome "Submitted" submission)
      results := results.push (asked, result)
    return .inl { history with items := history.items.push (.turn response results), formatErrors := 0 }

/-! ## The agent -/

/-- The mini agent, for a call of `model` on `task`, on the machine the call names. -/
def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Json := do
  -- The opening names the machine the commands run on, as the container says.
  let uname ← Tools.Uname.read
  iter (round config model) { items := (openingMessages task uname).map .told }

/-- MiniSwe as a routine. A call's arguments are its configuration, its model and its task
among it; one it cannot run on fails in the call's frame. Its scope is its tool. -/
def routine : Routine Agent where
  name := "mini-swe"
  body arguments :=
    match Config.fromJson arguments with
    | .error problem => .fail s!"mini-swe: {problem}"
    | .ok config => match config.model?, config.task? with
      | some model, some task => computation config model task
      | none, _ => .fail "mini-swe: it samples a model, and its configuration names none"
      | _, none => .fail "mini-swe: it works on a task, and its configuration names none"
  scope := Scope.of #[Tools.Bash.routine]

end Alaya.Agents.MiniSwe
