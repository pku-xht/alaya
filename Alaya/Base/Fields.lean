import Lean.Data.Json

/-! A record as JSON, each field described once: its key, how its value is written, and how it
is read. From the description come the record's JSON and its reading: an object whose keys are
all known, a typo being an error and not a setting silently ignored, and whose fields may be
left out, each then keeping the value it had. A configuration is read over its defaults. -/

namespace Alaya.Base

open Lean (Json)

/-- How a value is written as JSON, and read back. A reading that fails says what the value
must be, as in "must be true or false, not 3". -/
structure Codec (α : Type) where
  write : α → Json
  read : Json → Except String α

namespace Codec

def nat : Codec Nat where
  write n := n
  read json := json.getNat?.mapError fun _ => s!"must be a non-negative integer, not {json.compress}"

def bool : Codec Bool where
  write b := b
  read
    | .bool b => pure b
    | other => throw s!"must be true or false, not {other.compress}"

def string : Codec String where
  write s := s
  read
    | .str s => pure s
    | other => throw s!"must be a string, not {other.compress}"

/-- Any JSON object, as it is. -/
def object : Codec Json where
  write json := json
  read
    | json@(.obj _) => pure json
    | other => throw s!"must be an object, not {other.compress}"

/-- An array of `[name, value]` string pairs. -/
def pairs : Codec (Array (String × String)) where
  write items := .arr (items.map fun (name, value) => .arr #[.str name, .str value])
  read
    | .arr items => items.mapM fun
      | .arr #[.str name, .str value] => pure (name, value)
      | other => throw s!"must be [name, value] pairs of strings, not {other.compress}"
    | other => throw s!"must be an array of [name, value] pairs, not {other.compress}"

/-- One of `values`, by its `name`. -/
def enum (name : α → String) (values : List α) : Codec α where
  write value := name value
  read json :=
    let must := s!"must be {" or ".intercalate (values.map name)}"
    match json with
    | .str given => match values.find? (name · == given) with
      | some value => pure value
      | none => throw s!"{must}, not {given}"
    | other => throw s!"{must}, not {other.compress}"

/-- An array of values. -/
def array (codec : Codec α) : Codec (Array α) where
  write items := .arr (items.map codec.write)
  read
    | .arr items => items.mapM codec.read
    | other => throw s!"must be an array, not {other.compress}"

/-- A value, or `null` for none. -/
def option (codec : Codec α) : Codec (Option α) where
  write
    | some value => codec.write value
    | none => .null
  read
    | .null => pure none
    | json => some <$> codec.read json

end Codec

/-- A field of a record `σ`: its key, how it is written, and how its JSON is read into a record
over the value it has, so a field read alone changes only itself. -/
structure Field (σ : Type) where
  key : String
  write : σ → Json
  read : Json → σ → Except String σ

/-- A record's fields, in order. -/
abbrev Fields (σ : Type) := Array (Field σ)

/-- A field of `codec`'s values, which `get` reads off a record and `set` puts in one. -/
def Field.of (key : String) (codec : Codec α) (get : σ → α) (set : α → σ → σ) : Field σ where
  key
  write := codec.write ∘ get
  read json value := match codec.read json with
    | .ok field => pure (set field value)
    | .error problem => throw s!"'{key}' {problem}"

namespace Fields

/-- The record as a JSON object: every field. -/
def toJson (fields : Fields σ) (value : σ) : Json :=
  .mkObj (fields.toList.map fun field => (field.key, field.write value))

/-- `json`, an object, read over `value`: each of its keys is a field's, and each field it has
is read in turn; one it leaves out keeps the value it had. -/
def read (fields : Fields σ) (json : Json) (value : σ) : Except String σ := do
  let .obj kvs := json | throw s!"expected an object, got {json.compress}"
  let keys := fields.map (·.key)
  for key in kvs.foldl (init := #[]) fun keys key _ => keys.push key do
    if !keys.contains key then
      throw s!"unknown field '{key}' (the fields are {", ".intercalate keys.toList})"
  fields.foldlM (init := value) fun value field =>
    match json.getObjVal? field.key with
    | .ok field' => field.read field' value
    | .error _ => pure value

/-- The fields of a part of a record, which `get` reads off it and `set` puts in it: the fields
of a configuration another extends. -/
def lift (fields : Fields α) (get : σ → α) (set : α → σ → σ) : Fields σ :=
  fields.map fun field => {
    key := field.key
    write := field.write ∘ get
    read := fun json value => do pure (set (← field.read json (get value)) value) }

end Fields

/-- A field that is a record of its own, read over the value it has: the fields it leaves out
keep theirs. -/
def Field.record (key : String) (fields : Fields α) (get : σ → α) (set : α → σ → σ) : Field σ where
  key
  write := fields.toJson ∘ get
  read json value := match fields.read json (get value) with
    | .ok field => pure (set field value)
    | .error problem => throw s!"'{key}': {problem}"

end Alaya.Base
