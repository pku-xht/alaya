import Lean.Data.Json
import Alaya.Base.Error

/-!
Overrides from the command line. `--set PATH=VALUE` names a field of a program's configuration
by its path, `context_reserve` or `model.params.reasoning_effort`; the value is read as JSON
when it parses, and as a string otherwise. `--set-file PATH=FILE` sets the field to the text of
a file, as it is, such as an agent's task. A setting replaces exactly one key, with no deep
merging, and the result is then checked as a whole by what reads it.
-/

namespace Alaya.Base.Settings

/-- One `--set`: the path of the field, and its value. -/
structure Setting where
  path : List String
  value : Lean.Json
  deriving Inhabited

/-- The setting as it was written: `PATH=VALUE`. -/
def Setting.render (setting : Setting) : String :=
  s!"{".".intercalate setting.path}={setting.value.compress}"

/-- Splits `PATH=REST` into the keys of the path and the rest. -/
private def split (text : String) (form : String) : Except String (List String × String) := do
  let path :: value :: rest := text.splitOn "=" | throw s!"expects {form}, got '{text}'"
  let keys := path.splitOn "."
  if keys.any (·.isEmpty) then throw s!"has an empty key in '{path}'"
  pure (keys, "=".intercalate (value :: rest))

/-- Reads `PATH=VALUE`. -/
def parse (text : String) : Except String Setting := do
  let (path, value) ← split text "PATH=VALUE"
  pure { path, value := (Lean.Json.parse value).toOption.getD (.str value) }

/-- A setting as the command line gives it: its value, or the file whose text it is, which is
read when the command runs, so parsing stays pure. -/
inductive Given where
  | value (setting : Setting)
  | file (path : List String) (source : System.FilePath)
  deriving Inhabited

/-- Reads `PATH=FILE`. -/
def parseFile (text : String) : Except String Given := do
  let (path, file) ← split text "PATH=FILE"
  pure (.file path file)

/-- The setting: a file is read on the host, as it is, and must be UTF-8. Stdin is the file
`/dev/stdin`. -/
def Given.read : Given → Alaya.Base.Result Setting
  | .value setting => pure setting
  | .file path source => do
    let bytes ← match ← (Alaya.Base.Result.fromIO Alaya.Base.Error.input (IO.FS.readBinFile source)).toBaseIO with
      | .ok bytes => pure bytes
      | .error _ => throw <| .input s!"--set-file {".".intercalate path}: cannot read {source}"
    match String.fromUTF8? bytes with
    | some text => pure { path, value := .str text }
    | none => throw <| .input s!"--set-file {".".intercalate path}: {source} is not valid UTF-8"

/-- `json` with the value at `path` replaced by `value`, creating the objects on the way. -/
def setAt (json : Lean.Json) (path : List String) (value : Lean.Json) : Except String Lean.Json :=
  match path with
  | [] => pure value
  | key :: rest => do
    let .obj _ := json | throw s!"{key} is inside something that is not an object"
    let inner := (json.getObjVal? key).toOption.getD (.mkObj [])
    pure (json.setObjVal! key (← setAt inner rest value))

/-- `json` with one setting applied. -/
def apply (json : Lean.Json) (setting : Setting) : Except String Lean.Json := do
  match setAt json setting.path setting.value with
  | .ok updated => pure updated
  | .error message => throw s!"--set {".".intercalate setting.path}: {message}"

end Alaya.Base.Settings
