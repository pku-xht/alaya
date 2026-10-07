import Lean.Data.Json
import Alaya.Base.Hash
import Alaya.Base.Question

/-! Computations, routines and the log: an agent, and every routine it calls, is a computation,
a tree of the operations it asks the world for, under a name; a run is the flat, append-only log
of what happened. See `docs/language.md`.

A computation is the free monad on a signature of operations (Hancock and Setzer 2000; Kiselyov
and Ishii 2015), with a way to fail, a read of the inbox, a call of a routine by its name, and a
loop. The papers the design draws on are listed in `docs/language.md`. -/

namespace Alaya.Core

open Alaya.Base

open Lean (Json ToJson FromJson toJson fromJson?)

/-- A signature: the operations a computation may perform, each with the type of its answer, and how
the log keeps both. The log keeps an operation by a `Key`, enough to tell it from another: for
a model's sample that is the digest of its request, so the log does not hold the whole dialogue
again with every response. It keeps every answer as a `Stored` value, of whichever operation,
which `read` gives back as the answer of the operation it answers, or not when it is no answer
to it. -/
structure Signature where
  Op : Type
  Answer : Op → Type
  Key : Type
  key : Op → Key
  sameKey : Key → Key → Bool
  Stored : Type
  store : (op : Op) → Answer op → Stored
  read : (op : Op) → Stored → Option (Answer op)

/-- A step of a frame's path: a call, by the name of the routine called and how many calls of
that name its caller made before it. Nothing in a computation states it: the interpreter
assigns it. A call of one name does not move the calls of another, so a frame keeps its
identity when a program changes around it. -/
structure Frame.Segment where
  name : String
  occurrence : Nat := 0
  deriving BEq, Hashable, Inhabited, Repr

/-- A frame is the path of calls from outside the run. `#[]` is the outside: the person and the
driver, where nothing of the run's own runs. The run is a call made from there, in a frame of its
own, `session`; its calls are each in theirs, by routine: `session/mini-swe`, then
`session/grader`, a second `mini-swe` being `session/mini-swe#1`. -/
abbrev Frame := Array Frame.Segment

/-- A segment as a reader is shown it: `bash`, the first call of `bash`, or `bash#2`. -/
def Frame.Segment.render (segment : Frame.Segment) : String :=
  if segment.occurrence == 0 then segment.name else s!"{segment.name}#{segment.occurrence}"

/-- Reads a segment as `render` writes it. -/
def Frame.Segment.parse (text : String) : Except String Frame.Segment :=
  match text.splitOn "#" with
  | [name] => if name.isEmpty then .error "a frame has an empty step" else .ok { name }
  | [name, occurrence] => match occurrence.toNat? with
    | some occurrence => if name.isEmpty then .error s!"a frame step has no name: {text}" else .ok { name, occurrence }
    | none => .error s!"a frame step counts its calls with a number: {text}"
  | _ => .error s!"not a frame step: {text}"

/-- A frame as a reader is shown it: `session/mini-swe/bash#2`, or `-` for the outside. -/
def Frame.render (frame : Frame) : String :=
  if frame.isEmpty then "-" else "/".intercalate (frame.toList.map (·.render))

/-- Reads a frame as `render` writes it. -/
def Frame.parse (text : String) : Except String Frame :=
  if text == "-" then .ok #[] else (text.splitOn "/").toArray.mapM Frame.Segment.parse

/-- Whether `frame` is `outer` or inside it. -/
def Frame.within (frame outer : Frame) : Bool :=
  outer.size ≤ frame.size && frame.extract 0 outer.size == outer

/-- A call of a routine, by its name, with its arguments, and, when the caller says, where its
commands run: what the log holds as the opening of the call. It holds no body, so it is data.

What a call can reach is the scope of the routine it is made in, fixed where that routine is
defined; where its commands run is the environment of the nearest call on its path that names
one, which its caller decides. A call that names none runs where its caller's commands do. What
an environment is, the runtime says: here it is data, as the arguments are. -/
structure RoutineCall where
  name : String
  arguments : Json
  environment? : Option Json := none
  deriving BEq, Inhabited

/-- Something that happened without a computation asking for it, or the reply of a person to a
question a computation asked: that is asked for, but it comes in its own time, from outside, so it
is logged when it arrives like the rest. -/
inductive Notice where
  /-- A person said something: the task, or a message later on. -/
  | said (message : String)
  /-- The workspace was changed from outside: it is now `workspace`, and `summary` says how. No
  read takes it (`Notice.isMessage`). The first event of every log is one, the workspace a run
  starts from. -/
  | changed (workspace : Snapshot) (summary : String)
  /-- A person answered the question the call in frame `to` asked. -/
  | replied (to : Frame) (reply : Reply)
  /-- A person asked for a call of a routine: its name, its arguments, and where its commands
  run. The first is the run itself; later ones are for whichever computation waits for them. -/
  | called (call : RoutineCall)
  deriving Inhabited

/-- Whether a plain read of the inbox takes a notice: a message does. A reply and a call are for
one reader, who waits for them; a change of the workspace is for no reader, since what it says may
be out of date by the time a read would take it: it changes the files the next command runs on,
which a computation sees by looking. -/
def Notice.isMessage : Notice → Bool
  | .said _ => true
  | _ => false

/-- What a read that waits is for: the notices it takes, given the frame the read is made in,
and, when it waits for the reply to a question, the question. -/
structure Wait where
  accepts : Frame → Notice → Bool
  question? : Option Question := none
  /-- Whether the read takes only the first notice it is for, and leaves the others to later
  reads: a wait for a call takes one call. -/
  one : Bool := false

/-- A computation: a tree of operations, each continued with its answer, or with the error when the
world could not give one. A read of the inbox takes the messages not yet read; one that waits is
for some notices only, which it says given the frame it is made in, and is made once one of them
has arrived. A question is asked of a person, and continued with the reply. A call names a routine and what it is called with: the interpreter answers it by
running the routine the scope of the calling routine has under that name, in a child frame, and it ends with the
routine's value or its error. A loop goes round `step` from a state until a round gives a result; the state of a
loop is data, where a continuation is not. A comment says something to whoever reads the log,
and to no one else: nothing depends on it. -/
inductive Computation (σ : Signature) : Type → Type 1 where
  | pure : α → Computation σ α
  /-- Gives up, up to the call it is in, unless something catches it first. -/
  | fail : (error : String) → Computation σ α
  | perform : (op : σ.Op) → (Except String (σ.Answer op) → Computation σ α) → Computation σ α
  | inbox : (wait : Option Wait) → (List Notice → Computation σ α) → Computation σ α
  /-- Asks a person, and waits for a reply to the frame it is asked in, of a kind that fits. -/
  | ask : Question → (Reply → Computation σ α) → Computation σ α
  | call : RoutineCall → (Except String Json → Computation σ α) → Computation σ α
  | iter : {S β : Type} → (S → Computation σ (S ⊕ β)) → S → (β → Computation σ α) → Computation σ α
  | comment : (text : String) → Computation σ α → Computation σ α

namespace Computation

/-- Substitution. An operation, a read, a call and a failure commute with it; a loop extends
only its continuation, never its rounds. -/
def bind : Computation σ α → (α → Computation σ β) → Computation σ β
  | .pure a, f => f a
  | .fail error, _ => .fail error
  | .perform op k, f => .perform op fun answer => (k answer).bind f
  | .inbox wait k, f => .inbox wait fun notices => (k notices).bind f
  | .ask question k, f => .ask question fun reply => (k reply).bind f
  | .call routine k, f => .call routine fun result => (k result).bind f
  | .iter step s k, f => .iter step s fun b => (k b).bind f
  | .comment text k, f => .comment text (k.bind f)

instance : Monad (Computation σ) := { pure := .pure, bind := .bind }

/-- A computation made to give its value or its failure: what `try` and `catch` are. It does not
reach into a routine that is called, whose failure the call has caught already, and nothing is
logged for it. -/
def attempt : Computation σ α → Computation σ (Except String α)
  | .pure a => .pure (.ok a)
  | .fail error => .pure (.error error)
  | .perform op k => .perform op fun answer => (k answer).attempt
  | .inbox wait k => .inbox wait fun notices => (k notices).attempt
  | .ask question k => .ask question fun reply => (k reply).attempt
  | .call routine k => .call routine fun result => (k result).attempt
  | .iter step s k =>
    .iter (fun s => (step s).attempt.bind fun
        | .ok (.inl s) => .pure (.inl s)
        | .ok (.inr b) => .pure (.inr (Except.ok b))
        | .error error => .pure (.inr (Except.error error))) s fun
      | .ok b => (k b).attempt
      | .error error => .pure (.error error)
  | .comment text k => .comment text k.attempt

instance : MonadExcept String (Computation σ) where
  throw := .fail
  tryCatch body handler := body.attempt.bind fun
    | .ok a => .pure a
    | .error error => handler error

end Computation

/-- Takes every message not yet read (`Notice.isMessage`). -/
def inbox : Computation σ (List Notice) := .inbox none .pure

/-- Waits for notices that `accepts` takes, given the frame the read is made in, and takes them;
with `one`, only the first of them. -/
def await (accepts : Frame → Notice → Bool) (one := false) : Computation σ (List Notice) :=
  .inbox (some { accepts, one }) .pure

/-- Asks a person a question, and waits for the reply. The question goes into the log where it
is asked, and the run waits there until a person replies to the frame that asked, with a reply
that fits the question: no other notice ends the wait. A question that cannot be asked
(`Question.validate`) is a failure where it is asked. -/
def ask (question : Question) : Computation σ Reply :=
  match question.validate with
  | .ok () => .ask question .pure
  | .error problem => .fail problem

/-- Performs an operation, and fails where it was performed when the world could not answer. -/
def perform (op : σ.Op) : Computation σ (σ.Answer op) :=
  .perform op fun | .ok answer => .pure answer | .error error => .fail error

/-- Tries a computation again while it fails, up to `attempts` times more. Every try is in the log. -/
def retry (attempts : Nat) (computation : Computation σ α) : Computation σ α :=
  match attempts with
  | 0 => computation
  | attempts + 1 => try computation catch _ => retry attempts computation

/-- Calls a routine by its name, its commands to run in `environment?` when one is given, and
where the caller's do otherwise. Its failure is its caller's too, unless the caller catches it. -/
def call (name : String) (arguments : Json) (environment? : Option Json := none) :
    Computation σ Json :=
  .call { name, arguments, environment? } fun | .ok value => .pure value | .error error => .fail error

/-- Says `text` to whoever reads the log. Replay passes over it, and over every comment a log
holds, so a computation's comments can change without a log of it becoming no trace of it; the
driver writes it before the next event it appends. -/
def comment (text : String) : Computation σ Unit := .comment text (.pure ())

/-- Goes round `step` from `s` until a round gives a result. -/
def iter (step : S → Computation σ (S ⊕ α)) (s : S) : Computation σ α := .iter step s .pure

mutual
/-- A routine: a computation from its arguments to its result, both JSON, under a name, with a
scope: the routines it can call. A call is the only way into a routine, so it always
runs in a frame of its own, and the log brackets it: its opening, with its name and its
arguments, and its end, with its result or its failure. So the structure of an agent — its
workflows, its sub-agents, its tools — is the nesting of its log. The run itself is a routine,
which is called from outside, in a frame of its own, like any other.

Like a closure, a routine brings its scope: what a call inside it means is fixed where the
routine is defined, not by whoever calls it. What varies from call to call comes in its
arguments, so it is data in the log. -/
structure Routine (σ : Signature) : Type 1 where
  name : String
  body : Json → Computation σ Json
  scope : Scope σ

/-- A scope: a set of routines, by name. -/
structure Scope (σ : Signature) : Type 1 where
  find : String → Option (Routine σ)
end

instance : Inhabited (Scope σ) := ⟨⟨fun _ => none⟩⟩

namespace Scope

/-- The scope with no routines. -/
def empty : Scope σ := default

/-- The scope of these routines. -/
def of (routines : Array (Routine σ)) : Scope σ :=
  ⟨fun name => routines.find? (·.name == name)⟩

/-- The scope of the routines `make` gives, each given the scope itself, as `letrec` binds: so
routines defined together call each other, and themselves, by name. -/
partial def fix (make : Scope σ → Array (Routine σ)) : Scope σ :=
  ⟨fun name => (make (fix make)).find? (·.name == name)⟩

/-- The scope without the routine `name`, in it or in the scope of any routine it reaches. -/
partial def without (scope : Scope σ) (name : String) : Scope σ :=
  ⟨fun found => if found == name then none else
    (scope.find found).map fun routine => { routine with scope := routine.scope.without name }⟩

end Scope

/-- A routine as Lean code calls it, with typed arguments and result: its name, its body, and the
call. Its arguments and its result cross the call as JSON, which is what makes them data in the
log: a routine is given values, never a function. It becomes a routine when it is given its
scope (`within`). -/
structure Routine.Typed (σ : Signature) (α β : Type) where
  name : String
  body : Json → Computation σ Json
  call : α → Computation σ β

/-- The routine, its calls naming routines in `scope`. -/
def Routine.Typed.within (typed : Routine.Typed σ α β) (scope : Scope σ) : Routine σ :=
  { name := typed.name, body := typed.body, scope }

/-- The routine `name`, with `body`. Its arguments and its result are read back from JSON on the
other side of the call; what cannot be read is a failure, of the routine or of its caller. -/
def routine [ToJson α] [FromJson α] [ToJson β] [FromJson β] (name : String)
    (body : α → Computation σ β) : Routine.Typed σ α β where
  name
  body arguments :=
    match fromJson? arguments with
    | .ok a => toJson <$> body a
    | .error problem => .fail s!"{name}: its arguments cannot be read: {problem}"
  call a := do
    let result ← call name (toJson a)
    match fromJson? result with
    | .ok b => pure b
    | .error problem => throw s!"{name}: its result cannot be read: {problem}"

/-- What the driver is asked to do: an operation, and the frame that asked. -/
structure OpRequest (σ : Signature) where
  frame : Frame
  op : σ.Op

/-- One thing that happened. A notice is not asked for: it is logged when it arrives. An answer
is what the world gave an operation, with the frame that asked and the key of the operation; it
is an error when the world could not give one. The others are marks of what the computation did,
logged so that the log can be read without the computation: a read of the inbox, with the positions
of the notices it took, a question asked of a person, and the opening of a call and how it
ended, with a return or a failure.
A break comes from outside and ends the call open in its frame, and every call inside it: the
caller is given `reason` as the call's failure. A comment is for a reader alone, whoever wrote
it: replay passes over it wherever it stands. -/
inductive Event (σ : Signature) where
  | arrived (notice : Notice)
  | heard (frame : Frame) (notices : Array Nat)
  | asked (frame : Frame) (question : Question)
  | answered (frame : Frame) (key : σ.Key) (answer : Except String σ.Stored)
  | opened (frame : Frame) (call : RoutineCall)
  | returned (frame : Frame) (value : Json)
  | failed (frame : Frame) (error : String)
  | broke (frame : Frame) (reason : String)
  | commented (text : String)

instance : Inhabited (Event σ) := ⟨.commented ""⟩

/-- The frame an event is in; none for a notice, a break or a comment, which no frame makes. -/
def Event.frame? : Event σ → Option Frame
  | .heard frame _ | .asked frame _ | .answered frame .. | .opened frame _ | .returned frame _
  | .failed frame _ => some frame
  | .arrived _ | .broke .. | .commented _ => none

/-- A log: what happened, in order, from the workspace a run starts on. -/
abbrev Log (σ : Signature) := Array (Event σ)

end Alaya.Core
