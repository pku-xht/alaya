import Alaya.Runtime.Calls
import Alaya.Runtime.Store
import Alaya.LLM.Cache
import Alaya.LLM.Provider
import Alaya.Runtime.Workspaces

/-! The driver: the only part that carries out what a computation asks. It keeps the interpreter
live, asks it what is next after the log, and either carries out the operation it asks for and
appends the answer, or appends the mark it makes, an entry at a time, until the run is over, it
waits for a notice, or this invocation reaches a limit. Each call's commands run in a
container of the call's own image, and each sample is drawn from the model it names.
"Execution is an external operation rather than a constant within type theory" (Hancock and
Setzer 2000): this is the one loop that need not end. See `docs/agent-api.md` §10.

Resuming after a crash is no different from going on: the operation that was being carried out
when the driver stopped is asked for again. A command runs on the version of the workspace the
log has reached, which the driver restores, so a command run again starts from the same files;
it happens at least once, and what it does beyond the workspace may happen twice. -/

namespace Alaya.Runtime.Driver

open Alaya.Base Alaya.Core Alaya.LLM

open Lean (Json)

/-! ## Model construction -/

/-- The model stack behind a provider: provider, retry, batch, persistent cache. -/
def buildModel (spec : Models.Spec) (provider : Provider.Provider) (cacheDir : System.FilePath)
    (baseUrl? : Option String := none) : Result Model := do
  let base ← Provider.serve provider spec baseUrl?
  -- Transport failures are retried: a duplicate request costs less than an aborted run, whose
  -- container — and everything the agent kept outside the workspace — is lost when a run is driven on.
  let model ← base.retry { retryUnknownDelivery := true }
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## The world a run is driven in -/

/-- What a run is driven with: where its entries and snapshots are kept, the directory its
workspace is restored to, where a call's commands run, and the models its samples name. -/
structure Runtime where
  store : Store
  workspaces : Workspaces
  /-- Restored from a snapshot whenever the log has reached another version; holds nothing
  durable. -/
  workDir : System.FilePath
  /-- Where the whole output of each command is written, for the executor to mount at
  `outputsDir`; derived from the log, and holding nothing durable. -/
  outputsDir : System.FilePath
  /-- An executor for a call that runs in `environment`: a container of its image, started on
  the work directory at its first command, and closed by the driver. -/
  executor : Environment → Result Executor
  /-- The model of a spec, which a sample names. It fails when no provider was named: a run that
  samples then stops with an error. -/
  model : Models.Spec → Result Model

/-- Where a command finds the whole output of an earlier command, read-only, outside any
workdir. -/
def outputsDir : String := "/alaya/outputs"

/-- What one invocation allows. Neither limit is recorded, and a run paused at one goes on with
the next `run`. -/
structure Limits where
  /-- The responses this invocation may sample. -/
  samples? : Option Nat := none
  /-- The run's time, summed along its log, after which no operation starts. -/
  budgetMs? : Option Nat := none

/-- Why the driver stopped. -/
inductive Stop where
  /-- The run is over: its result, or its failure. -/
  | ended (result : Except String Json)
  /-- The computation in `frame` waits for a notice: a reply to `question?`, or, without one, any
  it waits for. -/
  | waits (frame : Frame) (question? : Option Question)
  /-- This invocation reached a limit; the next `resume` goes on from here. -/
  | paused (reason : String)
  deriving Inhabited

/-- The entries of a run, as the driver appends them: the name and the entry. -/
abbrev OnEntry := Hash → Entry → Result Unit

private def nowMs : Result Nat := Result.fromIO Error.storage IO.monoMsNow

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

/-- The file of `outputsDir` that holds `output`, named by its content alone: the first twelve
hex digits of its SHA-256. An agent is shown the name, so it says nothing of where in a log the
output is, or of anything else outside the agent: a comment or a notice earlier in the log
does not change it, and the same output has the same name in every run. -/
def outputFile (output : String) : String :=
  s!"{((Hash.ofBytes output.toUTF8).hex.take 12).toString}.txt"

/-- Makes the outputs directory hold the whole output of every command of `log` that was run
so, each in the file its answer names, written once, since a log only grows. The directory
itself stays, since a container's mount follows it. -/
private def prepareOutputs (rt : Runtime) (log : Log Agent) : Result Unit := io do
  IO.FS.createDirAll rt.outputsDir
  for event in log do
    if let .answered _ _ (.ok (.execution execution)) := event then
      if let some name := execution.file?.bind fun file => (System.FilePath.mk file).fileName then
        let path := rt.outputsDir / name
        unless ← path.pathExists do IO.FS.writeFile path execution.output.output

/-- Keeps the work directory at the version of the workspace the log has reached. -/
private structure Checkout where
  version? : Option Snapshot := none

/-- Classifies a failure of the model. A refusal of the request as too long for the model's
context is the computation's to deal with: it is the answer, an error in the provider's own words,
and trying again would not help. Anything else — a provider that cannot be reached, a key it
rejects, a response it garbles, a full disk — stops the driver with nothing logged, and the
next `resume` asks again. -/
private def modelAnswer (model : Model) (draw : Nat) (request : Chat.Request) :
    Result (Except String Chat.Response) := do
  tryCatch (do
      let responses ← (← model.sample request).nextN (draw + 1)
      let some response := responses[draw]?
        | throw <| .protocol "the model returned too few responses"
      pure (.ok response))
    fun
      | .contextExceeded message => pure (.error message)
      | error => throw error

/-- Whether the event is a response of the model: a draw taken. A refusal took none. -/
private def sampled : Event Agent → Bool
  | .answered _ (.sample ..) (.ok _) => true
  | _ => false

/-- The executor of `frame`'s commands: the container of the nearest call on its path that names
an environment. It is the one the driver holds when that call is the one it holds, or a new one,
the held one closed first: the commands of a call and of the calls inside it that name none share
its container. -/
private def executorFor (rt : Runtime) (held : IO.Ref (Option (Frame × Executor)))
    (log : Log Agent) (frame : Frame) : Result (Executor × Bool) := do
  let (named, environment) ← environmentOf log frame
  match ← io held.get with
  | some (at', executor) => if at' == named then return (executor, false) else io executor.close
  | none => pure ()
  let executor ← rt.executor environment
  io (held.set (some (named, executor)))
  pure (executor, true)

/-- Drives the run in `scope` on from the entry `tip`, appending each event as an entry and calling `onEntry`
with it, until the run is over, it waits for a notice, or it reaches one of `limits`.
Gives the last entry and why it stopped. A sample takes the next draw of its request: the first
when the tip has no other continuation that sampled, so a run that crashed takes the response
the cache kept, and the next one when it has, so running a point again is a new draw. -/
partial def drive (rt : Runtime) (scope : Scope Agent) (tip : Hash) (limits : Limits := {})
    (onEntry : OnEntry := fun _ _ => pure ()) : Result (Hash × Stop) := do
  let forest ← rt.store.forest
  let entries ← rt.store.entries forest tip
  let log := entries.map (·.event)
  let spent := entries.foldl (fun ms entry => ms + entry.elapsedMs) 0
  -- Another log's files may be there; this one's are written afresh.
  io do if ← rt.outputsDir.pathExists then IO.FS.removeDirAll rt.outputsDir
  let started ← nowMs
  let held ← io (IO.mkRef (none : Option (Frame × Executor)))
  let rec loop (forest : Forest) (tip : Hash) (log : Log Agent) (replayer : Replayer Agent)
      (spent stamp samples : Nat) (checkout : Checkout) : Result (Hash × Stop) := do
    -- Which limit, if any, keeps the driver from going on in `frame`: the time budget, before
    -- anything; the samples, before a sample or a read of a call's inbox.
    let limit? (now : Nat) (sampling : Bool) : Option String :=
      if limits.budgetMs?.any (spent + (now - stamp) ≥ ·) then some "the time budget is spent"
      else if sampling && limits.samples?.any (samples ≥ ·) then some s!"{samples} response(s) sampled"
      else none
    -- An entry's time is how long its event took the driver, except for a response whose own
    -- time is known (`took?`): a draw costs what it took when it was made, cached or not. The
    -- program's comments since its last event are written first, in no time.
    let appendTook (took? : Option Nat) (event : Event Agent) (checkout : Checkout) (samples : Nat) :
        Result (Hash × Stop) := do
      let comments := replayer.comments.map Event.commented
      let mut (forest, tip) := (forest, tip)
      for comment in comments do
        let entry : Entry := { parent? := some tip, event := comment }
        let (hash, grown) ← rt.store.put forest entry
        onEntry hash entry
        (forest, tip) := (grown, hash)
      let now ← nowMs
      let entry : Entry := { parent? := some tip, event, elapsedMs := took?.getD (now - stamp) }
      let (hash, grown) ← rt.store.put forest entry
      onEntry hash entry
      loop grown hash ((log ++ comments).push event) ((comments.foldl Replayer.feed replayer).feed event)
        (spent + entry.elapsedMs) now samples checkout
    let append := appendTook none
    match replayer.next with
    | .ended result => pure (tip, .ended result)
    | .waits frame question? => pure (tip, .waits frame question?)
    | .mismatch position =>
      throw <| .input <| s!"the log is no trace of its run's program: the event at {position} is not what it does; " ++
        "`alaya rebase` copies the part that is into a new data directory"
    | .unguarded frame =>
      throw <| .input s!"a loop in frame {frame.render} went round without reading an event"
    | .mark event =>
      -- A limit is checked before a read of the inbox too, so that what a person adds where the
      -- run paused is read before the next sample, not after it. A read that takes calls alone
      -- starts no work of its own: what the call does is limited where it does it.
      if let .heard _ taken := event then
        let calls := !taken.isEmpty && taken.all fun i => log[i]? matches some (.arrived (.called _))
        if !calls then
          if let some reason := limit? (← nowMs) (sampling := true) then
            return (tip, .paused reason)
      append event checkout samples
    | .ask call =>
      let now ← nowMs
      let timeSpent := spent + (now - stamp)
      if let some reason := limit? now (call.op matches .sample ..) then
        return (tip, .paused reason)
      let version := (workspace? log).getD ⟨""⟩
      match call.op with
      | .sample spec request =>
        let model ← rt.model spec
        let mut draw := 0
        for child in forest.childrenOf tip do
          if sampled (← rt.store.get forest child).event then draw := draw + 1
        let answer ← modelAnswer model draw request
        appendTook (answer.toOption.bind (·.elapsedMs?))
          (.answered call.frame (.sample spec.toJson (Model.requestDigest request)) (answer.map (.response ·)))
          checkout (samples + 1)
      | .exec command config =>
        let (executor, fresh) ← executorFor rt held log call.frame
        let mut checkout := if fresh then {} else checkout
        if checkout.version? != some version then
          -- A container's bind mount follows the directory it was started on, which a restore
          -- replaces, so the executor is closed first: its next command starts a container.
          io executor.close
          rt.workspaces.materialize version rt.workDir
          checkout := { version? := some version }
        if config.outputs then prepareOutputs rt log
        else io do
          IO.FS.createDirAll rt.outputsDir
          for entry in ← rt.outputsDir.readDir do IO.FS.removeFile entry.path
        -- What the executor throws is the machine's: no container could be started, or docker
        -- could not be run. Nothing is logged for the command, and the next `resume` asks again.
        let output ← Result.fromIO Error.environment (executor.bash config rt.workDir command)
        let file? := if config.outputs then some s!"{outputsDir}/{outputFile output.output}" else none
        let left ← rt.workspaces.snapshot rt.workDir
        append (.answered call.frame (.exec command config)
            (.ok (.execution { output, workspace := left, file? })))
          { version? := some left } samples
      | .time =>
        append (.answered call.frame .time
          (.ok (.timing { spentMs := timeSpent, budgetMs? := limits.budgetMs? }))) checkout samples
  try loop forest tip log (Replayer.ofLog scope log) spent started 0 {}
  finally
    if let some (_, executor) ← io held.get then io executor.close

/-! ## Notices: what a person appends -/

/-- Appends the marks the run makes after `tip` with no world — a read of what has arrived, the
opening of a call — and the comments before them, until it asks the world for something, waits,
or ends. Gives the entries appended, in order. So a run started by a call is at its first wait
before a person appends anything more. -/
partial def settle (store : Store) (scope : Scope Agent) (tip : Hash) : Result (Array (Hash × Entry)) := do
  let rec go (forest : Forest) (tip : Hash) (replayer : Replayer Agent) (written : Array (Hash × Entry)) :
      Result (Array (Hash × Entry)) := do
    let .mark event := replayer.next | pure written
    let mut (forest, tip, written) := (forest, tip, written)
    for text in replayer.comments do
      let entry : Entry := { parent? := some tip, event := .commented text }
      let (hash, grown) ← store.put forest entry
      (forest, tip, written) := (grown, hash, written.push (hash, entry))
    let entry : Entry := { parent? := some tip, event }
    let (hash, grown) ← store.put forest entry
    go grown hash ((replayer.comments.foldl (fun r text => r.feed (.commented text)) replayer).feed event)
      (written.push (hash, entry))
  let forest ← store.forest
  go forest tip (Replayer.ofLog scope (← store.log forest tip)) #[]

/-- Appends an event that comes from outside — a notice, a break — after `tip`, after checking
that the log can take it: a break only where a call is open in its frame, and a notice only
while the run is not over, when something may read it. What a person may append beyond that —
a call only where the run waits for one, a message only while a call runs — is the front end's
to say. Gives the new entry. -/
def append (store : Store) (scope : Scope Agent) (tip : Hash) (event : Event Agent) : Result (Hash × Entry) := do
  let forest ← store.forest
  let log ← store.log forest tip
  let replayer := Replayer.ofLog scope log
  if let .mismatch position := replayer.next then
    throw <| .input <| s!"the log is no trace of its run's program at position {position}; " ++
      "`alaya rebase` copies the part that is into a new data directory"
  match event with
  | .broke frame _ =>
    if !replayer.canBreak frame then throw <| .input s!"no call is open in {frame.render}: there is nothing to stop"
  | .arrived _ =>
    if replayer.next matches .ended _ then
      throw <| .input "the run is over: nothing would read a notice appended here"
  | _ => pure ()
  let entry : Entry := { parent? := some tip, event }
  let (hash, _) ← store.put forest entry
  pure (hash, entry)

end Alaya.Runtime.Driver
