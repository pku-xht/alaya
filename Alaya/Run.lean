import Alaya.Agents.Catalog

/-! A run of Alaya: a workspace, and the programs a person calls on it, one after another. The
run's routine, `session`, in its frame `#[]`, waits for a person to call a program — an agent, a
grader — calls it in a frame of its own, `#[0]`, `#[1]`, …, and when the call ends, waits for the
next. A call's configuration is the arguments of its opening, so every later command builds the
same program from the log alone, and its commands run in the container of its own image. See
`docs/agent-api.md` §9. -/

namespace Alaya

open Lean (Json)

/-- The run of Alaya: it waits for a person to call a program, calls it, and waits again. A
call's failure, or its stop, is the call's: the run goes on to wait for the next. The programs
it calls are those of the catalog. -/
def session : Routine Agent where
  name := "session"
  body _ := iter (fun (_ : Unit) => do
    match ← await fun _ notice => notice matches .called _ with
    | .called call :: _ => Computation.call call fun _ => pure (.inl ())
    | _ => throw "the wait for a call ended without one") ()
  scope := Agents.Catalog.scope

/-- The arrival of a person's call of a program. -/
def RoutineCall.event (call : RoutineCall) : Event Agent := .arrived (.called call)

/-- A person's call of the program `name`: its configuration, and where its commands run. -/
def programCall (name : String) (config : Json) (environment : Environment) : RoutineCall :=
  ⟨name, ({ config, environment? := some environment } : ProgramArguments).toJson⟩

/-! ## The calls of a log -/

/-- The arguments of the call the run made in frame `#[index]`, read off its opening. -/
def callAt? (log : Log Agent) (index : Nat) : Option ProgramArguments :=
  log.findSome? fun
    | .opened #[i] call => if i == index then (ProgramArguments.fromJson call.arguments).toOption else none
    | _ => none

/-- Where the commands of the call a frame is in run: the environment of the call the run made,
which a call inside it shares. -/
def environmentOf (log : Log Agent) (frame : Frame) : Result Environment := do
  let some index := frame[0]? | throw <| .storage "the run's own frame is no call's"
  let some { environment? := some environment, .. } := callAt? log index
    | throw <| .storage s!"the log does not open the call in frame {index} with an environment this build reads"
  pure environment

/-- How a call ended. -/
inductive CallEnd where
  | returned (value : Json)
  | failed (error : String)
  /-- Stopped from outside, by a person, with the reason the stop gives. -/
  | stopped (reason : String)
  deriving Inhabited

/-- How a call ends with an event, if the event ends one: the call's frame is `#[i]`. -/
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
