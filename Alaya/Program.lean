import Lean.Data.Json
import Alaya.Hash
import Alaya.Question

/-! Programs and the log: an agent, and every routine it calls, is a program, a tree of the
operations it asks the world for; a run is the flat, append-only log of what happened. See
`docs/agent-api.md`.

A program is the free monad on a signature of operations (Hancock and Setzer 2000; Kiselyov
and Ishii 2015), with a way to fail, a read of the inbox, a call of a routine by its name, and a
loop. The papers the design draws on are listed in `docs/agent-api.md`. -/

namespace Alaya

open Lean (Json ToJson FromJson toJson fromJson?)

/-- A signature: the operations a program may perform, each with the type of its answer, and how
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

/-- A frame is the path of calls from the root, each call being its ordinal among the calls its
parent made. Nothing in a program states an ordinal: the interpreter assigns it. `#[]` is the
frame of a run, `#[0]` in it that of the agent, and `#[1]`, `#[2]`, … those of what follows it. -/
abbrev Frame := Array Nat

/-- A frame as a reader is shown it: `0.2.1`, or `-` for the run's own. -/
def Frame.render (frame : Frame) : String :=
  if frame.isEmpty then "-" else ".".intercalate (frame.toList.map toString)

/-- Whether the frame is the agent's or inside it. -/
def Frame.inAgent (frame : Frame) : Bool := frame[0]? == some 0

/-- A call of a routine, by its name, with its arguments: what the log holds as the opening of
the call. It holds no body, so it is data. -/
structure RoutineCall where
  name : String
  arguments : Json
  deriving BEq, Inhabited

/-- Something that happened without a program asking for it, or the reply of a person to a
question a program asked: that is asked for, but it comes in its own time, from outside, so it
is logged when it arrives like the rest. -/
inductive Notice where
  /-- A person said something: the task, or a message later on. -/
  | said (message : String)
  /-- The workspace was changed from outside: it is now `workspace`, and `summary` says how. The
  first event of every log is one, the workspace a run starts from. -/
  | changed (workspace : Snapshot) (summary : String)
  /-- A person answered the question the call in frame `to` asked. -/
  | replied (to : Frame) (reply : Reply)
  /-- A person assigned the run its grader, what grades it once its agent is over: the grader,
  as JSON. What follows the agent waits for it. -/
  | assigned (grader : Json)
  deriving Inhabited

/-- Whether a notice is for one reader, who waits for it: a reply, for the call that asked, and a
grader, for what follows the agent. A plain read of the inbox leaves these. -/
def Notice.addressed : Notice → Bool
  | .replied .. | .assigned _ => true
  | _ => false

/-- A program: a tree of operations, each continued with its answer, or with the error when the
world could not give one. A read of the inbox takes the notices not yet read that are addressed to no one; one that waits is
for some notices only, which it says given the frame it is made in, and is made once one of them
has arrived. A call names a routine and what it is called with: the interpreter answers it by
running the routine the run has under that name, in a child frame, and it ends with the
routine's value or its error. A loop goes round `step` from a state until a round gives a result; the state of a
loop is data, where a continuation is not. A comment says something to whoever reads the log,
and to no one else: nothing depends on it. -/
inductive Program (σ : Signature) : Type → Type 1 where
  | pure : α → Program σ α
  /-- Gives up, up to the call it is in, unless something catches it first. -/
  | fail : (error : String) → Program σ α
  | perform : (op : σ.Op) → (Except String (σ.Answer op) → Program σ α) → Program σ α
  | inbox : (wait : Option (Frame → Notice → Bool)) → (List Notice → Program σ α) → Program σ α
  | call : RoutineCall → (Except String Json → Program σ α) → Program σ α
  | iter : {S β : Type} → (S → Program σ (S ⊕ β)) → S → (β → Program σ α) → Program σ α
  | comment : (text : String) → Program σ α → Program σ α

namespace Program

/-- Substitution. An operation, a read, a call and a failure commute with it; a loop extends
only its continuation, never its rounds. -/
def bind : Program σ α → (α → Program σ β) → Program σ β
  | .pure a, f => f a
  | .fail error, _ => .fail error
  | .perform op k, f => .perform op fun answer => (k answer).bind f
  | .inbox wait k, f => .inbox wait fun notices => (k notices).bind f
  | .call routine k, f => .call routine fun result => (k result).bind f
  | .iter step s k, f => .iter step s fun b => (k b).bind f
  | .comment text k, f => .comment text (k.bind f)

instance : Monad (Program σ) := { pure := .pure, bind := .bind }

/-- A program made to give its value or its failure: what `try` and `catch` are. It does not
reach into a routine that is called, whose failure the call has caught already, and nothing is
logged for it. -/
def attempt : Program σ α → Program σ (Except String α)
  | .pure a => .pure (.ok a)
  | .fail error => .pure (.error error)
  | .perform op k => .perform op fun answer => (k answer).attempt
  | .inbox wait k => .inbox wait fun notices => (k notices).attempt
  | .call routine k => .call routine fun result => (k result).attempt
  | .iter step s k =>
    .iter (fun s => (step s).attempt.bind fun
        | .ok (.inl s) => .pure (.inl s)
        | .ok (.inr b) => .pure (.inr (Except.ok b))
        | .error error => .pure (.inr (Except.error error))) s fun
      | .ok b => (k b).attempt
      | .error error => .pure (.error error)
  | .comment text k => .comment text k.attempt

instance : MonadExcept String (Program σ) where
  throw := .fail
  tryCatch body handler := body.attempt.bind fun
    | .ok a => .pure a
    | .error error => handler error

end Program

/-- Takes every notice not yet read that is addressed to no one (`Notice.addressed`). -/
def inbox : Program σ (List Notice) := .inbox none .pure

/-- Waits for notices that `accepts` takes, given the frame the read is made in, and takes them. -/
def await (accepts : Frame → Notice → Bool) : Program σ (List Notice) := .inbox (some accepts) .pure

/-- Performs an operation, and fails where it was performed when the world could not answer. -/
def perform (op : σ.Op) : Program σ (σ.Answer op) :=
  .perform op fun | .ok answer => .pure answer | .error error => .fail error

/-- Tries a program again while it fails, up to `attempts` times more. Every try is in the log. -/
def retry (attempts : Nat) (program : Program σ α) : Program σ α :=
  match attempts with
  | 0 => program
  | attempts + 1 => try program catch _ => retry attempts program

/-- Calls a routine by its name. Its failure is its caller's too, unless the caller catches it. -/
def call (name : String) (arguments : Json) : Program σ Json :=
  .call ⟨name, arguments⟩ fun | .ok value => .pure value | .error error => .fail error

/-- Says `text` to whoever reads the log. It is written where the driver reaches it, and replay
neither needs it nor minds it, so a program's comments can change without a log of it becoming
no trace of it. -/
def comment (text : String) : Program σ Unit := .comment text (.pure ())

/-- Goes round `step` from `s` until a round gives a result. -/
def iter (step : S → Program σ (S ⊕ α)) (s : S) : Program σ α := .iter step s .pure

/-- The routines of a run, by name: every program a call can enter. A tool a model may ask for
is one, and so is a sub-agent, and a step of a workflow. -/
abbrev Routines (σ : Signature) := String → Option (Json → Program σ Json)

/-- A routine as a table lists it: its name, and its body from a call's arguments to its result,
both JSON. -/
abbrev Routine.Entry (σ : Signature) := String × (Json → Program σ Json)

/-- The table of these routines. -/
def Routines.of (entries : Array (Routine.Entry σ)) : Routines σ :=
  fun name => (entries.find? (·.1 == name)).map (·.2)

/-- A routine: a named program from arguments to a result. A call is the only way into it, so it
always runs in a frame of its own, and the log brackets it: its opening, with its name and its
arguments, and its end, with its result or its failure. So the structure of an agent — its
workflows, its sub-agents, its tools — is the nesting of its log.

`entry` is what a run's table holds of it; `call` enters it by its name. Arguments and results
cross the call as JSON, which is what makes them data in the log: a routine is given values,
never a function. -/
structure Routine (σ : Signature) (α β : Type) where
  name : String
  entry : Routine.Entry σ
  call : α → Program σ β

/-- The routine `name`, with `body`. Its arguments and its result are read back from JSON on the
other side of the call; what cannot be read is a failure, of the routine or of its caller. -/
def routine [ToJson α] [FromJson α] [ToJson β] [FromJson β] (name : String)
    (body : α → Program σ β) : Routine σ α β where
  name
  entry := (name, fun arguments =>
    match fromJson? arguments with
    | .ok a => toJson <$> body a
    | .error problem => .fail s!"{name}: its arguments cannot be read: {problem}")
  call a := do
    let result ← call name (toJson a)
    match fromJson? result with
    | .ok b => pure b
    | .error problem => throw s!"{name}: its result cannot be read: {problem}"

/-- A run: the routines it has, the call of the agent among them, and what follows the agent.
What follows is given what the agent returned, or the error when it failed or was stopped; if it
returns, that is the result of the run. -/
structure Run (σ : Signature) where
  routines : Routines σ
  call : RoutineCall
  after : Except String Json → Program σ Json

/-- What the driver is asked to do: an operation, and the frame that asked. -/
structure Call (σ : Signature) where
  frame : Frame
  op : σ.Op

/-- One thing that happened. A notice is not asked for: it is logged when it arrives. An answer
is what the world gave an operation, with the frame that asked and the key of the operation; it
is an error when the world could not give one. The others are marks of what the program did,
logged so that the log can be read without the program: a read of the inbox, with the positions
of the notices it took, and the opening of a call and how it ended, with a return or a failure.
A stop comes from outside and ends every frame of the agent. A comment is for a reader alone:
replay passes over it wherever it stands. A program's comment has the frame that made it; a
person's has none. -/
inductive Event (σ : Signature) where
  | arrived (notice : Notice)
  | heard (frame : Frame) (notices : Array Nat)
  | answered (frame : Frame) (key : σ.Key) (answer : Except String σ.Stored)
  | opened (frame : Frame) (call : RoutineCall)
  | returned (frame : Frame) (value : Json)
  | failed (frame : Frame) (error : String)
  | stopped (reason : String)
  | commented (frame? : Option Frame) (text : String)

instance : Inhabited (Event σ) := ⟨.stopped ""⟩

/-- The frame an event is in; none for a notice, a stop or a person's comment, which come from
outside. -/
def Event.frame? : Event σ → Option Frame
  | .heard frame _ | .answered frame .. | .opened frame _ | .returned frame _ | .failed frame _ =>
    some frame
  | .commented frame? _ => frame?
  | .arrived _ | .stopped _ => none

/-- A log: what happened, in order, from the workspace a run starts on. -/
abbrev Log (σ : Signature) := Array (Event σ)

end Alaya
