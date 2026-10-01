import Alaya.Agent
import Alaya.Executor
import Alaya.Agent.Tools
import Alaya.Agent.Config
import Alaya.Models

/-! A port of mini-SWE-agent's default tool-calling agent as an `Alaya.Agent.Agent`. See
`docs/miniswe.md`. -/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error Output Executor Uname)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive Session)

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
  (`outputs`). Off, the agent is mini to the byte; on, only that warning differs. -/
  recoverOutput : Bool := false
  /-- Offer yes/no, single-choice, and open-ended questions. -/
  askUser : Bool := false
  /-- Tokens kept free for the next response when deciding whether the context is full, or the
  model's `output_tokens` when that is less. -/
  contextReserve : Nat := 8000
  /-- Omit old outputs from the view (`Masking`); `none` shows them all. -/
  masking? : Option Masking := none
  /-- The tokens a request may hold: the model's context less the reserve, set from the model
  when the agent is built (`agent`), and not part of the JSON; `none` is no check. -/
  contextLimit? : Option Nat := none
  /-- Offer `time_budget`, which says how much of the run's time budget is left. Not a field of
  mini-swe's configuration: MiniVero sets it (`time_budget` in its own). -/
  timeBudget : Bool := false
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
    ("ask_user", (config.askUser : Lean.Json)),
    ("context_reserve", (config.contextReserve : Lean.Json)),
    ("mask_observations", match config.masking? with
      | none => .null
      | some m => .mkObj [("keep_turns", (m.keepTurns : Lean.Json)), ("block", (m.block : Lean.Json))])]

/-- Reads a configuration; a field left out is `defaults`', and an unknown one is an error.
`own` names the fields of an agent built on this one, which it reads itself. -/
def Config.fromJson (json : Lean.Json) (defaults : Config := {}) (own : Array String := #[]) :
    Except String Config := do
  let object ← ConfigJson.object json
    (#["name", "step_limit", "max_consecutive_format_errors", "executor", "recover_output", "ask_user",
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
  pure {
    stepLimit := ← object.nat "step_limit" defaults.stepLimit
    maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors
    executor
    recoverOutput := ← object.bool "recover_output" defaults.recoverOutput
    askUser := ← object.bool "ask_user" defaults.askUser
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

/-- The rendered instance (task) message. `system`/`release`/`version`/`machine` are the
`uname` fields; the MacOS `sed` note is included exactly when `system == "Darwin"`. -/
def instanceMessage (task system release version machine : String) : String :=
  let note := if system == "Darwin" then darwinNote.trimAscii.toString else ""
  rendered <| sentinelToSubmit <|
    opening ++ task ++ rules ++ system ++ " " ++ release ++ " " ++ version ++ " " ++ machine ++
    examples.trimAsciiEnd.toString ++ note ++ sedExamples.trimAsciiStart.toString

/-- The tools besides `bash` and `submit` a configuration offers, with what each is for. -/
def extraTools (config : Config) : List (String × String) :=
  (if config.timeBudget then [("time_budget", "see how much time is left")] else []) ++
  (if config.askUser then [("ask_user", "ask a person a question")] else [])

/-- The one thing extra tools change in mini's texts: a response must hold a tool call, not a
bash call, since it may be one of them alone. -/
def withExtraTools (config : Config) (text : String) : String :=
  let extras := extraTools config
  if extras.isEmpty then text else
    let text := text.replace "Your response MUST include AT LEAST ONE bash tool call"
      (if config.askUser then "Your response MUST include AT LEAST ONE tool call" else
        "Your response MUST include AT LEAST ONE tool call: bash" ++
          String.join (extras.map fun (name, purpose) => s!", or {name} to {purpose}"))
    text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
      (if config.askUser then "Every response needs at least one tool call." else
        "Every response needs at least one tool call: 'bash' to execute commands" ++
          String.join (extras.map fun (name, purpose) => s!", or '{name}' to {purpose}") ++ ".")

/-- Allow a question turn in the opening and format-error prompts when the tool is offered. -/
def withAsk (enabled : Bool) (text : String) : String :=
  if !enabled then text else
    let text := text.replace "Your response MUST include AT LEAST ONE bash tool call"
      "Your response MUST include AT LEAST ONE tool call"
    let text := text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
      "Every response needs at least one tool call."
    let text := text.replace "exactly one bash tool call" "exactly one tool call"
    text ++ "\n\n" ++ Tools.AskUser.instruction

/-- The opening log of a run: the system prompt and the task. -/
def initialLog (config : Config) (task : String) (uname : Uname) : Log :=
  #[.message (.system systemMessage),
    .message (.user (withAsk config.askUser (withExtraTools config
      (instanceMessage task uname.system uname.release uname.version uname.machine))))]

/-- The user turn a malformed response is answered with: mini's `format_error_template`. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String)
    (config : Config := {}) : String :=
  withAsk config.askUser <|
  withExtraTools config <|
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
    (if config.timeBudget then #[Tools.TimeBudget.definition] else #[]) ++
    (if config.askUser then #[Tools.AskUser.definition] else #[])

/-! ## Reading a response -/

/-- One parsed tool call: a command to run, a question for the session or a person, or the
call that ends the run. -/
inductive Action where
  | bash (id : String) (command : String)
  | timeBudget (id : String)
  | ask (id : String) (question : Question)
  | submit (id : String) (message : String)
  deriving Inhabited

def Action.id : Action -> String
  | .bash id _ => id
  | .timeBudget id => id
  | .ask id _ => id
  | .submit id _ => id

/-- A parsed model turn: its actions, or a format-error message to send back as a user turn. -/
inductive Parsed where
  | actions (actions : Array Action)
  | formatError (message : String)

/-- Reads a response's tool calls; the first call with a problem makes the turn a format error.
`time_budget` and `ask_user` are known only when offered; an ask must be alone. -/
def parseActions (response : Chat.Response) (config : Config := {}) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason? config
  if config.askUser && response.toolCalls.any (·.name == "ask_user") && response.toolCalls.size != 1 then
    return .formatError <| formatErrorMessage "ask_user must be called alone."
      true response.finishReason? config
  let mut actions : Array Action := #[]
  for call in response.toolCalls do
    let action : Except String Action :=
      if let some raw := call.invalidArguments? then
        .error ("Error parsing tool call arguments: " ++
          (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
      else match call.name with
        | "submit" => .ok (.submit call.id (Tools.Submit.message call.arguments))
        | "bash" => (Tools.Bash.command call.arguments).map (.bash call.id ·)
        | "time_budget" =>
          if !config.timeBudget then .error "Unknown tool 'time_budget'." else .ok (.timeBudget call.id)
        | "ask_user" =>
          if !config.askUser then .error "Unknown tool 'ask_user'."
          else (Tools.AskUser.question call.arguments).map (.ask call.id ·)
        | other => .error s!"Unknown tool '{other}'."
    match action with
    | .error problem =>
      return .formatError (formatErrorMessage problem true response.finishReason? config)
    | .ok action => actions := actions.push action
  return .actions actions

/-! ## The agent: view, control, action -/

/-- The file holding the whole of the output recorded at `index` of the log by call `id`: named
by its position, which never changes on a branch, with the id, made safe for a file name, for
reading. -/
def outputFile (index : Nat) (id : String) : String :=
  let safe := id.map fun c => if c.isAlphanum || c == '-' || c == '_' || c == '.' then c else '_'
  s!"{index}-{safe}.txt"

/-- How many turns from the first are omitted when the log holds `turns`: none until the
boundary first moves, then a multiple of `block`. -/
def Masking.omittedTurns (m : Masking) (turns : Nat) : Nat :=
  if turns < m.keepTurns + m.block then 0 else ((turns - m.keepTurns) / m.block) * m.block

/-- For each event of the log, whether it is in a turn the view omits. An event belongs to the
turn of the response before it; the events before the first response, to the first. -/
private def omittedEvents (config : Config) (log : Log) : Array Bool :=
  let omitted := config.masking?.map (·.omittedTurns log.responses) |>.getD 0
  -- Fold oldest first, counting the responses so far.
  (log.foldl (init := (#[], 0)) fun (acc, seen) event =>
    let seen := match event with | .response _ => seen + 1 | _ => seen
    (acc.push (omitted > 0 && seen ≤ omitted), seen)).1

/-- How the view shows a command's output: whole, cut to its head and tail, or omitted. -/
private inductive Shown where
  | whole | cut | omitted

private def shown (omittedTurn : Bool) (file : String) (o : Output) : Shown :=
  -- An output no longer than the notice is cheaper to keep.
  if omittedTurn && o.output.length > (Tools.Bash.omittedNotice file).length then .omitted
  else if o.output.length < outputLimit then .whole else .cut

/-- The path the view gives for the output recorded at `index` by `id`. -/
private def outputPath (index : Nat) (id : String) : String :=
  s!"{Agent.outputsDir}/{outputFile index id}"

/-- The view: a malformed response is shown as the format error, as a user turn; an observation
as `Tools.Bash.observation` of the recorded `Output`, which with `recoverOutput` names the file
a cut output is in, or, in a turn masking omits, as `Tools.Bash.omitted`. -/
def view (config : Config) (log : Log) : Dialogue :=
  let omitted := omittedEvents config log
  log.mapIdx fun index event => match event with
    | .message m => m
    | .response r =>
      match parseActions r config with
      | .actions _ => r.message
      | .formatError message => .user message
    | .observation id content =>
      let path := outputPath index id
      let json := match Output.fromJson? content with
        | some output => match shown (omitted[index]?.getD false) path output with
          | .omitted => Tools.Bash.omitted output path
          | _ => Tools.Bash.observation output outputLimit (if config.recoverOutput then some path else none)
        | none => content
      .tool id (.str json.pretty)

/-- The files the view names: the whole of each output it omits, and with `recoverOutput`, of
each it cuts. -/
def outputs (config : Config) (log : Log) : Array (String × String) :=
  let omitted := omittedEvents config log
  (log.mapIdx fun index event => match event with
    | .observation id content => do
      let output ← Output.fromJson? content
      let named := match shown (omitted[index]?.getD false) (outputPath index id) output with
        | .omitted => true
        | .cut => config.recoverOutput
        | .whole => false
      if named then some (outputFile index id, output.output) else none
    | _ => none).filterMap (·)

/-- How many format-error responses end the log with no clean turn between them. A person's
message in between does not reset the count; an observation does, since it means a turn ran. -/
private def trailingFormatErrors (config : Config) (log : Log) : Nat := Id.run do
  let mut count := 0
  for event in log.reverse do
    match event with
    | .response r =>
      match parseActions r config with
      | .formatError _ => count := count + 1
      | .actions _ => return count
    | .observation _ _ => return count
    | .message _ => pure ()
  return count

/-- Mini's control flow (`DefaultAgent.run`), decided from the log; the session answers
`time_budget` and nothing else. -/
def next (config : Config) (session : Session) (log : Log) : Directive :=
  let sampleOrStop : Directive :=
    if config.stepLimit > 0 && log.responses >= config.stepLimit
    then .done { status := "LimitsExceeded" }
    else if config.contextLimit?.any (Agent.contextTokens (view config) log ≥ ·)
    then .done { status := "ContextExceeded" }
    else .sample
  match log.lastResponse? with
  | none => sampleOrStop
  | some response =>
    match parseActions response config with
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
      | some (.timeBudget id) => .record id (Tools.TimeBudget.answer session)
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
  | _, _ => throw <| .input s!"not a runnable bash call: {call.name}"

/-- The tokens a request to `model` may hold under `config`: its context less the room kept for
a response; `none` when its context is not known. -/
def contextLimit? (config : Config) (model : Models.Spec) : Option Nat :=
  model.contextTokens?.map fun tokens =>
    tokens - min config.contextReserve (model.outputTokens?.getD config.contextReserve)

/-- The mini agent, for a run of `model`, whose context it keeps within. -/
def agent (config : Config) (model : Models.Spec := default) : Agent :=
  let config := { config with contextLimit? := contextLimit? config model }
  {
  config := config.toJson
  initialLog := initialLog config
  executorConfig := config.executor
  tools := tools config
  view := view config
  next := next config
  act
  outputs := outputs config
}

end Alaya.Agent.MiniSwe
