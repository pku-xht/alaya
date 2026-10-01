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

open Alaya (Result Error)
open Alaya.Agent (Agent)

structure Family where
  name : String
  make : Lean.Json -> Except String Agent

def miniSwe : Family := {
  name := "mini-swe"
  make := fun json => do pure (MiniSwe.agent (← MiniSwe.Config.fromJson json)) }

def miniVero : Family := {
  name := "mini-vero"
  make := fun json => do pure (MiniVero.agent (← MiniVero.Config.fromJson json)) }

def all : Array Family := #[miniSwe, miniVero]

def names : String := ", ".intercalate (all.map (·.name)).toList

def family? (name : String) : Option Family := all.find? (·.name == name)

/-- The agent a configuration names, or what is wrong with the configuration. -/
def fromJson (json : Lean.Json) : Result Agent := do
  let name ← match json.getObjVal? "family" with
    | .ok (.str name) => pure name
    | _ => throw <| .input s!"an agent configuration needs a \"family\": one of {names}"
  let some family := family? name
    | throw <| .input s!"unknown agent family: {name} (use {names})"
  match family.make json with
  | .ok built => pure built
  | .error message => throw <| .input s!"{name} configuration: {message}"

/-- The agent a configuration file names. -/
def fromFile (path : System.FilePath) : Result Agent := do
  let text ← match ← (Result.fromIO Error.input (IO.FS.readFile path)).toBaseIO with
    | .ok text => pure text
    | .error _ => throw <| .input s!"cannot read the agent configuration {path}"
  match Lean.Json.parse text with
  | .ok json => fromJson json
  | .error message => throw <| .input s!"{path} is not JSON: {message}"

end Alaya.Agent.Families
