import Alaya.Agent

/-!
The tools an agent can offer, each on its own, as a `Tool`: a routine, and what a model needs to
call it — its definition, what it adds to the prompt, what is wrong with a call's arguments. Its
program answers a call: a command run in the workspace, a question for a person, the time left.
A tool is called by its name, like any routine, so it runs in a frame of its own, and the log
brackets it. Nothing here knows which agent offers a tool, what else it offers, or how it words a
refusal; an agent holds a list of tools and decides the rest. `submit` is no tool that runs: an
agent that offers it ends with its message.
-/

namespace Alaya.Agents

open Lean (Json)

/-- A tool as an agent offers it. A tool only adds to the prompt, never rewrites it: what it
needs the model to know is its `instruction?`, appended after the agent's own text. -/
structure Tool where
  definition : Chat.ToolDefinition
  /-- Must be the only call of its turn. -/
  alone : Bool := false
  /-- What the model is told of the tool beyond its definition, appended to the prompt. -/
  instruction? : Option String := none
  /-- What is wrong with a call's arguments, if anything: checked before the call is made. -/
  check : Json → Except String Unit := fun _ => pure ()
  /-- The program that answers a call, given its arguments. -/
  run : Json → Program Agent Json

def Tool.name (tool : Tool) : String := tool.definition.name

/-- The tool as a run's table lists it: a routine like any other. -/
def Tool.entry (tool : Tool) : Routine.Entry Agent := (tool.name, tool.run)

namespace Tools

/-! ## bash: a command in the workspace -/

namespace Bash

def definition : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
}

/-- The command of a call, or what is wrong with its arguments. -/
def command (arguments : Lean.Json) : Except String String :=
  match arguments.getObjVal? "command" with
  | .ok (.str command) => .ok command
  | .ok _ => .error "The 'command' argument of the bash tool must be a string."
  | .error _ => .error "Missing 'command' argument in bash tool call."

/-- The fields saying how a command ended, after `fields`. -/
private def withStatus (o : Output) (fields : List (String × Lean.Json)) : Lean.Json :=
  let fields := fields ++ [("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null)]
  let fields := match o.error? with
    | some error => fields ++ [("error", Lean.Json.str error)]
    | none => fields
  .mkObj fields

/-- A command's result, as its call gives it: the whole output, how it ended, and the file a
later command finds the output in, when the command was run so. What a model is shown of it is
its agent's to say (`observation`). -/
def result (execution : Execution) : Json :=
  .mkObj [("output", execution.output.output),
    ("exit_code", execution.output.exitCode?.map (fun c => Json.num c.toNat) |>.getD .null),
    ("error", execution.output.error?.map Json.str |>.getD .null),
    ("file", execution.file?.map Json.str |>.getD .null)]

/-- A command's result read back: its output, and where the whole of it is. -/
def ofResult? (json : Json) : Option (Output × Option String) := do
  let output ← Output.fromJson? json
  pure (output, (json.getObjVal? "file" >>= Json.getStr?).toOption)

/-- Runs the command in the workspace, as `config` says: how a command runs is the agent's
policy, not the model's. A command that exits with an error is no failure of the tool: its
status is in the result. -/
def tool (config : Executor.Config := {}) : Tool := {
  definition
  check := fun arguments => (command arguments).map fun _ => ()
  run := fun arguments => do
    let command ← match command arguments with
      | .ok command => pure command
      | .error problem => throw problem
    return result (← exec command config) }

/-- What an omitted output says in its place. -/
def omittedNotice (file : String) : String := s!"[output omitted; full output: {file}]"

/-- How the model sees an `Output`: as JSON, with `output` cut to its first and last `limit / 2`
characters when it is `limit` or longer — mini's `observation_template`. With `file?`, where
the whole output can be read, the warning names it instead, as the DeepSeek harness does. -/
def observation (o : Output) (limit : Nat) (file? : Option String := none) : Lean.Json :=
  let length := o.output.length
  let fields : List (String × Lean.Json) :=
    if length < limit then [("output", o.output)]
    else
      let half := limit / 2
      [("output_head", String.ofList (o.output.toList.take half)),
       ("output_tail", String.ofList (o.output.toList.drop (length - half))),
       ("elided_chars", (length - limit : Nat)),
       ("warning", match file? with
         | none => "Output too long."
         | some file => s!"[output truncated; full output: {file}]")]
  withStatus o fields

/-- How the model sees an `Output` it is no longer shown: the file holding it, in place of
`output`, and how the command ended. -/
def omitted (o : Output) (file : String) : Lean.Json :=
  withStatus o [("output", omittedNotice file)]

end Bash

/-! ## submit: the end of a run -/

namespace Submit

def definition : Chat.ToolDefinition := {
  name := "submit"
  description := "Finish the task. Call this once your changes are complete; nothing runs after it."
  parameters := .object #[("message", .string (description? := some "A short summary of what you did"))]
}

/-- The submission; a call without a string message submits nothing. -/
def message (arguments : Lean.Json) : String :=
  match arguments.getObjVal? "message" with
  | .ok (.str message) => message
  | _ => ""

/-- Ends the agent, its message the submission. An agent that offers it ends when the call is
the next to make, and never calls it: `run` only gives the message back. -/
def tool : Tool := {
  definition
  run := fun arguments => pure (.str (message arguments)) }

end Submit

/-! ## ask_user: a question a model asks a person

The tool is a model's way to `ask` (`Alaya.Program`), and nothing more. What a question is,
which replies fit it, and how a person gives one are not the tool's. The tool's are the words
and the schema a model is given, which kinds of question it may ask, and how a reply is shown
to it. -/

namespace AskUser

open Question (Kind)

/-- `a`, `a or b`, `a, b, or c`. -/
private def listed : List String → String
  | [] => ""
  | [a] => a
  | [a, b] => s!"{a} or {b}"
  | items => ", ".intercalate items.dropLast ++ ", or " ++ items.getLast!

/-- The kinds, in the order questions are always named in. -/
private def ordered (kinds : Array Kind) : List Kind :=
  Kind.all.toList.filter kinds.contains

/-- What the model is told of the tool beyond its definition, for the kinds it may ask: how the
tool works, and nothing of what to ask or how to treat the answer, which is the agent's, or the
experiment's, to say. -/
def instruction (kinds : Array Kind) : String :=
  let kinds := ordered kinds
  let choose := listed <| kinds.map fun
    | .yesNo => "yes_no for a yes/no answer"
    | .singleChoice => "single_choice to select exactly one of at least two distinct candidates"
    | .openEnded => "open_ended for a nonblank free-text answer"
  let options :=
    if !kinds.contains .singleChoice then ""
    else if kinds.length == 1 then ""
    else "Only single_choice takes options; otherwise pass an empty array. "
  let yesNo := if kinds.contains .yesNo then "A yes_no answer returns the string yes or no. " else ""
  let choice := if !kinds.contains .singleChoice then "" else
    "A selected candidate returns its one-based option number (starting at 1), as a number. " ++
    "The platform appends None of the above; never include that reserved label or none_of_above " ++
    "in options. It returns the plain string none_of_above when all listed candidates are incorrect, " ++
    "distinct from being unable to answer. "
  "You may ask a concrete question with ask_user instead of running a command. " ++
  s!"Include the relevant context and choose question_type: {choose}. " ++
  options ++ yesNo ++ choice ++
  "Call ask_user alone, without any other tool. " ++
  "For every question type, the person may be unable to answer; this returns the JSON " ++
  "object {\"status\":\"unavailable\"} instead of an answer."

/-- The tool as a model is offered it, for the kinds of question it may ask: `question_type`
names one of them, and `options` is there only when a choice is among them. -/
def definition (kinds : Array Kind) : Chat.ToolDefinition :=
  let kinds := ordered kinds
  let asks := listed <| kinds.map fun
    | .yesNo => "yes/no"
    | .singleChoice => "single-choice"
    | .openEnded => "open-ended"
  let others := (kinds.filter (· != .singleChoice)).map (·.name)
  let choice := if !kinds.contains .singleChoice then "" else
    "Single-choice answers return one candidate's one-based option number (starting at 1), " ++
    "or the platform's None of the above " ++
    "answer (plain text none_of_above). Never include that reserved option yourself. "
  { name := "ask_user"
    description := s!"Ask a {asks} question and wait for an answer. " ++ choice ++
      "If the person cannot answer, the result is {\"status\":\"unavailable\"}. Call this tool alone."
    parameters := .object (#[
      ("question_type", .string (description? := some "The form of the answer requested")
        (enum := (kinds.map (·.name)).toArray)),
      ("question", .string (description? := some "The question and enough context to answer it"))] ++
      (if !kinds.contains .singleChoice then #[] else #[
      ("options", .array (.string) (description? := some (
        "For single_choice, at least two distinct, nonempty actual candidates. " ++
        "Do not include None of the above or none_of_above; the platform adds it." ++
        (if others.isEmpty then "" else s!" For {" and ".intercalate others}, an empty array."))))])) }

/-- Reads the question a call asks, or says what is wrong with it: the arguments name a kind the
tool allows, only a choice has options, and the question is one that can be asked
(`Question.validate`). It does not judge whether a candidate is true. -/
def question (kinds : Array Kind) (arguments : Lean.Json) : Except String Question := do
  (definition kinds).parameters.validate arguments
  let text ← arguments.getObjVal? "question" >>= Lean.Json.getStr?
  let options ← match arguments.getObjVal? "options" with
    | .ok options => options.getArr? >>= (·.mapM Lean.Json.getStr?)
    | .error _ => pure #[]
  let noOptions : Except String Unit :=
    if options.isEmpty then pure ()
    else throw "Question options must be empty for yes_no and open_ended questions."
  let form ← match ← arguments.getObjVal? "question_type" >>= Lean.Json.getStr? with
    | "single_choice" => pure (Question.Form.singleChoice options)
    | "yes_no" => noOptions *> pure .yesNo
    | "open_ended" => noOptions *> pure .openEnded
    | other => throw s!"Unknown question_type: {other}."
  let question : Question := { text, form }
  question.validate
  pure question

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

/-- Asks a person, and waits; alone in its turn. `kinds` are the kinds of question the model may
ask, chosen by whoever configures the agent: the tool is offered with at least one, and a call
that asks another kind is refused before anything is asked. -/
def tool (kinds : Array Kind) : Tool := {
  definition := definition kinds
  alone := true
  instruction? := some (instruction kinds)
  check := fun arguments => (question kinds arguments).map fun _ => ()
  run := fun arguments => do
    let question ← match question kinds arguments with
      | .ok question => pure question
      | .error problem => throw problem
    return result (← ask question) }

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
def tool : Tool := {
  definition
  instruction? := some instruction
  run := fun _ => do
    let timing ← time
    return answer timing.spentMs timing.budgetMs? }

end TimeBudget

/-- What an agent's configuration says of the tools it offers. -/
structure Options where
  /-- How `bash` runs a command. -/
  commands : Executor.Config := {}
  /-- The kinds of question `ask_user` lets a model ask. -/
  questions : Array Question.Kind := #[]

/-- The tools an agent's configuration can name, as `options` say. -/
def all (options : Options := {}) : Array Tool :=
  #[Bash.tool options.commands, Submit.tool, AskUser.tool options.questions, TimeBudget.tool]

def names : Array String := (all).map (·.name)

def named? (name : String) (options : Options := {}) : Option Tool :=
  (all options).find? (·.name == name)

end Tools

end Alaya.Agents
