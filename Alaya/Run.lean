import Alaya.Agents.Catalog
import Alaya.Grader

/-! A run of Alaya: the agent, called with the run's configuration, and then its grading. The
configuration is the arguments of the agent's call, so the log holds it from its second event
on, and every later command builds the same run from the log alone: the agent and the model,
and the container its commands run in. A grader is no part of it: once the agent is over, the
run waits for a person to assign one, a notice, runs its program, and ends with its verdict. So any
point of any run can be graded, by any grader, at any time, and grading a point again is a fork
there. See `docs/agent-api.md` §9. -/

namespace Alaya

open Lean (Json)

/-- Where a run's commands run: a pinned image, the path the workspace is mounted at, and that
machine's `uname`, which an agent may tell its model. -/
structure Environment where
  image : String
  workdir : String
  uname : Uname
  deriving Inhabited

/-- What a run is created with. -/
structure RunConfig where
  /-- The agent's complete configuration: its `name` and every field. -/
  agent : Json
  /-- The model's complete spec (`Models.Spec`). -/
  model : Json
  environment : Environment
  deriving Inhabited

def Uname.toJson (uname : Uname) : Json :=
  .mkObj [("system", uname.system), ("release", uname.release), ("version", uname.version),
    ("machine", uname.machine)]

def Uname.fromJson (json : Json) : Except String Uname := do
  let field (name : String) := json.getObjVal? name >>= Json.getStr?
  pure { system := ← field "system", release := ← field "release", version := ← field "version"
         machine := ← field "machine" }

def Environment.toJson (environment : Environment) : Json :=
  .mkObj [("image", environment.image), ("workdir", environment.workdir),
    ("uname", environment.uname.toJson)]

def Environment.fromJson (json : Json) : Except String Environment := do
  pure { image := ← json.getObjVal? "image" >>= Json.getStr?
         workdir := ← json.getObjVal? "workdir" >>= Json.getStr?
         uname := ← json.getObjVal? "uname" >>= Uname.fromJson }

def RunConfig.toJson (config : RunConfig) : Json :=
  .mkObj [("agent", config.agent), ("model", config.model),
    ("environment", config.environment.toJson)]

def RunConfig.fromJson (json : Json) : Except String RunConfig := do
  pure { agent := ← json.getObjVal? "agent", model := ← json.getObjVal? "model"
         environment := ← json.getObjVal? "environment" >>= Environment.fromJson }

/-- The name of the agent's routine: the outermost call of every run. -/
def agentRoutine : String := "agent"

/-- A verdict as a run returns it: the status, the score, why, and every check, with how the
grader's program ended. -/
def verdictJson (verdict : Grader.Verdict) (ran : External) : Json :=
  let (passed, total) := Grader.Verdict.score verdict.checks
  .mkObj [("status", verdict.status.toString), ("passed", passed), ("total", total),
    ("reason", verdict.reason),
    ("checks", .arr (verdict.checks.map fun check =>
      .mkObj [("ok", check.ok), ("name", check.name), ("directive", check.directive)])),
    ("exit_code", ran.exitCode?.map (fun c => (c : Json)) |>.getD .null),
    ("elapsed_ms", ran.elapsedMs)]

/-- The notice that assigns `grader` to a run, as the event a person appends. -/
def assignment (grader : Grader) : Event Agent :=
  .arrived (.assigned grader.toJson)

/-- What follows the agent, however it ended: its grading, in the run's own frame. It waits for
a grader to be assigned, runs the grader's program — an external one, in a container of its own
image on a checkout of the workspace — and returns the verdict read off the TAP it printed,
which is the result of the run. A grader is no routine: nothing an agent calls reaches it. A log
has one grader: a point is graded again on a fork. -/
def grading (_ : Except String Json) : Program Agent Json := do
  let assigned ← await fun _ notice => notice matches .assigned _
  match assigned with
  | .assigned json :: _ =>
    match Grader.fromJson json with
    | .error problem => throw s!"the grader cannot be read: {problem}"
    | .ok grader =>
      let ran ← external grader.command grader.image grader.input? grader.timeoutSeconds
      return verdictJson (Grader.verdict ran.stdout ran.error?) ran
  | _ => throw "the wait for a grader ended without one"

/-- The run of an agent: its program, called as the routine `agent` with `arguments`, the
routines it calls, by name, and its grading after. A name declared twice, or the agent's own, is
refused: a call would not say which it enters. -/
def Run.ofAgent (arguments : Json) (program : Program Agent Json)
    (routines : Array (Routine.Entry Agent)) : Except String (Run Agent) := do
  let names := routines.map (·.1)
  for name in names do
    if name == agentRoutine then throw s!"a routine cannot be named {agentRoutine}: that is the agent itself"
    if (names.filter (· == name)).size > 1 then throw s!"two routines are named {name}"
  pure { routines := Routines.of (#[(agentRoutine, fun _ => program)] ++ routines)
         call := ⟨agentRoutine, arguments⟩
         after := grading }

/-- The run a configuration describes, for its model: its agent, called with the configuration,
the routines the agent declares, and its grading after. -/
def RunConfig.run (config : RunConfig) (model : Models.Spec) : Except String (Run Agent) := do
  let agent ← Agents.Catalog.build config.agent
  Run.ofAgent config.toJson (agent.program model config.environment.uname) agent.routines

/-- The configuration a log's run was created with: the arguments of the agent's call, which the
log opens after its root. -/
def configOf (log : Log Agent) : Result RunConfig := do
  let opening : Option (Event Agent) := log[1]?
  match opening with
  | some (.opened #[0] ⟨name, arguments⟩) =>
    if name != agentRoutine then throw <| .storage s!"the log calls {name} where it calls the agent"
    Result.fromExcept (fun message => .storage s!"the run's configuration: {message}")
      (RunConfig.fromJson arguments)
  | _ => throw <| .storage "the log does not open the agent after its root"

/-! ## How a log's run stands -/

/-- How the agent of a run ended. -/
inductive AgentEnd where
  | returned (value : Json)
  | failed (error : String)
  /-- Stopped from outside, by a person or at a limit, with the reason the stop gives. -/
  | stopped (reason : String)
  deriving Inhabited

/-- How the agent ends with an event, if the event ends it. The agent's frame is `#[0]`. -/
def AgentEnd.of? : Event Agent → Option AgentEnd
  | .returned #[0] value => some (.returned value)
  | .failed #[0] error => some (.failed error)
  | .stopped reason => some (.stopped reason)
  | _ => none

/-- How the agent of a log ended, once it has. -/
def agentEnd? (log : Log Agent) : Option AgentEnd := log.findSome? AgentEnd.of?

/-- The status of a verdict: `pass`, `fail` or `error`. -/
def verdictStatus (verdict : Json) : String :=
  (verdict.getObjVal? "status" >>= Json.getStr?).toOption.getD "error"

/-- Every snapshot a log names: its versions of the workspace, the input of the grader assigned
to it, and what a grader read and left. -/
def snapshots (log : Log Agent) : Array Snapshot :=
  log.foldl (init := #[]) fun found event =>
    match event with
    | .answered _ key answer =>
      let input := match key with
        | .external _ _ (some input) _ => #[input]
        | _ => #[]
      let left := match answer with
        | .ok (.execution execution) => #[execution.workspace]
        | .ok (.external external) => #[external.checkout]
        | _ => #[]
      found ++ input ++ left
    | .arrived (.changed workspace _) => found.push workspace
    | .arrived (.assigned grader) =>
      match Grader.fromJson grader with
      | .ok { input? := some input, .. } => found.push input
      | _ => found
    | _ => found

/-- The question an `ask_user` call asks, read off its opening. -/
def questionOfCall? (call : RoutineCall) : Option Question :=
  if call.name != Agents.Tools.AskUser.definition.name then none
  else (Agents.Tools.AskUser.question call.arguments).toOption

/-- The question a log waits on: the frame of the `ask_user` call that waits, and its question,
read off the opening of the call. -/
def questionOf? (log : Log Agent) (next : Next Agent) : Option (Frame × Question) := do
  let .waits frame := next | none
  let call ← log.findSome? fun
    | .opened opened call => if opened == frame then some call else none
    | _ => none
  pure (frame, ← questionOfCall? call)

/-- A person's reply to the question a log waits on, as the event to append: refused when no
question waits, or when the reply is not of the form the question asks for. -/
def replyTo (log : Log Agent) (next : Next Agent) (answer : Reply) : Except String (Event Agent) := do
  let some (frame, question) := questionOf? log next | throw "no question waits for a reply here"
  if !question.accepts answer then
    throw s!"the answer does not fit a {question.form.name} question"
  pure (.arrived (.replied frame answer))

end Alaya
