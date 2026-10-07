import Alaya.Core.Replay

/-! Rebase: a run's log, made again by another version of its agent. A log is a trace of the
run's routine that wrote it, and a routine changed after it was written reads it only up to its
first changed operation (`docs/language.md` §4). Rebase keeps that prefix, as the new routine makes
it, in a data directory of its own, where the run goes on: every log of a data directory stays a
trace of the agent that directory runs.

Rebase is the driver with the old log for its world. The new routine is replayed, and whatever
it asks for is taken from the old log: the answer to an operation it asks for again, a mark it
makes again, a notice where one arrived. The comments of the old log are left out, and the new
routine's are written as the driver writes them. Where it asks for something the log does not hold,
the copy ends, and what came from outside after that point is left out, since a position after it
corresponds to nothing in the new log. -/

namespace Alaya.Core

open Alaya.Base

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

/-- Whether an event comes from outside: a notice or a break. -/
def Event.fromOutside : Event σ → Bool
  | .arrived _ | .broke .. => true
  | _ => false

/-- The log `old` as a run in `scope` makes it: the longest prefix that is a trace of it. Its
comments are the run's, each written before the event the computation comes to after it, as the
driver writes them; the comments of `old` are left out. A read of the inbox is matched by the
notices it takes, which the new log has at positions of their own. -/
partial def rebase (scope : Scope σ) (old : Log σ) : Rebased σ :=
  go 0 (Replayer.start scope) #[] {}
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

end Alaya.Core
