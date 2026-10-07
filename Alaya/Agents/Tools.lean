import Alaya.Runtime.Agent
import Alaya.Base.Fields

/-!
The tools an agent can offer, each described once, as a `Tool.Spec`: what a model needs to call
it, its arguments read into a value of its own, the routine call that value makes, and the
routine's result, how it is written and read back. Only the routine checks arguments: it reads
its own with its tool's `read`, whoever made the call, a model, the log or another program, and
a call it cannot read fails its frame. The agent makes each call as the model gave it, with its
own settings added, and answers a call that failed with the failure. The schema is what the model
is told. See `docs/agents.md` §1.

The routines are `routines`, each fixed, its computation answering a call: a command run in the
workspace, a question for a person, the time left. What the agent's configuration says of a call
is in the call's arguments, so it is in the log with them. A tool is called by its name, like any
routine, so it runs in a frame of its own, and the log brackets it. `submit` calls no routine: an
agent that offers it ends with its message.
-/

namespace Alaya.Agents

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-- A tool, described once: its arguments read into `α`, and its routine's result, `β`. A tool
only adds to the prompt, never rewrites it: what it needs the model to know is its
`instruction?`, appended after the agent's own text. -/
structure Tool.Spec (α β : Type) where
  /-- Its name, description and schema, for a model. -/
  definition : Chat.ToolDefinition
  /-- Must be the only call of its turn. -/
  alone : Bool := false
  /-- What the model is told of the tool beyond its definition, appended to the prompt. -/
  instruction? : Option String := none
  /-- Its routine's arguments, or what is wrong with them: the one check of a call. It reads any
  JSON, the agent's settings among it. -/
  read : Json → Except String α
  /-- The routine call a model's arguments make: the agent's settings added, and nothing
  checked. -/
  call : Json → RoutineCall
  /-- How the routine's result is written, and read back. -/
  result : Codec β

/-- A routine's own arguments read with its tool's `read`; arguments it cannot read fail its
frame. -/
def Tool.Spec.arguments (spec : Tool.Spec α β) (arguments : Json) : Computation Agent α :=
  match spec.read arguments with
  | .ok value => pure value
  | .error problem => throw problem

/-- A tool as an agent offers it, whatever its types. -/
structure Tool where
  definition : Chat.ToolDefinition
  alone : Bool
  instruction? : Option String
  /-- The routine call the model's arguments make. -/
  call : Json → RoutineCall

def Tool.Spec.tool (spec : Tool.Spec α β) : Tool where
  definition := spec.definition
  alone := spec.alone
  instruction? := spec.instruction?
  call := spec.call

def Tool.name (tool : Tool) : String := tool.definition.name

/-- How an agent ends: a status, what it submitted, and, where the status alone does not say,
why. It is the result of a call of an agent, a sub-agent's among them. -/
structure Outcome where
  status : String
  submission : String := ""
  reason? : Option String := none
  deriving BEq, Repr, Inhabited

/-- An outcome as JSON, with no `reason` when there is none. -/
def Outcome.codec : Codec Outcome where
  write outcome := .mkObj ([("status", (outcome.status : Json)), ("submission", (outcome.submission : Json))] ++
    (outcome.reason?.map fun reason => ("reason", (reason : Json))).toList)
  read json := do
    let text (key : String) := (json.getObjVal? key >>= Json.getStr?).toOption
    let some status := text "status" | throw s!"must be an agent's outcome, not {json.compress}"
    pure { status, submission := (text "submission").getD "", reason? := text "reason" }

namespace Tools

/-- Why a tool call cannot be made at all, if it cannot: its arguments are not JSON, or it names
no tool offered. Whether its arguments are right is its routine's to say. -/
def callProblem? (tools : Array Tool) (call : Chat.ToolCall) : Option String :=
  if let some raw := call.invalidArguments? then
    some ("Error parsing tool call arguments: " ++
      (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
  else if tools.any (·.name == call.name) then none
  else some s!"Unknown tool '{call.name}'."

/-- The tool that must be alone in a response with other calls, if any. -/
def lone? (tools : Array Tool) (response : Chat.Response) : Option Tool :=
  if response.toolCalls.size ≤ 1 then none
  else tools.find? fun tool => tool.alone && response.toolCalls.any (·.name == tool.name)

/-- Makes the call a model's tool call asks for: the routine call its tool makes of the model's
arguments. Gives its result, or its error when it fails, as when it cannot read its arguments. -/
def make (tools : Array Tool) (asked : Chat.ToolCall) : Computation Agent (Except String Json) := do
  let some tool := tools.find? (·.name == asked.name) | return .error s!"Unknown tool '{asked.name}'."
  let made := tool.call asked.arguments
  try .ok <$> call made.name made.arguments
  catch error => pure (.error error)

/-! ## bash: a command in the workspace -/

namespace Bash

def definition : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
}

/-- A command's result, as its call gives it: the whole output, how it ended, and the file a
later command finds the output in, when the command was run so. What a model is shown of it is
its agent's to say. -/
structure Result where
  output : Output
  file? : Option String := none

def result : Codec Result where
  write r := .mkObj [("output", r.output.output),
    ("exit_code", r.output.exitCode?.map (fun c => Json.num c.toNat) |>.getD .null),
    ("error", r.output.error?.map Json.str |>.getD .null),
    ("file", r.file?.map Json.str |>.getD .null)]
  read json := match Output.fromJson? json with
    | some output => pure { output, file? := (json.getObjVal? "file" >>= Json.getStr?).toOption }
    | none => throw s!"must be a command's result, not {json.compress}"

/-- The model's command, run as `config` says: how a command runs is the agent's policy, not the
model's. -/
def spec (config : Executor.Config := {}) : Tool.Spec String Result where
  definition
  read arguments := (arguments.getObjVal? "command" >>= Json.getStr?).mapError fun _ =>
    "The bash tool takes its command as a string."
  call arguments := { name := definition.name, arguments := arguments.setObjVal! "executor" config.toJson }
  result

def tool (config : Executor.Config := {}) : Tool := (spec config).tool

/-- Runs the command in the workspace, as the call's `executor` says, or as an executor does by
default. A command that exits with an error is no failure of the routine: its status is in the
result. -/
def routine : Routine Agent := {
  name := definition.name
  body := fun arguments => do
    let command ← (spec).arguments arguments
    let config ← match arguments.getObjVal? "executor" with
      | .error _ => pure {}
      | .ok json => match Executor.Config.fromJson json with
        | .ok config => pure config
        | .error problem => throw s!"bash: its executor: {problem}"
    let ran ← exec command config
    return result.write { output := ran.output, file? := ran.file? }
  scope := .empty }

end Bash

/-! ## submit: the end of a run -/

namespace Submit

def definition : Chat.ToolDefinition := {
  name := "submit"
  description := "Finish the task. Call this once your changes are complete; nothing runs after it."
  parameters := .object #[("message", .string (description? := some "A short summary of what you did"))]
}

/-- Ends the agent, its message the submission; alone in its turn, so that nothing is left
unmade. An agent that offers it ends at the call and reads the message itself, as it calls no
routine; a message that is not a string submits nothing. It has no result. -/
def spec : Tool.Spec String Unit where
  definition
  alone := true
  read arguments := pure ((arguments.getObjVal? "message" >>= Json.getStr?).toOption.getD "")
  call arguments := { name := definition.name, arguments }
  result := { write := fun () => .null, read := fun _ => pure () }

def tool : Tool := spec.tool

end Submit

/-! ## ask_user: a question a model asks a person

The tool is a model's way to `ask` (`Alaya.Core.Computation`), and nothing more. What a question is,
which replies fit it, and how a person gives one are not the tool's. The tool's are the words
and the schema a model is given, which kinds of question it may ask, and how a reply is shown
to it. -/

namespace AskUser

open Question (Kind)

/-- The kinds, in the order questions are always named in. -/
private def ordered (kinds : Array Kind) : List Kind :=
  Kind.all.toList.filter kinds.contains

/-- What the model is told of the tool beyond its definition, for the kinds it may ask: only
what the schema cannot say, and nothing of what to ask or how to treat the answer, which is the
agent's, or the experiment's, to say. -/
def instruction (kinds : Array Kind) : String :=
  "You may ask the person a question with ask_user. Give enough context to answer it." ++
  (if !kinds.contains .singleChoice then "" else
    " A single_choice question needs at least two distinct options; the person may also answer " ++
    "None of the above, so do not list it yourself.")

/-- The tool as a model is offered it, for the kinds of question it may ask: what each kind's
answer is, `question_type` naming one of the kinds, and `options` there only when a choice is
among them. -/
def definition (kinds : Array Kind) : Chat.ToolDefinition :=
  let kinds := ordered kinds
  let answers := "; ".intercalate <| kinds.map fun
    | .yesNo => "yes or no for yes_no"
    | .singleChoice => "the chosen option's number (from 1) or none_of_above for single_choice"
    | .openEnded => "the person's own words for open_ended"
  let others := (kinds.filter (· != .singleChoice)).map (·.name)
  { name := "ask_user"
    description := s!"Ask the person a question and wait for the answer. The answer is {answers}. " ++
      "If the person cannot answer, the result is {\"status\": \"unavailable\"}. Call this tool alone."
    parameters := .object (#[
      ("question_type", .string (description? := some "The kind of answer the question asks for")
        (enum := (kinds.map (·.name)).toArray)),
      ("question", .string (description? := some "The question, with enough context to answer it"))] ++
      (if !kinds.contains .singleChoice then #[] else #[
      ("options", .array (.string) (description? := some (
        "The answers to choose from" ++
        (if others.isEmpty then "." else s!", for single_choice; an empty array for {" and ".intercalate others}."))))])) }

/-- The kinds of question a call may ask, as the agent's tool adds them to its arguments: every
kind, for a call no agent's tool made. -/
def kinds (arguments : Lean.Json) : Except String (Array Kind) :=
  match arguments.getObjVal? "question_types" with
  | .error _ => pure Kind.all
  | .ok json => (Codec.array (.enum Kind.name Kind.all.toList)).read json |>.mapError
      (s!"The ask_user tool's question_types {·}.")

/-- Reads the question of a call's arguments, or says what is wrong with it: its kind is one the
call may ask, only a choice has options, and the question is one that can be asked
(`Question.validate`). Options left out are none. It does not judge whether an option is true. -/
def read (arguments : Lean.Json) : Except String Question := do
  let kinds ← kinds arguments
  let text ← (arguments.getObjVal? "question" >>= Lean.Json.getStr?).mapError fun _ =>
    "The ask_user tool takes its question as a string."
  let options ← match arguments.getObjVal? "options" with
    | .ok options => (options.getArr? >>= (·.mapM Lean.Json.getStr?)).mapError fun _ =>
      "The ask_user tool takes its options as an array of strings."
    | .error _ => pure #[]
  let noOptions : Except String Unit :=
    if options.isEmpty then pure ()
    else throw "Options must be empty for yes_no and open_ended."
  let kind? := (arguments.getObjVal? "question_type" >>= Lean.Json.getStr?).toOption.bind Kind.ofName?
  let form ← match kind?.filter kinds.contains with
    | some .singleChoice => pure (Question.Form.singleChoice options)
    | some .yesNo => noOptions *> pure .yesNo
    | some .openEnded => noOptions *> pure .openEnded
    | none => throw s!"The ask_user tool takes a question_type: {" or ".intercalate ((ordered kinds).map (·.name))}."
  let question : Question := { text, form }
  question.validate
  pure question

/-- What a call gives for a reply, and so what the model is shown as its result: `"yes"` or
`"no"`, the option's number, `"none_of_above"`, the person's text, or the object
`{"status": "unavailable"}`. Read back, a text that reads as another reply reads as that reply:
the result is what the model is shown, and the question is not part of it. -/
def result : Codec Reply where
  write
    | .yes => "yes"
    | .no => "no"
    | .choice number => (number : Json)
    | .noneOfAbove => "none_of_above"
    | .text words => .str words
    | .unavailable => .mkObj [("status", "unavailable")]
  read
    | .str "yes" => pure .yes
    | .str "no" => pure .no
    | .str "none_of_above" => pure .noneOfAbove
    | .str words => pure (.text words)
    | json@(.num _) => match json.getNat? with
      | .ok number => pure (.choice number)
      | .error _ => throw s!"must be a reply, not {json.compress}"
    | json => match json.getObjVal? "status" >>= Json.getStr? with
      | .ok "unavailable" => pure .unavailable
      | _ => throw s!"must be a reply, not {json.compress}"

/-- Asks a person, and waits; alone in its turn. `kinds` are the kinds of question the model may
ask, chosen by whoever configures the agent: the tool is offered with at least one, and adds
them to every call, so that its routine refuses another kind before anything is asked. -/
def spec (kinds : Array Kind) : Tool.Spec Question Reply where
  definition := definition kinds
  alone := true
  instruction? := some (instruction kinds)
  read
  call arguments :=
    let allowed : Json := .arr ((ordered kinds).toArray.map fun kind => .str kind.name)
    { name := "ask_user", arguments := arguments.setObjVal! "question_types" allowed }
  result

def tool (kinds : Array Kind) : Tool := (spec kinds).tool

/-- Asks a person the question, of any kind, and waits. -/
def routine : Routine Agent := {
  name := "ask_user"
  body := fun arguments => do
    let question ← (spec Kind.all).arguments arguments
    return result.write (← ask question)
  scope := .empty }

end AskUser

/-! ## time_budget: how long the run has left -/

namespace TimeBudget

def definition : Chat.ToolDefinition := {
  name := "time_budget"
  description := "How many seconds of this run's time budget are left. Use it, not `date`, " ++
    "to pace yourself: the run may be resumed from a checkpoint, and the clock is not the budget."
  parameters := .object #[]
}

/-- What a `time_budget` call gives: the whole seconds left, or that there is no limit. -/
def result : Codec (Option Nat) where
  write
    | some seconds => .mkObj [("seconds_left", seconds)]
    | none => .mkObj [("seconds_left", .null), ("note", "this run has no time limit")]
  read json := match json.getObjVal? "seconds_left" with
    | .ok .null => pure none
    | .ok seconds => some <$> (seconds.getNat?.mapError fun _ => s!"must be the seconds left, not {json.compress}")
    | .error _ => throw s!"must be the seconds left, not {json.compress}"

def instruction : String :=
  "You may call time_budget to see how many seconds of this run's time budget are left."

/-- The time left; it takes no arguments. -/
def spec : Tool.Spec Unit (Option Nat) where
  definition
  instruction? := some instruction
  read _ := pure ()
  call arguments := { name := definition.name, arguments }
  result

def tool : Tool := spec.tool

/-- Times the run, and says what it leaves of the budget: the budget less the run's time, never
negative. -/
def routine : Routine Agent := {
  name := definition.name
  body := fun arguments => do
    spec.arguments arguments
    let timing ← time
    return result.write (timing.budgetMs?.map fun budget => (budget - timing.spentMs) / 1000)
  scope := .empty }

end TimeBudget

/-! ## uname: the machine, which an agent reads for its opening -/

namespace Uname

/-- The command, and how its output reads: the system and the architecture, on one line. The
kernel's release and version are left out: a container has its host's kernel. -/
def command : String := "uname -sm"

def parse (output : String) : Except String Alaya.Runtime.Uname :=
  match (output.trimAscii.toString.splitOn " ").filter (!·.isEmpty) with
  | [system, machine] => .ok { system, machine }
  | _ => .error s!"uname: unexpected output: {output}"

/-- The system and architecture the call's commands run on, as the container says: a command in
the frame of whoever reads it, and no call. -/
def read : Computation Agent Alaya.Runtime.Uname := do
  let ran ← exec command
  match ran.output.exitCode?, parse ran.output.output with
  | some 0, .ok uname => pure uname
  | _, .error problem => throw problem
  | _, _ => throw s!"uname: {ran.output.output}"

end Uname

/-! ## subagent: the agent itself, on a task of the model's -/

namespace Subagent

def definition : Chat.ToolDefinition := {
  name := "subagent"
  description := "Delegate a self-contained task to a sub-agent like you. It works in the same " ++
    "workspace, from a conversation of its own that holds only the task, and gives back how it ended."
  parameters := .object #[("task", .string (description? := some "The task, complete: the sub-agent sees nothing else"))]
}

/-- The task of a call, or that it is not a string, or blank. -/
def task (arguments : Lean.Json) : Except String String := do
  let task ← (arguments.getObjVal? "task" >>= Lean.Json.getStr?).mapError fun _ =>
    "The subagent tool takes its task as a string."
  if task.trimAscii.isEmpty then throw "The 'task' argument of the subagent tool is empty."
  pure task

def instruction : String :=
  "You may call subagent to hand a self-contained part of the work to a sub-agent like you; " ++
  "it has its own conversation, so say everything it needs in the task."

/-- A call of the agent `name` with the configuration `config`, the agent that offers the tool,
on the model's task: the agent itself, with another task, in its own scope, so the sub-agent
offers the same tools, this one among them. It runs where its caller's commands do, and gives
how it ended. Its routine is the agent, which reads the task with the rest of its configuration:
`read` says what it refuses. -/
def spec (name : String) (config : Json) : Tool.Spec String Outcome where
  definition
  instruction? := some instruction
  read := task
  call arguments := { name, arguments := config.setObjVal! "task" ((arguments.getObjVal? "task").toOption.getD .null) }
  result := Outcome.codec

def tool (name : String) (config : Json) : Tool := (spec name config).tool

end Subagent

/-- The routines the tools call, but an agent's own: each fixed, what an agent's configuration
says of a call coming in its arguments. -/
def routines : Array (Routine Agent) := #[Bash.routine, AskUser.routine, TimeBudget.routine]

end Tools

end Alaya.Agents
