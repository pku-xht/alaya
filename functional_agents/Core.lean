/-- A signature: the operations a program may perform, each with the type of its answer.
Hancock and Setzer (2000) call it a world, of commands and responses; McBride (2015) has the
same pair as `S` and `T`. -/
structure Signature where
  Op : Type
  Answer : Op → Type

/-- A frame is the path of calls from the root, each call being its ordinal among the calls
its parent made. Nothing in a program states an ordinal: the interpreter assigns it. `#[]` is
the frame of a run, and `#[0]` in it that of the agent. -/
abbrev Frame := Array Nat

/-- Something that happened without a program asking for it, or the reply of a person to a
question a program asked: that is asked for, but it comes in its own time, from outside, so it
is logged when it arrives like the rest. A reply names the call that asked. -/
inductive Notice where
  | said (message : String)                            -- a person spoke
  | changed (workspace : Snapshot) (summary : String)  -- the workspace was changed from outside
  | replied (to : Frame) (reply : Reply)               -- a person answered a question

def Notice.isReply : Notice → Bool
  | .replied .. => true
  | _ => false

/-- A program: a tree of operations, each continued with its answer, or with the error when the
world could not give one. It is the free monad on its signature (`Program` in Apfelmus 2010;
Kiselyov and Ishii 2015), with three constructors more, and a way to fail. The inbox gives the
notices not yet read, replies apart. A read that waits is for some notices only, which it says
given the frame it is made in: it is made once one of them has arrived, takes those that stand
at the end of the log, and leaves the rest unread. A call names a tool and what it is called with, and
holds no body: it is a request, as a recursive call is in McBride (2015), and so it is data.
The interpreter answers it by running the tool the run has under that name, in a child frame.
A program cannot run a tool otherwise, and the opening the log holds is the call itself. A
program that fails gives up what it was doing, up to the call it is in: a call ends with the
value of its tool or with its error (the `Catch` of Wu, Schrijvers and Hinze 2014). A loop
goes round `step` from a state until a round gives a result: `iter` of Xia et al. (2020),
`while` of Hancock and Setzer (2000). The state of a loop is data, where a continuation is
not. -/
inductive Program (σ : Signature) : Type → Type 1 where
  | pure : α → Program σ α
  | fail : (error : String) → Program σ α                               -- give up
  | perform : (op : σ.Op) → (Except String (σ.Answer op) → Program σ α) → Program σ α  -- ask
  | inbox : (wait : Option (Frame → Notice → Bool)) → (List Notice → Program σ α) → Program σ α
  | call : ToolCall → (Except String Json → Program σ α) → Program σ α  -- a tool, by its name
  | iter : {S : Type} → (S → Program σ (S ⊕ β)) → S → (β → Program σ α) → Program σ α

/-- Substitution. `perform` commutes with it, which is what makes an operation algebraic
(Plotkin and Power 2003), and so do a read of the inbox, a call, and `fail`, which has nothing
to continue. A loop does not: only its continuation is extended, never its rounds. -/
def Program.bind : Program σ α → (α → Program σ β) → Program σ β
  | .pure a, f => f a
  | .fail error, _ => .fail error
  | .perform op k, f => .perform op fun answer => (k answer).bind f
  | .inbox wait k, f => .inbox wait fun notices => (k notices).bind f
  | .call tool k, f => .call tool fun result => (k result).bind f
  | .iter step s k, f => .iter step s fun b => (k b).bind f

instance : Monad (Program σ) := { pure := .pure, bind := .bind }

/-- A program made to give its value or its failure: what `try` and `catch` are. Raising is
algebraic, and handling is "of a different computational character" (Plotkin and Power 2003):
here it is a function of the whole program. It does not reach into a tool that is called,
whose failure the call has caught already. Nothing is logged for it. -/
def Program.attempt : Program σ α → Program σ (Except String α)
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

def inbox : Program σ (List Notice) := .inbox none .pure
def await (accepts : Frame → Notice → Bool) : Program σ (List Notice) := .inbox (some accepts) .pure
/-- Tries a program again while it fails, up to `attempts` times more. Every try is in the log,
with how it ended. -/
def retry (attempts : Nat) (program : Program σ α) : Program σ α :=
  match attempts with
  | 0 => program
  | attempts + 1 => try program catch _ => retry attempts program

/-- Calls a tool. Its failure is its caller's too, unless the caller catches it. -/
def call (name : String) (arguments : Json) : Program σ Json :=
  .call ⟨name, arguments⟩ fun | .ok value => .pure value | .error error => .fail error

/-- The tools of a run, by name. -/
abbrev Tools (σ : Signature) := String → Option (Json → Program σ Json)
def iter (step : S → Program σ (S ⊕ α)) (s : S) : Program σ α := .iter step s .pure

/-- What the driver is asked to do: an operation, and the frame that asked. -/
structure Call (σ : Signature) where
  frame : Frame
  op : σ.Op

/-- The log is a list of events. A call with its answer is what the program asked for; the
answer is an error when the world could not give one, and the call then fails. A notice is
not asked for: the driver logs it when it arrives, before anything acts on it, as Goldstein et al.
(2020) do with input that cannot be replayed. The other three are marks of what the program
did, logged so that the log can be read without the program. A read of the inbox holds the
positions in the log of the notices it took.
A call is bracketed by its opening, which is the call, and its end: a return, with what the
tool gave, or a failure, with the error. They are the begin and end markers of Wu, Schrijvers and
Hinze (2014, §7). The frame `#[]` of the run
has a return alone, and a log is complete when it ends with it. A stop, like a notice, comes
from outside; it is not read: it ends every frame of the agent. -/
inductive Event (σ : Signature) where
  | arrived (notice : Notice)
  | heard (frame : Frame) (notices : List Nat)
  | answered (call : Call σ) (answer : Except String (σ.Answer call.op))
  | opened (frame : Frame) (tool : ToolCall)
  | returned (frame : Frame) (value : Json)
  | failed (frame : Frame) (error : String)
  | stopped (reason : String)
