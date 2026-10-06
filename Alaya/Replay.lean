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

A comment is no part of any of this. Replay passes over every comment in the log, and over
every comment the program makes. It keeps only the comments the program has made since the last
event it read, which the driver writes before the next event it appends. -/

namespace Alaya

open Lean (Json)

/-- What waits for the value of the program being run: the rounds of loops, and the calls it is
in, each with the frame and the counter of the caller to go back to, and the routines the calls
inside it enter. The bottom is the run's own frame, whose value is the result of the run. -/
inductive Stack (σ : Signature) : Type → Type 1 where
  | top : Stack σ Json
  /-- A round of a loop; `start` is how many events the machine had read when it began. -/
  | round {S β α : Type} (step : S → Program σ (S ⊕ β)) (k : β → Program σ α) (start : Nat)
      (rest : Stack σ α) : Stack σ (S ⊕ β)
  | call {α : Type} (parent : Frame) (opened : Nat) (k : Except String Json → Program σ α)
      (routines : Routines σ) (rest : Stack σ α) : Stack σ Json

/-- The routines a call enters from inside the innermost call; none in the run's own frame. -/
def Stack.routines? : Stack σ α → Option (Routines σ)
  | .top => none
  | .round _ _ _ rest => rest.routines?
  | .call _ _ _ routines _ => some routines

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
of the inbox, or nothing more; or what it says before it, a comment, which it does not need. -/
inductive Demand (σ : Signature) where
  | ask (call : Call σ) (resume : Except String (σ.Answer call.op) → Machine σ)
  | mark (expected : Event σ) (resume : Machine σ)
  | read (frame : Frame) (wait : Option Wait) (resume : List Notice → Machine σ)
  | comment (text : String) (resume : Machine σ)
  | finished (result : Except String Json)
  | unguarded (frame : Frame)

instance : Inhabited (Machine σ) := ⟨⟨Json, .pure .null, .top, #[], 0, 0, none⟩⟩
instance : Inhabited (Demand σ) := ⟨.unguarded #[]⟩

namespace Machine

/-- The machine at the start of a run: the run's own program, in `#[]`. -/
def start (run : Run σ) : Machine σ :=
  { α := Json, program := run.top, stack := .top, frame := #[], opened := 0, read := 0 }

/-- Runs the machine until it needs something from the log. A call from the run's own frame
enters one of `programs`; a call inside it, the routines that program came with. -/
partial def advance (programs : Programs σ) (m : Machine σ) : Demand σ :=
  if let some result := m.result? then .finished result else
  match m with
  | ⟨_, .pure a, .top, frame, _, read, _⟩ =>
    .mark (.returned frame a) { m with result? := some (.ok a), read := read + 1 }
  | ⟨_, .fail error, .top, frame, _, read, _⟩ =>
    .mark (.failed frame error) { m with result? := some (.error error), read := read + 1 }
  | ⟨_, .pure value, .call parent opened k _ rest, frame, _, read, _⟩ =>
    .mark (.returned frame value)
      { α := _, program := k (.ok value), stack := rest, frame := parent, opened := opened + 1
        read := read + 1 }
  | ⟨_, .fail error, .call parent opened k _ rest, frame, _, read, _⟩ =>
    .mark (.failed frame error)
      { α := _, program := k (.error error), stack := rest, frame := parent, opened := opened + 1
        read := read + 1 }
  | ⟨_, .pure (.inl s), .round step k start rest, frame, opened, read, _⟩ =>
    if read == start then .unguarded frame
    else advance programs { α := _, program := step s, stack := .round step k read rest, frame, opened, read }
  | ⟨_, .pure (.inr b), .round _ k _ rest, frame, opened, read, _⟩ =>
    advance programs { α := _, program := k b, stack := rest, frame, opened, read }
  | ⟨_, .fail error, .round _ _ _ rest, frame, opened, read, _⟩ =>
    advance programs { α := _, program := .fail error, stack := rest, frame, opened, read }
  | ⟨α, .perform op k, stack, frame, opened, read, _⟩ =>
    .ask { frame, op } fun answer => ⟨α, k answer, stack, frame, opened, read + 1, none⟩
  | ⟨α, .inbox wait k, stack, frame, opened, read, _⟩ =>
    .read frame wait fun notices => ⟨α, k notices, stack, frame, opened, read + 1, none⟩
  -- A question is a mark, the question itself, and then a read that waits for its reply.
  | ⟨α, .ask question k, stack, frame, opened, read, _⟩ =>
    let wait : Wait := { question? := some question, accepts := fun asking notice => match notice with
      | .replied to reply => to == asking && question.accepts reply
      | _ => false }
    let answered : List Notice → Program σ α
      | .replied _ reply :: _ => k reply
      | _ => .fail "the wait for a reply ended without one"
    .mark (.asked frame question) ⟨α, .inbox (some wait) answered, stack, frame, opened, read + 1, none⟩
  | ⟨_, .call routine k, stack, frame, opened, read, _⟩ =>
    let child := frame.push opened
    let made : Except String (Program σ Json × Routines σ) := match stack.routines? with
      | none => match programs routine.name with
        | some make => make routine.arguments
        | none => .error s!"no program named {routine.name}"
      | some routines => match routines routine.name with
        | some body => .ok (body routine.arguments, routines)
        | none => .error s!"no routine named {routine.name}"
    let (body, routines) : Program σ Json × Routines σ := match made with
      | .ok made => made
      | .error problem => (.fail problem, fun _ => none)
    .mark (.opened child routine)
      { α := _, program := body, stack := .call frame opened k routines stack, frame := child
        opened := 0, read := read + 1 }
  | ⟨_, .iter step s k, stack, frame, opened, read, _⟩ =>
    advance programs { α := _, program := step s, stack := .round step k read stack, frame, opened, read }
  -- A comment reads no event: a round that only comments is no guarded round.
  | ⟨α, .comment text k, stack, frame, opened, read, _⟩ =>
    .comment text ⟨α, k, stack, frame, opened, read, none⟩

/-- The machine after a stop from outside: every frame of the call the run made ends, whatever
the nesting, without a mark, and the run's own program is given the error. Nothing in the call
can catch it. `none` when no call is running, where a stop has no place. -/
def stop (m : Machine σ) : Option (Machine σ) :=
  let rec unwind {α : Type} : Stack σ α → Option (Machine σ)
    | .top => none
    | .round _ _ _ rest => unwind rest
    | .call parent opened k _ rest =>
      if parent.isEmpty then
        some { α := _, program := k (.error "stopped"), stack := rest, frame := parent
               opened := opened + 1, read := m.read + 1 }
      else unwind rest
  match m with
  -- the first call is about to be opened
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
  /-- The run is over, and its own program failed. -/
  | raised (error : String)
  /-- The first operation the log has no answer to. -/
  | ask (call : Call σ)
  /-- The first read of the inbox not yet marked, with the positions of what it takes. -/
  | hears (frame : Frame) (notices : Array Nat)
  /-- A read that waits, and nothing it takes has arrived: for the reply to `question?`, when it
  is a question's. In `#[]` with no question when the log has no root. -/
  | waits (frame : Frame) (question? : Option Question)
  /-- The program asks a person a question: a mark, after which it waits for the reply. -/
  | questions (frame : Frame) (question : Question)
  | opens (frame : Frame) (call : RoutineCall)
  | returns (frame : Frame) (value : Json)
  | fails (frame : Frame) (error : String)
  /-- The event here is not what the program does: the log is no trace of it. -/
  | mismatch (position : Nat)
  /-- A loop went round without reading an event. -/
  | unguarded (frame : Frame)

instance : Inhabited (Next σ) := ⟨.mismatch 0⟩

/-- Where replay has got to in a log: the machine and what it needs, how many events it has
passed, and the notices it has passed that no read took, each with its position. -/
structure Replayer (σ : Signature) where
  programs : Programs σ
  stops : Nat → Bool := fun _ => true
  machine : Machine σ
  demand : Demand σ
  position : Nat := 0
  unread : Array (Nat × Notice) := #[]
  /-- Whether the root, the first event, has been read. -/
  rooted : Bool := false
  /-- Set when the log has turned out to be no trace of the run. -/
  broken? : Option (Next σ) := none
  /-- The comments the program has made since the last event it read, in order: the driver
  writes them before the next event it appends. -/
  comments : Array String := #[]

namespace Replayer

/-- Goes on past the comments the program makes, keeping them, to what it needs of the log. -/
private partial def settle (r : Replayer σ) : Replayer σ :=
  match r.demand with
  | .comment text machine =>
    settle { r with machine, demand := machine.advance r.programs, comments := r.comments.push text }
  | _ => r

def start (run : Run σ) : Replayer σ :=
  let machine := Machine.start run
  settle { programs := run.programs, stops := run.stops, machine, demand := machine.advance run.programs }

/-- What a read takes, and what it leaves unread. A read that waits takes the notices it is for,
among those not yet read; any other takes all that are not yet read and addressed to no one. -/
private def take (r : Replayer σ) (frame : Frame) (wait : Option Wait) :
    Array (Nat × Notice) × Array (Nat × Notice) :=
  match wait with
  | some wait => r.unread.partition fun (_, notice) => wait.accepts frame notice
  | none => r.unread.partition fun (_, notice) => !notice.addressed

/-- What to do next, when the log ends here. -/
def next (r : Replayer σ) : Next σ :=
  if let some broken := r.broken? then broken else
  if !r.rooted then .waits #[] none else
  match r.demand with
  | .finished (.ok value) => .done value
  | .finished (.error error) => .raised error
  | .unguarded frame => .unguarded frame
  | .ask call _ => .ask call
  | .mark (.asked frame question) _ => .questions frame question
  | .mark (.opened frame call) _ => .opens frame call
  | .mark (.returned frame value) _ => .returns frame value
  | .mark (.failed frame error) _ => .fails frame error
  | .mark _ _ => .mismatch r.position
  -- Never: `settle` goes on past every comment.
  | .comment .. => .mismatch r.position
  | .read frame wait _ =>
    let (taken, _) := r.take frame wait
    if wait.isSome && taken.isEmpty then .waits frame (wait.bind (·.question?))
    else .hears frame (taken.map (·.1))

/-- The replayer with the machine gone on to `machine`, the event at its position read: the
comments made before that event are behind it. -/
private def resume (r : Replayer σ) (machine : Machine σ) : Replayer σ :=
  settle { r with machine, demand := machine.advance r.programs, position := r.position + 1, comments := #[] }

private def broken (r : Replayer σ) (next : Next σ) : Replayer σ :=
  { r with broken? := some next }

/-- The frame of what the machine needs, which says whether a stop may end it. -/
private def demandFrame? : Demand σ → Option Frame
  | .ask call _ => some call.frame
  | .mark event _ => event.frame?
  | .read frame _ _ => some frame
  | _ => none

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
  | .commented _ => { r with position := position + 1 }
  | .arrived notice => { r with unread := r.unread.push (position, notice), position := position + 1 }
  | .stopped _ =>
    let inCall := (demandFrame? r.demand).any fun frame => frame.inCall && r.stops (frame[0]?.getD 0)
    match inCall, r.machine.stop with
    | true, some machine => r.resume machine
    | _, _ => r.broken (.mismatch position)
  | event =>
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
      | .mark (.asked frame question) resume, .asked frame' question' =>
        if frame == frame' && question == question' then r.resume resume else r.broken (.mismatch position)
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
