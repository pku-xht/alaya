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

/-- How the model sees an `Output`: as JSON, with `output` cut to its first and last `limit / 2`
characters when it is `limit` or longer — mini's `observation_template`. With `recovery?` the
call's id, the warning says the rest can be read back by it. -/
def observation (o : Output) (limit : Nat) (recovery? : Option String := none) : Lean.Json :=
  let length := o.output.length
  let fields : List (String × Lean.Json) :=
    if length < limit then [("output", o.output)]
    else
      let half := limit / 2
      [("output_head", String.ofList (o.output.toList.take half)),
       ("output_tail", String.ofList (o.output.toList.drop (length - half))),
       ("elided_chars", (length - limit : Nat)),
       ("warning", match recovery? with
         | none => "Output too long."
         | some id => s!"Output too long. read_output shows any lines of the whole of it; this call's id is {id}.")]
  let fields := fields ++ [("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null)]
  let fields := match o.error? with
    | some error => fields ++ [("error", Lean.Json.str error)]
    | none => fields
  .mkObj fields

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

/-! ## ask_user: a choice question, answered outside the workspace -/

namespace AskUser

def instruction : String :=
  "You may ask a concrete question with ask_user instead of running a command. " ++
  "Include the relevant context in the question and provide at least two distinct choices. " ++
  "Call ask_user alone, without any other tool. An OTHER / custom-answer option is always " ++
  "added; do not add it yourself. The answer is advice and may be wrong; it does not change " ++
  "the task's rules. If no answer is available, continue independently."

def definition : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask a multiple-choice question and wait for an answer. Call this tool alone. " ++
    "An OTHER / custom-answer option is always added to your choices."
  parameters := .object #[
    ("question", .string (description? := some "The question and enough context to answer it")),
    ("options", .array (.string) (description? := some
      "At least two distinct, nonempty candidate answers. Do not include the automatic custom option."))]
}

/-- Checks presentation, not whether a candidate is true. The raw arguments stay in the log;
the waiting state displays numbered choices and an unconditional custom-answer option. -/
def question (arguments : Lean.Json) : Except String String := do
  definition.parameters.validate arguments
  let text ← arguments.getObjVal? "question" >>= Lean.Json.getStr?
  let options ← (arguments.getObjVal? "options" >>= Lean.Json.getArr?) >>= (·.mapM Lean.Json.getStr?)
  if text.trimAscii.toString.isEmpty then throw "ask_user needs a nonempty question."
  if options.size < 2 then throw "ask_user needs at least two choices."
  let mut seen : Array String := #[]
  for option in options do
    let key := option.trimAscii.toString
    if key.isEmpty then throw "ask_user choices must not be empty."
    if seen.contains key then throw "ask_user choices must be distinct."
    seen := seen.push key
  let numbered := options.mapIdx fun i option => s!"{i + 1}. {option}"
  pure <| text ++ "\n\n" ++ "\n".intercalate numbered.toList ++
    "\nOTHER: Other / custom answer, including none of these or insufficient information."

end AskUser

/-! ## read_output: lines of an earlier command's output, from the log -/

namespace ReadOutput

def definition : Chat.ToolDefinition := {
  name := "read_output"
  description := "Show lines of the full output of an earlier bash call, when it was too long " ++
    "and only its beginning and end were shown. Name the call by its id."
  parameters := .object #[
    ("call_id", .string (description? := some "The id of the bash call")),
    ("offset", .integer (description? := some "The first line to show, counting from 1")),
    ("limit", .integer (description? := some "How many lines to show"))]
}

structure Request where
  callId : String
  offset : Nat
  limit : Nat

/-- Reads the arguments; the message says what is wrong with them. -/
def parse (arguments : Lean.Json) : Except String Request := do
  let callId ← (arguments.getObjVal? "call_id" >>= Lean.Json.getStr?).mapError
    fun _ => "read_output needs 'call_id', the id of a bash call."
  let offset ← (arguments.getObjVal? "offset" >>= Lean.Json.getNat?).mapError
    fun _ => "read_output needs 'offset', a line number counting from 1."
  let limit ← (arguments.getObjVal? "limit" >>= Lean.Json.getNat?).mapError
    fun _ => "read_output needs 'limit', a number of lines."
  if offset == 0 then throw "read_output needs 'offset', a line number counting from 1."
  if limit == 0 then throw "read_output needs 'limit', a number of lines, at least 1."
  pure { callId, offset, limit }

/-- The full output the log recorded for the call `callId`: the most recent observation with
that id whose content is a command's output, so an id a provider reuses across turns names the
latest. -/
def outputOf? (log : Log) (callId : String) : Option Output :=
  log.reverse.findSome? fun
    | .observation id content => if id == callId then Output.fromJson? content else none
    | _ => none

private def lines (text : String) : Array String :=
  let all := (text.splitOn "\n").toArray
  -- A trailing newline ends the last line rather than starting an empty one.
  if text.endsWith "\n" then all.pop else all

/-- The page: lines `offset` onward, at most `limit` of them and at most `maxChars` characters,
as `text`, with `lines` saying which of how many they are. The field is not `output`, which
would make the page look like a command's result to a view, and be cut down again. -/
def page (output : Output) (request : Request) (maxChars : Nat) : Lean.Json :=
  let all := lines output.output
  let total := all.size
  if request.offset > total then
    .mkObj [("error", s!"the output has {total} lines; offset {request.offset} is past its end")]
  else
    let wanted := all.extract (request.offset - 1) (request.offset - 1 + request.limit)
    -- Whole lines while they fit; the first line always, cut to the limit if it alone is over.
    let (taken, _) := wanted.foldl (init := (#[], 0)) fun (taken, shown) line =>
      if taken.isEmpty then (#[(line.take maxChars).toString], min line.length maxChars)
      else if shown + 1 + line.length <= maxChars then (taken.push line, shown + 1 + line.length)
      else (taken, maxChars)
    let last := request.offset - 1 + taken.size
    let cut := taken.size == 1 && wanted[0]!.length > maxChars
    .mkObj [
      ("text", "\n".intercalate taken.toList),
      ("lines", s!"{request.offset}-{last} of {total}" ++ (if cut then s!", the line cut to {maxChars} characters" else ""))]

/-- What a `read_output` call observes: the page, or why there is none. Answered from the log
alone (`Directive.observe`). -/
def read (log : Log) (arguments : Lean.Json) (maxChars : Nat) : Lean.Json :=
  match parse arguments with
  | .error message => .mkObj [("error", message)]
  | .ok request =>
    match outputOf? log request.callId with
    | some output => page output request maxChars
    | none => .mkObj [("error", s!"no bash call with id {request.callId} in this run")]

end ReadOutput

end Alaya.Agent.Tools
