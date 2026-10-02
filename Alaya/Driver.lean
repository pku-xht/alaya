import Alaya.Trajectory
import Alaya.Cache
import Alaya.Provider
import Alaya.Executor

/-! The driver: the only part that carries out the agent's effects. Its handler samples the
model, runs commands and reads the clock; its loop asks the agent what is next, has the handler
answer it, and records each answer as an event in a new state of the trajectory. See
`docs/architecture.md` §6. -/

namespace Alaya.Driver

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect CallRef Question Reply)
open Alaya.Trajectory

/-! ## Model construction -/

/-- The model stack behind a `provider:name` spec: provider, retry, batch, persistent cache. -/
def buildModel (spec : Models.Spec) (provider : Provider.Provider) (cacheDir : System.FilePath)
    (baseUrl? : Option String := none) : Result Model := do
  let base ← Provider.serve provider spec baseUrl?
  -- Transport failures are retried: a duplicate request costs less than an aborted run, whose
  -- container — and everything the agent kept outside the workspace — is lost on resume.
  let model ← base.retry { retryUnknownDelivery := true }
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## Driving the agent, recording each step as a state -/

/-- What a run runs on: where its states and its files are kept, where its commands run, the
model that answers its samples, and the agent being driven. -/
structure Runtime where
  store : Store
  workspaces : Workspaces
  /-- Wiped and re-materialized from a snapshot at every checkout; holds nothing durable. -/
  workDir : System.FilePath
  /-- Where the branch's command outputs (`Agent.outputFile`) are written, for the executor to
  mount at `Agent.outputsDir`; derived from the log, and holding nothing durable. -/
  outputsDir : System.FilePath
  executor : Executor
  model : Model
  agent : Agent

/-- What one invocation of `resume` allows; neither is recorded, and a run stopped at one is
continued by a later `resume`. Both are checked between steps and never inside one, since a
step stopped between its tool calls would leave calls unanswered. -/
structure Limits where
  /-- The run's time, summed from the root, after which no step starts: a run can overrun it by
  one step. An agent that times its run is told it (`Event.timed`). -/
  budgetMs? : Option Nat := none
  /-- The steps this invocation may take. -/
  steps? : Option Nat := none

/-- Why a `resume` stopped: the run ended, it waits for a person, or the invocation reached one
of its limits. -/
inductive Stop where
  /-- A step ended the run. -/
  | outcome (outcome : Outcome)
  /-- A step asked a person something; the run waits for `reply`. -/
  | question (asked : Asked)
  /-- The invocation's time budget was spent. -/
  | outOfTime
  /-- The invocation took the steps it was allowed. -/
  | outOfSteps
  deriving Inhabited, BEq

/-- Makes `rt.outputsDir`, which the container mounts at `Agent.outputsDir`, hold what a command
of `log` may see: with `shown`, the whole output of every earlier command of the branch, as
`Agent.outputFile` names it, written once each, since a branch's log only grows; without, nothing.
The directory itself stays, since a container's mount follows it. -/
private def prepareOutputs (rt : Runtime) (log : Log) (shown : Bool) : Result Unit := do
  let dir := rt.outputsDir
  Result.fromIO Error.storage do
    IO.FS.createDirAll dir
    if !shown then
      for entry in ← dir.readDir do IO.FS.removeFile entry.path
      return
    let calls := log.index
    for (event, index) in log.zipIdx do
      if let .executed call _ _ output _ := event then
        if let some id := calls.callId? call then
          let path := dir / Agent.outputFile index id
          unless ← path.pathExists do IO.FS.writeFile path output.output

private def nowMs : Result Nat := Result.fromIO Error.storage IO.monoMsNow

/-- Carries out an effect, asked for from `log`: its answer, or `none` when the answer comes
later, from outside the run — a person's, to `ask`. -/
private abbrev Handler := Log -> (effect : Effect) -> Result (Option effect.Answer)

/-- The handler of a live run: the model, the executor and the clock. A sample takes draw `draw`
of its request; `elapsed` reads how long the run has taken, and `budgetMs?` is the invocation's
budget, which a timing reports with it. A command runs in the work directory as it is: `resume`
checked out the workspace of the state it started from, and each command since left the
directory as the snapshot taken after it, so the directory always holds where the log is. -/
private def handler (rt : Runtime) (draw : Nat) (elapsed : Result Nat) (budgetMs? : Option Nat) :
    Handler := fun log effect =>
  match effect with
  | .sample _ request => do
    let responses ← (← rt.model.sample request).nextN (draw + 1)
    let some response := responses[draw]?
      | throw <| .protocol "model returned too few responses"
    pure (some response)
  | .exec _ command config => do
    prepareOutputs rt log config.outputs
    let output ← Result.fromIO Error.storage (rt.executor.bash config rt.workDir command)
    pure (some (output, ← rt.workspaces.snapshot rt.workDir))
  | .record .. => pure (some ())
  | .time => do pure (some (← elapsed, budgetMs?))
  | .ask .. => pure none

/-- Follows the agent from `log`, `handle` answering each effect it asks for, until it wants a
second sample, stops, or asks a person: at most one sample, the first thing a step does, so
every sampled child of a state is a draw of the same request. Gives the events the step
appended, in `appended` so far, and how it stopped the run, if it did: what a step records. -/
private partial def follow (agent : Agent) (handle : Handler) (log appended : Log) :
    Result (Log × Option (Outcome ⊕ Asked)) := do
  match agent.next log with
  | .inr outcome => return (appended, some (.inl outcome))
  | .inl effect =>
    if effect matches .sample .. && !appended.isEmpty then return (appended, none)
    let answered ← tryCatch (Sum.inr <$> handle log effect) fun
      | .contextExceeded message => pure (Sum.inl message)
      | error => throw error
    match answered with
    | .inl message =>
      -- A request too long for the model's context ends the run, recorded, rather than failing
      -- it: the outcome says so and keeps the provider's words, and nothing was sampled.
      return (appended, some (.inl {
        status := "ContextExceeded", reason? := some s!"the provider refused the request: {message}" }))
    | .inr (some answer) =>
      let event := effect.event answer
      follow agent handle (log.push event) (appended.push event)
    | .inr none =>
      let .ask call question := effect
        | throw <| .protocol s!"nothing answered the agent's effect: {effect.describe}"
      return (appended, some (.inr { call, question }))

/-- Runs one step from `parent` (whose log is `log`, and `before` of whose run has been spent),
with its workspace in `rt.workDir`, records it as a new child state with its time, and returns
the child, its log, the run's time so far, and how the step stopped the run, if it did. -/
private def advance (rt : Runtime) (budgetMs? : Option Nat) (parent : Hash) (log : Log)
    (before : Nat) : Result (Hash × Log × Nat × Option (Outcome ⊕ Asked)) := do
  let parentState ← getState rt.store parent
  -- Draw index = the number of children that came from sampling.
  let mut draw := 0
  for child in ← children rt.store parent do
    if (← getState rt.store child).sampled then draw := draw + 1
  let started ← nowMs
  let elapsed := do pure (before + ((← nowMs) - started))
  let (appended, stop?) ← follow rt.agent (handler rt draw elapsed budgetMs?) log #[]
  let elapsed := (← nowMs) - started
  let child ← putState rt.store {
    parent? := some parent, appended
    workspace := appended.workspace?.getD parentState.workspace
    kind := .step (some elapsed) stop? }
  pure (child, log ++ appended, before + elapsed, stop?)

/-- Grows a continuation from `hash` until the run ends, stops at a question, or reaches one of
the invocation's `limits`, calling `onStep` with each state it writes, and returns the state it
reached and why it stopped there. Stopping for a limit writes nothing more: that state is where
a later `resume` continues. -/
partial def resume (rt : Runtime) (hash : Hash) (limits : Limits := {})
    (onStep : Hash -> Result Unit := fun _ => pure ()) : Result (Hash × Stop) := do
  let start ← getState rt.store hash
  Result.fromExcept Error.input start.continuable
  let withinBudget (elapsed : Nat) : Bool := !limits.budgetMs?.any (elapsed ≥ ·)
  let before ← elapsedMs rt.store hash
  if !withinBudget before then return (hash, .outOfTime)
  -- A container bind mount follows the directory it was started on, which a checkout replaces,
  -- so the executor is closed first: its next command starts a container on the new directory.
  Result.fromIO Error.storage rt.executor.close
  rt.workspaces.materialize start.workspace rt.workDir
  let log ← logOf rt.store hash
  -- Another branch's files may be there; this one's are written afresh.
  Result.fromIO Error.storage do
    if ← rt.outputsDir.pathExists then IO.FS.removeDirAll rt.outputsDir
  let rec go (parent : Hash) (log : Log) (elapsed taken : Nat) : Result (Hash × Stop) := do
    let (child, log, elapsed, stop?) ← advance rt limits.budgetMs? parent log elapsed
    onStep child
    match stop? with
    | some (.inl outcome) => pure (child, .outcome outcome)
    | some (.inr asked) => pure (child, .question asked)
    | none =>
      if !withinBudget elapsed then pure (child, .outOfTime)
      else if limits.steps?.any (taken + 1 ≥ ·) then pure (child, .outOfSteps)
      else go child log elapsed (taken + 1)
  go hash log before 0

end Alaya.Driver
