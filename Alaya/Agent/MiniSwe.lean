import Alaya.Agent
import Alaya.Executor
import Alaya.Agent.Tools
import Alaya.Agent.Config
import Alaya.Models

/-! A port of mini-SWE-agent's default tool-calling agent as an `Alaya.Agent.Agent`. See
`docs/miniswe.md`. -/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error Output Executor Uname)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect Tool CallRef Purpose)

/-! ## Configuration -/

/-- How mini runs a command: a 30-second limit, and its environment overrides. -/
def defaultExecutor : Executor.Config := {
  timeoutSeconds := 30
  env := #[("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
           ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")] }

/-- Which old outputs the view omits: those of the turns before a boundary that keeps the last
`keepTurns` turns whole and moves `block` turns at a time, so between its moves the context only
grows at its end and the provider's prompt cache holds. -/
structure Masking where
  keepTurns : Nat
  block : Nat
  deriving Inhabited, BEq, Repr

structure Config where
  /-- Maximum model calls; 0 disables the limit (as in mini.yaml). -/
  stepLimit : Nat := 0
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  /-- Name, in a long output's warning, the file under `outputsDir` that holds the whole of it
  (`Agent.outputFile`). Off, the agent is mini to the byte; on, only that warning differs. -/
  recoverOutput : Bool := false
  /-- The tools offered, in order: `bash` and `submit`, and any others from `Tools.all`. -/
  tools : Array Tool := #[Tools.Bash.tool, Tools.Submit.tool]
  /-- Tokens kept free for the next response when deciding whether the context is full, or the
  model's `output_tokens` when that is less. -/
  contextReserve : Nat := 8000
  /-- Omit old outputs from the view (`Masking`); `none` shows them all. -/
  masking? : Option Masking := none
  /-- The tokens a request may hold: the model's context less the reserve, set from the model
  when the agent is built (`agent`), and not part of the JSON; `none` is no check. -/
  contextLimit? : Option Nat := none
  deriving Inhabited

/-- The configuration as JSON: what a root records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Lean.Json :=
  .mkObj [
    ("name", "mini-swe"),
    ("step_limit", (config.stepLimit : Lean.Json)),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("executor", .mkObj [
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json)),
      ("env", .arr (config.executor.env.map fun (name, value) => .arr #[.str name, .str value]))]),
    ("recover_output", (config.recoverOutput : Lean.Json)),
    ("tools", .arr (config.tools.map (.str ·.name))),
    ("context_reserve", (config.contextReserve : Lean.Json)),
    ("mask_observations", match config.masking? with
      | none => .null
      | some m => .mkObj [("keep_turns", (m.keepTurns : Lean.Json)), ("block", (m.block : Lean.Json))])]

/-- Reads a configuration; a field left out is `defaults`', and an unknown one is an error.
`own` names the fields of an agent built on this one, which it reads itself. -/
def Config.fromJson (json : Lean.Json) (defaults : Config := {}) (own : Array String := #[]) :
    Except String Config := do
  let object ← ConfigJson.object json
    (#["name", "step_limit", "max_consecutive_format_errors", "executor", "recover_output", "tools",
      "context_reserve", "mask_observations"] ++ own)
  let executor ← match ← object.field? "executor" with
    | none => pure defaults.executor
    | some json => do
      let object ← ConfigJson.object json #["timeout_seconds", "env"]
      let env ← match ← object.field? "env" with
        | none => pure defaults.executor.env
        | some json => ConfigJson.pairs json
      pure { timeoutSeconds := ← object.nat "timeout_seconds" defaults.executor.timeoutSeconds, env }
  let masking? ← match ← object.field? "mask_observations" with
    | none => pure defaults.masking?
    | some .null => pure none
    | some json => do
      let object ← ConfigJson.object json #["keep_turns", "block"]
      let some keepTurns ← object.field? "keep_turns" |>.map (·.bind (·.getNat?.toOption))
        | throw "'mask_observations' needs 'keep_turns', a non-negative integer"
      let some block ← object.field? "block" |>.map (·.bind (·.getNat?.toOption))
        | throw "'mask_observations' needs 'block', a positive integer"
      if block == 0 then throw "'mask_observations.block' must be positive"
      pure (some { keepTurns, block })
  let tools ← match ← object.field? "tools" with
    | none => pure defaults.tools
    | some (.arr names) => names.mapM fun
      | .str name => match Tools.named? name with
        | some tool => pure tool
        | none => throw s!"unknown tool '{name}' (the tools are {", ".intercalate (Tools.all.map (·.name)).toList})"
      | other => throw s!"'tools' must be an array of tool names, not {other.compress}"
    | some other => throw s!"'tools' must be an array of tool names, not {other.compress}"
  let names := tools.map (·.name)
  for required in #["bash", "submit"] do
    if !names.contains required then throw s!"'tools' must include {required}: mini's prompts are about it"
  for name in names do
    if (names.filter (· == name)).size > 1 then throw s!"'tools' names {name} twice"
  pure {
    stepLimit := ← object.nat "step_limit" defaults.stepLimit
    maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors
    executor
    recoverOutput := ← object.bool "recover_output" defaults.recoverOutput
    tools
    contextReserve := ← object.nat "context_reserve" defaults.contextReserve
    masking? }

/-! ## Prompts

The files in `MiniSwe/` are mini's templates from `mini.yaml` (vendored beside them, from
SWE-agent/mini-swe-agent `04d809c`), cut where jinja substitutes or branches, byte for byte;
`Test/MiniSwe.lean` checks each against the vendored copy. Assembly does what jinja does: puts
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

/-- The port's one change of mini's texts besides `sentinelToSubmit`: the sentences that say a
response must call `bash` say it must call a tool, so that tools added after them — some of
which must be called alone — never contradict them. -/
def toolNeutral (text : String) : String :=
  let text := text.replace "Your response MUST include AT LEAST ONE bash tool call"
    "Your response MUST include AT LEAST ONE tool call"
  let text := text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
    "Every response needs at least one tool call."
  text.replace "exactly one bash tool call" "exactly one tool call"

/-- The rendered instance (task) message. `system`/`release`/`version`/`machine` are the
`uname` fields; the MacOS `sed` note is included exactly when `system == "Darwin"`. -/
def instanceMessage (task system release version machine : String) : String :=
  let note := if system == "Darwin" then darwinNote.trimAscii.toString else ""
  rendered <| toolNeutral <| sentinelToSubmit <|
    opening ++ task ++ rules ++ system ++ " " ++ release ++ " " ++ version ++ " " ++ machine ++
    examples.trimAsciiEnd.toString ++ note ++ sedExamples.trimAsciiStart.toString

/-- `text` with the instructions of the configuration's tools after it, a blank line before
each: what a tool adds to the prompt, which is only ever added. -/
def withInstructions (config : Config) (text : String) : String :=
  config.tools.foldl (init := text) fun text tool =>
    match tool.instruction? with
    | some instruction => text ++ "\n\n" ++ instruction
    | none => text

/-- The opening log of a run: the system prompt and the task. -/
def initialLog (config : Config) (task : String) (uname : Uname) : Log :=
  #[.told (.system systemMessage),
    .told (.user (withInstructions config
      (instanceMessage task uname.system uname.release uname.version uname.machine)))]

/-- The user turn a malformed response is answered with: mini's `format_error_template`. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String)
    (config : Config := {}) : String :=
  withInstructions config <| toolNeutral <|
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
def tools (config : Config) : Array Chat.ToolDefinition := config.tools.map (·.definition)

/-! ## Reading a response -/

/-- One parsed tool call: which of the response's calls it is, and how its tool answers it
(`Tool.read`): what to ask for next, by the call's reference, from the log at its point. -/
structure Action where
  index : Nat
  next : CallRef -> Log -> Effect ⊕ Outcome

/-- A parsed model turn: its actions, or a format-error message to send back as a user turn. -/
inductive Parsed where
  | actions (actions : Array Action)
  | formatError (message : String)

/-- Reads a response's tool calls, each by the configuration's tool of its name; the first call
with a problem makes the turn a format error, and so does a tool that must be alone and is not. -/
def parseActions (response : Chat.Response) (config : Config := {}) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason? config
  if response.toolCalls.size != 1 then
    if let some tool := config.tools.find? fun tool =>
        tool.alone && response.toolCalls.any (·.name == tool.name) then
      return .formatError <| formatErrorMessage s!"{tool.name} must be called alone."
        true response.finishReason? config
  let mut actions : Array Action := #[]
  for (call, index) in response.toolCalls.zipIdx do
    let next : Except String (CallRef -> Log -> Effect ⊕ Outcome) :=
      if let some raw := call.invalidArguments? then
        .error ("Error parsing tool call arguments: " ++
          (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
      else match config.tools.find? (·.name == call.name) with
        | some tool => tool.read call
        | none => .error s!"Unknown tool '{call.name}'."
    match next with
    | .error problem =>
      return .formatError (formatErrorMessage problem true response.finishReason? config)
    | .ok next => actions := actions.push { index, next }
  return .actions actions

/-! ## The agent: view, control, action -/

/-- How many turns from the first are omitted when the log holds `turns`: none until the
boundary first moves, then a multiple of `block`. -/
def Masking.omittedTurns (m : Masking) (turns : Nat) : Nat :=
  if turns < m.keepTurns + m.block then 0 else ((turns - m.keepTurns) / m.block) * m.block

/-- For each event of the log, whether it is in a turn the view omits. An event belongs to the
turn of the response before it; the events before the first response, to the first. -/
private def omittedEvents (config : Config) (index : Agent.Index) : Array Bool :=
  let omitted := config.masking?.map (·.omittedTurns index.turns.size) |>.getD 0
  index.turnOf.map fun turn => omitted > 0 && turn ≤ omitted

/-- How the view shows a command's output: whole, cut to its head and tail, or omitted. -/
private inductive Shown where
  | whole | cut | omitted

private def shown (omittedTurn : Bool) (file : String) (o : Output) : Shown :=
  -- An output no longer than the notice is cheaper to keep.
  if omittedTurn && o.output.length > (Tools.Bash.omittedNotice file).length then .omitted
  else if o.output.length < outputLimit then .whole else .cut

/-- The view: a malformed response is shown as the format error, as a user turn; a command's
output as `Tools.Bash.observation`, which with `recoverOutput` names the file a cut output is
in, or, in a turn masking omits, as `Tools.Bash.omitted`; any other observation as recorded.
Workspaces placed and timings of the run are not shown. -/
def view (config : Config) (log : Log) : Dialogue :=
  let index := log.index
  let omitted := omittedEvents config index
  let shownOutput (position : Nat) (id : String) (output : Output) : Chat.Message :=
    let path := Agent.outputPath position id
    let json := match shown (omitted[position]?.getD false) path output with
      | .omitted => Tools.Bash.omitted output path
      | _ => Tools.Bash.observation output outputLimit (if config.recoverOutput then some path else none)
    .tool id (.str json.pretty)
  (log.mapIdx fun position event => match event with
    | .told m => some m
    | .sampled _ purpose r =>
      if purpose != Purpose.turn then none else
      match parseActions r config with
      | .actions _ => some r.message
      | .formatError message => some (.user message)
    | .executed call _ _ output _ => (index.callId? call).map (shownOutput position · output)
    | .recorded call content => (index.callId? call).map (.tool · (.str content.pretty))
    | .placed _ | .timed .. => none).filterMap id

/-- How many format-error responses end the log with no clean turn between them. A person's
message in between does not reset the count; an observation does, since it means a turn ran. -/
private def trailingFormatErrors (config : Config) (index : Agent.Index) : Nat := Id.run do
  let mut count := 0
  for turn in index.turns.reverse do
    match parseActions turn.response config with
    | .formatError _ => count := count + 1
    | .actions _ => return count
  return count

/-- The request of a model turn: the view of the log, with the tools. -/
def request (config : Config) (log : Log) : Chat.Request :=
  { messages := view config log, tools := tools config }

/-- Mini's control flow (`DefaultAgent.run`), decided from the log, without its limits on steps
and context, which `agent` adds (`Agent.limitResponses`, `Agent.limitContext`). The next call to
answer is answered by its tool. -/
def next (config : Config) (log : Log) : Effect ⊕ Outcome :=
  let sample := .inl (.sample Purpose.turn (request config log))
  let index := log.index
  match index.lastTurn? with
  | none => sample
  | some turn =>
    match parseActions turn.response config with
    | .formatError _ =>
      if config.maxConsecutiveFormatErrors > 0 &&
          trailingFormatErrors config index >= config.maxConsecutiveFormatErrors
      then .inr { status := "RepeatedFormatError" }
      else sample
    | .actions actions =>
      match index.pending[0]? with
      | none => sample
      | some call =>
        match actions.find? (·.index == call.ref.index) with
        | some action => action.next call.ref log
        | none => sample

/-- The tokens a request to `model` may hold under `config`: its context less the room kept for
a response; `none` when its context is not known. -/
def contextLimit? (config : Config) (model : Models.Spec) : Option Nat :=
  model.contextTokens?.map fun tokens =>
    tokens - min config.contextReserve (model.outputTokens?.getD config.contextReserve)

/-- The mini agent, for a run of `model`, whose context it keeps within: mini's control flow,
its commands run as `executor` says, stopped at the step limit, and before that at the context
limit. A command sees the branch's outputs only when the view may name one: with
`recover_output`, or with masking. -/
def agent (config : Config) (model : Models.Spec := default) : Agent :=
  let config := { config with contextLimit? := contextLimit? config model }
  let base : Agent := {
    config := config.toJson
    initialLog := initialLog config
    next := next config }
  let commands := { config.executor with outputs := config.recoverOutput || config.masking?.isSome }
  ((base.runCommandsWith commands).limitContext config.contextLimit?).limitResponses config.stepLimit

end Alaya.Agent.MiniSwe
