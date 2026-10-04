import Alaya.Agents.Catalog

/-! A run of Alaya: the agent, called with the run's configuration, and then its grading. The
configuration is the arguments of the agent's call, so the log holds it from its second event
on, and every later command builds the same run from the log alone: the agent and the model,
and the container its commands run in. A grader is no part of it: once the agent is over, the
run waits for a person to assign one, a notice, calls it, and ends with its verdict. So any
point of any run can be graded, by any grader, at any time, and grading a point again is a fork
there. See `docs/architecture.md`. -/

namespace Alaya

open Lean (Json)
open Alaya.Agents (Tool)
open Alaya.Agents.Tools.Grade (Grader)

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

/-- The name of the agent's tool: the outermost call of every run. -/
def agentTool : String := "agent"

/-- The name of the graders' tool. -/
def graderTool : String := Agents.Tools.Grade.definition.name

/-- The notice that assigns `grader` to a run, as the event a person appends. -/
def assignment (grader : Grader) : Event Agent :=
  .arrived (.assigned grader.toJson)

/-- What follows the agent, however it ended: its grading. It waits for a grader to be assigned,
calls the graders' tool with it, in the frame after the agent's, and returns the verdict, which
is the result of the run. A log has one grader: a point is graded again on a fork. -/
def grading (_ : Except String Json) : Program Agent Json := do
  let assigned ← await fun _ notice => notice matches .assigned _
  match assigned with
  | .assigned grader :: _ => call graderTool grader
  | _ => throw "the wait for a grader ended without one"

/-- The run a configuration describes, for its model: its agent, called with the configuration,
the tools the agent offers and the graders' tool, by name, and its grading after. -/
def RunConfig.run (config : RunConfig) (model : Models.Spec) : Except String (Run Agent) :=
  match Agents.Catalog.build config.agent with
  | .error problem => .error problem
  | .ok agent =>
    let tools : Array Tool := agent.tools.push Agents.Tools.Grade.tool
    let program := agent.program model config.environment.uname
    .ok {
      tools := fun name =>
        if name == agentTool then some fun _ => program
        else (tools.find? (·.name == name)).map (·.run)
      call := ⟨agentTool, config.toJson⟩
      after := grading }

/-- The configuration a log's run was created with: the arguments of the agent's call, which the
log opens after its root. -/
def configOf (log : Log Agent) : Result RunConfig := do
  let opening : Option (Event Agent) := log[1]?
  match opening with
  | some (.opened #[0] ⟨name, arguments⟩) =>
    if name != agentTool then throw <| .storage s!"the log calls {name} where it calls the agent"
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
def questionOfCall? (tool : ToolCall) : Option Question :=
  if tool.name != Agents.Tools.AskUser.definition.name then none
  else (Agents.Tools.AskUser.question tool.arguments).toOption

/-- The question a log waits on: the frame of the `ask_user` call that waits, and its question,
read off the opening of the call. -/
def questionOf? (log : Log Agent) (next : Next Agent) : Option (Frame × Question) := do
  let .waits frame := next | none
  let tool ← log.findSome? fun
    | .opened opened tool => if opened == frame then some tool else none
    | _ => none
  pure (frame, ← questionOfCall? tool)

/-- A person's reply to the question a log waits on, as the event to append: refused when no
question waits, or when the reply is not of the form the question asks for. -/
def replyTo (log : Log Agent) (next : Next Agent) (answer : Reply) : Except String (Event Agent) := do
  let some (frame, question) := questionOf? log next | throw "no question waits for a reply here"
  if !question.accepts answer then
    throw s!"the answer does not fit a {question.form.name} question"
  pure (.arrived (.replied frame answer))

end Alaya
