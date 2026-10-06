import Alaya.Runtime.Agent

/-! What a log says of its calls: their arguments, where their commands run, and how they ended.
A call's configuration is the arguments of its opening, so every later command builds the same
program from the log alone; its commands run in the container of the environment the nearest
call on its path names. See `docs/agent-api.md` §9. -/

namespace Alaya.Runtime

open Alaya.Base Alaya.Core Alaya.LLM

open Lean (Json)

/-- The arrival of a person's call. -/
def _root_.Alaya.Core.RoutineCall.event (call : RoutineCall) : Event Agent := .arrived (.called call)

/-! ## The calls of a log -/

/-- The arguments of the call the run made in its frame's step `call`, read off its opening. -/
def argumentsAt? (log : Log Agent) (call : Frame.Segment) : Option Json :=
  log.findSome? fun
    | .opened #[_, opened] routine => if opened == call then some routine.arguments else none
    | _ => none

/-- Where the commands of a frame run, and the frame whose call said so: the nearest call on its
path that names an environment, read off the openings of `log`. -/
def environmentOf (log : Log Agent) (frame : Frame) : Result (Frame × Environment) := do
  let named : Std.HashMap Frame Json := log.foldl (init := {}) fun named event =>
    match event with
    | .opened opened { environment? := some environment, .. } => named.insert opened environment
    | _ => named
  let mut here := frame
  while !here.isEmpty do
    if let some json := named.get? here then
      match Environment.fromJson json with
      | .ok environment => return (here, environment)
      | .error problem =>
        throw <| .storage s!"the call {here.render} names an environment this build does not read: {problem}"
    here := here.pop
  throw <| .storage s!"no call on the path of {frame.render} names where its commands run"

/-- How a call ended. -/
inductive CallEnd where
  | returned (value : Json)
  | failed (error : String)
  /-- Broken from outside, by a person, with the reason the break gives. -/
  | stopped (reason : String)
  deriving Inhabited

/-- How a call the run makes ends with an event, if the event ends one: its frame is two steps,
the run's and its own; a break ends it in its frame, or in the run's. -/
def CallEnd.of? : Event Agent → Option CallEnd
  | .returned #[_, _] value => some (.returned value)
  | .failed #[_, _] error => some (.failed error)
  | .broke frame reason => if frame.size ≤ 2 then some (.stopped reason) else none
  | _ => none

/-- The last call the run makes in a log, and how it ended, once it has. -/
def lastCall? (log : Log Agent) : Option (RoutineCall × Option CallEnd) :=
  log.foldl (init := none) fun last event =>
    match event, last with
    | .opened #[_, _] call, _ => some (call, none)
    | event, some (call, none) => some (call, CallEnd.of? event)
    | _, last => last

/-- Every snapshot a log names: its versions of the workspace. -/
def snapshots (log : Log Agent) : Array Snapshot :=
  log.filterMap versionAfter?

/-- The event with every snapshot it names renamed by `rename`: the ones `snapshots` finds. -/
def _root_.Alaya.Core.Event.renameSnapshots (rename : Snapshot → Snapshot) : Event Agent → Event Agent
  | .answered frame key (.ok (.execution execution)) =>
    .answered frame key (.ok (.execution { execution with workspace := rename execution.workspace }))
  | .arrived (.changed workspace summary) => .arrived (.changed (rename workspace) summary)
  | event => event

/-- The question a run waits on, where it waits on one: the frame that asked, and the question.
Whatever asked it — a tool a model called, a step of a workflow — replay says so itself. -/
def questionOf? : Next Agent → Option (Frame × Question)
  | .waits frame (some question) => some (frame, question)
  | _ => none

/-- A person's reply to the question a run waits on, as the event to append: refused when no
question waits, or when the reply is not of the form the question asks for. -/
def replyTo (next : Next Agent) (answer : Reply) : Except String (Event Agent) := do
  let some (frame, question) := questionOf? next | throw "no question waits for a reply here"
  if !question.accepts answer then
    throw s!"the answer does not fit a {question.form.name} question"
  pure (.arrived (.replied frame answer))

/-! ## What a call is, and what it gave -/

/-- A call of an agent, by its name and its model's, `mini-swe, gpt-6-luna`: a call whose
arguments name a model, wherever it is made. -/
def agentTitle? (call : RoutineCall) : Option String :=
  (call.arguments.getObjVal? "model" >>= (·.getObjVal? "name") >>= Json.getStr?).toOption.map
    fun model => s!"{call.name}, {model}"

/-- A call of a program, by its name and, for an agent, its model's: `mini-swe, gpt-6-luna`. -/
def callTitle (call : RoutineCall) : String := (agentTitle? call).getD call.name

/-- What a value is, when it has the shape one of Alaya's own writes: a grader's verdict
(`verdictJson`), a command's result (`Tools.Bash.result`), an agent's outcome
(`MiniSwe.outcome`). Any routine may return any value, so a value is of a kind only when it has
every field of the kind, each of its type, and no other; anything else is of no kind, and is
shown as what it holds. -/
inductive ValueKind where
  | verdict
  | command
  | outcome
  deriving BEq, Repr

def ValueKind.name : ValueKind → String
  | .verdict => "verdict"
  | .command => "command"
  | .outcome => "outcome"

private def isText : Json → Bool
  | .str _ => true
  | _ => false

private def isNumber : Json → Bool
  | .num _ => true
  | _ => false

private def isArray : Json → Bool
  | .arr _ => true
  | _ => false

private def orNull (fits : Json → Bool) : Json → Bool
  | .null => true
  | other => fits other

/-- Whether `value` is an object that has every field of `required`, each as its test says, and
beside them only fields of `optional`. -/
private def shaped (value : Json) (required : List (String × (Json → Bool)))
    (optional : List String := []) : Bool :=
  match value with
  | .obj fields =>
    required.all (fun (name, fits) => (value.getObjVal? name).toOption.any fits) &&
    fields.foldl (fun known name _ => known && (required.any (·.1 == name) || optional.contains name)) true
  | _ => false

def valueKind? (value : Json) : Option ValueKind :=
  if shaped value [("status", isText), ("passed", isNumber), ("total", isNumber), ("checks", isArray)]
      ["reason", "exit_code"] then some .verdict
  else if shaped value [("output", isText), ("exit_code", orNull isNumber), ("error", orNull isText),
      ("file", orNull isText)] then some .command
  else if shaped value [("status", isText), ("submission", isText)] ["reason"] then some .outcome
  else none

end Alaya.Runtime
