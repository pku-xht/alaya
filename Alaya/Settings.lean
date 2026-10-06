import Lean.Data.Json

/-!
Overrides from the command line. `--set PATH=VALUE` names a field of a program's configuration
by its path, `context_reserve` or `model.params.reasoning_effort`; the value is read as JSON
when it parses, and as a string otherwise. A setting replaces exactly one key, with no deep
merging, and the result is then checked as a whole by what reads it.
-/

namespace Alaya.Settings

/-- One `--set`: the path of the field, and its value. -/
structure Setting where
  path : List String
  value : Lean.Json
  deriving Inhabited

/-- The setting as it was written: `PATH=VALUE`. -/
def Setting.render (setting : Setting) : String :=
  s!"{".".intercalate setting.path}={setting.value.compress}"

/-- Reads `PATH=VALUE`. -/
def parse (text : String) : Except String Setting := do
  let path :: value :: rest := text.splitOn "=" | throw s!"expects PATH=VALUE, got '{text}'"
  let value := "=".intercalate (value :: rest)
  let keys := path.splitOn "."
  if keys.any (·.isEmpty) then throw s!"has an empty key in '{path}'"
  pure { path := keys, value := (Lean.Json.parse value).toOption.getD (.str value) }

/-- `json` with the value at `path` replaced by `value`, creating the objects on the way. -/
def setAt (json : Lean.Json) (path : List String) (value : Lean.Json) : Except String Lean.Json :=
  match path with
  | [] => pure value
  | key :: rest => do
    let .obj _ := json | throw s!"{key} is inside something that is not an object"
    let inner := (json.getObjVal? key).toOption.getD (.mkObj [])
    pure (json.setObjVal! key (← setAt inner rest value))

/-- `json` with one setting applied. The name is not a setting: it is what the call names. -/
def apply (json : Lean.Json) (setting : Setting) : Except String Lean.Json := do
  if setting.path == ["name"] then throw "the program's name is PROGRAM, not a --set"
  match setAt json setting.path setting.value with
  | .ok updated => pure updated
  | .error message => throw s!"--set {".".intercalate setting.path}: {message}"

end Alaya.Settings
