import Alaya.Agents.Tools
import Alaya.Agents.Config
import Alaya.Models

/-! A port of mini-SWE-agent's default tool-calling agent as a program. It waits for its task,
then goes round a loop whose state is the conversation: it samples the model on mini's view of
the conversation, reads the response's tool calls as mini does, calls each tool by its name, and
reads its inbox, so that what a person says or changes reaches the model in the next request.
See `docs/miniswe.md`. -/

namespace Alaya.Agents.MiniSwe

open Lean (Json)
open Alaya (Output Executor Uname)

/-- The context a sample is conditioned on: the output of a view. -/
abbrev Dialogue := Array Chat.Message

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
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  /-- Name, in a long output's warning, the file under `outputsDir` that holds the whole of it
  (`Driver.outputFile`, named by the output's content). Off, the agent is mini to the byte; on,
  only that warning differs. -/
  recoverOutput : Bool := false
  /-- The tools offered, by name, in order: `bash` and `submit`, and any others of `Tools.all`. -/
  tools : Array String := #["bash", "submit"]
  /-- The kinds of question `ask_user` lets the model ask: at least one when the tool is
  offered, and none when it is not. There is no default: whoever offers the tool says. -/
  questionTypes : Array Question.Kind := #[]
  /-- Tokens kept free for the next response when deciding whether the context is full, or the
  model's `output_tokens` when that is less. -/
  contextReserve : Nat := 8000
  /-- Omit old outputs from the view (`Masking`); `none` shows them all. -/
  masking? : Option Masking := none
  /-- The tokens a request may hold: the model's context less the reserve, set from the model
  when the agent is built (`agent`), and not part of the JSON; `none` is no check. -/
  contextLimit? : Option Nat := none
  deriving Inhabited

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Lean.Json :=
  .mkObj [
    ("name", "mini-swe"),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("executor", .mkObj [
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json)),
      ("env", .arr (config.executor.env.map fun (name, value) => .arr #[.str name, .str value]))]),
    ("recover_output", (config.recoverOutput : Lean.Json)),
    ("tools", .arr (config.tools.map .str)),
    ("question_types", .arr (config.questionTypes.map fun kind => .str kind.name)),
    ("context_reserve", (config.contextReserve : Lean.Json)),
    ("mask_observations", match config.masking? with
      | none => .null
      | some m => .mkObj [("keep_turns", (m.keepTurns : Lean.Json)), ("block", (m.block : Lean.Json))])]

/-- Reads a configuration; a field left out is `defaults`', and an unknown one is an error.
`own` names the fields of an agent built on this one, which it reads itself. -/
def Config.fromJson (json : Lean.Json) (defaults : Config := {}) (own : Array String := #[]) :
    Except String Config := do
  let object ← ConfigJson.object json
    (#["name", "max_consecutive_format_errors", "executor", "recover_output", "tools", "question_types",
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
      | .str name =>
        if Tools.names.contains name then pure name
        else throw s!"unknown tool '{name}' (the tools are {", ".intercalate Tools.names.toList})"
      | other => throw s!"'tools' must be an array of tool names, not {other.compress}"
    | some other => throw s!"'tools' must be an array of tool names, not {other.compress}"
  let names := tools
  for required in #["bash", "submit"] do
    if !names.contains required then throw s!"'tools' must include {required}: mini's prompts are about it"
  for name in names do
    if (names.filter (· == name)).size > 1 then throw s!"'tools' names {name} twice"
  let wrongTypes := s!"'question_types' must be an array of {Question.Kind.names}"
  let questionTypes ← match ← object.field? "question_types" with
    | none => pure defaults.questionTypes
    | some (.arr names) => names.mapM fun
      | .str name => match Question.Kind.ofName? name with
        | some kind => pure kind
        | none => throw s!"unknown kind of question '{name}': {wrongTypes}"
      | other => throw s!"{wrongTypes}, not {other.compress}"
    | some other => throw s!"{wrongTypes}, not {other.compress}"
  for kind in questionTypes do
    if (questionTypes.filter (· == kind)).size > 1 then throw s!"'question_types' names {kind.name} twice"
  -- The kinds a model may ask are chosen with the tool, never assumed.
  if names.contains "ask_user" && questionTypes.isEmpty then
    throw s!"'tools' offers ask_user: 'question_types' must say which kinds of question the model may ask ({Question.Kind.names})"
  if !names.contains "ask_user" && !questionTypes.isEmpty then
    throw "'question_types' is for ask_user, which 'tools' does not offer"
  pure {
    maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors
    executor
    recoverOutput := ← object.bool "recover_output" defaults.recoverOutput
    tools
    questionTypes
    contextReserve := ← object.nat "context_reserve" defaults.contextReserve
    masking? }

/-- How the configuration runs a command: mini's executor settings, and, when the view may
name a file an output is in, with the outputs kept as files. -/
def Config.commands (config : Config) : Executor.Config :=
  { config.executor with outputs := config.recoverOutput || config.masking?.isSome }

/-- The tools the configuration offers, its commands run as it says. -/
def Config.offered (config : Config) : Array Tool :=
  config.tools.filterMap (Tools.named? · { commands := config.commands, questions := config.questionTypes })

/-! ## Prompts

The files in `MiniSwe/` are mini's templates from `mini.yaml` (vendored beside them, from
SWE-agent/mini-swe-agent `04d809c`), cut where jinja substitutes or branches, byte for byte;
`Test/MiniSwe.lean` checks each against the vendored copy. Assembly does what jinja does: puts
the task and the `uname` in, keeps the MacOS note when `system == "Darwin"` with the
whitespace its `{%-`/`-%}` tags strip, and drops one trailing newline from a rendering. The
changes of text are the port's: the sentences that name mini's submission sentinel say the
`submit` tool (`sentinelToSubmit`), those that require a `bash` call require a tool call
(`toolNeutral`), and the machine line has no kernel release or version (`instanceMessage`). -/

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

/-- The rendered instance (task) message. Where mini's template has the whole `uname`, it has
the `system` and the `machine` alone: under docker the kernel's release and version are the
host's, and a prompt should not say which machine a run was created on. The MacOS `sed` note is
included exactly when `system == "Darwin"`. -/
def instanceMessage (task system machine : String) : String :=
  let note := if system == "Darwin" then darwinNote.trimAscii.toString else ""
  rendered <| toolNeutral <| sentinelToSubmit <|
    opening ++ task ++ rules ++ system ++ " " ++ machine ++
    examples.trimAsciiEnd.toString ++ note ++ sedExamples.trimAsciiStart.toString

/-- `text` with the instructions of the offered tools after it, a blank line before each: what
a tool adds to the prompt, which is only ever added. -/
def withInstructions (config : Config) (text : String) : String :=
  (config.offered).foldl (init := text) fun text tool =>
    match tool.instruction? with
    | some instruction => text ++ "\n\n" ++ instruction
    | none => text

/-- The opening of a conversation: the system prompt and the task. -/
def openingMessages (config : Config) (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system systemMessage,
    .user (withInstructions config
      (instanceMessage task uname.system uname.machine))]

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
def tools (config : Config) : Array Chat.ToolDefinition := config.offered.map (·.definition)

/-! ## Reading a response -/

/-- A parsed model turn: the calls to make, in order, or a format-error message to send back as
a user turn. -/
inductive Parsed where
  | calls (calls : Array Chat.ToolCall)
  | formatError (message : String)

/-- Reads a response's tool calls, each by the offered tool of its name; the first call with a
problem makes the turn a format error, and so does a tool that must be alone and is not. -/
def parseActions (response : Chat.Response) (config : Config := {}) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason? config
  let offered := config.offered
  if response.toolCalls.size != 1 then
    if let some tool := offered.find? fun tool =>
        tool.alone && response.toolCalls.any (·.name == tool.name) then
      return .formatError <| formatErrorMessage s!"{tool.name} must be called alone."
        true response.finishReason? config
  for call in response.toolCalls do
    let problem? : Option String :=
      if let some raw := call.invalidArguments? then
        some ("Error parsing tool call arguments: " ++
          (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
      else match offered.find? (·.name == call.name) with
        | some tool => match tool.check call.arguments with
          | .ok () => none
          | .error problem => some problem
        | none => some s!"Unknown tool '{call.name}'."
    if let some problem := problem? then
      return .formatError (formatErrorMessage problem true response.finishReason? config)
  return .calls response.toolCalls

/-! ## The conversation -/

/-- One thing a conversation holds: a message told, the model's turn with each of its calls and
what the call gave, or a malformed response, which the model is shown as the format error. -/
inductive Item where
  | told (message : Chat.Message)
  | turn (response : Chat.Response) (results : Array (Chat.ToolCall × Json))
  | malformed (message : String)

/-- The state of the loop: the conversation, and what mini's limits count. -/
structure History where
  items : Array Item := #[]
  /-- The latest request whose response reported its size: its messages, the tokens it held,
  and the tokens of the response. -/
  measured? : Option (Dialogue × Nat × Option Nat) := none
  /-- Malformed responses since the last well-formed one. A person's message in between does
  not reset the count. -/
  formatErrors : Nat := 0

/-- How many turns from the first are omitted when the conversation holds `turns`: none until
the boundary first moves, then a multiple of `block`. -/
def Masking.omittedTurns (m : Masking) (turns : Nat) : Nat :=
  if turns < m.keepTurns + m.block then 0 else ((turns - m.keepTurns) / m.block) * m.block

/-- How the view shows a command's output: whole, cut to its head and tail, or omitted. -/
private inductive Shown where
  | whole | cut | omitted

private def shown (omittedTurn : Bool) (file? : Option String) (o : Output) : Shown :=
  match file? with
  -- An output no longer than the notice is cheaper to keep, and one with no file cannot go.
  | some file =>
    if omittedTurn && o.output.length > (Tools.Bash.omittedNotice file).length then .omitted
    else if o.output.length < outputLimit then .whole else .cut
  | none => if o.output.length < outputLimit then .whole else .cut

/-- What the model is shown of a call's result: a command's output as
`Tools.Bash.observation`, which with `recoverOutput` names the file a cut output is in, or, in a
turn masking omits, as `Tools.Bash.omitted`; any other result as JSON. -/
private def resultMessage (config : Config) (omittedTurn : Bool) (call : Chat.ToolCall)
    (result : Json) : Chat.Message :=
  let content : Json := match call.name, Tools.Bash.ofResult? result with
    | "bash", some (output, file?) =>
      match shown omittedTurn file? output, file? with
      | .omitted, some file => Tools.Bash.omitted output file
      | _, _ => Tools.Bash.observation output outputLimit (if config.recoverOutput then file? else none)
    | _, _ => result
  .tool call.id (.str content.pretty)

/-- The view: what is told as it is, a turn as the response and its calls' results, a malformed
response as the format error, as a user turn. -/
def view (config : Config) (history : History) : Dialogue := Id.run do
  let turns := history.items.foldl (init := 0) fun n item =>
    match item with | .told _ => n | _ => n + 1
  let omitted := config.masking?.map (·.omittedTurns turns) |>.getD 0
  let mut messages : Dialogue := #[]
  let mut turn := 0
  for item in history.items do
    match item with
    | .told message => messages := messages.push message
    | .malformed message =>
      turn := turn + 1
      messages := messages.push (.user message)
    | .turn response results =>
      turn := turn + 1
      messages := messages.push response.message
      for (call, result) in results do
        messages := messages.push (resultMessage config (omitted > 0 && turn ≤ omitted) call result)
  return messages

/-- The request of a model turn: the view, with the tools. -/
def request (config : Config) (history : History) : Chat.Request :=
  { messages := view config history, tools := tools config }

/-- The tokens of a request with `dialogue`, estimated at four characters a token of its JSON. -/
def estimateTokens (dialogue : Dialogue) : Nat :=
  (dialogue.foldl (fun n m => n + m.toJson.compress.length) 0 + 3) / 4

/-- The tokens `full`, the messages of the next request, holds, known without a tokenizer. The
latest response that reported its size says how many the request it answered held, and how many
it returned; what `full` holds after that request and the message that shows the response is
estimated. When `full` no longer begins with that request, as when old outputs have since been
masked, or nothing reported a size, the whole is estimated. -/
def contextTokens (history : History) (full : Dialogue) : Nat :=
  let wire (dialogue : Dialogue) := dialogue.map (·.toJson.compress)
  match history.measured? with
  | none => estimateTokens full
  | some (before, input, output?) =>
    if before.size < full.size && wire (full.extract 0 before.size) == wire before then
      let response := output?.getD (estimateTokens (full.extract before.size (before.size + 1)))
      input + response + estimateTokens (full.extract (before.size + 1) full.size)
    else estimateTokens full

/-- How the agent ends: a status, what it submitted, and, where the status alone does not say,
why. -/
def outcome (status : String) (submission : String := "") (reason? : Option String := none) : Json :=
  .mkObj ([("status", (status : Json)), ("submission", (submission : Json))] ++
    (reason?.map fun reason => ("reason", (reason : Json))).toList)

/-- What a notice tells the model: a person's message, or a change a person made to the
workspace, in an envelope that says it came from a person while the agent was paused. A notice
addressed to another reader — a reply, a grader — tells it nothing, and no read of the agent's
takes one. -/
def noticeMessage : Notice → Option Chat.Message
  | .said message =>
    some (.user s!"<intervention>\nA person sent you a message while you were paused.\n{message}\n</intervention>")
  | .changed _ summary =>
    some (.user s!"<intervention>\nA person changed the workspace while you were paused:\n{summary}\n</intervention>")
  | .replied .. | .assigned _ => none

/-- The conversation with what has arrived since the last read of the inbox. -/
def listen (history : History) : Program Agent History := do
  let heard ← inbox
  return { history with items := history.items ++ (heard.toArray.filterMap noticeMessage).map .told }

/-- One round of mini's loop (`DefaultAgent.run`): read the inbox, so that what a person said
or changed while the run was paused reaches the model in this round's request; stop before a
request too large for the model's context; sample, and stop the same way
when the provider refuses the request as too long, which is the one failure of a sample the
driver answers with; answer a malformed response with the format error, and stop after too many in a row; otherwise call each tool in
order, a `submit` ending the agent with its message. A tool that fails gives its error as its
result. -/
def round (config : Config) (history : History) : Program Agent (History ⊕ Json) := do
  let history ← listen history
  let request := request config history
  if let some limit := config.contextLimit? then
    if contextTokens history request.messages >= limit then return .inr (outcome "ContextExceeded")
  let response ← try sample request
    catch refusal =>
      return .inr (outcome "ContextExceeded" (reason? := some s!"the provider refused the request: {refusal}"))
  let measured? := match response.usage?.bind (·.input?) with
    | some input => some (request.messages, input, response.usage?.bind (·.output?))
    | none => history.measured?
  let history := { history with measured? }
  match parseActions response config with
  | .formatError message =>
    let history := { history with items := history.items.push (.malformed message)
                                  formatErrors := history.formatErrors + 1 }
    if config.maxConsecutiveFormatErrors > 0 && history.formatErrors >= config.maxConsecutiveFormatErrors then
      return .inr (outcome "RepeatedFormatError")
    return .inl history
  | .calls calls =>
    let mut results : Array (Chat.ToolCall × Json) := #[]
    for asked in calls do
      if asked.name == Tools.Submit.definition.name then
        return .inr (outcome "Submitted" (Tools.Submit.message asked.arguments))
      let result ← try call asked.name asked.arguments
        catch error => pure (.mkObj [("error", .str error)])
      results := results.push (asked, result)
    return .inl { history with items := history.items.push (.turn response results), formatErrors := 0 }

/-- An agent with mini's loop: it waits for its task, a notice from a person, opens the
conversation with `opening` of it, and goes round until it ends. A second notice that arrives
with the task is told as any later one. -/
def converse (config : Config) (opening : String → Array Chat.Message) : Program Agent Json := do
  let notices ← await fun _ notice => notice matches .said _
  let (task, later) := match notices with
    | .said task :: later => (task, later)
    | _ => ("", notices)
  let history : History :=
    { items := (opening task).map .told ++ (later.toArray.filterMap noticeMessage).map .told }
  iter (round config) history

/-- The tokens a request to `model` may hold under `config`: its context less the room kept for
a response; `none` when its context is not known. -/
def contextLimit? (config : Config) (model : Models.Spec) : Option Nat :=
  model.contextTokens?.map fun tokens =>
    tokens - min config.contextReserve (model.outputTokens?.getD config.contextReserve)

/-- The mini agent, for a run of `model` on a machine described by `uname`. -/
def program (config : Config) (model : Models.Spec) (uname : Uname) : Program Agent Json :=
  converse { config with contextLimit? := contextLimit? config model } (openingMessages config · uname)

end Alaya.Agents.MiniSwe
