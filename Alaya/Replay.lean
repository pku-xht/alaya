import Alaya.Program

/-! Replay: the interpreter that turns a run into the function from its log to what to do next,
which is all the driver sees of an agent.

It replays the program against the log from the start: every answer is read back in order to
continue the program where it stopped (Thiemann 2002; Koppel, Scherer and Solar-Lezama 2018;
Burckhardt et al. 2021), and every mark is checked against the one the program makes, so a log
that is no trace of the program is found out (`Next.mismatch`), not taken for an outcome of the
agent. A call runs the routine the run has under its name in a child frame, with a counter of its
own (Piróg et al. 2018), and is bracketed in the log by its opening and its end (Wu, Schrijvers
and Hinze 2014).

The interpreter is a machine whose continuation is kept between events, so a driver feeds it one
event at a time and never replays from the start, and a reader replays a whole log in one pass.
A loop must read an event every round (Hancock and Setzer 2000), which is what makes every step
of the machine end.

A comment is no part of any of this. Replay passes over a comment in the log wherever it
stands, and over a comment the program makes where the log holds none: a program's comment is
written when the driver reaches it at the end of a log, and never needed after. -/

namespace Alaya

open Lean (Json)

/-- What waits for the value of the program being run: the rounds of loops, and the calls it is
in, each with the frame and the counter of the caller to go back to. The bottom is the run's own
frame, whose value is the result of the run. -/
inductive Stack (σ : Signature) : Type → Type 1 where
  | top : Stack σ Json
  /-- A round of a loop; `start` is how many events the machine had read when it began. -/
  | round {S β α : Type} (step : S → Program σ (S ⊕ β)) (k : β → Program σ α) (start : Nat)
      (rest : Stack σ α) : Stack σ (S ⊕ β)
  | call {α : Type} (parent : Frame) (opened : Nat) (k : Except String Json → Program σ α)
      (rest : Stack σ α) : Stack σ Json

/-- The interpreter between two events: the program it runs, what waits for its value, the frame
it runs in and how many calls that frame has opened, and how many events it has read. -/
structure Machine (σ : Signature) : Type 1 where
  α : Type
  program : Program σ α
  stack : Stack σ α
  frame : Frame
  opened : Nat
  read : Nat
  /-- The result of the run, once its end is logged. -/
  result? : Option (Except String Json) := none

/-- What the machine needs next from the log: an answer to an operation, a mark it makes, a read
of the inbox, or nothing more; or what it says there, a comment, which it does not need. -/
inductive Demand (σ : Signature) where
  | ask (call : Call σ) (resume : Except String (σ.Answer call.op) → Machine σ)
  | mark (expected : Event σ) (resume : Machine σ)
  | read (frame : Frame) (wait : Option (Frame → Notice → Bool)) (resume : List Notice → Machine σ)
  | comment (frame : Frame) (text : String) (resume : Machine σ)
  | finished (result : Except String Json)
  | unguarded (frame : Frame)

instance : Inhabited (Machine σ) := ⟨⟨Json, .pure .null, .top, #[], 0, 0, none⟩⟩
instance : Inhabited (Demand σ) := ⟨.unguarded #[]⟩

namespace Machine

/-- The machine at the start of a run: the agent is called in `#[0]`, and what follows it is the
continuation of that call, in the run's own frame. -/
def start (run : Run σ) : Machine σ :=
  { α := Json, program := .call run.call run.after, stack := .top, frame := #[], opened := 0
    read := 0 }

/-- Runs the machine until it needs something from the log. -/
partial def advance (routines : Routines σ) (m : Machine σ) : Demand σ :=
  if let some result := m.result? then .finished result else
  match m with
  | ⟨_, .pure a, .top, frame, _, read, _⟩ =>
    .mark (.returned frame a) { m with result? := some (.ok a), read := read + 1 }
  | ⟨_, .fail error, .top, frame, _, read, _⟩ =>
    .mark (.failed frame error) { m with result? := some (.error error), read := read + 1 }
  | ⟨_, .pure value, .call parent opened k rest, frame, _, read, _⟩ =>
    .mark (.returned frame value)
      { α := _, program := k (.ok value), stack := rest, frame := parent, opened := opened + 1
        read := read + 1 }
  | ⟨_, .fail error, .call parent opened k rest, frame, _, read, _⟩ =>
    .mark (.failed frame error)
      { α := _, program := k (.error error), stack := rest, frame := parent, opened := opened + 1
        read := read + 1 }
  | ⟨_, .pure (.inl s), .round step k start rest, frame, opened, read, _⟩ =>
    if read == start then .unguarded frame
    else advance routines { α := _, program := step s, stack := .round step k read rest, frame, opened, read }
  | ⟨_, .pure (.inr b), .round _ k _ rest, frame, opened, read, _⟩ =>
    advance routines { α := _, program := k b, stack := rest, frame, opened, read }
  | ⟨_, .fail error, .round _ _ _ rest, frame, opened, read, _⟩ =>
    advance routines { α := _, program := .fail error, stack := rest, frame, opened, read }
  | ⟨α, .perform op k, stack, frame, opened, read, _⟩ =>
    .ask { frame, op } fun answer => ⟨α, k answer, stack, frame, opened, read + 1, none⟩
  | ⟨α, .inbox wait k, stack, frame, opened, read, _⟩ =>
    .read frame wait fun notices => ⟨α, k notices, stack, frame, opened, read + 1, none⟩
  | ⟨_, .call routine k, stack, frame, opened, read, _⟩ =>
    let child := frame.push opened
    let body : Program σ Json := match routines routine.name with
      | some body => body routine.arguments
      | none => .fail s!"no routine named {routine.name}"
    .mark (.opened child routine)
      { α := _, program := body, stack := .call frame opened k stack, frame := child, opened := 0
        read := read + 1 }
  | ⟨_, .iter step s k, stack, frame, opened, read, _⟩ =>
    advance routines { α := _, program := step s, stack := .round step k read stack, frame, opened, read }
  -- A comment reads no event: a round that only comments is no guarded round.
  | ⟨α, .comment text k, stack, frame, opened, read, _⟩ =>
    .comment frame text ⟨α, k, stack, frame, opened, read, none⟩

/-- The machine after a stop from outside: every frame of the agent ends, whatever the nesting,
without a mark, and what follows the agent is given the error. Nothing in the agent can catch
it. `none` when the agent is over, where a stop has no place. -/
def stop (m : Machine σ) : Option (Machine σ) :=
  let rec unwind {α : Type} : Stack σ α → Option (Machine σ)
    | .top => none
    | .round _ _ _ rest => unwind rest
    | .call parent opened k rest =>
      if parent.isEmpty then
        some { α := _, program := k (.error "stopped"), stack := rest, frame := parent
               opened := opened + 1, read := m.read + 1 }
      else unwind rest
  match m with
  -- the agent is about to be opened
  | ⟨_, .call _ k, stack, #[], opened, read, none⟩ =>
    if opened == 0 then
      some { α := _, program := k (.error "stopped"), stack, frame := #[], opened := 1
             read := read + 1 }
    else none
  | ⟨_, _, stack, _, _, _, none⟩ => unwind stack
  | _ => none

end Machine

/-- What to do next, as far as the log tells. -/
inductive Next (σ : Signature) where
  /-- The run is over, with this result. -/
  | done (value : Json)
  /-- The run is over, and what follows the agent failed. -/
  | raised (error : String)
  /-- The first operation the log has no answer to. -/
  | ask (call : Call σ)
  /-- The first read of the inbox not yet marked, with the positions of what it takes. -/
  | hears (frame : Frame) (notices : Array Nat)
  /-- A read that waits, and nothing it takes has arrived; `#[]` when the log has no root. -/
  | waits (frame : Frame)
  | opens (frame : Frame) (call : RoutineCall)
  | returns (frame : Frame) (value : Json)
  | fails (frame : Frame) (error : String)
  /-- The event here is not what the program does: the log is no trace of it. -/
  | mismatch (position : Nat)
  /-- A loop went round without reading an event. -/
  | unguarded (frame : Frame)
  /-- The program says this next: a comment, which the driver writes and replay does not need. -/
  | comments (frame : Frame) (text : String)

instance : Inhabited (Next σ) := ⟨.mismatch 0⟩

/-- Where replay has got to in a log: the machine and what it needs, how many events it has
passed, and the notices it has passed that no read took, each with its position. -/
structure Replayer (σ : Signature) where
  routines : Routines σ
  machine : Machine σ
  demand : Demand σ
  position : Nat := 0
  unread : Array (Nat × Notice) := #[]
  /-- Whether the root, the first event, has been read. -/
  rooted : Bool := false
  /-- Set when the log has turned out to be no trace of the run. -/
  broken? : Option (Next σ) := none

namespace Replayer

def start (run : Run σ) : Replayer σ :=
  let machine := Machine.start run
  { routines := run.routines, machine, demand := machine.advance run.routines }

/-- What a read takes, and what it leaves unread. A read that waits takes the notices it is for,
among those not yet read; any other takes all that are not yet read and addressed to no one. -/
private def take (r : Replayer σ) (frame : Frame) (wait : Option (Frame → Notice → Bool)) :
    Array (Nat × Notice) × Array (Nat × Notice) :=
  match wait with
  | some accepts => r.unread.partition fun (_, notice) => accepts frame notice
  | none => r.unread.partition fun (_, notice) => !notice.addressed

/-- What to do next, when the log ends here. -/
def next (r : Replayer σ) : Next σ :=
  if let some broken := r.broken? then broken else
  if !r.rooted then .waits #[] else
  match r.demand with
  | .finished (.ok value) => .done value
  | .finished (.error error) => .raised error
  | .unguarded frame => .unguarded frame
  | .ask call _ => .ask call
  | .mark (.opened frame call) _ => .opens frame call
  | .mark (.returned frame value) _ => .returns frame value
  | .mark (.failed frame error) _ => .fails frame error
  | .mark _ _ => .mismatch r.position
  | .comment frame text _ => .comments frame text
  | .read frame wait _ =>
    let (taken, _) := r.take frame wait
    if wait.isSome && taken.isEmpty then .waits frame else .hears frame (taken.map (·.1))

/-- The replayer with the machine gone on to `machine`, the event at its position read. -/
private def resume (r : Replayer σ) (machine : Machine σ) : Replayer σ :=
  { r with machine, demand := machine.advance r.routines, position := r.position + 1 }

private def broken (r : Replayer σ) (next : Next σ) : Replayer σ :=
  { r with broken? := some next }

/-- The frame of what the machine needs, which says whether a stop may end it. -/
private def demandFrame? : Demand σ → Option Frame
  | .ask call _ => some call.frame
  | .mark event _ => event.frame?
  | .read frame _ _ => some frame
  | .comment frame _ _ => some frame
  | _ => none

/-- Passes over the comments the program makes where the log holds none: one is written at the
end of a log or not at all, and replay never needs it. -/
private partial def passComments (r : Replayer σ) : Replayer σ :=
  match r.demand with
  | .comment _ _ machine => passComments { r with machine, demand := machine.advance r.routines }
  | _ => r

/-- Reads one more event of the log. -/
def feed (r : Replayer σ) (event : Event σ) : Replayer σ :=
  if r.broken?.isSome then r else
  if let .unguarded frame := r.demand then r.broken (.unguarded frame) else
  let position := r.position
  if !r.rooted then
    match event with
    | .arrived (.changed ..) => { r with rooted := true, position := 1 }
    | _ => r.broken (.mismatch position)
  else match event with
  | .commented frame? text =>
    -- The comment the program makes here, written; any other is passed over, and changes nothing.
    match r.demand with
    | .comment frame expected machine =>
      if frame? == some frame && text == expected then r.resume machine
      else { r with position := position + 1 }
    | _ => { r with position := position + 1 }
  | .arrived notice => { r with unread := r.unread.push (position, notice), position := position + 1 }
  | .stopped _ =>
    let inAgent := (demandFrame? r.demand).any (·.inAgent)
    match inAgent, r.machine.stop with
    | true, some machine => r.resume machine
    | _, _ => r.broken (.mismatch position)
  | event =>
    let r := r.passComments
    if let .unguarded frame := r.demand then r.broken (.unguarded frame) else
    match r.demand with
    | .read frame wait resume =>
      let (taken, left) := r.take frame wait
      if wait.isSome && taken.isEmpty then r.broken (.mismatch position) else
      match event with
      | .heard reader positions =>
        if reader == frame && positions == taken.map (·.1) then
          let notices : List Notice := (taken.map fun (_, notice) => notice).toList
          { r with unread := left }.resume (resume notices)
        else r.broken (.mismatch position)
      | _ => r.broken (.mismatch position)
    | demand =>
      match demand, event with
      | .ask call resume, .answered frame key answer =>
        if frame == call.frame && (σ.sameKey key (σ.key call.op)) then
          match answer with
          | .error error => r.resume (resume (.error error))
          | .ok stored => match σ.read call.op stored with
            | some answer => r.resume (resume (.ok answer))
            | none => r.broken (.mismatch position)
        else r.broken (.mismatch position)
      | .mark (.opened frame call) resume, .opened frame' call' =>
        if frame == frame' && call == call' then r.resume resume else r.broken (.mismatch position)
      | .mark (.returned frame value) resume, .returned frame' value' =>
        if frame == frame' && value == value' then r.resume resume else r.broken (.mismatch position)
      | .mark (.failed frame error) resume, .failed frame' error' =>
        if frame == frame' && error == error' then r.resume resume else r.broken (.mismatch position)
      | _, _ => r.broken (.mismatch position)

/-- Replays a whole log. -/
def ofLog (run : Run σ) (log : Log σ) : Replayer σ :=
  log.foldl feed (start run)

end Replayer

/-- What a run does next after `log`: the pure function from the log that the driver sees. -/
def next (run : Run σ) (log : Log σ) : Next σ := (Replayer.ofLog run log).next

end Alaya
