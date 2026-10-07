import Alaya.Runtime.Agent

/-!
The tools an agent can offer, each as a `Tool`: what a model needs to call it, the routine a call
of it calls, and the settings the agent adds to every call. A tool is data; `make` makes a
model's call of one. Only the routine checks its arguments: it reads its own JSON, whoever made
the call, a model, the log or another program, and a call it cannot read fails its frame. The
agent answers each call with what the routine gave, its result or its failure, and shows it its
own way. The schema is what the model is told. See `docs/agents.md` §1.

The routines are `routines`, each fixed, its computation answering a call: a command run in the
workspace, a question for a person, the time left. What the agent's configuration says of a call
is in the call's arguments, so it is in the log with them. A tool is called by its name, like any
routine, so it runs in a frame of its own, and the log brackets it. `submit` calls no routine: an
agent that offers it ends with its message.
-/

namespace Alaya.Agents

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-- A tool as an agent offers it. A tool only adds to the prompt, never rewrites it: what it
needs the model to know is its `instruction?`, appended after the agent's own text. -/
structure Tool where
  /-- Its name, description and schema, for a model. -/
  definition : Chat.ToolDefinition
  /-- Must be the only call of its turn. -/
  alone : Bool := false
  /-- What the model is told of the tool beyond its definition, appended to the prompt. -/
  instruction? : Option String := none
  /-- What the agent says of every call, merged over the model's arguments: how a command runs,
  which kinds of question may be asked. They win over the model's. -/
  settings : Json := .mkObj []

def Tool.name (tool : Tool) : String := tool.definition.name

/-- A call's arguments: the model's, with the tool's settings over them. -/
def Tool.arguments (tool : Tool) (given : Json) : Json :=
  match tool.settings, given with
  | .obj settings, .obj _ => settings.foldl (init := given) fun json key value => json.setObjVal! key value
  | _, _ => given

/-- `json`, an object, without the key `key`. -/
private def without (json : Json) (key : String) : Json :=
  match json with
  | .obj kvs => .mkObj (kvs.foldl (init := []) fun kept k v => if k == key then kept else kept ++ [(k, v)])
  | other => other

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

/-- Makes the call a model's tool call asks for: of the routine of its tool's name, with the
model's arguments and the tool's settings over them. Gives its result, or how it failed: refused,
as when it cannot read its arguments, or broken, when a person stopped it. A defect it does not
give: that fails the agent too. -/
def make (tools : Array Tool) (asked : Chat.ToolCall) : Computation Agent (Except Failure Json) := do
  let some tool := tools.find? (·.name == asked.name) | return .error (.refused s!"Unknown tool '{asked.name}'.")
  try .ok <$> call tool.name (tool.arguments asked.arguments)
  catch error => pure (.error error)

/-! ## bash: a command in the workspace -/

namespace Bash

def definition : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
}

/-- The command of a call, or what is wrong with its arguments. -/
def command (arguments : Json) : Except String String :=
  (arguments.getObjVal? "command" >>= Json.getStr?).mapError fun _ =>
    "The bash tool takes its command as a string."

/-- A command's result, as its call gives it: the whole output, how it ended, and the file a
later command finds the output in, when the command was run so. What a model is shown of it is
its agent's to say. -/
def result (execution : Execution) : Json :=
  .mkObj [("output", execution.output.output),
    ("exit_code", execution.output.exitCode?.map (fun c => Json.num c.toNat) |>.getD .null),
    ("error", execution.output.error?.map Json.str |>.getD .null),
    ("file", execution.file?.map Json.str |>.getD .null)]

/-- A command's result read back, for an agent to show it: its output, and where the whole of it
is. -/
def ofResult? (json : Json) : Option (Output × Option String) := do
  let output ← Output.fromJson? json
  pure (output, (json.getObjVal? "file" >>= Json.getStr?).toOption)

/-- Runs the command in the workspace, as the call's `executor` says, or as an executor does by
default. A command that exits with an error is no failure of the routine: its status is in the
result. -/
def routine : Routine Agent := {
  name := definition.name
  body := fun arguments => do
    let command ← match command arguments with
      | .ok command => pure command
      | .error problem => throw (.refused problem)
    let config ← match arguments.getObjVal? "executor" with
      | .error _ => pure {}
      | .ok json => match Executor.Config.fromJson json with
        | .ok config => pure config
        | .error problem => throw (.defect s!"bash: its executor: {problem}")
    return result (← exec command config)
  scope := .empty }

/-- The model's command, run as `config` says: how a command runs is the agent's policy, not the
model's. -/
def tool (config : Executor.Config := {}) : Tool :=
  { definition, settings := .mkObj [("executor", config.toJson)] }

end Bash

/-! ## submit: the end of a run -/

namespace Submit

def definition : Chat.ToolDefinition := {
  name := "submit"
  description := "Finish the task. Call this once your changes are complete; nothing runs after it."
  parameters := .object #[("message", .string (description? := some "A short summary of what you did"))]
}

/-- The submission of a call: its message, or nothing when that is not a string. -/
def message (arguments : Json) : String :=
  (arguments.getObjVal? "message" >>= Json.getStr?).toOption.getD ""

/-- Ends the agent, its message the submission; alone in its turn, so that nothing is left
unmade. An agent that offers it ends at the call and reads the message itself: it calls no
routine. -/
def tool : Tool := { definition, alone := true }

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
  | .ok (.arr names) => names.mapM fun
    | .str name => match Kind.ofName? name with
      | some kind => pure kind
      | none => throw s!"The ask_user tool's question_types names no kind {name}."
    | other => throw s!"The ask_user tool's question_types names no kind {other.compress}."
  | .ok other => throw s!"The ask_user tool's question_types must be an array, not {other.compress}."

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
`{"status": "unavailable"}`. -/
def result : Reply → Json
  | .yes => "yes"
  | .no => "no"
  | .choice number => (number : Json)
  | .noneOfAbove => "none_of_above"
  | .text words => .str words
  | .unavailable => .mkObj [("status", "unavailable")]

/-- Asks a person the question, of a kind the call may ask, and waits. -/
def routine : Routine Agent := {
  name := "ask_user"
  body := fun arguments => do
    let question ← match read arguments with
      | .ok question => pure question
      | .error problem => throw (.refused problem)
    return result (← ask question)
  scope := .empty }

/-- Asks a person, and waits; alone in its turn. `kinds` are the kinds of question the model may
ask, chosen by whoever configures the agent: the tool is offered with at least one, and adds
them to every call, so that its routine refuses another kind before anything is asked. -/
def tool (kinds : Array Kind) : Tool where
  definition := definition kinds
  alone := true
  instruction? := some (instruction kinds)
  settings := .mkObj [("question_types", .arr ((ordered kinds).toArray.map fun kind => .str kind.name))]

end AskUser

/-! ## time_budget: how long the run has left -/

namespace TimeBudget

def definition : Chat.ToolDefinition := {
  name := "time_budget"
  description := "How many seconds of this run's time budget are left. Use it, not `date`, " ++
    "to pace yourself: the run may be resumed from a checkpoint, and the clock is not the budget."
  parameters := .object #[]
}

/-- What a `time_budget` call gives, from a timing of the run: the whole seconds left, never
negative, or that there is no limit. -/
def answer (runTimeMs : Nat) (budgetMs? : Option Nat) : Json :=
  match budgetMs? with
  | some budget => .mkObj [("seconds_left", ((budget - runTimeMs) / 1000 : Nat))]
  | none => .mkObj [("seconds_left", .null), ("note", "this run has no time limit")]

def instruction : String :=
  "You may call time_budget to see how many seconds of this run's time budget are left."

/-- Times the run, and says what it leaves of the budget; it takes no arguments. -/
def routine : Routine Agent := {
  name := definition.name
  body := fun _ => do
    let timing ← time
    return answer timing.spentMs timing.budgetMs?
  scope := .empty }

def tool : Tool := { definition, instruction? := some instruction }

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
  | _, .error problem => throw (.refused problem)
  | _, _ => throw (.refused s!"uname: {ran.output.output}")

end Uname

/-! ## subagent: the agent itself, on a task of the model's -/

namespace Subagent

def definition : Chat.ToolDefinition := {
  name := "subagent"
  description := "Delegate a self-contained task to a sub-agent like you. It works in the same " ++
    "workspace, from a conversation of its own that holds only the task, and gives back how it ended."
  parameters := .object #[("task", .string (description? := some "The task, complete: the sub-agent sees nothing else"))]
}

def instruction : String :=
  "You may call subagent to hand a self-contained part of the work to a sub-agent like you; " ++
  "it has its own conversation, so say everything it needs in the task."

/-- Calls the agent its settings name, with their configuration and the model's task: the agent
that offers the tool, on another task, so the sub-agent offers the same tools, this one among
them. It runs where its caller's commands do, and gives how the sub-agent ended. The agent reads
the task with the rest of its configuration, and refuses what it cannot run on. The routine finds
the agent by name in its scope, so an agent that offers the tool gives it a scope with itself in
it (`MiniVero.routine`). -/
def routine : Routine Agent := {
  name := definition.name
  body := fun arguments => do
    let agent ← match arguments.getObjVal? "agent" >>= Json.getStr? with
      | .ok agent => pure agent
      | .error _ => throw (.defect "The subagent tool's settings name no agent.")
    let config := (arguments.getObjVal? "configuration").toOption.getD (.mkObj [])
    call agent (config.setObjVal! "task" ((arguments.getObjVal? "task").toOption.getD .null))
  scope := .empty }

/-- A sub-agent that is the agent `name`, with the configuration `config`. -/
def tool (name : String) (config : Json) : Tool :=
  { definition, instruction? := some instruction
    settings := .mkObj [("agent", name), ("configuration", without config "task")] }

end Subagent

/-- The routines the tools call, but an agent's own: each fixed, what an agent's configuration
says of a call coming in its arguments. -/
def routines : Array (Routine Agent) := #[Bash.routine, AskUser.routine, TimeBudget.routine]

end Tools

end Alaya.Agents
