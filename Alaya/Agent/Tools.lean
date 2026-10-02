import Alaya.Agent
import Alaya.Executor

/-!
The tools an agent can offer, each on its own, as a `Tool`: its definition for the model, what
it adds to the prompt, and how a call is read and answered — a command run in the workspace, a
value computed from the log, a question for a person, the end of the run. Nothing here knows
which agent offers a tool, what else it offers, or how it words a refusal; an agent holds a list
of tools and decides the rest. `all` names every tool, for an agent's configuration.
-/

namespace Alaya.Agent

/-- A tool as an agent offers it. A tool only adds to the prompt, never rewrites it: what it
needs the model to know is its `instruction?`, appended after the agent's own text. -/
structure Tool where
  definition : Chat.ToolDefinition
  /-- Must be the only call of its turn. -/
  alone : Bool := false
  /-- What the model is told of the tool beyond its definition, appended to the prompt. -/
  instruction? : Option String := none
  /-- Reads a call: what is wrong with its arguments, or how it is answered — what the agent
  asks for next, for the call's reference, from the log at the point it is the next call to
  answer: the effect that answers the call, an effect whose answer it needs first, or the
  outcome that ends the run instead. -/
  read : Chat.ToolCall -> Except String (CallRef -> Log -> Effect ⊕ Outcome)

def Tool.name (tool : Tool) : String := tool.definition.name

namespace Tools

open Alaya (Output)

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

/-- Runs the command in the workspace, as `Executor.Config`'s defaults say; an
agent sets how its commands run with `Agent.runCommandsWith`. -/
def tool : Tool := {
  definition
  read := fun call => do
    let command ← command call.arguments
    pure fun ref _ => .inl (.exec ref command {}) }

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

/-- Ends the run, its message the submission. -/
def tool : Tool := {
  definition
  read := fun call => pure fun _ _ => .inr { status := "Submitted", submission := message call.arguments } }

end Submit

/-! ## ask_user: a typed question, answered outside the workspace -/

namespace AskUser

/-- How the tool works, and nothing of what to ask or how to treat the answer: that is the
agent's, or the experiment's, to say. -/
def instruction : String :=
  "You may ask a concrete question with ask_user instead of running a command. " ++
  "Include the relevant context and choose question_type: yes_no for a yes/no answer, " ++
  "single_choice to select exactly one of at least two distinct candidates, or open_ended " ++
  "for a nonblank free-text answer. Only single_choice takes options; otherwise pass an empty array. " ++
  "A yes_no answer returns the string yes or no. " ++
  "A selected candidate returns its one-based option number (starting at 1), as a number. " ++
  "The platform appends None of the above; never include that reserved label or none_of_above " ++
  "in options. It returns the plain string none_of_above when all listed candidates are incorrect, " ++
  "distinct from being unable to answer. Call ask_user alone, without any other tool. " ++
  "For every question type, the person may be unable to answer; this returns the JSON " ++
  "object {\"status\":\"unavailable\"} instead of an answer."

def definition : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask a yes/no, single-choice, or open-ended question and wait for an answer. " ++
    "Single-choice answers return one candidate's one-based option number (starting at 1), " ++
    "or the platform's None of the above " ++
    "answer (plain text none_of_above). Never include that reserved option yourself. " ++
    "If the person cannot answer, the result is {\"status\":\"unavailable\"}. Call this tool alone."
  parameters := .object #[
    ("question_type", .string (description? := some "The form of the answer requested")
      (enum := #["yes_no", "single_choice", "open_ended"])),
    ("question", .string (description? := some "The question and enough context to answer it")),
    ("options", .array (.string) (description? := some (
      "For single_choice, at least two distinct, nonempty actual candidates. " ++
      "Do not include None of the above or none_of_above; the platform adds it. " ++
      "For yes_no and open_ended, an empty array.")))]
}

/-- Reads the question a call asks, or says what is wrong with it: the arguments name a form,
only a choice has options, and the question is one that can be asked (`Question.validate`). It
does not judge whether a candidate is true. -/
def question (arguments : Lean.Json) : Except String Question := do
  definition.parameters.validate arguments
  let text ← arguments.getObjVal? "question" >>= Lean.Json.getStr?
  let options ← (arguments.getObjVal? "options" >>= Lean.Json.getArr?) >>= (·.mapM Lean.Json.getStr?)
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

/-- Asks a person, and waits; alone in its turn. -/
def tool : Tool := {
  definition
  alone := true
  instruction? := some instruction
  read := fun call => do
    let question ← question call.arguments
    pure fun ref _ => .inl (.ask ref question) }

end AskUser

/-! ## time_budget: how long the run has left -/

namespace TimeBudget

def definition : Chat.ToolDefinition := {
  name := "time_budget"
  description := "How many seconds of this run's time budget are left. Use it, not `date`, " ++
    "to pace yourself: the run may be resumed from a checkpoint, and the clock is not the budget."
  parameters := .object #[]
}

/-- What a `time_budget` call records, from a timing of the run (`Event.timed`): the whole
seconds left, never negative, or that there is no limit. -/
def answer (runTimeMs : Nat) (budgetMs? : Option Nat) : Lean.Json :=
  match budgetMs? with
  | some budget => .mkObj [("seconds_left", ((budget - runTimeMs) / 1000 : Nat))]
  | none => .mkObj [("seconds_left", .null), ("note", "this run has no time limit")]

def instruction : String :=
  "You may call time_budget to see how many seconds of this run's time budget are left."

/-- Times the run, then, once the log holds the timing, records what it leaves of the
budget. -/
def tool : Tool := {
  definition
  instruction? := some instruction
  read := fun _ => pure fun ref log => match log.back? with
    | some (.timed runTimeMs budgetMs?) => .inl (.record ref (answer runTimeMs budgetMs?))
    | _ => .inl .time }

end TimeBudget

/-- Every tool an agent's configuration can name. -/
def all : Array Tool := #[Bash.tool, Submit.tool, AskUser.tool, TimeBudget.tool]

def named? (name : String) : Option Tool := all.find? (·.name == name)

end Tools

end Alaya.Agent
