import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Settings

/-!
The agents the command line can run, by name, and how a run's agent is configured.

An agent's defaults are in code, in its definition. A run names an agent (`new --agent NAME`)
and overrides any of its fields on the command line (`--set agent.FIELD=VALUE`), and the run's
configuration — the opening of the agent's call, the second event of its log — holds the
complete configuration, from which every later command builds the same agent again. There are
no configuration files.
-/

namespace Alaya.Agents.Catalog

open Lean (Json)
open Alaya (Result Error Uname)

/-- An agent built from its configuration: the complete configuration, the tools it offers, which
the run has under their names, and its program, for a run of a model on a machine. -/
structure Built where
  config : Json
  tools : Array Tool
  program : Models.Spec → Uname → Program Agent Json

/-- An agent the command line can name, and how a configuration builds it. -/
structure Definition where
  name : String
  /-- The agent a configuration describes: one that names this agent, with any of its fields
  left out for their defaults. -/
  make : Json → Except String Built

def miniSwe : Definition := {
  name := "mini-swe"
  make := fun json => match MiniSwe.Config.fromJson json with
    | .ok config => .ok { config := config.toJson, tools := config.offered, program := MiniSwe.program config }
    | .error problem => .error problem }

def miniVero : Definition := {
  name := "mini-vero"
  make := fun json => match MiniVero.Config.fromJson json with
    | .ok config =>
      .ok { config := config.toJson, tools := config.base.offered, program := MiniVero.program config }
    | .error problem => .error problem }

def all : Array Definition := #[miniSwe, miniVero]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The agent a configuration describes, or what is wrong with it. -/
def build (json : Json) : Except String Built :=
  match json.getObjVal? "name" with
  | .ok (.str name) => match named? name with
    | some definition => match definition.make json with
      | .ok built => .ok built
      | .error message => .error s!"{name}: {message}"
    | none => .error s!"unknown agent: {name} (use {names})"
  | _ => .error s!"an agent configuration needs a \"name\": one of {names}"

/-- The complete configuration of the agent a configuration describes, or what is wrong with
it: every field, those left out at their defaults. -/
def complete (json : Json) : Result Json :=
  match build json with
  | .ok built => pure built.config
  | .error message => throw <| .input message

/-- The complete configuration of the agent `name` with the agent's settings applied over its
defaults. Every key is checked as a configuration's would be: an unknown one, or a value of the
wrong type, is an error naming it. -/
def resolve (name : String) (settings : Array Settings.Setting) : Result Json := do
  let defaults ← complete (.mkObj [("name", name)])
  match Settings.apply .agent defaults settings with
  | .ok config => complete config
  | .error message => throw <| .input message

end Alaya.Agents.Catalog
