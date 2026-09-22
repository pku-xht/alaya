import Lean.Data.Json

/-! Reading an agent's configuration from JSON: an object whose keys are all known — a typo is
an error, not a silently ignored setting — and whose fields may be left out for their
defaults. -/

namespace Alaya.Agent.ConfigJson

structure Object where
  fields : Array (String × Lean.Json)

/-- `json` as an object with no key outside `known`. -/
def object (json : Lean.Json) (known : Array String) : Except String Object := do
  let .obj kvs := json | throw s!"expected an object, got {json.compress}"
  let fields := kvs.foldl (init := #[]) fun acc key value => acc.push (key, value)
  for (key, _) in fields do
    if !known.contains key then
      throw s!"unknown field '{key}' (the fields are {", ".intercalate known.toList})"
  pure { fields }

def Object.field? (object : Object) (key : String) : Except String (Option Lean.Json) :=
  pure (object.fields.findSome? fun (k, v) => if k == key then some v else none)

def Object.nat (object : Object) (key : String) (default : Nat) : Except String Nat := do
  match ← object.field? key with
  | none => pure default
  | some value =>
    match value.getNat? with
    | .ok n => pure n
    | .error _ => throw s!"'{key}' must be a non-negative integer, not {value.compress}"

def Object.bool (object : Object) (key : String) (default : Bool) : Except String Bool := do
  match ← object.field? key with
  | none => pure default
  | some (.bool b) => pure b
  | some other => throw s!"'{key}' must be true or false, not {other.compress}"

def Object.string (object : Object) (key : String) (default : String) : Except String String := do
  match ← object.field? key with
  | none => pure default
  | some (.str s) => pure s
  | some other => throw s!"'{key}' must be a string, not {other.compress}"

/-- An array of `[name, value]` string pairs. -/
def pairs (json : Lean.Json) : Except String (Array (String × String)) := do
  let .arr items := json | throw s!"expected an array of [name, value] pairs, got {json.compress}"
  items.mapM fun
    | .arr #[.str name, .str value] => pure (name, value)
    | other => throw s!"expected a [name, value] pair of strings, got {other.compress}"

end Alaya.Agent.ConfigJson
