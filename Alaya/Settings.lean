import Lean.Data.Json

/-!
Overrides from the command line. `--set PATH=VALUE` names what it changes — `agent.` or
`model.` — and a path into it; the value is read as JSON when it parses, and as a string
otherwise. A setting replaces exactly one key of a complete configuration, with no deep
merging, and the result is then checked as a whole by what reads it.
-/

namespace Alaya.Settings

/-- What a setting changes. -/
inductive Target where
  | agent
  | model
  deriving BEq, Repr, Inhabited

/-- One `--set`: what it changes, the path within it, and the value. -/
structure Setting where
  target : Target
  path : List String
  value : Lean.Json
  deriving Inhabited

/-- Reads `agent.PATH=VALUE` or `model.PATH=VALUE`. -/
def parse (text : String) : Except String Setting := do
  let path :: value :: rest := text.splitOn "=" | throw s!"expects agent.PATH=VALUE or model.PATH=VALUE, got '{text}'"
  let value := "=".intercalate (value :: rest)
  let (target, keys) ← match path.splitOn "." with
    | "agent" :: keys@(_ :: _) => pure (Target.agent, keys)
    | "model" :: keys@(_ :: _) => pure (Target.model, keys)
    | _ => throw s!"sets agent.FIELD or model.FIELD, not '{path}'"
  if keys.any (·.isEmpty) then throw s!"has an empty key in '{path}'"
  pure { target, path := keys, value := (Lean.Json.parse value).toOption.getD (.str value) }

/-- `json` with the value at `path` replaced by `value`, creating the objects on the way. -/
def setAt (json : Lean.Json) (path : List String) (value : Lean.Json) : Except String Lean.Json :=
  match path with
  | [] => pure value
  | key :: rest => do
    let .obj _ := json | throw s!"{key} is inside something that is not an object"
    let inner := (json.getObjVal? key).toOption.getD (.mkObj [])
    pure (json.setObjVal! key (← setAt inner rest value))

/-- `json` with each setting for `target` applied in order. The name is not a setting: it is
what `--agent NAME` or `--model NAME` chose. -/
def apply (target : Target) (json : Lean.Json) (settings : Array Setting) : Except String Lean.Json := do
  let prefix_ := match target with | .agent => "agent" | .model => "model"
  let mut json := json
  for setting in settings do
    if setting.target != target then continue
    if setting.path == ["name"] then throw s!"the {prefix_}'s name is --{prefix_} NAME, not a --set"
    match setAt json setting.path setting.value with
    | .ok updated => json := updated
    | .error message => throw s!"--set {prefix_}.{".".intercalate setting.path}: {message}"
  pure json

end Alaya.Settings
