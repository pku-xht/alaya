import Alaya.Agent
import Alaya.Grader

/-!
The tools an agent can offer, each on its own, as a `Tool`: its definition for the model, what
it adds to the prompt, what is wrong with a call's arguments, and the program that answers a
call — a command run in the workspace, a question for a person, the time left, a grader's
verdict. A tool is called by its name, so it runs in a frame of its own, and the log brackets
it. Nothing here knows which agent offers a tool, what else it offers, or how it words a
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

/-- Asks a person, and waits; alone in its turn. The question is the argument, so the opening of
the call puts it in the log. The tool then waits for a reply to this call, of the form the
question asks for: no other notice ends the wait or is taken for the answer. The model is shown
the reply as `Reply.toJson` gives it. -/
def tool : Tool := {
  definition
  alone := true
  instruction? := some instruction
  check := fun arguments => (question arguments).map fun _ => ()
  run := fun arguments => do
    let question ← match question arguments with
      | .ok question => pure question
      | .error problem => throw problem
    let replies ← await fun frame notice =>
      match notice with
      | .replied to reply => to == frame && question.accepts reply
      | _ => false
    match replies with
    | .replied _ reply :: _ => return reply.toJson
    | _ => throw "the wait for a reply ended without one" }

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

/-! ## grade: a grader's verdict

A grader is a tool that no conversation offers its model: a run calls it once its agent is over,
with the grader a person assigned to it (`Alaya.grading`). It is an external program, a command
in a container of its own image on a checkout of the workspace with trusted files mounted at
`/grader`, and a reading of the TAP it prints (`Alaya.Grader`). The call's arguments are the
grader itself, so its opening puts the whole of it in the log. -/

namespace Grade

/-- A grader: a name for a reader, the command, the pinned image it runs in, the snapshot of its
trusted input, and how long it may take; 0 is no limit. -/
structure Grader where
  name : String := "grader"
  command : String
  image : String
  input? : Option Snapshot := none
  timeoutSeconds : Nat := 900
  deriving Inhabited

def Grader.toJson (grader : Grader) : Json :=
  .mkObj [("name", grader.name), ("command", grader.command), ("image", grader.image),
    ("input", grader.input?.map (Json.str ·.hex) |>.getD .null),
    ("timeout_seconds", grader.timeoutSeconds)]

def Grader.fromJson (json : Json) : Except String Grader := do
  let input? ← match json.getObjVal? "input" with
    | .ok (.str hex) => if Hash.valid hex then pure (some ⟨hex⟩) else throw s!"not a snapshot: {hex}"
    | .ok .null | .error _ => pure none
    | .ok other => throw s!"a grader's input is a snapshot, not {other.compress}"
  pure {
    name := (json.getObjVal? "name" >>= Json.getStr?).toOption.getD "grader"
    command := ← json.getObjVal? "command" >>= Json.getStr?
    image := ← json.getObjVal? "image" >>= Json.getStr?
    input?
    timeoutSeconds := (json.getObjVal? "timeout_seconds" >>= Json.getNat?).toOption.getD 900 }

def definition : Chat.ToolDefinition := {
  name := "grade"
  description := "Grade the workspace with the grader assigned to the run."
  parameters := .object #[] }

/-- A verdict as a grader's call gives it: the status, the score, why, and every check. -/
def verdictJson (verdict : Alaya.Grader.Verdict) (ran : External) : Json :=
  let (passed, total) := Alaya.Grader.Verdict.score verdict.checks
  .mkObj [("status", verdict.status.toString), ("passed", passed), ("total", total),
    ("reason", verdict.reason),
    ("checks", .arr (verdict.checks.map fun check =>
      .mkObj [("ok", check.ok), ("name", check.name), ("directive", check.directive)])),
    ("exit_code", ran.exitCode?.map (fun c => (c : Json)) |>.getD .null),
    ("elapsed_ms", ran.elapsedMs)]

/-- Runs the grader its arguments describe, and gives its verdict. -/
def tool : Tool := {
  definition
  check := fun arguments => (Grader.fromJson arguments).map fun _ => ()
  run := fun arguments => do
    let grader ← match Grader.fromJson arguments with
      | .ok grader => pure grader
      | .error problem => throw problem
    let ran ← external grader.command grader.image grader.input? grader.timeoutSeconds
    return verdictJson (Alaya.Grader.verdict ran.stdout ran.error?) ran }

end Grade

/-- The tools an agent's configuration can name, its commands run as `config` says. -/
def all (config : Executor.Config := {}) : Array Tool :=
  #[Bash.tool config, Submit.tool, AskUser.tool, TimeBudget.tool]

def names : Array String := (all).map (·.name)

def named? (name : String) (config : Executor.Config := {}) : Option Tool :=
  (all config).find? (·.name == name)

end Tools

end Alaya.Agents
