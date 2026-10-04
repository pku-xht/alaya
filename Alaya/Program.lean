import Lean.Data.Json
import Alaya.Hash
import Alaya.Question

/-! Programs and the log: an agent, and every tool it calls, is a program, a tree of the
operations it asks the world for; a run is the flat, append-only log of what happened. See
`docs/architecture.md` and `docs/agent-api.md`.

The design follows the sketch in `functional_agents/` and the papers it cites: a program is the
free monad on a signature of operations (Hancock and Setzer 2000; Kiselyov and Ishii 2015), with
a way to fail, a read of the inbox, a call of a tool by its name, and a loop. -/

namespace Alaya

open Lean (Json)

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

/-- A call of a tool, by its name, with its arguments: what the log holds as the opening of the
call. It holds no body, so it is data. -/
structure ToolCall where
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
has arrived. A call names a tool and what it is called with: the interpreter answers it by
running the tool the run has under that name, in a child frame, and it ends with the tool's value
or its error. A loop goes round `step` from a state until a round gives a result; the state of a
loop is data, where a continuation is not. -/
inductive Program (σ : Signature) : Type → Type 1 where
  | pure : α → Program σ α
  /-- Gives up, up to the call it is in, unless something catches it first. -/
  | fail : (error : String) → Program σ α
  | perform : (op : σ.Op) → (Except String (σ.Answer op) → Program σ α) → Program σ α
  | inbox : (wait : Option (Frame → Notice → Bool)) → (List Notice → Program σ α) → Program σ α
  | call : ToolCall → (Except String Json → Program σ α) → Program σ α
  | iter : {S β : Type} → (S → Program σ (S ⊕ β)) → S → (β → Program σ α) → Program σ α

namespace Program

/-- Substitution. An operation, a read, a call and a failure commute with it; a loop extends
only its continuation, never its rounds. -/
def bind : Program σ α → (α → Program σ β) → Program σ β
  | .pure a, f => f a
  | .fail error, _ => .fail error
  | .perform op k, f => .perform op fun answer => (k answer).bind f
  | .inbox wait k, f => .inbox wait fun notices => (k notices).bind f
  | .call tool k, f => .call tool fun result => (k result).bind f
  | .iter step s k, f => .iter step s fun b => (k b).bind f

instance : Monad (Program σ) := { pure := .pure, bind := .bind }

/-- A program made to give its value or its failure: what `try` and `catch` are. It does not
reach into a tool that is called, whose failure the call has caught already, and nothing is
logged for it. -/
def attempt : Program σ α → Program σ (Except String α)
  | .pure a => .pure (.ok a)
  | .fail error => .pure (.error error)
  | .perform op k => .perform op fun answer => (k answer).attempt
  | .inbox wait k => .inbox wait fun notices => (k notices).attempt
  | .call tool k => .call tool fun result => (k result).attempt
  | .iter step s k =>
    .iter (fun s => (step s).attempt.bind fun
        | .ok (.inl s) => .pure (.inl s)
        | .ok (.inr b) => .pure (.inr (Except.ok b))
        | .error error => .pure (.inr (Except.error error))) s fun
      | .ok b => (k b).attempt
      | .error error => .pure (.error error)

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

/-- Calls a tool by its name. Its failure is its caller's too, unless the caller catches it. -/
def call (name : String) (arguments : Json) : Program σ Json :=
  .call ⟨name, arguments⟩ fun | .ok value => .pure value | .error error => .fail error

/-- Goes round `step` from `s` until a round gives a result. -/
def iter (step : S → Program σ (S ⊕ α)) (s : S) : Program σ α := .iter step s .pure

/-- The tools of a run, by name. -/
abbrev Tools (σ : Signature) := String → Option (Json → Program σ Json)

/-- A run: the tools it has, the call of the agent among them, and what follows the agent. What
follows is given what the agent returned, or the error when it failed or was stopped; if it
returns, that is the result of the run. -/
structure Run (σ : Signature) where
  tools : Tools σ
  call : ToolCall
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
A stop comes from outside and ends every frame of the agent. -/
inductive Event (σ : Signature) where
  | arrived (notice : Notice)
  | heard (frame : Frame) (notices : Array Nat)
  | answered (frame : Frame) (key : σ.Key) (answer : Except String σ.Stored)
  | opened (frame : Frame) (tool : ToolCall)
  | returned (frame : Frame) (value : Json)
  | failed (frame : Frame) (error : String)
  | stopped (reason : String)

instance : Inhabited (Event σ) := ⟨.stopped ""⟩

/-- The frame an event is in; none for a notice or a stop, which come from outside. -/
def Event.frame? : Event σ → Option Frame
  | .heard frame _ | .answered frame .. | .opened frame _ | .returned frame _ | .failed frame _ =>
    some frame
  | .arrived _ | .stopped _ => none

/-- A log: what happened, in order, from the workspace a run starts on. -/
abbrev Log (σ : Signature) := Array (Event σ)

end Alaya
