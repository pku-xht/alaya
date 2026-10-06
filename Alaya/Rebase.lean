import Alaya.Render
import Alaya.Cache
import Alaya.Workspaces

/-! Rebase: a run's log, made again by another version of its agent. A log is a trace of the
run's routine that wrote it, and a routine changed after it was written reads it only up to its
first changed operation (`docs/agent-api.md` §4). Rebase keeps that prefix, as the new routine makes
it, in a data directory of its own, where the run goes on: every log of a data directory stays a
trace of the agent that directory runs.

Rebase is the driver with the old log for its world. The new routine is replayed, and whatever
it asks for is taken from the old log: the answer to an operation it asks for again, a mark it
makes again, a notice where one arrived. The comments of the old log are left out, and the new
routine's are written as the driver writes them. Where it asks for something the log does not hold,
the copy ends, and what came from outside after that point is left out, since a position after it
corresponds to nothing in the new log. -/

namespace Alaya

open Lean (Json)

/-- Where a log stops being a trace of a routine. -/
structure Divergence (σ : Signature) where
  /-- The position of the first event of the old log that the new one does not take. -/
  position : Nat
  found : Event σ
  /-- What the routine does there. -/
  expected : Next σ

/-- A log made again by a routine: the events of the new log, each with the position in the old
one it was taken from, none for a comment of the routine's; where the old log stopped being a
trace; and the events from outside after that point, with their positions, which the new log
does not have. -/
structure Rebased (σ : Signature) where
  log : Array (Event σ × Option Nat)
  divergence? : Option (Divergence σ) := none
  dropped : Array (Nat × Event σ) := #[]

instance : Inhabited (Rebased σ) := ⟨{ log := #[] }⟩

/-- Whether an event comes from outside: a notice or a stop. -/
def Event.fromOutside : Event σ → Bool
  | .arrived _ | .stopped _ => true
  | _ => false

/-- The log `old` as a run of `root` makes it: the longest prefix that is a trace of it. Its
comments are `root`'s, each written before the event the computation comes to after it, as the
driver writes them; the comments of `old` are left out. A read of the inbox is matched by the
notices it takes, which the new log has at positions of their own. -/
partial def rebase (root : Routine σ) (old : Log σ) : Rebased σ :=
  go 0 (Replayer.start root) #[] {}
where
  go (i : Nat) (r : Replayer σ) (new : Array (Event σ × Option Nat))
      (moved : Std.HashMap Nat Nat) : Rebased σ :=
    match old[i]? with
    | none => { log := new }
    | some event =>
      let diverge (expected : Next σ) : Rebased σ :=
        { log := new, divergence? := some { position := i, found := event, expected }
          dropped := (old.zipIdx.extract i old.size).filterMap fun (event, position) =>
            if event.fromOutside then some (position, event) else none }
      let take (event : Event σ) : Rebased σ :=
        -- An event of the computation comes after the comments it made since its last one.
        let comments := if event.frame?.isSome then r.comments.map fun text => (.commented text, none) else #[]
        let fed := (comments.foldl (fun r (comment, _) => r.feed comment) r).feed event
        if fed.broken?.isSome then diverge r.next else
        let new := new ++ comments
        let moved := if event matches .arrived _ then moved.insert i new.size else moved
        go (i + 1) fed (new.push (event, some i)) moved
      match event with
      | .commented _ => go (i + 1) r new moved
      | .heard frame notices =>
        match notices.mapM moved.get? with
        | some notices => take (.heard frame notices)
        | none => diverge r.next
      | event => take event

namespace Rebase

open Alaya (Result Error)

/-- `action`, an input error in it said to be about reading the call of `name`. -/
private def reading (name : String) (action : Result α) : Result α :=
  tryCatch action fun
    | .input message => throw <| .input s!"the call of {name}, as the current version reads it: {message}"
    | error => throw error

/-- A call's configuration as the current version of its program reads it, with the settings
of `settings` its program takes over it, every field complete; and which of `settings` it takes. -/
private def reconfigureCall (call : RoutineCall) (settings : Array Settings.Setting) :
    Result (RoutineCall × Array Bool) := do
  let arguments ← Result.fromExcept (fun m => .storage s!"the call of {call.name}: {m}")
    (ProgramArguments.fromJson call.arguments)
  let mut config ← reading call.name (Agents.Catalog.complete call.name arguments.config)
  let mut taken := #[]
  -- A setting fits a call when its program takes it.
  for setting in settings do
    match ← tryCatch (some <$> Agents.Catalog.applying call.name config #[setting]) (fun _ => pure none) with
    | some applied => config := applied; taken := taken.push true
    | none => taken := taken.push false
  pure (⟨call.name, { arguments with config }.toJson⟩, taken)

/-- The log with every call configured as the current version of its program reads it, with
`settings` over each call they fit, both where the call is asked for and where it opens. A
setting that fits no call is an error. -/
def reconfigure (log : Log Agent) (settings : Array Settings.Setting) : Result (Log Agent) := do
  let mut events := #[]
  let mut accepted := settings.map fun _ => false
  for event in log do
    match event with
    | .arrived (.called call) =>
      let (call, _) ← reconfigureCall call settings
      events := events.push (.arrived (.called call))
    | .opened #[i] call =>
      let (call, fits) ← reconfigureCall call settings
      accepted := (accepted.zip fits).map fun (a, b) => a || b
      events := events.push (.opened #[i] call)
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

/-- Writes the rebased log into `store`, an empty one, with the snapshots it names copied from
`workspaces` into a new store at `repository`, and then `note`, a comment that says where it came
from. An entry taken from the old log keeps its time, `entries` being the old log's; a comment
the routine made took none. Gives the entries written, in order. -/
def write (rebased : Rebased Agent) (entries : Array Entry) (workspaces : Workspaces)
    (repository : System.FilePath) (store : Store) (note : String) : Result (Array (Hash × Entry)) := do
  let ids := snapshots (rebased.log.map (·.1))
  let copies ← workspaces.transfer ids repository
  let renamed : Std.HashMap Snapshot Snapshot := (ids.zip copies).foldl (init := {}) fun m (id, copy) =>
    m.insert id copy
  let rename (id : Snapshot) := renamed.getD id id
  let mut forest ← store.forest
  let mut parent? : Option Hash := none
  let mut written : Array (Hash × Entry) := #[]
  let events := rebased.log.map (fun (event, origin?) =>
    (event.renameSnapshots rename, (origin?.bind (entries[·]?)).map (·.elapsedMs) |>.getD 0))
  for (event, elapsedMs) in events.push (.commented note, 0) do
    let entry : Entry := { parent?, event, elapsedMs }
    let (hash, grown) ← store.put forest entry
    forest := grown
    parent? := some hash
    written := written.push (hash, entry)
  pure written

end Rebase

end Alaya
