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
  tool : ToolCall
  position : Nat

/-- What a reader knows at an entry of the forest. -/
structure Visit where
  hash : Hash
  entry : Entry
  position : Nat
  /-- The configuration of the run, once the log has opened its agent. -/
  config? : Option RunConfig
  /-- The operation the event answers, as the program asked for it: for a sample, the whole
  request. -/
  asked? : Option (Call Agent)
  /-- What the run does next after this entry, or none before the run is known. -/
  next? : Option (Next Agent)
  /-- The question the log waits on here, when it waits for a reply. -/
  question? : Option Question
  /-- The calls open after this entry, outermost first. -/
  stack : Array OpenCall
  /-- How the agent ended, once it has. -/
  agent? : Option AgentEnd
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
  | .opened frame tool => stack.push { frame, tool, position }
  | .returned _ _ | .failed _ _ => stack.pop
  | .stopped _ => stack.filter fun call => !call.frame.inAgent
  | _ => stack

/-- The run of a configuration, if it and its model can be read. -/
private def runOf? (config : RunConfig) : Option (Run Agent) :=
  match Models.read config.model with
  | .ok model => (config.run model).toOption
  | .error _ => none

/-- Where the walk is in one log. -/
private structure Place where
  position : Nat
  config? : Option RunConfig
  replayer? : Option (Replayer Agent)
  stack : Array OpenCall
  agent? : Option AgentEnd
  spentMs : Nat
  usage : Chat.TokenUsage
  workspace? : Option Snapshot

/-- Folds `f` over every entry of the forest, depth first, from each root, parents before
children. A log whose run cannot be built is walked without `next?` and `asked?`. -/
partial def walk (store : Store) (forest : Forest) (init : β) (f : β → Visit → Result β) : Result β := do
  let rec go (acc : β) (place : Place) (hash : Hash) : Result β := do
    let entry ← store.get forest hash
    let event := entry.event
    let asked? := match place.replayer?.map (·.next), event with
      | some (.ask call), .answered .. => some call
      | _, _ => none
    -- The run is known from the opening of the agent's call, the second event.
    let (config?, replayer?) : Option RunConfig × Option (Replayer Agent) :=
      match place.position, event with
      | 1, .opened #[0] tool =>
        match RunConfig.fromJson tool.arguments with
        | .ok config =>
          match runOf? config with
          | some run =>
            let root := Replayer.start run |>.feed (.arrived (.changed ⟨""⟩ ""))
            (some config, some (root.feed event))
          | none => (some config, none)
        | .error _ => (none, none)
      | 0, _ => (none, none)
      | _, _ => (place.config?, place.replayer?.map (·.feed event))
    let before := place.workspace?
    let workspace? := (versionAfter? event).or before
    let usage := match event with
      | .answered _ _ (.ok (.response response)) => addUsage place.usage (response.usage?.getD {})
      | _ => place.usage
    let stack := OpenCall.after place.stack place.position event
    let agent? := place.agent?.or (AgentEnd.of? event)
    let spentMs := place.spentMs + entry.elapsedMs
    let next? := replayer?.map (·.next)
    let question? := match next? with
      | some (.waits frame) => (stack.find? (·.frame == frame)).bind (questionOfCall? ·.tool)
      | _ => none
    let visit : Visit := {
      hash, entry, position := place.position, config?, asked?, next?, question?, stack, agent?, spentMs
      usage, workspace?
      before? := if workspace? != before then before else none }
    let acc ← f acc visit
    let place := { position := place.position + 1, config?, replayer?, stack, agent?, spentMs, usage, workspace? }
    (forest.childrenOf hash).foldlM (init := acc) fun acc child => go acc place child
  forest.roots.foldlM (init := init) fun acc root =>
    go acc { position := 0, config? := none, replayer? := none, stack := #[], agent? := none, spentMs := 0
             usage := {}, workspace? := none } root

end Alaya
