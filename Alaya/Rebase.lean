import Alaya.Render
import Alaya.Cache
import Alaya.Workspaces

/-! Rebase: a run's log, made again by another version of its agent. A log is a trace of the
program that wrote it, and a program changed after it was written reads it only up to its first
changed operation (`docs/agent-api.md` §4). Rebase keeps that prefix, as the new program makes
it, in a data directory of its own, where the run goes on: every log of a data directory stays a
trace of the agent that directory runs.

Rebase is the driver with the old log for its world. The new program is replayed, and whatever
it asks for is taken from the old log: the answer to an operation it asks for again, a mark it
makes again, a notice where one arrived. Its comments are written where it makes them, and the
old program's are left out. Where the program asks for something the log does not hold, the
copy ends, and what came from outside after that point is left out, since a position after it
corresponds to nothing in the new log. -/

namespace Alaya

open Lean (Json)

/-- Where a log stops being a trace of a program. -/
structure Divergence (σ : Signature) where
  /-- The position of the first event of the old log that the new one does not take. -/
  position : Nat
  found : Event σ
  /-- What the program does there; `none` where the event is one it is not to take. -/
  expected? : Option (Next σ)

/-- A log made again by a program: the events of the new log, each with the position in the old
one it was taken from, none for a comment of the program; where the old log stopped being a
trace; and the events from outside after that point, with their positions, which the new log
does not have. -/
structure Rebased (σ : Signature) where
  log : Array (Event σ × Option Nat)
  divergence? : Option (Divergence σ) := none
  dropped : Array (Nat × Event σ) := #[]

instance : Inhabited (Rebased σ) := ⟨{ log := #[] }⟩

/-- Whether an event comes from outside: a notice, a stop, a person's comment. -/
def Event.fromOutside : Event σ → Bool
  | .arrived _ | .stopped _ | .commented none _ => true
  | _ => false

/-- The log `old` as `run` makes it: the longest prefix that is a trace of `run`, its program's
comments its own. An event `takes` refuses ends the prefix, as one the program does not make
there would. A read of the inbox is matched by the notices it takes, which the new log has at
positions of their own. -/
partial def rebase (run : Run σ) (old : Log σ) (takes : Event σ → Bool := fun _ => true) :
    Rebased σ :=
  go 0 (Replayer.start run) #[] {}
where
  go (i : Nat) (r : Replayer σ) (new : Array (Event σ × Option Nat))
      (moved : Std.HashMap Nat Nat) : Rebased σ :=
    -- A comment is written as soon as the program makes it, before anything that comes after.
    match r.next with
    | .comments frame text =>
      let comment : Event σ := .commented (some frame) text
      go i (r.feed comment) (new.push (comment, none)) moved
    | next =>
    match old[i]? with
    | none => { log := new }
    | some event =>
      let diverge (expected? : Option (Next σ)) : Rebased σ :=
        { log := new, divergence? := some { position := i, found := event, expected? }
          dropped := (old.zipIdx.extract i old.size).filterMap fun (event, position) =>
            if event.fromOutside then some (position, event) else none }
      let take (event : Event σ) : Rebased σ :=
        if !takes event then diverge none else
        let fed := r.feed event
        if fed.broken?.isSome then diverge (some next) else
        let moved := if event matches .arrived _ then moved.insert i new.size else moved
        go (i + 1) fed (new.push (event, some i)) moved
      match event with
      -- The old program's comment: the new one says its own.
      | .commented (some _) _ => go (i + 1) r new moved
      | .heard frame notices =>
        match notices.mapM moved.get? with
        | some notices => take (.heard frame notices)
        | none => diverge (some next)
      | event => take event

namespace Rebase

open Alaya (Result Error)

/-- The configuration a run has once rebased: the one its log records, read by the current version of its agent, with
`settings` over it, every field complete; and the model's spec. -/
def configure (log : Log Agent) (settings : Array Settings.Setting) : Result (RunConfig × Models.Spec) := do
  let config ← configOf log
  let explain (message : String) := s!"the run's configuration, as the current version of its agent reads it: {message}"
  let agent ← match Settings.apply .agent config.agent settings with
    | .ok agent => tryCatch (Agents.Catalog.complete agent) fun
      | .input message => throw <| .input (explain message)
      | error => throw error
    | .error message => throw <| .input message
  let model ← match Settings.apply .model config.model settings with
    | .ok model => tryCatch (Models.fromJson model) fun
      | .input message => throw <| .input (explain message)
      | error => throw error
    | .error message => throw <| .input message
  pure ({ config with agent, model := model.toJson }, model)

/-- `log` rebased onto `run`, a run of the current version of its agent: the opening of the agent's call
is `run`'s, whose configuration may differ from the log's. A response of the model is taken only
when `sameModel`, the model being the one the log was written with. -/
def plan (run : Run Agent) (log : Log Agent) (sameModel : Bool) : Rebased Agent :=
  let takes : Event Agent → Bool
    | .answered _ (.sample _) _ => sameModel
    | _ => true
  rebase run (log.set! 1 (.opened #[0] run.call)) takes

/-- What the agent does where the log stops being a trace of it, in a few words. -/
def expectedSummary : Option (Next Agent) → String
  | none => "no response of another model"
  | some (.ask call) => call.op.describe
  | some next =>
    let line := Render.nextSummary none none next
    if line.startsWith "next: " then (line.drop 6).toString else line

/-- How much of a log of `total` events a rebase kept, and, where it stopped, why. -/
def summary (rebased : Rebased Agent) (total : Nat) : String :=
  match rebased.divergence? with
  | none => s!"all {total} events hold"
  | some divergence =>
    let found := s!"{divergence.position} of {total} events hold; at {divergence.position} the log has " ++
      (Render.eventSummary divergence.found).quote
    match divergence.expected? with
    | some _ => s!"{found}, where the agent goes on with: {expectedSummary divergence.expected?}"
    | none => s!"{found}: the agent takes {expectedSummary none}"

/-- The events from outside a rebase left out, in a line each. -/
def droppedLines (rebased : Rebased Agent) : Array String :=
  rebased.dropped.map fun (position, event) => s!"left out: {position}  {Render.eventSummary event}"

/-- Writes the rebased log into `store`, an empty one, with the snapshots it names copied from
`workspaces` into a new store at `repository`, and then `note`, a comment that says where it came
from. An entry taken from the old log keeps its time, `entries` being the old log's; a comment
the program made took none. Gives the entries written, in order. -/
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
  for (event, elapsedMs) in events.push (.commented none note, 0) do
    let entry : Entry := { parent?, event, elapsedMs }
    let (hash, grown) ← store.put forest entry
    forest := grown
    parent? := some hash
    written := written.push (hash, entry)
  pure written

end Rebase

end Alaya
