import Alaya.App.Catalog
import Alaya.Runtime.Walk

/-!
A run that `alaya new` starts is a call of `session`: in its frame, `session`, it waits for a
person to call a program, calls it in a frame of its own (`session/mini-swe`), and when the call
ends waits for the next. Whether a run waits for a call, whether a call runs, and which call a
stop ends are what the session makes of them; the runtime knows none of it.
-/

namespace Alaya.App.Session

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

/-- The run of programs of `scope`: it waits for a person to call one, calls it, and waits
again. A call's failure, or its break, is the call's: the run goes on to wait for the next. -/
def «of» (scope : Scope Agent) : Routine Agent where
  name := "session"
  body _ := iter (fun (_ : Unit) => do
    match ← await (one := true) fun _ notice => notice matches .called _ with
    | .called call :: _ => Computation.call call fun _ => pure (.inl ())
    | _ => throw "the wait for a call ended without one") ()
  scope

/-- What a run's call may name: the session over the catalog's programs, or a program alone. -/
def scope : Scope Agent := Scope.of (#[«of» Catalog.scope] ++ Catalog.all.map (·.routine))

/-- The call that starts a run of `alaya new`. -/
def call : RoutineCall := { name := "session", arguments := .null }

/-- The session's frame. -/
def frame : Frame := #[{ name := "session" }]

/-- Whether the run waits for a person to call a program: the session waits, with no question. -/
def idle : Next Agent → Bool
  | .waits waiting none => waiting == frame
  | _ => false

/-- Whether a call of the session's runs where a log ends: what the run does next is in its frame
or inside it, the call opened already. -/
def running : Next Agent → Bool
  | .ask call => call.frame.size ≥ 2
  | .mark (.opened frame _) => frame.size > 2
  | .mark event => event.frame?.any (·.size ≥ 2)
  | .waits frame _ => frame.size ≥ 2
  | _ => false

/-- Whether a person may call a program where the run does `next`: only where the session waits
for one, no call running and none read yet. -/
def admitsCall (next : Next Agent) : Result Unit := do
  if running next then
    throw <| .input "a call is running: a program is called once it is over; `alaya stop` ends it first"
  if next matches .ended _ then throw <| .input "the run is over: it calls nothing more"
  if !idle next then throw <| .input "the run has a call to make here already: `alaya resume` makes it"

/-- Whether a person's notice — a message, a change, a reply — has a reader where the run does
`next`: only while a call runs. -/
def admitsNotice (next : Next Agent) : Result Unit := do
  if !running next then
    throw <| .input "no call is running: nothing would read a notice appended here; append it at an entry before the call's end"

/-- The frame a stop ends by default: the session's call open at an entry, given the calls open
there, outermost first. -/
def callToStop (open' : Array OpenCall) : Result Frame := do
  let some call := open'.find? (·.frame.size == 2)
    | throw <| .input "no call is running: there is nothing to stop"
  pure call.frame

end Alaya.App.Session
