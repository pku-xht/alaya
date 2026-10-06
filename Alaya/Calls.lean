import Alaya.Agent

/-! The calls of a run: a workspace, and the programs a person calls on it, one after another.
The run's routine, `session scope`, in its frame `#[]`, waits for a person to call a program of
`scope` — an agent, a grader — calls it in a frame of its own, named by the program (`mini-swe`,
then `grader`), and when the call ends, waits for the next. A call's configuration is the
arguments of its opening, so every later command builds the same program from the log alone;
its commands run in the container of the environment the person's call names. Then what a log
says of its calls: their arguments, where their commands run, and how they ended. See
`docs/agent-api.md` §9. -/

namespace Alaya

open Lean (Json)

/-- The run of programs of `scope`: it waits for a person to call one, calls it, and waits
again. A call's failure, or its stop, is the call's: the run goes on to wait for the next. -/
def session (scope : Scope Agent) : Routine Agent where
  name := "session"
  body _ := iter (fun (_ : Unit) => do
    match ← await fun _ notice => notice matches .called _ with
    | .called call :: _ => Computation.call call fun _ => pure (.inl ())
    | _ => throw "the wait for a call ended without one") ()
  scope

/-- The arrival of a person's call. -/
def RoutineCall.event (call : RoutineCall) : Event Agent := .arrived (.called call)

/-! ## The calls of a log -/

/-- The arguments of the call the run made in frame `#[call]`, read off its opening. -/
def argumentsAt? (log : Log Agent) (call : Frame.Segment) : Option Json :=
  log.findSome? fun
    | .opened #[opened] routine => if opened == call then some routine.arguments else none
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
  /-- Stopped from outside, by a person, with the reason the stop gives. -/
  | stopped (reason : String)
  deriving Inhabited

/-- How a call the run made ends with an event, if the event ends one: its frame is one step. -/
def CallEnd.of? : Event Agent → Option CallEnd
  | .returned #[_] value => some (.returned value)
  | .failed #[_] error => some (.failed error)
  | .stopped reason => some (.stopped reason)
  | _ => none

/-- The last call a log opens, and how it ended, once it has. -/
def lastCall? (log : Log Agent) : Option (RoutineCall × Option CallEnd) :=
  log.foldl (init := none) fun last event =>
    match event, last with
    | .opened #[_] call, _ => some (call, none)
    | event, some (call, none) => some (call, CallEnd.of? event)
    | _, last => last

/-- Every snapshot a log names: its versions of the workspace. -/
def snapshots (log : Log Agent) : Array Snapshot :=
  log.filterMap versionAfter?

/-- The event with every snapshot it names renamed by `rename`: the ones `snapshots` finds. -/
def Event.renameSnapshots (rename : Snapshot → Snapshot) : Event Agent → Event Agent
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

end Alaya
