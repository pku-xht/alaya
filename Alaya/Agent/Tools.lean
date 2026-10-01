import Alaya.Agent
import Alaya.Executor

/-!
The tools an agent can offer, each on its own: its definition for the model, how its arguments
are read, and what answers a call — a command run in the workspace, or a value computed from
the log. Nothing here knows which agent offers a tool, what else it offers, or how it words a
refusal; an agent composes these and decides the rest.
-/

namespace Alaya.Agent.Tools

open Alaya (Result Error Output Executor)

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

/-- Runs the command in the workspace through the executor; the observation is the `Output`. -/
def act (executor : Executor) (workspace : Workspace) (command : String) : Result Lean.Json := do
  let output ← Result.fromIO Error.storage (executor.bash workspace.dir command)
  pure output.toJson

/-- The fields saying how a command ended, after `fields`. -/
private def withStatus (o : Output) (fields : List (String × Lean.Json)) : Lean.Json :=
  let fields := fields ++ [("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null)]
  let fields := match o.error? with
    | some error => fields ++ [("error", Lean.Json.str error)]
    | none => fields
  .mkObj fields

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

end Submit

/-! ## ask_user: a typed question, answered outside the workspace -/

namespace AskUser

def instruction : String :=
  "You may ask a concrete question with ask_user instead of running a command. " ++
  "Write your messages, questions, and answer options in English. " ++
  "Include the relevant context and choose question_type: yes_no for a yes/no answer, " ++
  "single_choice to select exactly one of at least two distinct candidates, or open_ended " ++
  "for a nonblank free-text answer. Only single_choice takes options; otherwise pass an empty array. " ++
  "A selected candidate returns its one-based option number (starting at 1) as a string. " ++
  "The platform appends None of the above; never include that reserved label or none_of_above " ++
  "in options. It returns the plain string none_of_above when all listed candidates are incorrect, " ++
  "distinct from being unable to answer. Call ask_user alone, without any other tool. " ++
  "For every question type, the person may be unable to answer; this returns the JSON " ++
  "object {\"status\":\"unavailable\"} instead of a string answer. " ++
  "The answer is advice and may be wrong; it does not change " ++
  "the task's rules."

def definition : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask a yes/no, single-choice, or open-ended question and wait for an answer. " ++
    "Write the question, its context, and all options in English. " ++
    "Single-choice answers return one candidate's one-based option number (starting at 1) as a string, " ++
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

/-- Checks the question's form, not whether a candidate is true. The raw arguments stay in
the log; the structured question gives collectors and `reply` the same answer contract. -/
def question (arguments : Lean.Json) : Except String Question := do
  definition.parameters.validate arguments
  let questionType ← arguments.getObjVal? "question_type" >>= Lean.Json.getStr? >>=
    QuestionType.fromString
  let text ← arguments.getObjVal? "question" >>= Lean.Json.getStr?
  let options ← (arguments.getObjVal? "options" >>= Lean.Json.getArr?) >>= (·.mapM Lean.Json.getStr?)
  if text.trimAscii.toString.isEmpty then throw "ask_user needs a nonempty question."
  let question : Question := { text, questionType, options }
  question.validate
  pure question

end AskUser

/-! ## time_budget: how long the run has left -/

namespace TimeBudget

def definition : Chat.ToolDefinition := {
  name := "time_budget"
  description := "How many seconds of this run's time budget are left. Use it, not `date`, " ++
    "to pace yourself: the run may be resumed from a checkpoint, and the clock is not the budget."
  parameters := .object #[]
}

/-- What a `time_budget` call records: the seconds left, or that there is no limit. -/
def answer (session : Session) : Lean.Json :=
  match session.secondsLeft? with
  | some seconds => .mkObj [("seconds_left", (seconds : Lean.Json))]
  | none => .mkObj [("seconds_left", .null), ("note", "this run has no time limit")]

end TimeBudget

end Alaya.Agent.Tools
