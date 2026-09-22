import Alaya.Agent.MiniSwe
import Alaya.Agent.MiniVero

/-!
The agent families the command line can run, and how a configuration names one.

An agent is a **family** and a **configuration**: a JSON object with a `family` field and the
family's own fields, read by the family's `Config.fromJson`. A configuration is a file, named
by `root --agent`; `agents/*.json` in the repository are the families' defaults, and the
documentation of their fields. Whatever a root was created with, its complete configuration is
what the root records (`Trajectory.State.agent?`), and every later command rebuilds the agent
from that.
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
  make : Lean.Json -> Except String Instance

def miniSwe : Family := {
  name := "mini-swe"
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

/-- The agent a configuration file names. -/
def fromFile (path : System.FilePath) : Result Instance := do
  let text ← match ← (Result.fromIO Error.configuration (IO.FS.readFile path)).toBaseIO with
    | .ok text => pure text
    | .error _ => throw <| .configuration s!"cannot read the agent configuration {path}"
  match Lean.Json.parse text with
  | .ok json => instanceOf json
  | .error message => throw <| .configuration s!"{path} is not JSON: {message}"

end Alaya.Agent.Families
