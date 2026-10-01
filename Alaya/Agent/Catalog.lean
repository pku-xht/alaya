import Alaya.Agent.MiniSwe
import Alaya.Agent.MiniVero
import Alaya.Settings

/-!
The agents the command line can run, by name, and how a run's agent is configured.

An agent's defaults are in code, in its definition. A run names an agent (`root --agent NAME`)
and overrides any of its fields on the command line (`--set agent.FIELD=VALUE`), and the root
records the complete configuration — the agent's `name` and every field — from which every
later command builds the same agent again. There are no configuration files.
-/

namespace Alaya.Agent.Catalog

open Alaya (Result Error)
open Alaya.Agent (Agent)

/-- An agent the command line can name, and how a configuration builds it. -/
structure Definition where
  name : String
  /-- The agent a configuration describes, for a run of a model: one that names this agent, with
  any of its fields left out for their defaults. -/
  make : Lean.Json -> Models.Spec -> Except String Agent

def miniSwe : Definition := {
  name := "mini-swe"
  make := fun json model => do pure (MiniSwe.agent (← MiniSwe.Config.fromJson json) model) }

def miniVero : Definition := {
  name := "mini-vero"
  make := fun json model => do pure (MiniVero.agent (← MiniVero.Config.fromJson json) model) }

def all : Array Definition := #[miniSwe, miniVero]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The agent a configuration describes, for a run of `model`, or what is wrong with it. A
configuration checked for no run leaves `model` out; its agent knows no context size. -/
def fromJson (json : Lean.Json) (model : Models.Spec := default) : Result Agent := do
  let name ← match json.getObjVal? "name" with
    | .ok (.str name) => pure name
    | _ => throw <| .input s!"an agent configuration needs a \"name\": one of {names}"
  let some definition := named? name
    | throw <| .input s!"unknown agent: {name} (use {names})"
  match definition.make json model with
  | .ok agent => pure agent
  | .error message => throw <| .input s!"{name}: {message}"

/-- The agent `name` with the agent's settings applied over its complete defaults. Every key is
checked as a configuration's would be: an unknown one, or a value of the wrong type, is an error
naming it. -/
def resolve (name : String) (settings : Array Settings.Setting) (model : Models.Spec := default) :
    Result Agent := do
  let defaults ← fromJson (.mkObj [("name", name)])
  match Settings.apply .agent defaults.config settings with
  | .ok config => fromJson config model
  | .error message => throw <| .input message

end Alaya.Agent.Catalog
