import Test.Support.Framework
import Test.Support.Frames
import Test.Support.DirectoryWorkspaces
import Test.Support.Container
import Alaya

/-! Helpers shared by tests that drive an agent with a scripted model: the model itself, builders
for the tool calls it answers with, a fixed `uname`, a run of MiniSwe, a driver over the test's
own store, and readers of what a log holds. -/

namespace Scripted

open Testing
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

/-- An executor that answers every command with `output`, and runs nothing. -/
def echoing (output : String := "ok") : Executor :=
  { exec := fun _ _ _ _ => pure { output, exitCode? := some 0 } }

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

/-- Where a test's calls run: the test's recorded image and workdir. -/
def testEnvironment : Environment := { image := recordedImage, workdir := recordedWorkdir }

/-- What `uname` prints on the test's machine, `testUname`. -/
def testUnameOutput : String := s!"{testUname.system} {testUname.machine}\n"

/-- `executor`, but for `uname`, which it answers as the test's machine, whatever runs the rest:
so an agent's opening is the same wherever the tests run, and an executor that counts its
commands counts the agent's alone. -/
def answeringUname (executor : Executor) : Executor :=
  { executor with exec := fun config workDir argv display =>
      if argv[0]? == some Agents.Tools.Uname.command then pure { output := testUnameOutput, exitCode? := some 0 }
      else executor.exec config workDir argv display }

/-- The call that starts a run: the session. -/
def sessionCall : RoutineCall := Session.call

/-- Whether the driver stopped where the session waits for a call. -/
def isIdle : Driver.Stop → Bool
  | .waits frame none => frame == Session.frame
  | _ => false

/-- The calls open where a log ends, outermost first. -/
def openCalls (log : Log Agent) : Array OpenCall :=
  log.zipIdx.foldl (init := #[]) fun open' (event, i) => OpenCall.after open' i event

/-- The configuration of the test's agent, `agent`, on `task`, with the test model. -/
def testConfig (task : String := "t") : Json :=
  .mkObj [("model", testModelSpec.toJson), ("task", task)]

/-- A person's call of the test's agent on `task`, in `environment`. -/
def testCall (task : String := "t") (environment : Environment := testEnvironment) : RoutineCall :=
  { name := "agent", arguments := testConfig task, environment? := some environment.toJson }

/-- The notice that calls the test's agent on `task`. -/
def callAgent (task : String := "t") (environment : Environment := testEnvironment) : Event Agent :=
  (testCall task environment).event

/-- The task a configuration gives, if any. -/
def taskOf (config : Json) : Option String :=
  (config.getObjVal? "task" >>= Json.getStr?).toOption

/-- A run of Alaya, the session, whose program `agent` runs `body` on its call's configuration,
its calls naming routines in `scope`. Every program of the catalog is there too, the grader among
them. -/
def runWith (body : Json → Computation Agent Json) (scope : Scope Agent := .empty) : Scope Agent :=
  Scope.of #[Session.of ⟨fun name =>
      if name == "agent" then
        some { name, scope, body }
      else Catalog.scope.find name⟩]

/-- A run of Alaya whose program `agent` is `make`'s computation for the call's task, its calls
naming routines in `scope`. -/
def runOf (make : String → Computation Agent Json) (scope : Scope Agent := .empty) : Scope Agent :=
  runWith (fun config => make ((taskOf config).getD "")) scope

/-- A run whose `agent` is the program `name` of the catalog with the configuration `config`,
with `model` as its model and the call's task as its task, in the scope the catalog gives that
program. -/
def runOfConfig (name : String) (config : Json) (model : Models.Spec := testModelSpec) :
    Except String (Scope Agent) :=
  match Catalog.named? name with
  | none => .error s!"unknown program: {name}"
  | some definition => match definition.complete (config.setObjVal! "model" model.toJson) with
    | .error problem => .error problem
    | .ok (config : Json) => .ok <| runWith (scope := definition.routine.scope) fun called =>
      definition.routine.body <| match taskOf called with
        | some task => config.setObjVal! "task" task
        | none => config

/-- A run of MiniSwe with `config`, as the program `agent`, for the test model, in the scope the
catalog gives MiniSwe: its tools, and itself, which `subagent` calls. -/
def miniRun (config : Agents.MiniSwe.Config := {}) : Except String (Scope Agent) :=
  runOfConfig "mini-swe" config.toJson

/-- A runtime over a store and directory workspaces of the test's own, with `executor` and
`model`. Each call has a store of its own; the work directory is the test's. -/
def runtime (executor : Executor) (model? : Option Model) : TestM Driver.Runtime := do
  let base := (← scratch) / s!"run-{← IO.monoNanosNow}"
  let work ← workDir
  let store ← assertOk <| Store.create (base / "entries")
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir := base / "outputs"
         executor := fun _ => pure (answeringUname executor)
         model := fun _ => match model? with
           | some model => pure model
           | none => throw <| .input "a call samples its model: name a --provider" }

/-- An executor that keeps files and runs nothing: `write PATH TEXT` writes a file of the work
directory, `rm PATH` removes one, `cat PATH` prints one, `leak` drops a file among the outputs, and
anything else lists the work directory and the outputs. -/
def filing (outputs : System.FilePath) : Executor :=
  let done : Output := { output := "", exitCode? := some 0 }
  let names (dir : System.FilePath) : IO String := do
    if !(← dir.isDir) then return ""
    pure (" ".intercalate ((← dir.readDir).map (·.fileName) |>.qsort (· < ·)).toList)
  { exec := fun _ workDir argv _ => do
      match (argv[0]?.getD "").splitOn " " with
      | ["write", path, text] =>
        let file := workDir / (path : System.FilePath)
        IO.FS.createDirAll (file.parent.getD workDir)
        IO.FS.writeFile file (text ++ "\n")
        pure done
      | ["rm", path] =>
        IO.FS.removeFile (workDir / (path : System.FilePath))
        pure done
      | ["cat", path] =>
        let file := workDir / (path : System.FilePath)
        if ← file.pathExists then pure { done with output := ← IO.FS.readFile file }
        else pure { output := s!"cat: {path}: No such file or directory", exitCode? := some 1 }
      | ["leak"] =>
        IO.FS.createDirAll outputs
        IO.FS.writeFile (outputs / "leak.txt") "x"
        pure done
      | _ => pure { done with output := s!"work: {← names workDir}; outputs: {← names outputs}" } }

/-- A runtime whose commands are `filing`'s, over a store and workspaces of the test's own. -/
def filingRuntime (model : Model) : TestM Driver.Runtime := do
  let rt ← runtime (echoing) (some model)
  pure { rt with executor := fun _ => pure (answeringUname (filing rt.outputsDir)) }

/-- Runs `k` with MiniSwe's run, configured by `config`. -/
def withMini (config : Agents.MiniSwe.Config := {}) (k : Scope Agent → TestM Unit) : TestM Unit :=
  match miniRun config with
  | .ok run => k run
  | .error problem => fail problem

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

/-- Creates a run over `project` as `alaya new` does: its root, and the session, read and opened,
waiting for a call. Gives the entry it waits at. -/
def begin (store : Store) (workspaces : Workspaces) (run : Scope Agent) (project : System.FilePath) :
    TestM Hash := do
  let (root, _) ← assertOk <| Notices.create store workspaces project
  let (tip, _) ← assertOk <| Driver.append store run root sessionCall.event
  let settled ← assertOk <| Driver.settle store run tip
  pure ((settled.back?.map (·.1)).getD tip)

/-- Creates a run over `project` (an empty one when none), in `rt`'s store, and calls the test's
agent on `task`. Gives the entry the log ends at. -/
def start (rt : Driver.Runtime) (run : Scope Agent) (task : String := "t")
    (project? : Option System.FilePath := none) (environment : Environment := testEnvironment) : TestM Hash := do
  let project ← match project? with
    | some project => pure project
    | none =>
      let project := rt.outputsDir.withFileName s!"project-{← IO.monoNanosNow}"
      IO.FS.createDirAll project
      pure project
  let tip ← begin rt.store rt.workspaces run project
  let (tip, _) ← assertOk <| Driver.append rt.store run tip (callAgent task environment)
  pure tip

/-- Drives `run` from a new log, with `task`, until it is over, waits, or reaches `limits`. -/
def drive (run : Scope Agent) (executor : Executor) (model : Model) (task : String := "t")
    (limits : Driver.Limits := {}) : TestM (Driver.Runtime × Hash × Driver.Stop) := do
  let rt ← runtime executor (some model)
  let tip ← start rt run task
  let (last, stop) ← assertOk <| Driver.drive rt run tip limits
  pure (rt, last, stop)

/-- The log that ends at `hash`. -/
def logAt (rt : Driver.Runtime) (hash : Hash) : TestM (Log Agent) := do
  let forest ← assertOk rt.store.forest
  assertOk <| rt.store.log forest hash

/-- A person's call of the grader with `command`, in `image`. -/
def graderCall (command : String) (image : String := recordedImage) (timeoutSeconds : Nat := 900)
    (workdir : String := recordedWorkdir) : RoutineCall :=
  { name := "grader", arguments := .mkObj [("command", command), ("timeout_seconds", timeoutSeconds)]
    environment? := some ({ image, workdir } : Environment).toJson }

/-- Grades the point `tip` of a run with the grader `call`, as a person does: stops the call
running there, if one is, calls the grader, and drives it to its end. Gives the entry the log
ends at, and the verdict. -/
def grade (rt : Driver.Runtime) (run : Scope Agent) (tip : Hash) (call : RoutineCall) :
    TestM (Hash × Json) := do
  let mut tip := tip
  let log ← logAt rt tip
  if Session.running (next run log) then
    let frame ← assertOk <| Session.callToStop (openCalls log)
    tip := (← assertOk <| Driver.append rt.store run tip (.broke frame "to grade this point")).1
    tip := (← assertOk <| Driver.drive rt run tip).1
  tip := (← assertOk <| Driver.append rt.store run tip call.event).1
  let (graded, stop) ← assertOk <| Driver.drive rt run tip
  check (isIdle stop) "the grader is over"
  let some (_, some (.returned verdict)) := lastCall? (← logAt rt graded) | fail "the grader gave no verdict"
  pure (graded, verdict)

/-- Every sample of a log: the request replay says it answers, and the response. -/
def samplesOf (run : Scope Agent) (log : Log Agent) : Array (Chat.Request × Chat.Response) :=
  let step := fun (state : Replayer Agent × Array (Chat.Request × Chat.Response)) (event : Event Agent) =>
    let (replayer, found) := state
    let found := match replayer.next, event with
      | .ask { op := .sample _ request, .. }, .answered _ _ (.ok (.response response)) =>
        found.push (request, response)
      | _, _ => found
    (replayer.feed event, found)
  (log.foldl step (Replayer.start run, #[])).2

/-- What MiniSwe's model saw last, and the response it gave: the last request's messages, then
that response as the view shows it. -/
def lastDialogue (config : Agents.MiniSwe.Config) (run : Scope Agent) (log : Log Agent) :
    Array Chat.Message :=
  match (samplesOf run log).back? with
  | none => #[]
  | some (request, response) =>
    request.messages.push <| match Agents.MiniSwe.parseActions response config with
      | .calls _ => response.message
      | .formatError message => .user message

/-- The log with `event` appended as the driver appends an event of the program: after the
comments the program made since its last one. -/
def appended (run : Scope Agent) (log : Log Agent) (event : Event Agent) : Log Agent :=
  (log ++ (Replayer.ofLog run log).comments.map Event.commented).push event

/-- The log with every mark `run` makes after it appended, and the answer to an agent's `uname`,
the test's machine, up to what it asks of the world next, or how it ends: what the driver would
log before its next operation, without one. -/
partial def settle (run : Scope Agent) (log : Log Agent) : Log Agent :=
  match next run log with
  | .ask { frame, op := .exec command config } =>
    if command != Agents.Tools.Uname.command then log else
    let execution : Execution :=
      { output := { output := testUnameOutput, exitCode? := some 0 }, workspace := (workspace? log).getD default }
    settle run (appended run log (.answered frame (.exec command config) (.ok (.execution execution))))
  | .mark event => settle run (appended run log event)
  | _ => log

/-- The log with the answer to what `run` asks next appended, and then its marks: what the world
said, as a log keeps it. -/
def answer (run : Scope Agent) (log : Log Agent) (stored : Stored) : Log Agent :=
  match next run log with
  | .ask call => settle run (appended run log (.answered call.frame call.op.key (.ok stored)))
  | _ => log

/-- The log with `response` as the model's answer to what `run` asks next. -/
def respond (run : Scope Agent) (log : Log Agent) (response : Chat.Response) : Log Agent :=
  answer run log (.response response)

/-- The start of a log of the test's agent: its root, the call of the session, its read and its
opening, the call of the agent on `task`, the session's read of it, and the opening of the call. -/
def opening (task : String := "t") : Log Agent :=
  #[.arrived (.changed default "the project"), sessionCall.event, .heard #[] #[1], .opened ⟪"session"⟫ sessionCall,
    callAgent task, .heard ⟪"session"⟫ #[4], .opened ⟪"session", "agent"⟫ (testCall task)]

/-- How the agent of a log ended: the value its frame returned, or its error. -/
def agentResult (log : Log Agent) : Option (Except String Json) :=
  log.findSome? fun
    | .returned ⟪"session", "agent"⟫ value => some (.ok value)
    | .failed ⟪"session", "agent"⟫ error => some (.error error)
    | _ => none

/-- The status of MiniSwe's outcome, from how its frame ended. -/
def agentStatus (log : Log Agent) : String :=
  match agentResult log with
  | some (.ok value) => (value.getObjVal? "status" >>= Json.getStr?).toOption.getD value.compress
  | some (.error error) => s!"error: {error}"
  | none => "running"

end Scripted
