import Alaya.Agents.Tools
import Alaya.LLM.Models
import Alaya.Base.Fields

/-! The basic agent: a model with `bash` and `submit`, as simple as an agent can be and still
robust. Every tool call is answered: with its result, or with why it was not made. A response
with no tool call is answered with a reminder. Nothing but `submit` and a provider's refusal
ends it; how long it may run is the driver's to bound. A command's output is shown as its end,
as pi shows it, and the whole of it is kept in a file the model can read. The pieces an agent
built on it needs are public. See `docs/agents.md` §4. -/

namespace Alaya.Agents.Basic

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-! ## Configuration -/

/-- How it runs a command: a five-minute limit, and no overrides. -/
def defaultExecutor : Executor.Config := { timeoutSeconds := 300 }

/-- What every agent's configuration holds: the model, the task, and how commands run. -/
structure Common where
  /-- The model it samples: its complete spec. There is no default: whoever calls the agent
  names one. -/
  model? : Option Models.Spec := none
  /-- The task, verbatim. There is no default: whoever calls the agent gives one. -/
  task? : Option String := none
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  deriving Inhabited

/-- The basic agent's configuration: the common fields, and the kinds of question `ask_user`
lets the model ask; none, the default, offers no `ask_user`. -/
structure Config extends Common where
  questionTypes : Array Question.Kind := #[]
  deriving Inhabited

/-- How commands run, as a configuration holds it: their time limit, and their environment. -/
def executorFields : Fields Executor.Config := #[
  .of "timeout_seconds" .nat (·.timeoutSeconds) fun v e => { e with timeoutSeconds := v },
  .of "env" .pairs (·.env) fun v e => { e with env := v }]

/-- The fields every agent's configuration has. -/
def commonFields : Fields Common := #[
  .of "model" (.option Models.Spec.codec) (·.model?) fun v c => { c with model? := v },
  .of "task" (.option .string) (·.task?) fun v c => { c with task? := v },
  .record "executor" executorFields (·.executor) fun v c => { c with executor := v }]

/-- Kinds of question, each named once. -/
def questionTypesCodec : Codec (Array Question.Kind) :=
  let kinds := Codec.array (.enum Question.Kind.name Question.Kind.all.toList)
  { kinds with read := fun json => do
      let read ← kinds.read json
      for kind in read do
        if (read.filter (· == kind)).size > 1 then throw s!"names {kind.name} twice"
      pure read }

/-- The fields of its configuration, which an agent built on it has too. -/
def fields : Fields Config :=
  commonFields.lift (·.toCommon) (fun b c => { c with toCommon := b }) ++ #[
  .of "question_types" questionTypesCodec (·.questionTypes) fun v c => { c with questionTypes := v }]

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Json := fields.toJson config

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Json) : Except String Config := fields.read json {}

/-- An agent's routine: its configuration read from a call's arguments, `fields` over
`defaults`, and its computation run on the model and the task the configuration names. A call
it cannot run on fails in the call's frame, saying why in the configuration's terms. -/
def agent (name : String) (fields : Fields σ) (defaults : σ) (base : σ → Common)
    (computation : σ → Models.Spec → String → Computation Agent Json) (scope : Scope Agent) : Routine Agent where
  name
  body arguments :=
    match fields.read arguments defaults with
    | .error problem => .fail (.refused s!"{name}: {problem}")
    | .ok config => match (base config).model?, (base config).task? with
      | some model, some task =>
        if task.trimAscii.isEmpty then .fail (.refused s!"{name}: its task is blank")
        else computation config model task
      | none, _ => .fail (.refused s!"{name}: it samples a model, and its configuration names none")
      | _, none => .fail (.refused s!"{name}: it works on a task, and its configuration names none")
  scope

/-! ## Commands and their output -/

/-- The most lines, and bytes, of an output the model is shown: pi's. -/
def maxLines : Nat := 2000
def maxBytes : Nat := 50 * 1024

/-- The lines of a text; a last newline ends the last line, and starts none. -/
def lines (text : String) : List String :=
  if text.isEmpty then [] else
    let all := text.splitOn "\n"
    if text.endsWith "\n" then all.dropLast else all

/-- The end of `line` that fits in `bytes`, whole characters only. -/
private def lastBytes (line : String) (bytes : Nat) : String := Id.run do
  let mut kept : List Char := []
  let mut size := 0
  for c in line.toList.reverse do
    if size + c.utf8Size > bytes then break
    kept := c :: kept
    size := size + c.utf8Size
  return String.ofList kept

/-- The end of an output the model is shown when the whole is too long: its last lines, as many
as fit in `maxLines` and `maxBytes`, or, when even the last line does not fit, the end of it. -/
structure Tail where
  text : String
  /-- The lines shown, and the lines of the whole. -/
  shown : Nat
  total : Nat
  /-- Whether `maxBytes` cut it, rather than `maxLines`. -/
  byBytes : Bool
  /-- Whether it is the end of one line too long to show whole. -/
  partialLine : Bool

/-- The end of `text` the model is shown, pi's `truncateTail`; `none` when it is shown whole. -/
def tail (text : String) : Option Tail := Id.run do
  let all := lines text
  if all.length ≤ maxLines && text.utf8ByteSize ≤ maxBytes then return none
  let mut kept : List String := []
  let mut count := 0
  let mut bytes := 0
  let mut byBytes := false
  let mut partialLine := false
  for line in all.reverse do
    if count ≥ maxLines then break
    let size := line.utf8ByteSize + (if count == 0 then 0 else 1)
    if bytes + size > maxBytes then
      byBytes := true
      if count == 0 then
        kept := [lastBytes line maxBytes]
        count := 1
        partialLine := true
      break
    kept := line :: kept
    count := count + 1
    bytes := bytes + size
  return some { text := "\n".intercalate kept, shown := count, total := all.length, byBytes, partialLine }

/-- How a command ended, when it did not end well: what went wrong, or its exit code. -/
def status (o : Output) : Option String :=
  match o.error?, o.exitCode? with
  | some error, _ => some error
  | none, some 0 => none
  | none, some code => some s!"Command exited with code {code}"
  | none, none => some "Command ended without an exit code"

/-- `text`, then `status` after a blank line, when there is one. -/
def withStatus (o : Output) (text : String) : String :=
  match status o with
  | none => text
  | some status => if text.isEmpty then status else text ++ "\n\n" ++ status

/-- How the model sees a command, as pi shows it: its output, or its end with a note that says
which lines are shown and names the file that holds the whole; then how it ended, when it did
not end well. -/
def observation (o : Output) (file? : Option String) : String :=
  let whole := match file? with
    | some file => s!" Full output: {file}"
    | none => ""
  let text := match tail o.output with
    | none => o.output
    | some t =>
      let note :=
        if t.partialLine then s!"[Showing the end of line {t.total}, which is too long to show whole.{whole}]"
        else
          let range := s!"lines {t.total - t.shown + 1}-{t.total} of {t.total}"
          if t.byBytes then s!"[Showing {range} ({maxBytes / 1024}KB limit).{whole}]"
          else s!"[Showing {range}.{whole}]"
      t.text ++ "\n\n" ++ note
  match status o with
  | none => if text.isEmpty then "(no output)" else text
  | some _ => withStatus o text

/-! ## The loop

Each round reads what a person said, samples a response, and answers every tool call in it:
with the call's result, or with why it was not made. A response with no tool call is answered
with a reminder. The run ends at `submit`. -/

/-- The context a sample is conditioned on. -/
abbrev Dialogue := Array Chat.Message

/-- The tools it offers: `bash`, each command's output kept as a file; `submit`; and `ask_user`,
for the kinds of question its configuration names. -/
def tools (config : Config) : Array Tool :=
  #[Tools.Bash.tool { config.executor with outputs := true }, Tools.Submit.tool] ++
    (if config.questionTypes.isEmpty then #[] else #[Tools.AskUser.tool config.questionTypes])

/-- `text` with the instructions of `tools` after it, a blank line before each: what a tool adds
to the prompt, which is only ever added. -/
def withInstructions (tools : Array Tool) (text : String) : String :=
  tools.foldl (init := text) fun text tool =>
    match tool.instruction? with
    | some instruction => text ++ "\n\n" ++ instruction
    | none => text

/-- The system message, which names the machine the commands run on: its system and its
architecture, as `uname -sm` reads them. -/
def systemMessage (uname : Uname) : String :=
  "You are an agent working on a task in a repository. You act only through tools: run shell " ++
  "commands with bash, and when the task is done, call submit, alone. Every response must call " ++
  "a tool. Each command runs in a new shell at the repository's root, so a cd or an exported " ++
  "variable does not last to the next command. A long output is cut to its end; the note after " ++
  s!"it names a file that holds all of it. The commands run on {uname.system} {uname.machine}."

/-- The opening of a conversation: the system message, with what its tools add, and the task. -/
def openingMessages (config : Config) (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system (withInstructions (tools config) (systemMessage uname)), .user task]

/-- What a call is answered with: its routine's result, or why it was not made, or how its
routine failed. -/
abbrev Answer := Except String Json

/-- One thing a conversation holds: a message told, or the model's turn with the answer to each
of its calls. -/
inductive Item where
  | told (message : Chat.Message)
  | turn (response : Chat.Response) (answers : Array (Chat.ToolCall × Answer))

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

/-- What has arrived since the last read of the inbox, as the model is told it. -/
def heard : Computation Agent (Array Chat.Message) := do
  return (← inbox).toArray.filterMap noticeMessage

/-- What a response with no tool call is answered with. -/
def reminder (response : Chat.Response) : String :=
  if response.finishReason? == some "length" then
    "Your response hit the output token limit before any tool call. Respond more briefly, and call a tool."
  else "Your response called no tool. Call a tool: run a command with bash, or call submit when the task is done."

/-- What the model is told of a call that failed: why its routine refused it, or that a person
stopped it. -/
def failureMessage : Failure → String
  | .broken reason => s!"A person stopped this call: {reason}"
  | failure => failure.reason

/-- Why a call of `response` is not made, if it is not: the response was cut off, so its
arguments may be too; it calls, beside others, a tool that must be alone; or the call itself
has a problem. -/
def problem? (tools : Array Tool) (response : Chat.Response) (call : Chat.ToolCall) : Option String :=
  if response.finishReason? == some "length" then
    some s!"Tool call \"{call.name}\" was not made: the response hit the output token limit, so its arguments may be cut off. Call the tool again with complete arguments."
  else match Tools.lone? tools response with
    | some tool => some s!"{tool.name} must be called alone: no call of this response was made."
    | none => Tools.callProblem? tools call

/-- The conversation after `response`, or how the agent ends: each call is answered in order,
a call with a problem by the problem, and a `submit` ends the agent with its message. A response
with no tool call is kept when it says something, and answered with a reminder. -/
def respond (tools : Array Tool) (items : Array Item) (response : Chat.Response) :
    Computation Agent (Array Item ⊕ Json) := do
  if response.toolCalls.isEmpty then
    let said := response.content?.any (!·.trimAscii.isEmpty)
    let items := if said then items.push (.turn response #[]) else items
    return .inl (items.push (.told (.user (reminder response))))
  let mut answers : Array (Chat.ToolCall × Answer) := #[]
  for asked in response.toolCalls do
    match problem? tools response asked with
    | some problem => answers := answers.push (asked, .error problem)
    | none =>
      if asked.name == Tools.Submit.definition.name then
        return .inr (outcome "Submitted" (Tools.Submit.message asked.arguments))
      answers := answers.push (asked, (← Tools.make tools asked).mapError failureMessage)
  return .inl (items.push (.turn response answers))

/-- The messages of a conversation: what is told as it is, and a turn as the response and a
tool message for each call, its result as `shown` gives it with the turn's number, from 1, and
a call not made or failed as its problem. -/
def viewWith (shown : Nat → Chat.ToolCall → Json → String) (items : Array Item) : Dialogue := Id.run do
  let mut messages : Dialogue := #[]
  let mut turn := 0
  for item in items do
    match item with
    | .told message => messages := messages.push message
    | .turn response answers =>
      turn := turn + 1
      messages := messages.push response.message
      for (call, answer) in answers do
        let text := match answer with
          | .ok result => shown turn call result
          | .error problem => problem
        messages := messages.push (.tool call.id (.str text))
  return messages

/-- A call's result as the model sees it: a command's as its `observation`, a text as it is, and
any other as JSON. -/
def shown (call : Chat.ToolCall) (result : Json) : String :=
  match call.name, Tools.Bash.ofResult? result, result with
  | "bash", some (output, file?), _ => observation output file?
  | _, _, .str text => text
  | _, _, _ => result.pretty

/-- Every turn, each call's result as `shown`. -/
def view (items : Array Item) : Dialogue :=
  viewWith (items := items) fun _ call result => shown call result

/-- One round: read the inbox, so that what a person said while the run was paused reaches the
model in this round's request; sample, and end when the provider refuses the request as too
long; then answer the response. -/
def round (config : Config) (model : Models.Spec) (items : Array Item) : Computation Agent (Array Item ⊕ Json) := do
  let items := items ++ (← heard).map .told
  let request : Chat.Request := { messages := view items, tools := (tools config).map (·.definition) }
  let response ← try sample model request catch
    | .refused refusal => return .inr (refused refusal)
    | failure => throw failure
  respond (tools config) items response

/-! ## The agent -/

/-- The basic agent, for a call of `model` on `task`, on the machine the call names. -/
def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Json := do
  -- The opening names the machine the commands run on, as the container says.
  let uname ← Tools.Uname.read
  iter (round config model) ((openingMessages config task uname).map .told)

/-- The basic agent as a routine. Its scope is its tools' routines. -/
def routine : Routine Agent :=
  agent "basic" fields {} (·.toCommon) computation (Scope.of #[Tools.Bash.routine, Tools.AskUser.routine])

end Alaya.Agents.Basic
