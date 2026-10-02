import Alaya.Trajectory
import Alaya.Executor.Docker

/-! What a person adds to a trajectory: a root over a project, an edit, a message, a reply. Each is
placed in the agent's log as an event from the world. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect CallRef Question Reply)

/-! ## Root creation and what a person adds -/

/-- Creates a root state from the initial project directory: the agent's opening log — its
prompts — and then a snapshot of `project`, placed in the log as its first workspace. The root
records what the run is created with: the agent, the model, the image and workdir its commands
run in, and the task. -/
def createRoot (store : Store) (workspaces : Workspaces) (log : Log) (project : System.FilePath)
    (image : String) (task? : Option String := none) (agent model : Lean.Json)
    (workdir : String := Executor.Docker.defaultWorkdir) : Result Hash := do
  let workspace ← workspaces.snapshot project
  putState store { parent? := none, workspace, kind := .root { agent, model, image, workdir, task? }
                   appended := log.push (.placed workspace) }

/-- A state a person may build on: anything but an evaluation, which is a leaf, or a state
waiting for an answer, which `reply` alone grows. An ended run is fine: fixing something after a
submission and continuing is what interventions are for. -/
private def buildable (state : State) : Result Unit := do
  if state.kind matches .evaluation _ then
    throw <| .input "cannot build on an evaluation: it is a verdict, not a point in the run"
  if let some q := state.question? then
    throw <| .input
      s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

/-- Records a hand-edited workspace `dir` as an intervention child of `hash`: the new workspace,
placed in the log, and a notice listing what changed, so the agent is always told and its view
never disagrees with its files; `message`, what the person says of the change, follows the list
in the same notice. A directory with no change is refused; `tell` sends a message alone. -/
def commit (store : Store) (workspaces : Workspaces) (hash : Hash) (dir : System.FilePath)
    (message : String := "") : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let workspace ← workspaces.snapshot dir
  let changed ← changedLines workspaces parent.workspace workspace
  if changed.isEmpty then
    throw <| .input s!"{dir} has no change from {hash.hex}: to send a message alone, use `tell`"
  let intervention : Intervention := { message, changed }
  putState store {
    parent? := some hash, workspace, kind := .intervention intervention
    appended := #[.placed workspace, .told (.user (interventionNotice intervention))] }

/-- Records a person's message to the agent as a child of `hash`: same workspace, and the log
grown by one user message carrying it in the intervention envelope. -/
def tell (store : Store) (hash : Hash) (message : String) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let intervention : Intervention := { message }
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .intervention intervention
    appended := #[.told (.user (interventionNotice intervention))] }

/-- What the state at `hash` has asked, when it waits for an answer. -/
private def askedAt (store : Store) (hash : Hash) : Result (State × Asked) := do
  let state ← getState store hash
  match state.asked? with
  | some asked => pure (state, asked)
  | none => throw <| .input "this state is not waiting for an answer"

/-- Records a person's answer to the question the state at `hash` waits on, as a reply child:
its one event is the result recorded for the asking call. The answer must be one the question's
form accepts; that the person cannot answer (`Reply.unavailable`) fits any. A reply keeps the
workspace and samples nothing. -/
def reply (store : Store) (hash : Hash) (answer : Reply) : Result Hash := do
  let (parent, asked) ← askedAt store hash
  if !asked.question.accepts answer then
    throw <| .input s!"the answer does not fit a {asked.question.form.name} question"
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .reply
    appended := #[asked.effect.event answer] }

/-- Records a person's answer as they typed it: read against the question's form
(`Question.parseReply`), then recorded by `reply`. -/
def replyText (store : Store) (hash : Hash) (text : String) : Result Hash := do
  let (_, asked) ← askedAt store hash
  reply store hash (← Result.fromExcept Error.input (asked.question.parseReply text))

end Alaya.Trajectory
