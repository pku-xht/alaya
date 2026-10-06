import Alaya.Run
import Alaya.Store

/-! Reading the forest with the interpreter: one walk, depth first, that replays every log as it
goes, so an entry that many logs share is read once, and what the run did at each entry — the
request a sample answered, the calls open there, what comes next — is known without running
anything. Readers of the whole forest (`tree`, `waiting`, the HTML report) are folds over this
walk; a reader of one log (`log`, `show`) replays that log. -/

namespace Alaya

open Lean (Json)

/-- A call open at an entry: its frame, the call, and the position of its opening. -/
structure OpenCall where
  frame : Frame
  call : RoutineCall
  position : Nat

/-- What a reader knows at an entry of the forest. -/
structure Visit where
  hash : Hash
  entry : Entry
  position : Nat
  /-- The operation the event answers, as the computation asked for it: for a sample, the whole
  request. -/
  asked? : Option (OpRequest Agent)
  /-- What the run does next after this entry, or none before the run is known. -/
  next? : Option (Next Agent)
  /-- The question the log waits on here, when it waits for a reply. -/
  question? : Option Question
  /-- The calls open after this entry, outermost first. -/
  stack : Array OpenCall
  /-- The last call the log opens up to this entry, and how it ended, once it has. -/
  last? : Option (RoutineCall × Option CallEnd)
  /-- The run's time up to this entry, its own included. -/
  spentMs : Nat
  /-- The tokens the run's responses cost up to this entry. -/
  usage : Chat.TokenUsage
  /-- The version of the workspace the log has reached. -/
  workspace? : Option Snapshot
  /-- The version before this entry, when the entry changes it. -/
  before? : Option Snapshot

private def addCounts (a b : Option Nat) : Option Nat :=
  match a, b with
  | some a, some b => some (a + b)
  | some n, none | none, some n => some n
  | none, none => none

/-- Two usages added; a count stays unknown only where neither reported it. -/
def addUsage (a b : Chat.TokenUsage) : Chat.TokenUsage :=
  { input? := addCounts a.input? b.input?, output? := addCounts a.output? b.output?
    total? := addCounts a.total? b.total?, reasoning? := addCounts a.reasoning? b.reasoning?
    cached? := addCounts a.cached? b.cached? }

/-- The calls open after `event`, given those open before it. -/
def OpenCall.after (stack : Array OpenCall) (position : Nat) : Event Agent → Array OpenCall
  | .opened frame call => stack.push { frame, call, position }
  | .returned _ _ | .failed _ _ => stack.pop
  | .stopped _ => stack.filter fun call => !call.frame.inCall
  | _ => stack

/-- Where the walk is in one log. -/
private structure Place where
  position : Nat
  replayer : Replayer Agent
  stack : Array OpenCall
  last? : Option (RoutineCall × Option CallEnd)
  spentMs : Nat
  usage : Chat.TokenUsage
  workspace? : Option Snapshot

/-- Folds `f` over every entry of the forest, depth first, from each root, parents before
children, each log replayed by `root`, the run's routine. -/
partial def walk (store : Store) (forest : Forest) (init : β) (f : β → Visit → Result β)
    (root : Routine Agent := session) : Result β := do
  let rec go (acc : β) (place : Place) (hash : Hash) : Result β := do
    let entry ← store.get forest hash
    let event := entry.event
    let asked? := match place.replayer.next, event with
      | .ask call, .answered .. => some call
      | _, _ => none
    let replayer := place.replayer.feed event
    let before := place.workspace?
    let workspace? := (versionAfter? event).or before
    let usage := match event with
      | .answered _ _ (.ok (.response response)) => addUsage place.usage (response.usage?.getD {})
      | _ => place.usage
    let stack := OpenCall.after place.stack place.position event
    let last? := match event, place.last? with
      | .opened #[_] call, _ => some (call, none)
      | event, some (call, none) => some (call, CallEnd.of? event)
      | _, last => last
    let spentMs := place.spentMs + entry.elapsedMs
    let next? := some replayer.next
    let question? := (next?.bind questionOf?).map (·.2)
    let visit : Visit := {
      hash, entry, position := place.position, asked?, next?, question?, stack, last?, spentMs
      usage, workspace?
      before? := if workspace? != before then before else none }
    let acc ← f acc visit
    let place := { position := place.position + 1, replayer, stack, last?, spentMs, usage, workspace? }
    (forest.childrenOf hash).foldlM (init := acc) fun acc child => go acc place child
  forest.roots.foldlM (init := init) fun acc first =>
    go acc { position := 0, replayer := Replayer.start root, stack := #[], last? := none, spentMs := 0
             usage := {}, workspace? := none } first

end Alaya
