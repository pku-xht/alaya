import Alaya.Agent.MiniSwe
import Alaya.Agent.MiniVero

/-!
The agent families the command line can run, and how a configuration names one.

An agent is a **family** and a **configuration**: a JSON object with a `family` field and the
family's own fields, read by the family's `Config.fromJson`. `agents/*.json` in the repository
are configurations — `mini-swe-default.json` and `mini-vero-default.json` are each family's
defaults, and the documentation of its fields — and the two defaults are built into the
program, so `--agent mini-swe-default` needs no path. Whatever a root was created with, its
complete configuration is what the root records (`Trajectory.State.agent?`), and every later
command rebuilds the agent from that.
-/

namespace Alaya.Agent.Families

open Alaya (Result Error Executor Uname)
open Alaya.Agent (Agent Log View)

/-- An agent built from a configuration: what the command line needs of it. -/
structure Instance where
  /-- The opening log of a run for a task, on a machine described by `uname`. -/
  initialLog : String -> Uname -> Log
  executorConfig : Executor.Config
  build : Executor -> Agent
  view : View
  tools : Array Chat.ToolDefinition
  /-- The configuration, complete and in canonical form: what a root records. -/
  config : Lean.Json

structure Family where
  name : String
  /-- The family's default configuration, as `agents/<name>-default.json`. -/
  defaults : Lean.Json
  make : Lean.Json -> Except String Instance

private def parsed (text : String) : Lean.Json :=
  match Lean.Json.parse text with
  | .ok json => json
  | .error _ => .null

def miniSwe : Family := {
  name := "mini-swe"
  defaults := parsed (include_str "../../agents/mini-swe-default.json")
  make := fun json => do
    let config ← MiniSwe.Config.fromJson json
    pure {
      initialLog := MiniSwe.initialLog config
      executorConfig := config.executor
      build := fun executor => MiniSwe.agent executor config
      view := MiniSwe.view config
      tools := MiniSwe.tools config
      config := config.toJson } }

def miniVero : Family := {
  name := "mini-vero"
  defaults := parsed (include_str "../../agents/mini-vero-default.json")
  make := fun json => do
    let config ← MiniVero.Config.fromJson json
    pure {
      initialLog := MiniVero.initialLog config
      executorConfig := config.base.executor
      build := fun executor => MiniVero.agent executor config
      view := MiniVero.view config
      tools := MiniVero.tools config
      config := config.toJson } }

def all : Array Family := #[miniSwe, miniVero]

def names : String := ", ".intercalate (all.map (·.name)).toList

def family? (name : String) : Option Family := all.find? (·.name == name)

/-- The agent a configuration names, or what is wrong with the configuration. -/
def instanceOf (json : Lean.Json) : Result Instance := do
  let name ← match json.getObjVal? "family" with
    | .ok (.str name) => pure name
    | _ => throw <| .configuration s!"an agent configuration needs a \"family\": one of {names}"
  let some family := family? name
    | throw <| .configuration s!"unknown agent family: {name} (use {names})"
  match family.make json with
  | .ok built => pure built
  | .error message => throw <| .configuration s!"{name} configuration: {message}"

/-- `json` with the value at a dotted `path` replaced, objects created along the way. -/
partial def set (json : Lean.Json) (path : List String) (value : Lean.Json) : Lean.Json :=
  match path with
  | [] => value
  | key :: rest =>
    let fields := match json with | .obj fields => fields | _ => {}
    let inner := fields.get? key |>.getD .null
    .obj (fields.insert key (set inner rest value))

/-- A `--set path=value`: the value is JSON when it parses, the text otherwise, so `step_limit=5`,
`recover_output=true`, `mode=proof` and `executor.env=[["A","1"]]` all read as meant. -/
def overlay (json : Lean.Json) (setting : String) : Result Lean.Json := do
  match setting.splitOn "=" with
  | [] | [_] => throw <| .configuration s!"--set takes path=value, not '{setting}'"
  | path :: rest =>
    let text := "=".intercalate rest
    let value := match Lean.Json.parse text with
      | .ok value => value
      | .error _ => .str text
    pure (set json (path.splitOn ".") value)

end Alaya.Agent.Families
