import Test.Support.Framework
import Alaya.Base.Settings
import Alaya.Base.ConfigJson

/-! Settings from the command line, and the strict reading of a configuration object: a setting
replaces exactly one key at its path, and a configuration names no key it does not know. -/

namespace SettingsTests

open Testing Alaya.Base
open Lean (Json)

private def parsed (text : String) : TestM Settings.Setting :=
  match Settings.parse text with
  | .ok setting => pure setting
  | .error problem => fail s!"{text}: {problem}"

private def json (text : String) : Json := (Json.parse text).toOption.getD .null

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

  test "a configuration object names only keys it knows, and each field has the type it takes" do
    let known := #["count", "on", "name", "env"]
    match ConfigJson.object (json "{\"cuont\":1}") known with
    | .ok _ => fail "a typo was taken"
    | .error message => assertContains "a typo" message "unknown field 'cuont' (the fields are count, on, name, env)"
    check ((ConfigJson.object (json "[1]") known).toOption.isNone) "not an object"
    let some object := (ConfigJson.object (json "{\"count\":3,\"on\":true,\"name\":\"x\"}") known).toOption
      | fail "a valid object"
    assertEqual "fields" ((object.nat "count" 0).toOption, (object.bool "on" false).toOption,
      (object.string "name" "").toOption, (object.nat "missing" 7).toOption) (some 3, some true, some "x", some 7)
    for (label, text, field) in [("a negative count", "{\"count\":-1}", "count"), ("a fraction", "{\"count\":1.5}", "count"),
        ("a count as text", "{\"count\":\"3\"}", "count")] do
      let some object := (ConfigJson.object (json text) known).toOption | fail label
      check ((object.nat field 0).toOption.isNone) label
    let some object := (ConfigJson.object (json "{\"on\":\"true\",\"name\":3}") known).toOption | fail "an object"
    check ((object.bool "on" false).toOption.isNone) "true as text is no bool"
    check ((object.string "name" "").toOption.isNone) "a number is no string"
    assertEqual "pairs" (ConfigJson.pairs (json "[[\"A\",\"1\"]]")).toOption (some #[("A", "1")])
    for bad in ["{}", "[[\"A\"]]", "[[\"A\",1]]", "[\"A=1\"]"] do
      check ((ConfigJson.pairs (json bad)).toOption.isNone) s!"{bad} is no list of pairs"
]

end SettingsTests
