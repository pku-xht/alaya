import Alaya.Run
import Alaya.Store
import Alaya.Cache
import Alaya.Provider
import Alaya.Workspaces
import Alaya.Executor.Docker

/-! The driver: the only part that carries out what a program asks. It keeps the interpreter
live, asks it what is next after the log, and either carries out the operation it asks for and
appends the answer, or appends the mark it makes, an entry at a time, until the agent is over and no grader is assigned,
the run is graded, it waits for a person, or this invocation reaches a limit. "Execution is an external operation
rather than a constant within type theory" (Hancock and Setzer 2000): this is the one loop that
need not end. See `docs/architecture.md`.

Resuming after a crash is no different from going on: the operation that was being carried out
when the driver stopped is asked for again. A command runs on the version of the workspace the
log has reached, which the driver restores, so a command run again starts from the same files;
it happens at least once, and what it does beyond the workspace may happen twice. -/

namespace Alaya.Driver

open Lean (Json)
open Alaya (Result Error Output Executor)

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
workspace is restored to, where its commands run, the model, and how graders' containers run. -/
structure Runtime where
  store : Store
  workspaces : Workspaces
  /-- Restored from a snapshot whenever the log has reached another version; holds nothing
  durable. -/
  workDir : System.FilePath
  /-- Where the whole output of each command is written, for the executor to mount at
  `outputsDir`; derived from the log, and holding nothing durable. -/
  outputsDir : System.FilePath
  /-- Where a grader's checkout and input are restored. -/
  scratch : System.FilePath
  executor : Executor
  /-- Where the workspace is mounted in a container. -/
  workdir : String
  /-- None when no provider was named: a run that needs a sample then stops with an error. -/
  model? : Option Model := none
  /-- The user a grader's container runs as. -/
  graderUser? : Option String := none

/-- Where a command finds the whole output of an earlier command, read-only, outside any
workdir. -/
def outputsDir : String := "/alaya/outputs"

/-- Where a grader finds its trusted input, read-only. -/
def graderInput : String := "/grader"

/-- What one invocation allows. Neither limit is recorded, and a run paused at one goes on with
the next `run`. -/
structure Limits where
  /-- The responses this invocation may sample. -/
  samples? : Option Nat := none
  /-- The run's time, summed along its log, after which no operation starts. -/
  budgetMs? : Option Nat := none

/-- Why the driver stopped. -/
inductive Stop where
  /-- The agent is over, however it ended: the run waits for a grader, or, graded, has ended
  with its verdict. -/
  | over (agent : AgentEnd) (verdict? : Option Json)
  /-- The program waits for a notice: a reply to `question?`, or, without one, the task. -/
  | waits (frame : Frame) (question? : Option Question)
  /-- This invocation reached a limit; the next `run` goes on from here. -/
  | paused (reason : String)
  deriving Inhabited

/-- The entries of a run, as the driver appends them: the name and the entry. -/
abbrev OnEntry := Hash → Entry → Result Unit

private def nowMs : Result Nat := Result.fromIO Error.storage IO.monoMsNow

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

/-- Empties `dir`, creating it if needed. -/
private def emptyDir (dir : System.FilePath) : Result Unit := do
  Workspaces.makeWritable dir
  io do
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll dir

/-- The file of `outputsDir` that holds the output answered at `position` of a log. -/
def outputFile (position : Nat) : String := s!"{position}.txt"

/-- Makes the outputs directory hold the whole output of every command of `log` that was run
so, each in its file, written once, since a log only grows. The directory itself stays, since a
container's mount follows it. -/
private def prepareOutputs (rt : Runtime) (log : Log Agent) : Result Unit := io do
  IO.FS.createDirAll rt.outputsDir
  for (event, position) in log.zipIdx do
    if let .answered _ _ (.ok (.execution execution)) := event then
      if execution.file?.isSome then
        let path := rt.outputsDir / outputFile position
        unless ← path.pathExists do IO.FS.writeFile path execution.output.output

/-- Keeps the work directory at the version of the workspace the log has reached. -/
private structure Checkout where
  version? : Option Snapshot := none

/-- Classifies a failure of the model. A refusal of the request as too long for the model's
context is the program's to deal with: it is the answer, an error in the provider's own words,
and trying again would not help. Anything else — a provider that cannot be reached, a key it
rejects, a response it garbles, a full disk — stops the driver with nothing logged, and the
next `run` asks again. -/
private def modelAnswer (rt : Runtime) (draw : Nat) (request : Chat.Request) :
    Result (Except String Chat.Response) := do
  let some model := rt.model?
    | throw <| .input "the run asks the model for a response: name a --provider"
  tryCatch (do
      let responses ← (← model.sample request).nextN (draw + 1)
      let some response := responses[draw]?
        | throw <| .protocol "the model returned too few responses"
      pure (.ok response))
    fun
      | .contextExceeded message => pure (.error message)
      | error => throw error

/-- Runs a grader's program: a fresh checkout of the workspace, the input at `graderInput`, a
container of its image with no network, and a snapshot of the checkout as it left it. -/
private def runExternal (rt : Runtime) (version : Snapshot) (command image : String)
    (input? : Option Snapshot) (timeoutSeconds : Nat) : Result External := do
  let checkout := rt.scratch / "checkout"
  let input := rt.scratch / "input"
  emptyDir checkout
  emptyDir input
  try
    rt.workspaces.materialize version checkout
    if let some id := input? then rt.workspaces.materialize id input
    let checkoutPath ← io (IO.FS.realPath checkout)
    let inputPath ← io (IO.FS.realPath input)
    let mounts := #[{ host := checkoutPath, container := rt.workdir : Executor.Docker.Mount }] ++
      (if input?.isSome then #[{ host := inputPath, container := graderInput, readOnly := true }]
       else #[])
    let started ← nowMs
    let captured ← io <| Executor.Docker.runOnce { image, user? := rt.graderUser? } mounts rt.workdir
      command timeoutSeconds
    let elapsedMs := (← nowMs) - started
    pure { exitCode? := captured.exitCode?.map fun c => Int.ofNat c.toNat
           stdout := captured.stdout, stderr := captured.stderr
           checkout := ← rt.workspaces.snapshot checkout, elapsedMs, error? := captured.stopped? }
  finally
    Workspaces.makeWritable rt.scratch
    io do
      if ← checkout.pathExists then IO.FS.removeDirAll checkout
      if ← input.pathExists then IO.FS.removeDirAll input

/-- Whether the event is a response of the model: a draw taken. A refusal took none. -/
private def sampled : Event Agent → Bool
  | .answered _ (.sample _) (.ok _) => true
  | _ => false

/-- Drives `run` on from the entry `tip`, appending each event as an entry and calling `onEntry`
with it, until its agent is over and it waits for a grader, it is graded, it waits for a person,
or it reaches one of `limits`. Gives the last entry and why
it stopped. A sample takes the next draw of its request: the first when the tip has no other
continuation that sampled, so a run that crashed takes the response the cache kept, and the
next one when it has, so running a point again is a new draw. -/
partial def drive (rt : Runtime) (run : Run Agent) (tip : Hash) (limits : Limits := {})
    (onEntry : OnEntry := fun _ _ => pure ()) : Result (Hash × Stop) := do
  let forest ← rt.store.forest
  let entries ← rt.store.entries forest tip
  let log := entries.map (·.event)
  let spent := entries.foldl (fun ms entry => ms + entry.elapsedMs) 0
  -- Another log's files may be there; this one's are written afresh.
  io do if ← rt.outputsDir.pathExists then IO.FS.removeDirAll rt.outputsDir
  let started ← nowMs
  let rec loop (forest : Forest) (tip : Hash) (log : Log Agent) (replayer : Replayer Agent)
      (spent stamp samples : Nat) (checkout : Checkout) : Result (Hash × Stop) := do
    -- Which limit, if any, keeps the driver from going on in `frame`: the time budget, before
    -- anything; the samples, before a sample or a read of the agent's inbox.
    let limit? (now : Nat) (frame : Frame) (sampling : Bool) : Option String :=
      if !frame.inAgent then none
      else if limits.budgetMs?.any (spent + (now - stamp) ≥ ·) then some "the time budget is spent"
      else if sampling && limits.samples?.any (samples ≥ ·) then some s!"{samples} response(s) sampled"
      else none
    let append (event : Event Agent) (checkout : Checkout) (samples : Nat) : Result (Hash × Stop) := do
      let now ← nowMs
      let entry : Entry := { parent? := some tip, event, elapsedMs := now - stamp }
      let (hash, forest) ← rt.store.put forest entry
      onEntry hash entry
      loop forest hash (log.push event) (replayer.feed event) (spent + entry.elapsedMs) now samples
        checkout
    match replayer.next with
    -- The run has ended: with its verdict, or, when its grader's call failed, an error.
    | .done value => pure (tip, .over ((agentEnd? log).getD (.returned .null)) (some value))
    | .raised error =>
      pure (tip, .over ((agentEnd? log).getD (.failed error))
        (some (.mkObj [("status", "error"), ("reason", .str error)])))
    | .waits frame =>
      match frame.isEmpty, agentEnd? log with
      | true, some agent => pure (tip, .over agent none)
      | _, _ => pure (tip, .waits frame ((questionOf? log (.waits frame)).map (·.2)))
    | .mismatch position =>
      throw <| .input s!"the log is no trace of its run's program: the event at {position} is not what it does"
    | .unguarded frame =>
      throw <| .input s!"a loop in frame {frame.render} went round without reading an event"
    | .hears frame notices =>
      -- A limit is checked before a read of the agent's inbox too, so that what a person adds
      -- where the run paused is read before the next sample, not after it.
      if let some reason := limit? (← nowMs) frame (sampling := true) then
        return (tip, .paused reason)
      append (.heard frame notices) checkout samples
    | .opens frame tool => append (.opened frame tool) checkout samples
    | .returns frame value => append (.returned frame value) checkout samples
    | .fails frame error => append (.failed frame error) checkout samples
    | .ask call =>
      let now ← nowMs
      let timeSpent := spent + (now - stamp)
      if let some reason := limit? now call.frame (call.op matches .sample _) then
        return (tip, .paused reason)
      let version := (workspace? log).getD ⟨""⟩
      match call.op with
      | .sample request =>
        let mut draw := 0
        for child in forest.childrenOf tip do
          if sampled (← rt.store.get forest child).event then draw := draw + 1
        let answer ← modelAnswer rt draw request
        append (.answered call.frame (.sample (Model.requestDigest request))
          (answer.map (.response ·))) checkout (samples + 1)
      | .exec command config =>
        let mut checkout := checkout
        if checkout.version? != some version then
          -- A container's bind mount follows the directory it was started on, which a restore
          -- replaces, so the executor is closed first: its next command starts a container.
          io rt.executor.close
          rt.workspaces.materialize version rt.workDir
          checkout := { version? := some version }
        let file? := if config.outputs then some s!"{outputsDir}/{outputFile log.size}" else none
        if config.outputs then prepareOutputs rt log
        else io do
          IO.FS.createDirAll rt.outputsDir
          for entry in ← rt.outputsDir.readDir do IO.FS.removeFile entry.path
        let output ← io (rt.executor.bash config rt.workDir command)
        let left ← rt.workspaces.snapshot rt.workDir
        append (.answered call.frame (.exec command config)
            (.ok (.execution { output, workspace := left, file? })))
          { version? := some left } samples
      | .time =>
        append (.answered call.frame .time
          (.ok (.timing { spentMs := timeSpent, budgetMs? := limits.budgetMs? }))) checkout samples
      | .external command image input? timeout =>
        let ran ← runExternal rt version command image input? timeout
        append (.answered call.frame (.external command image input? timeout) (.ok (.external ran)))
          checkout samples
  loop forest tip log (Replayer.ofLog run log) spent started 0 {}

/-! ## Notices: what a person appends -/

/-- Whether the agent is still running where a log ends: what its run does next is in the agent's
frame, or inside it. -/
def running : Next Agent → Bool
  | .ask call => call.frame.inAgent
  | .opens frame _ | .returns frame _ | .fails frame _ | .hears frame _ | .waits frame => frame.inAgent
  | _ => false

/-- Appends an event that comes from outside — a notice, a stop — after `tip`, after checking
that the log can take it: a stop, a message, a change or a reply only while the agent is
running, when it has something to end or someone to read it; a grader only where the run waits
for one, its agent over and no grader assigned yet, and only one that can be read. Gives the
new entry. -/
def append (store : Store) (run : Run Agent) (tip : Hash) (event : Event Agent) : Result (Hash × Entry) := do
  let forest ← store.forest
  let log ← store.log forest tip
  let next := (Replayer.ofLog run log).next
  if let .mismatch position := next then
    throw <| .input s!"the log is no trace of its run's program at position {position}"
  match event with
  | .stopped _ =>
    if !running next then throw <| .input "the agent is over: there is nothing to stop"
  | .arrived (.assigned grader) =>
    if running next then
      throw <| .input "the agent is still running: a grader is assigned once it is over; `alaya grade` stops it first"
    if !(next matches .waits #[]) then
      throw <| .input "the log has its grader: a point is graded again on a fork, from the entry before the grader was assigned, as `alaya grade` does"
    if let .error problem := Agents.Tools.Grade.Grader.fromJson grader then
      throw <| .input s!"the grader cannot be read: {problem}"
  | .arrived _ =>
    if !running next then
      throw <| .input "the agent is over: nothing would read a notice appended here; append it at an entry before its end"
  | _ => pure ()
  let entry : Entry := { parent? := some tip, event }
  let (hash, _) ← store.put forest entry
  pure (hash, entry)

end Alaya.Driver
