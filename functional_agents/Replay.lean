/-- Where replay has got to: how many events it has passed, the notices among them that the
program has not read, each with its position in the log, and how many calls the current
frame has opened (the next one's ordinal). -/
structure Cursor where
  position : Nat := 0
  unread : List (Nat × Notice) := []
  opened : Nat := 0

/-- What to do next, as far as the log tells. A log that is no trace of the program is a
result of its own, not an outcome of the agent. -/
inductive Next (σ : Signature) (α : Type) where
  | done (a : α)
  | ask (call : Call σ)                     -- the first operation the log has no answer to
  | hears (frame : Frame) (notices : List Nat)  -- the first read of the inbox not yet marked
  | waits (frame : Frame)                   -- a read that waits, and nothing has arrived for it
  | opens (frame : Frame) (tool : ToolCall) -- the first call whose opening is not logged
  | returns (frame : Frame) (value : Json)  -- the first call to end with its return not logged
  | fails (frame : Frame) (error : String)  -- the first call to fail with that not logged
  | raised (error : String) (cursor : Cursor)  -- a failure, on its way to the call that catches
  | stopped (cursor : Cursor)               -- the run was stopped from outside: every frame ends
  | mismatch (position : Nat)               -- the event here is not what the program does now
  | unguarded (frame : Frame)               -- a loop went round without reading an event

def Next.bind : Next σ α → (α → Next σ β) → Next σ β
  | .done a, f => f a
  | .ask call, _ => .ask call
  | .hears frame notices, _ => .hears frame notices
  | .waits frame, _ => .waits frame
  | .opens frame tool, _ => .opens frame tool
  | .returns frame value, _ => .returns frame value
  | .fails frame error, _ => .fails frame error
  | .raised error cursor, _ => .raised error cursor
  | .stopped cursor, _ => .stopped cursor
  | .mismatch position, _ => .mismatch position
  | .unguarded frame, _ => .unguarded frame

instance : Inhabited (Next σ α) := ⟨.mismatch 0⟩

/-- The notices at the front of the events, the first of them at `position` in the log. -/
def notices : Nat → List (Event σ) → List (Nat × Notice)
  | position, .arrived notice :: rest => (position, notice) :: notices (position + 1) rest
  | _, _ => []

/-- Passes the notices at the cursor and keeps them for the next read of the inbox. They are
events of the environment, taken in until it is the program's turn (Gu et al. 2018). So a
notice is delivered by where it stands in the log: to the first read after it that takes it. -/
def Cursor.pass (cursor : Cursor) (log : List (Event σ)) : Cursor :=
  let passed := notices cursor.position (log.drop cursor.position)
  { cursor with position := cursor.position + passed.length, unread := cursor.unread ++ passed }

/-- The answer the event gives to `call`, which may be an error. The check that it answers
exactly this call is not needed to replay a log (Thiemann 2002 logs answers alone); it is what
detects a program that is not the one that wrote the log. -/
def Event.answer? [DecidableEq σ.Op] (call : Call σ) :
    Event σ → Option (Except String (σ.Answer call.op))
  | .answered logged answer =>
    if h : logged.frame = call.frame ∧ logged.op = call.op then some (h.2 ▸ answer) else none
  | _ => none

/-- Reads a mark off the log: an event that says what the program did, with nothing in it for
the program to learn. `missing` is what to do when the log ends before it. Replay knows what
the mark must be and checks the logged one against it, so the brackets of a call cannot be
out of place, where markers alone "run the risk of being unbalanced" (Wu, Schrijvers and Hinze
2014). -/
def Cursor.mark (cursor : Cursor) (log : List (Event σ)) (expected : Event σ → Bool)
    (missing : Next σ Cursor) : Next σ Cursor :=
  let cursor := cursor.pass log
  let after := { cursor with position := cursor.position + 1 }
  match log[cursor.position]? with
  | none => missing
  | some (.stopped _) => .stopped after
  | some event => if expected event then .done after else .mismatch cursor.position

/-- Ends a frame: reads off the log the mark of how its body ended, a return with its value
or a failure with its error. This is where a failure is caught. -/
def close (log : List (Event σ)) (frame : Frame) :
    Next σ (Json × Cursor) → Next σ (Except String Json × Cursor)
  | .raised error cursor =>
    let failing | .failed left given => left == frame && given == error | _ => false
    (cursor.mark log failing (.fails frame error)).bind fun cursor => .done (.error error, cursor)
  | body => body.bind fun (value, cursor) =>
    let returning | .returned left given => left == frame && given == value | _ => false
    (cursor.mark log returning (.returns frame value)).bind fun cursor => .done (.ok value, cursor)

/-- Goes round a loop until a round gives a result. A round must read an event, so the length
of the log bounds the rounds: it is the fuel (the petrol of McBride 2015), and the guard is the
one that makes a loop well defined (Hancock and Setzer 2000; Piróg and Gibbons 2014). -/
def rounds (round : S → Cursor → Next σ ((S ⊕ β) × Cursor)) (frame : Frame) :
    Nat → S → Cursor → Next σ (β × Cursor)
  | 0, _, _ => .unguarded frame
  | fuel + 1, s, cursor =>
    (round s cursor).bind fun
      | (.inr b, after) => .done (b, after)
      | (.inl s, after) =>
        if after.position > cursor.position then rounds round frame fuel s after
        else .unguarded frame

/-- Calls a tool in the frame `child`: reads its opening off the log, lets `enter` run its body,
and reads how it ended. -/
def invoke (enter : ToolCall → Frame → Cursor → Next σ (Json × Cursor)) (log : List (Event σ))
    (tool : ToolCall) (child : Frame) (cursor : Cursor) : Next σ (Except String Json × Cursor) :=
  let opening | .opened entered called => entered == child && called == tool | _ => false
  (cursor.mark log opening (.opens child tool)).bind fun inside =>
    close log child (enter tool child { inside with opened := 0 })

/-- Runs `program` against the log, from the start: every answer is read back in order, to
continue the program where it stopped (Thiemann 2002; Koppel, Scherer and Solar-Lezama 2018;
Burckhardt et al. 2021). It is a handler that passes its place in the log along (Plotkin and
Pretnar 2009, §6.7). A call is handled by entering the tool it names in a child frame, with a
counter of its own, and going on in the parent's (the promotion and demotion of Piróg et al.
2018); its opening and its end are marks in the log. -/
def replay [DecidableEq σ.Op] (enter : ToolCall → Frame → Cursor → Next σ (Json × Cursor))
    (log : List (Event σ)) : {α : Type} → Program σ α → Frame → Cursor → Next σ (α × Cursor)
  | _, .pure a, _, cursor => .done (a, cursor)
  | _, .fail error, _, cursor => .raised error cursor
  | _, .perform op k, frame, cursor =>
    let cursor := cursor.pass log
    match log[cursor.position]? with
    | none => .ask { frame, op }
    | some (.stopped _) => .stopped { cursor with position := cursor.position + 1 }
    | some event =>
      let cursor := { cursor with position := cursor.position + 1 }
      match event.answer? { frame, op } with
      | some answer => replay enter log (k answer) frame cursor
      | none => .mismatch (cursor.position - 1)
  | _, .inbox wait k, frame, cursor =>
    let arrived := notices cursor.position (log.drop cursor.position)
    -- what the read takes, and what it leaves unread: a read that waits takes those of the
    -- notices just arrived that it is for; any other takes all that is unread, replies apart
    let (taken, left) : List (Nat × Notice) × List (Nat × Notice) := match wait with
      | some accepts =>
        let (mine, others) := arrived.partition fun (_, notice) => accepts frame notice
        (mine, cursor.unread ++ others)
      | none => (cursor.unread ++ arrived).partition fun (_, notice) => !notice.isReply
    let passed := cursor.pass log
    if wait.isSome ∧ taken.isEmpty then
      match log[passed.position]? with
      | none => .waits frame
      | some (.stopped _) => .stopped { passed with position := passed.position + 1 }
      | some _ => .mismatch passed.position
    else
      let positions := taken.map (·.1)
      let reading | .heard reader read => reader == frame && read == positions | _ => false
      (cursor.mark log reading (.hears frame positions)).bind
        fun cursor => replay enter log (k (taken.map (·.2))) frame { cursor with unread := left }
  | _, .call tool k, frame, cursor =>
    (invoke enter log tool (frame.push cursor.opened) cursor).bind fun (result, after) =>
      replay enter log (k result) frame { after with opened := cursor.opened + 1 }
  | _, .iter step s k, frame, cursor =>
    (rounds (fun s => replay enter log (step s) frame) frame (log.length + 1) s cursor).bind
      fun (b, cursor) => replay enter log (k b) frame cursor

/-- Enters a tool: looks its name up among the tools of the run and replays its body. A name
the run does not have is a failure of the call. The body is not part of the program that
called it, so this is a recursion of its own, on fuel that bounds how deep calls nest. A body
is entered only once the log holds the opening of its call, so the length of the log is fuel
enough, as it is for a loop (McBride 2015). -/
def enter [DecidableEq σ.Op] (tools : Tools σ) (log : List (Event σ)) :
    Nat → ToolCall → Frame → Cursor → Next σ (Json × Cursor)
  | 0, _, frame, _ => .unguarded frame
  | fuel + 1, tool, frame, cursor =>
    match tools tool.name with
    | some body => replay (enter tools log fuel) log (body tool.arguments) frame cursor
    | none => .raised s!"no tool named {tool.name}" cursor

/-- A run: the tools it has, the call of the agent among them, and what follows the agent.
What follows is given what the agent returned, or the error when it failed or was stopped from
outside. -/
structure Run (σ : Signature) where
  tools : Tools σ
  call : ToolCall
  after : Except String Json → Program σ Json

/-- A run, as the driver sees it: a pure function from the log to what to do next. A
participant as "a deterministic partial function from the current log to its next move" is the
strategy of Gu et al. (2018).

A run starts from a root: the first event of its log is a change from outside, the workspace
that someone provides. Without it the run waits. The root is the ground the run stands on and
not a notice for the agent: no read of the inbox takes it.

The agent is called in the frame `#[0]`, and what follows it runs in `#[]`. A stop ends every
frame of the agent, whatever the nesting, and nothing in the agent can catch it, where a
failure is caught by the call it happens in. What the agent did is kept in either case, since
the log only grows. So what follows the agent runs when the agent is over, and nothing it does
can reach the agent. The run is done once the log holds how it ended; an event left over after
that is a mismatch too. -/
def next [DecidableEq σ.Op] (run : Run σ) (log : List (Event σ)) : Next σ Json :=
  match log with
  | [] => .waits #[]
  | .arrived (.changed _ _) :: _ =>
    let enter := enter run.tools log (log.length + 1)
    let ended : Next σ (Except String Json × Cursor) :=
      match invoke enter log run.call #[0] { position := 1 } with
      | .stopped cursor => .done (.error "stopped", cursor)
      | agent => agent
    let whole := ended.bind fun (result, cursor) =>
      close log #[] (replay enter log (run.after result) #[] { cursor with opened := 1 })
    match whole with
    | .stopped cursor => .mismatch (cursor.position - 1)  -- a stop when the agent was over
    | whole => whole.bind fun (result, cursor) =>
      let cursor := cursor.pass log
      if cursor.position < log.length then .mismatch cursor.position
      else match result with
        | .ok value => .done value
        | .error error => .raised error cursor
  | _ => .mismatch 0
