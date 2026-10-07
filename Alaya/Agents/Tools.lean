import Alaya.Runtime.Agent

/-!
The tools an agent can offer, each on its own, as a `Tool`: what a model needs to call it — its
definition, what it adds to the prompt, what is wrong with a call's arguments — and the routine
call the model's arguments make, as the tool's parameters say: a command with the agent's
executor settings, a sub-agent that is the agent itself. The routines are `routines`, each fixed,
its computation answering a call: a command run in the workspace, a question for a person, the
time left. What the agent's configuration says of a call is in the call's arguments, so it is in
the log with them. A tool is called by its name, like any routine, so it runs in a frame of its
own, and the log brackets it. Nothing here knows which agent offers a tool, what else it offers,
or how it words a refusal; an agent holds a list of tools and decides the rest. `submit` calls no
routine: an agent that offers it ends with its message.
-/

namespace Alaya.Agents

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-- A tool as an agent offers it. A tool only adds to the prompt, never rewrites it: what it
needs the model to know is its `instruction?`, appended after the agent's own text. -/
structure Tool where
  definition : Chat.ToolDefinition
  /-- Must be the only call of its turn. -/
  alone : Bool := false
  /-- What the model is told of the tool beyond its definition, appended to the prompt. -/
  instruction? : Option String := none
  /-- What is wrong with a call's arguments, if anything: checked before the call is made. By
  default, whether they fit the tool's schema. -/
  check : Json → Except String Unit := fun arguments =>
    (definition.parameters.validate arguments).mapError fun problem =>
      s!"Invalid arguments for the {definition.name} tool: {problem}."
  /-- The routine call the model's arguments make: by default, of the routine of the tool's name,
  with those arguments. -/
  call : Json → RoutineCall := fun arguments => { name := definition.name, arguments }

def Tool.name (tool : Tool) : String := tool.definition.name

namespace Tools

/-- What is wrong with one tool call against the tools offered: arguments that are not JSON, a
tool not offered, or arguments its tool refuses; `none` when it can be made. -/
def callProblem? (tools : Array Tool) (call : Chat.ToolCall) : Option String :=
  if let some raw := call.invalidArguments? then
    some ("Error parsing tool call arguments: " ++
      (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
  else match tools.find? (·.name == call.name) with
    | none => some s!"Unknown tool '{call.name}'."
    | some tool => match tool.check call.arguments with
      | .ok () => none
      | .error problem => some problem

/-- The tool that must be alone in a response with other calls, if any. -/
def lone? (tools : Array Tool) (response : Chat.Response) : Option Tool :=
  if response.toolCalls.size ≤ 1 then none
  else tools.find? fun tool => tool.alone && response.toolCalls.any (·.name == tool.name)

/-- Makes the call a model's tool call asks for: the routine call its tool makes of the model's
arguments. Gives its result, or its error when it fails. -/
def make (tools : Array Tool) (asked : Chat.ToolCall) : Computation Agent (Except String Json) := do
  let made : RoutineCall := match tools.find? (·.name == asked.name) with
    | some tool => tool.call asked.arguments
    | none => { name := asked.name, arguments := asked.arguments }
  try .ok <$> call made.name made.arguments
  catch error => pure (.error error)

/-! ## bash: a command in the workspace -/

namespace Bash

def definition : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
}

/-- The command of a call, or what is wrong with its arguments, in mini's words: the check of
the tool, in place of its schema's. -/
def command (arguments : Lean.Json) : Except String String :=
  match arguments.getObjVal? "command" with
  | .ok (.str command) => .ok command
  | .ok _ => .error "The 'command' argument of the bash tool must be a string."
  | .error _ => .error "Missing 'command' argument in bash tool call."

/-- A command's result, as its call gives it: the whole output, how it ended, and the file a
later command finds the output in, when the command was run so. What a model is shown of it is
its agent's to say. -/
def result (execution : Execution) : Json :=
  .mkObj [("output", execution.output.output),
    ("exit_code", execution.output.exitCode?.map (fun c => Json.num c.toNat) |>.getD .null),
    ("error", execution.output.error?.map Json.str |>.getD .null),
    ("file", execution.file?.map Json.str |>.getD .null)]

/-- A command's result read back: its output, and where the whole of it is. -/
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
      | .error problem => throw problem
    let config ← match arguments.getObjVal? "executor" with
      | .error _ => pure {}
      | .ok json => match Executor.Config.fromJson json with
        | .ok config => pure config
        | .error problem => throw s!"bash: its executor: {problem}"
    return result (← exec command config)
  scope := .empty }

/-- The model's command, run as `config` says: how a command runs is the agent's policy, not the
model's. -/
def tool (config : Executor.Config := {}) : Tool := {
  definition
  check := fun arguments => (command arguments).map fun _ => ()
  call := fun arguments => { name := definition.name, arguments := arguments.setObjVal! "executor" config.toJson } }

end Bash

/-! ## submit: the end of a run -/

namespace Submit

def definition : Chat.ToolDefinition := {
  name := "submit"
  description := "Finish the task. Call this once your changes are complete; nothing runs after it."
  parameters := .object #[("message", .string (description? := some "A short summary of what you did"))]
}

/-- The submission of a call, whose arguments fit the schema. -/
def message (arguments : Lean.Json) : String :=
  match arguments.getObjVal? "message" with
  | .ok (.str message) => message
  | _ => ""

/-- Ends the agent, its message the submission; alone in its turn, so that nothing is left
unmade. An agent that offers it ends at the call, and calls no routine. -/
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

/-- Reads the question of a call's arguments, or says what is wrong with it: only a choice has
options, and the question is one that can be asked (`Question.validate`). Options left out are
none. It does not judge whether an option is true. -/
def read (arguments : Lean.Json) : Except String Question := do
  let text ← (arguments.getObjVal? "question" >>= Lean.Json.getStr?).mapError fun _ =>
    "The ask_user tool takes its question as a string."
  let options ← match arguments.getObjVal? "options" with
    | .ok options => (options.getArr? >>= (·.mapM Lean.Json.getStr?)).mapError fun _ =>
      "The ask_user tool takes its options as an array of strings."
    | .error _ => pure #[]
  let noOptions : Except String Unit :=
    if options.isEmpty then pure ()
    else throw "Options must be empty for yes_no and open_ended."
  let form ← match arguments.getObjVal? "question_type" >>= Lean.Json.getStr? with
    | .ok "single_choice" => pure (Question.Form.singleChoice options)
    | .ok "yes_no" => noOptions *> pure .yesNo
    | .ok "open_ended" => noOptions *> pure .openEnded
    | _ => throw s!"The ask_user tool takes a question_type: one of {Kind.names}."
  let question : Question := { text, form }
  question.validate
  pure question

/-- Reads the question a call asks of a tool that allows `kinds`, or says what is wrong with it:
the arguments fit the tool's schema, so they name a kind it allows, and the question reads. -/
def question (kinds : Array Kind) (arguments : Lean.Json) : Except String Question := do
  ({ definition := definition kinds } : Tool).check arguments
  read arguments

/-- What a call gives for a reply, and so what the model is shown as its result: `"yes"` or
`"no"`, the candidate's number, `"none_of_above"`, the person's text, or the object
`{"status": "unavailable"}`. -/
def result : Reply → Lean.Json
  | .yes => "yes"
  | .no => "no"
  | .choice number => (number : Lean.Json)
  | .noneOfAbove => "none_of_above"
  | .text words => .str words
  | .unavailable => .mkObj [("status", "unavailable")]

/-- Asks a person the question, of any kind, and waits. -/
def routine : Routine Agent := {
  name := "ask_user"
  body := fun arguments => do
    -- The agent checked the call against the tool it offered; the question is read again here,
    -- from the opening in the log, whichever kinds that tool allowed.
    let question ← match read arguments with
      | .ok question => pure question
      | .error problem => throw problem
    return result (← ask question)
  scope := .empty }

/-- Asks a person, and waits; alone in its turn. `kinds` are the kinds of question the model may
ask, chosen by whoever configures the agent: the tool is offered with at least one, and a call
that asks another kind is refused before anything is asked. -/
def tool (kinds : Array Kind) : Tool := {
  definition := definition kinds
  alone := true
  instruction? := some (instruction kinds)
  check := fun arguments => (question kinds arguments).map fun _ => () }

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
def answer (runTimeMs : Nat) (budgetMs? : Option Nat) : Lean.Json :=
  match budgetMs? with
  | some budget => .mkObj [("seconds_left", ((budget - runTimeMs) / 1000 : Nat))]
  | none => .mkObj [("seconds_left", .null), ("note", "this run has no time limit")]

def instruction : String :=
  "You may call time_budget to see how many seconds of this run's time budget are left."

/-- Times the run, and says what it leaves of the budget. -/
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

/-- The task of a call whose arguments fit the schema, or that it is blank. -/
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
offers the same tools, this one among them. It runs where its caller's commands do. -/
def tool (name : String) (config : Json) : Tool := {
  definition
  instruction? := some instruction
  check := fun arguments => do
    ({ definition } : Tool).check arguments
    discard <| task arguments
  call := fun arguments => match task arguments with
    | .ok task => { name, arguments := config.setObjVal! "task" task }
    | .error _ => { name, arguments } }

end Subagent

/-- The routines the tools call, but an agent's own: each fixed, what an agent's configuration
says of a call coming in its arguments. -/
def routines : Array (Routine Agent) := #[Bash.routine, AskUser.routine, TimeBudget.routine]

end Tools

end Alaya.Agents
