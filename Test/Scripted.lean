import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! Helpers shared by tests that drive an agent with a scripted model: the model itself, builders
for the tool calls it answers with, a fixed `uname`, a run of MiniSwe, a driver over the test's
own store, and readers of what a log holds. -/

namespace Scripted

open Testing
open Alaya
open Lean (Json)

def contains (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length >= 2

/-- Reports the first differing character index, so a golden mismatch is diagnosable. -/
def assertStringEq (label actual expected : String) : TestM Unit := do
  if actual == expected then return ()
  let a := actual.toList
  let e := expected.toList
  let mut i := 0
  while i < a.length && i < e.length && a[i]? == e[i]? do
    i := i + 1
  fail s!"{label}: differ at char {i}\n  actual  ({actual.length}): {repr (actual.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}\n  expected({expected.length}): {repr (expected.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}"

/-- A fixed `uname`, so prompts do not depend on the machine the tests run on. -/
def testUname : Uname :=
  { system := "Linux", machine := "x86_64" }

def call (id name command : String) : Chat.ToolCall :=
  { id, name, arguments := .mkObj [("command", (command : Json))] }

def submitCall (id : String) (message : String := "") : Chat.ToolCall :=
  { id, name := "submit", arguments := .mkObj [("message", (message : Json))] }

def askCall (id question : String) (form := "yes_no") (options : Array String := #[]) : Chat.ToolCall :=
  { id, name := "ask_user", arguments := .mkObj [("question_type", (form : Json)),
      ("question", (question : Json)), ("options", .arr (options.map Json.str))] }

def responseWith (calls : Array Chat.ToolCall) (finish := "tool_calls") : Chat.Response :=
  { toolCalls := calls, finishReason? := some finish }

/-- A model that answers each request with the next response of `responses`, whatever it asks. -/
def scriptedModel (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

def workDir : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

/-- The model a run records when the test does not care which, and its spec. -/
def testModelSpec : Models.Spec := { name := "gpt-oss-120b" }

/-- The configuration of a run of `agent` in the test's recorded image. -/
def testConfig (agent : Json) : RunConfig :=
  { agent, model := testModelSpec.toJson
    environment := { image := recordedImage, workdir := recordedWorkdir, uname := testUname } }

/-- A run of MiniSwe with `config`, for the test model. -/
def miniRun (config : Agents.MiniSwe.Config := {}) : Except String (Run Agent) :=
  (testConfig config.toJson).run testModelSpec

/-- A runtime over a store and directory workspaces of the test's own, with `executor` and
`model`. Each call has a store of its own; the work directory is the test's. -/
def runtime (executor : Executor) (model? : Option Model) : TestM Driver.Runtime := do
  let base := (← scratch) / s!"run-{← IO.monoNanosNow}"
  let work ← workDir
  let store ← assertOk <| Store.create (base / "entries")
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir := base / "outputs"
         scratch := base / "external", executor, workdir := recordedWorkdir, model? }

/-- A runtime whose commands run in the test container, with the outputs directory mounted where
a command finds the whole output of an earlier one. -/
def containerRuntime (model? : Option Model) : TestM Driver.Runtime := do
  let outputs := (← scratch) / s!"outputs-{← IO.monoNanosNow}"
  IO.FS.createDirAll outputs
  let settings ← testSettings
  let executor ← assertOk <| Executor.Docker.executor { settings with
    mounts := #[{ host := ← IO.FS.realPath outputs, container := Driver.outputsDir, readOnly := true }] }
  pure { (← runtime executor model?) with outputsDir := outputs }

/-- `model` behind Alaya's persistent cache, as a run's model is: a second draw of a request keeps
the first. -/
def cached (model : Model) : TestM Model := do
  assertOk <| Cache.persistent model { directory := (← scratch) / s!"cache-{← IO.monoNanosNow}" }

/-- Creates a run over `project` (an empty one when none), with `task`, in `rt`'s store. Gives
the entry the log ends at. -/
def start (rt : Driver.Runtime) (run : Run Agent) (task : String := "t")
    (project? : Option System.FilePath := none) : TestM Hash := do
  let project ← match project? with
    | some project => pure project
    | none =>
      let project := rt.outputsDir.withFileName s!"project-{← IO.monoNanosNow}"
      IO.FS.createDirAll project
      pure project
  let made ← assertOk <| Notices.create rt.store rt.workspaces run project task
  let some (tip, _) := made.back? | fail "no entries were made"
  pure tip

/-- Drives `run` from a new log, with `task`, until it is over, waits, or reaches `limits`. -/
def drive (run : Run Agent) (executor : Executor) (model : Model) (task : String := "t")
    (limits : Driver.Limits := {}) : TestM (Driver.Runtime × Hash × Driver.Stop) := do
  let rt ← runtime executor (some model)
  let tip ← start rt run task
  let (last, stop) ← assertOk <| Driver.drive rt run tip limits
  pure (rt, last, stop)

/-- The log that ends at `hash`. -/
def logAt (rt : Driver.Runtime) (hash : Hash) : TestM (Log Agent) := do
  let forest ← assertOk rt.store.forest
  assertOk <| rt.store.log forest hash

/-- Grades the point `tip` of a run with `grader`, as `alaya grade` does: stops the agent there
if it is still running, assigns the grader, and drives the run to its end. Gives the entry the
log ends at, and the verdict. -/
def grade (rt : Driver.Runtime) (run : Run Agent) (tip : Hash) (grader : Grader) :
    TestM (Hash × Json) := do
  let mut tip := tip
  if Driver.running (next run (← logAt rt tip)) then
    tip := (← assertOk <| Driver.append rt.store run tip (.stopped "to grade this point")).1
  tip := (← assertOk <| Driver.append rt.store run tip (assignment grader)).1
  let (graded, stop) ← assertOk <| Driver.drive rt run tip
  let .over _ (some verdict) := stop | fail "the run did not come to its verdict"
  pure (graded, verdict)

/-- Every sample of a log: the request replay says it answers, and the response. -/
def samplesOf (run : Run Agent) (log : Log Agent) : Array (Chat.Request × Chat.Response) :=
  let step := fun (state : Replayer Agent × Array (Chat.Request × Chat.Response)) (event : Event Agent) =>
    let (replayer, found) := state
    let found := match replayer.next, event with
      | .ask { op := .sample request, .. }, .answered _ _ (.ok (.response response)) =>
        found.push (request, response)
      | _, _ => found
    (replayer.feed event, found)
  (log.foldl step (Replayer.start run, #[])).2

/-- What MiniSwe's model saw last, and the response it gave: the last request's messages, then
that response as the view shows it. -/
def lastDialogue (config : Agents.MiniSwe.Config) (run : Run Agent) (log : Log Agent) :
    Array Chat.Message :=
  match (samplesOf run log).back? with
  | none => #[]
  | some (request, response) =>
    request.messages.push <| match Agents.MiniSwe.parseActions response config with
      | .calls _ => response.message
      | .formatError message => .user message

/-- The log with `event` appended as the driver appends an event of the program: after the
comments the program made since its last one. -/
def appended (run : Run Agent) (log : Log Agent) (event : Event Agent) : Log Agent :=
  (log ++ (Replayer.ofLog run log).comments.map Event.commented).push event

/-- The log with every mark `run` makes after it appended, up to what it asks of the world
next, or how it ends: what the driver would log before its next operation, without one. -/
partial def settle (run : Run Agent) (log : Log Agent) : Log Agent :=
  match next run log with
  | .hears frame notices => settle run (appended run log (.heard frame notices))
  | .questions frame question => settle run (appended run log (.asked frame question))
  | .opens frame opened => settle run (appended run log (.opened frame opened))
  | .returns frame value => settle run (appended run log (.returned frame value))
  | .fails frame error => settle run (appended run log (.failed frame error))
  | _ => log

/-- The log with the answer to what `run` asks next appended, and then its marks: what the world
said, as a log keeps it. -/
def answer (run : Run Agent) (log : Log Agent) (stored : Stored) : Log Agent :=
  match next run log with
  | .ask call => settle run (appended run log (.answered call.frame call.op.key (.ok stored)))
  | _ => log

/-- The log with `response` as the model's answer to what `run` asks next. -/
def respond (run : Run Agent) (log : Log Agent) (response : Chat.Response) : Log Agent :=
  answer run log (.response response)

/-- The start of a log of `run`: its root, the opening of its agent, and `task`. -/
def opening (run : Run Agent) (task : String := "t") : Log Agent :=
  #[.arrived (.changed default "the project"), .opened #[0] run.call, .arrived (.said task)]

/-- How the agent of a log ended: the value its frame returned, or its error. -/
def agentResult (log : Log Agent) : Option (Except String Json) :=
  log.findSome? fun
    | .returned #[0] value => some (.ok value)
    | .failed #[0] error => some (.error error)
    | _ => none

/-- The status of MiniSwe's outcome, from how its frame ended. -/
def agentStatus (log : Log Agent) : String :=
  match agentResult log with
  | some (.ok value) => (value.getObjVal? "status" >>= Json.getStr?).toOption.getD value.compress
  | some (.error error) => s!"error: {error}"
  | none => "running"

end Scripted
