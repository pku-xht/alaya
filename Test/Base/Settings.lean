import Test.Support.Framework
import Alaya.Base.Settings
import Alaya.Base.Fields

/-! Settings from the command line, and the strict reading of a record described by its fields: a
setting replaces exactly one key at its path, and a record names no key it does not know. -/

namespace SettingsTests

open Testing Alaya.Base
open Lean (Json)

private def parsed (text : String) : TestM Settings.Setting :=
  match Settings.parse text with
  | .ok setting => pure setting
  | .error problem => fail s!"{text}: {problem}"

private def json (text : String) : Json := (Json.parse text).toOption.getD .null

/-- A record to read and write. -/
private structure Sample where
  count : Nat := 0
  on : Bool := false
  name : String := ""
  env : Array (String × String) := #[("PAGER", "cat")]

def suite : Suite := Testing.suite "base/settings" #[
  test "a value is JSON when it parses, and text otherwise, and only the first = splits it" do
    for (text, path, value) in [("a.b=1", ["a", "b"], Json.num 1), ("x=true", ["x"], .bool true),
        ("x=hello", ["x"], .str "hello"), ("x=a=b", ["x"], .str "a=b"), ("x=", ["x"], .str ""),
        ("x={\"k\":[1]}", ["x"], json "{\"k\":[1]}"),
        -- A number is a number, even for a field that takes text: what reads the field says so.
        ("name=123", ["name"], .num 123)] do
      let setting ← parsed text
      assertEqual text (setting.path, setting.value.compress) (path, value.compress)
    assertEqual "it renders as it was written" (← parsed "a.b=1").render "a.b=1"
    for bad in ["noequals", "=v", "a..b=1", ".a=1", "a.=1"] do
      check ((Settings.parse bad).toOption.isNone) s!"{bad} is no setting",

  test "a setting replaces one key at its path, making the objects on the way, and no more" do
    let apply (config : String) (text : String) : TestM String := do
      match Settings.apply (json config) (← parsed text) with
      | .ok updated => pure updated.compress
      | .error problem => fail problem
    assertEqual "deep, from nothing" (← apply "{}" "a.b.c=1") "{\"a\":{\"b\":{\"c\":1}}}"
    assertEqual "one key, the others kept" (← apply "{\"m\":{\"x\":1,\"y\":2}}" "m.x=3") "{\"m\":{\"x\":3,\"y\":2}}"
    assertEqual "an object replaces, never merges" (← apply "{\"m\":{\"x\":1,\"y\":2}}" "m={\"x\":3}") "{\"m\":{\"x\":3}}"
    match Settings.apply (json "{\"a\":1}") (← parsed "a.b=2") with
    | .ok _ => fail "a key inside a number was set"
    | .error message => assertContains "says where" message "--set a.b: b is inside something that is not an object",

  test "a record names only keys it knows, each field has the type it takes, and one left out keeps its value" do
    let fields : Fields Sample := #[
      .of "count" .nat (·.count) fun v r => { r with count := v },
      .of "on" .bool (·.on) fun v r => { r with on := v },
      .of "name" .string (·.name) fun v r => { r with name := v },
      .of "env" .pairs (·.env) fun v r => { r with env := v }]
    let read (text : String) := fields.read (json text) {}
    match read "{\"cuont\":1}" with
    | .ok _ => fail "a typo was taken"
    | .error message => assertContains "a typo" message "unknown field 'cuont' (the fields are count, on, name, env)"
    check ((read "[1]").toOption.isNone) "not an object"
    let some sample := (read "{\"count\":3,\"on\":true,\"name\":\"x\"}").toOption | fail "a valid object"
    assertEqual "fields" (sample.count, sample.on, sample.name, sample.env) (3, true, "x", #[("PAGER", "cat")])
    assertEqual "written back" (fields.toJson sample).compress
      "{\"count\":3,\"env\":[[\"PAGER\",\"cat\"]],\"name\":\"x\",\"on\":true}"
    for (label, text, says) in [("a negative count", "{\"count\":-1}", "'count' must be a non-negative integer"),
        ("a fraction", "{\"count\":1.5}", "'count' must be a non-negative integer"),
        ("a count as text", "{\"count\":\"3\"}", "'count' must be a non-negative integer"),
        ("true as text", "{\"on\":\"true\"}", "'on' must be true or false"),
        ("a number for text", "{\"name\":3}", "'name' must be a string")] do
      match read text with
      | .ok _ => fail s!"{label} was taken"
      | .error message => assertContains label message says
    assertEqual "pairs" ((read "{\"env\":[[\"A\",\"1\"]]}").toOption.map (·.env)) (some #[("A", "1")])
    for bad in ["{}", "[[\"A\"]]", "[[\"A\",1]]", "[\"A=1\"]"] do
      check ((read ("{\"env\":" ++ bad ++ "}")).toOption.isNone) s!"{bad} is no list of pairs"
    let enum : Codec Bool := .enum (if · then "yes" else "no") [true, false]
    assertEqual "one of its names" ((enum.read "no").toOption) (some false)
    assertEqual "another" (match enum.read "maybe" with | .error m => m | .ok _ => "") "must be yes or no, not maybe"
]

end SettingsTests
