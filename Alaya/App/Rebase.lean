import Alaya.Core.Rebase
import Alaya.App.Render
import Alaya.App.Catalog

/-! The rebase command's part: the log reconfigured as the current version of its programs reads
it, and what a rebase says of itself; `Data.rebase` writes the rebased log into a new data
directory. The rebase
itself is `Alaya.Core.rebase`, a pure function of a routine and a log. -/

namespace Alaya.App

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

namespace Rebase

/-- `action`, an input error in it said to be about reading the call of `name`. -/
private def reading (name : String) (action : Result α) : Result α :=
  tryCatch action fun
    | .input message => throw <| .input s!"the call of {name}, as the current version reads it: {message}"
    | error => throw error

/-- A call's configuration as the current version of its program reads it, with the settings
of `settings` its program takes over it, every field complete; and which of `settings` it takes. -/
private def reconfigureCall (catalog : Catalog) (call : RoutineCall) (settings : Array Settings.Setting) :
    Result (RoutineCall × Array Bool) := do
  let mut config ← reading call.name (catalog.complete call.name call.arguments)
  let mut taken := #[]
  -- A setting fits a call when its program takes it.
  for setting in settings do
    match ← tryCatch (some <$> catalog.applying call.name config #[setting]) (fun _ => pure none) with
    | some applied => config := applied; taken := taken.push true
    | none => taken := taken.push false
  pure ({ call with arguments := config }, taken)

/-- The log with every call configured as the current version of its program reads it, with
`settings` over each call they fit, both where the call is asked for and where it opens. A
setting that fits no call is an error. -/
def reconfigure (catalog : Catalog) (log : Log Agent) (settings : Array Settings.Setting) :
    Result (Log Agent) := do
  let mut events := #[]
  let mut accepted := settings.map fun _ => false
  for event in log do
    match event with
    -- The calls of the catalog's programs: the run's own, the session's, is none of them.
    | .arrived (.called call) =>
      if (catalog.program? call.name).isNone then events := events.push event else
      let (call, _) ← reconfigureCall catalog call settings
      events := events.push (.arrived (.called call))
    | .opened frame call =>
      if frame.size != 2 || (catalog.program? call.name).isNone then events := events.push event else
      let (call, fits) ← reconfigureCall catalog call settings
      accepted := (accepted.zip fits).map fun (a, b) => a || b
      events := events.push (.opened frame call)
    | event => events := events.push event
  if let some (setting, _) := (settings.zip accepted).find? (!·.2) then
    throw <| .input s!"--set {setting.render} fits no call of the log"
  pure events

/-- What the agent does where the log stops being a trace of it, in a few words. -/
def expectedSummary : Next Agent → String
  | .ask call => call.op.describe
  | next =>
    let line := Render.nextSummary none none next
    if line.startsWith "next: " then (line.drop 6).toString else line

/-- How much of a log of `total` events a rebase kept, and, where it stopped, why. -/
def summary (rebased : Rebased Agent) (total : Nat) : String :=
  match rebased.divergence? with
  | none => s!"all {total} events hold"
  | some divergence =>
    s!"{divergence.position} of {total} events hold; at {divergence.position} the log has " ++
      s!"{(Render.eventSummary divergence.found).quote}, where the revised agent goes on with: " ++
      expectedSummary divergence.expected

/-- The events from outside a rebase left out, in a line each. -/
def droppedLines (rebased : Rebased Agent) : Array String :=
  rebased.dropped.map fun (position, event) => s!"left out: {position}  {Render.eventSummary event}"

end Rebase

end Alaya.App
