import Alaya.Agents.Basic

/-! A port of mini-SWE-agent's default tool-calling agent: mini's prompts, its one `bash` tool,
its sentinel that ends a run, its observations, and its loop, whose context keeps every turn.
What does not depend on mini's terms, reading a configuration and a person's messages and how
an agent ends, is the basic agent's. See `docs/agents.md` §6. -/

namespace Alaya.Agents.MiniSwe

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-! ## Configuration -/

/-- How mini runs a command: a 30-second limit, and its environment overrides. -/
def defaultExecutor : Executor.Config := {
  timeoutSeconds := 30
  env := #[("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
           ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")] }

/-- The basic agent's configuration, with mini's command settings, and how many malformed
responses in a row end it: mini's limit, 0 for none. -/
structure Config extends Basic.Common where
  executor := defaultExecutor
  maxConsecutiveFormatErrors : Nat := 3
  deriving Inhabited

def fields : Fields Config :=
  Basic.commonFields.lift (·.toCommon) (fun b c => { c with toCommon := b }) ++ #[
  .of "max_consecutive_format_errors" .nat (·.maxConsecutiveFormatErrors)
    fun v c => { c with maxConsecutiveFormatErrors := v }]

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Json := fields.toJson config

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Json) : Except String Config := fields.read json {}

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

/-- The user turn a malformed response is answered with: mini's `format_error_template`, which
says so when the provider cut the response off before a tool call. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String) : String :=
  let cut := match finishReason? with
    | some "length" => true
    | some "tool_calls" => !hasToolCalls
    | _ => false
  if cut then formatErrorCut.replace "{{ finish_reason }}" (finishReason?.getD "")
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

Mini's `DefaultAgent`: its context is the messages so far, each appended once and kept. A round
reads what a person said, samples a response, answers a malformed one with the format error,
and otherwise makes each tool call in order, until a command prints the sentinel first. -/

/-- The tools it offers: mini's `bash`, alone. -/
def tools (config : Config) : Array Tool := #[Tools.Bash.tool config.executor]

/-- The format error a response is answered with, mini's `parse_actions`: of its first problem,
no call at all or the first call with a problem; `none` when every call can be made. -/
def formatError? (config : Config) (response : Chat.Response) : Option String :=
  let problem? := if response.toolCalls.isEmpty
    then some "No tool calls found in the response. Every response MUST include at least one tool call."
    else response.toolCalls.findSome? (Tools.callProblem? (tools config))
  problem?.map (formatErrorMessage · (!response.toolCalls.isEmpty) response.finishReason?)

/-- What a command printed after the sentinel `line`, when it printed the line first: mini's
`has_finished`. -/
def submitted? (line : String) (result : Json) : Option String := do
  let (output, _) ← Tools.Bash.ofResult? result
  match (output.output.trimAsciiStart.toString.splitOn "\n") with
  | first :: rest => if first.trimAscii.toString == line then some ("\n".intercalate rest) else none
  | [] => none

/-- One round of mini's `DefaultAgent.run`, on the messages so far and the malformed responses
in a row: read the inbox, so that what a person said while the run was paused reaches the model;
sample, and end when the provider refuses the request as too long; answer a malformed response
with the format error, and end after too many in a row; otherwise make each call in order, each
shown as its observation or its error, until a command prints the sentinel first. -/
def round (config : Config) (model : Models.Spec) : Basic.Dialogue × Nat → Computation Agent (Basic.Dialogue × Nat ⊕ Json)
  | (messages, errors) => do
  let messages := messages ++ (← Basic.heard)
  let response ← try sample model { messages, tools := (tools config).map (·.definition) }
    catch refusal => return .inr (Basic.refused refusal)
  if let some message := formatError? config response then
    let limit := config.maxConsecutiveFormatErrors
    if limit > 0 && errors + 1 >= limit then return .inr (Basic.outcome "RepeatedFormatError")
    return .inl (messages.push (.user message), errors + 1)
  let mut messages := messages.push response.message
  for asked in response.toolCalls do
    let shown ← match ← Tools.make (tools config) asked with
      | .error error => pure (Json.mkObj [("error", .str error)]).pretty
      | .ok result =>
        if let some submission := submitted? sentinel result then
          return .inr (Basic.outcome "Submitted" submission)
        pure <| match Tools.Bash.ofResult? result with
          | some (output, _) => observation output
          | none => result.pretty
    messages := messages.push (.tool asked.id (.str shown))
  return .inl (messages, 0)

/-! ## The agent -/

/-- The mini agent, for a call of `model` on `task`, on the machine the call names. -/
def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Json := do
  -- The opening names the machine the commands run on, as the container says.
  let uname ← Tools.Uname.read
  iter (round config model) (openingMessages task uname, 0)

/-- MiniSwe as a routine. Its scope is its tool. -/
def routine : Routine Agent :=
  Basic.agent "mini-swe" fields {} (·.toCommon) computation (Scope.of #[Tools.Bash.routine])

end Alaya.Agents.MiniSwe
