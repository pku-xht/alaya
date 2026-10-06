import Test.Support.Framework
import Test.Support.DirectoryWorkspaces
import Test.Support.Container
import Test.Support.Scripted
import Alaya

/-! Command-line parsing: the spec of a command, and the settings `call` reads. -/

namespace CliTests

open Testing
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App

private def parsed (label : String) (result : Except (Array String) α) : TestM α :=
  match result with
  | .ok a => pure a
  | .error problems => fail s!"{label}: {problems}"

private def problemsOf (label : String) (result : Except (Array String) α) : TestM (Array String) :=
  match result with
  | .ok _ => fail s!"{label}: parsed, but should have been refused"
  | .error problems => pure problems

/-- `--set` and `--set-file`, as `call` reads them. -/
private def givenSpec : Cli.Spec (Array Settings.Given) :=
  Cli.interleaved #[
    ("set", ⟨"PATH=VALUE", fun text => Settings.Given.value <$> Settings.parse text⟩, ""),
    ("set-file", ⟨"PATH=FILE", Settings.parseFile⟩, "")]

/-- The settings of `argv`, files read. -/
private def given (argv : List String) : TestM (Result (Array Settings.Setting)) := do
  let given ← parsed "settings" (givenSpec.parse argv)
  pure (given.mapM (·.read))

/-- The task of `argv`'s one setting. -/
private def task (argv : List String) : TestM (Result String) := do
  pure <| (← given argv).map fun settings => match (settings[0]?.map (·.value) : Option Lean.Json) with
    | some (.str text) => text
    | _ => ""

def taskSuite : Suite := suite "app/cli.task" #[
  test "a task file's middle reaches the first serialized model request as it is" do
    let path := (← scratch) / "MINIVERO_TASK.md"
    let contents := String.ofList (List.replicate 6500 '界') ++
      "\nDONE: implement every API and prove every fixed specification.\n" ++
      String.ofList (List.replicate 6500 '🦉') ++ "\n"
    IO.FS.writeFile path contents
    let task ← assertOk (← task ["--set-file", s!"task={path}"])
    assertEqual "verbatim, trailing newline included" task contents
    -- What each agent asks first, given the task as the notice it waits for.
    for (name, agent) in [("mini-swe", Lean.Json.mkObj []), ("mini-vero", .mkObj [("mode", "proof")]),
        ("mini-vero", .mkObj [("mode", "codeproof")])] do
      let request? : Option Chat.Request := match Scripted.runOfConfig name agent with
        | .ok run => match next run (Scripted.settle run (Scripted.opening task)) with
          | .ask { op := .sample _ request, .. } => some request
          | _ => none
        | .error _ => none
      let some request := request? | fail s!"{agent.compress} does not sample first"
      let json := request.toJson .native
      let .ok messages := json.getObjValAs? (Array Lean.Json) "messages"
        | fail "serialized request is missing messages"
      let .ok content := messages[1]!.getObjValAs? String "content"
        | fail "serialized request is missing initial task"
      check ((content.splitOn contents).length == 2) "the whole file must occur once in the first model input",

  test "a field is set to a file's text, in order with --set, and the file must be readable UTF-8" do
    let configuration (label : String) (result : Result String) (expected : String -> Bool) : TestM Unit :=
      assertError label result fun
        | .input m => expected m
        | _ => false
    assertEqual "text" (← assertOk (← task ["--set", "task=fix it"])) "fix it"
    let path := (← scratch) / "task.md"
    IO.FS.writeFile path "from the file"
    let settings ← assertOk (← given ["--set", "task=first", "--set-file", s!"task={path}", "--set", "mode=proof"])
    assertEqual "in the order given, across the two flags" (settings.map (·.render))
      #["task=\"first\"", "task=\"from the file\"", "mode=\"proof\""]
    let refused (label : String) (argv : List String) : TestM (Array String) :=
      problemsOf label (givenSpec.parse argv)
    check ((← refused "no path" ["--set-file", "TASK.md"])[0]!.endsWith "expects PATH=FILE, got 'TASK.md'") "no path"
    check ((← refused "missing" ["--set-file"])[0]!.startsWith "--set-file needs a value") "missing value"
    let missing := (← scratch) / "missing"
    configuration "missing file" (← task ["--set-file", s!"task={missing}"]) (·.startsWith "--set-file task: cannot read")
    IO.FS.writeBinFile missing ⟨#[255, 254]⟩
    configuration "invalid UTF-8" (← task ["--set-file", s!"task={missing}"]) (·.endsWith "is not valid UTF-8")
]



private def view : Cli.Spec (Bool × String) :=
  Prod.mk <$> Cli.switch "view" "show the view" <*> Cli.arg "ENTRY" .string "the entry"

private def sample : Cli.Command where
  name := "sample"
  summary := "A command for the tests."
  examples := #["alaya sample abc --count 3"]
  spec := (fun (_ : String × Nat × Option String) (_ : Cli.Out) => (pure 0 : Result UInt32))
    <$> (Prod.mk <$> Cli.arg "ENTRY" .string "the entry"
      <*> (Prod.mk <$> Cli.flag "count" .nat "how many" <*> Cli.flag? "note" .string "a note"))

private def app : Cli.App := { name := "alaya", summary := "Tests.", commands := #[sample] }

def specSuite : Suite := suite "app/cli.spec" #[
  test "a switch never takes the next token, wherever it stands" do
    assertEqual "before" (← parsed "before" (view.parse ["--view", "abc"])) (true, "abc")
    assertEqual "after" (← parsed "after" (view.parse ["abc", "--view"])) (true, "abc")
    assertEqual "absent" (← parsed "absent" (view.parse ["abc"])) (false, "abc")
    assertEqual "no value" (← problemsOf "value" (view.parse ["abc", "--view=yes"]))
      #["--view is a switch and takes no value"],

  test "a valued flag takes the next token or its value after =" do
    let note := Cli.flag? "note" .string "a note"
    assertEqual "next" (← parsed "next" (note.parse ["--note", "x y"])) (some "x y")
    assertEqual "equals" (← parsed "equals" (note.parse ["--note=--x"])) (some "--x")
    assertEqual "equals twice" (← parsed "equals twice" (note.parse ["--note=a=b"])) (some "a=b")
    assertEqual "dash" (← parsed "dash" (note.parse ["--note", "-"])) (some "-")
    assertEqual "absent" (← parsed "absent" (note.parse [])) none
    for argv in [["--note", "--x"], ["--note"], ["--note="], ["--note", ""]] do
      let problems ← problemsOf s!"{argv}" (note.parse argv)
      check ((problems[0]?.getD "").startsWith "--note needs a value") s!"{argv}: {problems}",

  test "an unknown option is refused with the nearest name, and a typo keeps its value" do
    let temperature := Cli.flagD "temperature" .float 0.0 "the temperature"
    assertEqual "typo" (← problemsOf "typo" (temperature.parse ["--temprature", "0.7"]))
      #["unknown option --temprature (did you mean --temperature?)"]
    assertEqual "far" (← problemsOf "far" (temperature.parse ["--zzz"])) #["unknown option --zzz"]
    assertEqual "short" (← problemsOf "short" (temperature.parse ["-m", "x"]))
      #["unknown option -m (an argument that begins with - goes after --)", "unexpected argument 'x'"]
    assertEqual "typed" (← parsed "typed" (temperature.parse ["--temperature", "0.25"])) 0.25
    assertEqual "default" (← parsed "default" (temperature.parse [])) 0.0
    assertEqual "not a number" (← problemsOf "nan" (temperature.parse ["--temperature", "warm"]))
      #["--temperature expects a number, got 'warm'"],

  test "a flag given twice is refused unless it is declared repeatable" do
    assertEqual "twice" (← problemsOf "twice" ((Cli.flag? "model" .string "").parse ["--model", "a", "--model", "b"]))
      #["--model is given more than once"]
    assertEqual "repeated" (← parsed "repeated" ((Cli.repeated "hide" .string "").parse ["--hide", "a", "--hide=b"]))
      #["a", "b"],

  test "positionals are matched in order, and a missing or extra one is refused" do
    let two := Prod.mk <$> Cli.arg "A" .string "the first" <*> Cli.arg? "B" .string "the second"
    assertEqual "missing" (← problemsOf "missing" (two.parse [])) #["missing A: the first"]
    assertEqual "one" (← parsed "one" (two.parse ["a"])) ("a", none)
    assertEqual "two" (← parsed "two" (two.parse ["a", "b"])) ("a", some "b")
    assertEqual "extra" (← problemsOf "extra" (two.parse ["a", "b", "c"])) #["unexpected argument 'c'"],

  test "after -- everything is positional, empty strings and flag-like tokens included" do
    let reply := Prod.mk <$> Cli.arg "ENTRY" .string "" <*> Cli.arg "TEXT" .string ""
    for answer in ["", "--data", "-m", "--", "--json", "  answer\n--data other\n原文  "] do
      assertEqual s!"answer {answer}" (← parsed "reply" (reply.parse ["--", "q", answer])) ("q", answer),

  test "a refined spec checks the whole value, after every item has parsed" do
    let answer := (Prod.mk <$> Cli.arg? "TEXT" .string "" <*> Cli.switch "unavailable" "").refine
      fun
      | (some text, false) => .ok (some text)
      | (none, true) => .ok none
      | _ => .error "give the answer or --unavailable"
    assertEqual "text" (← parsed "text" (answer.parse ["yes"])) (some "yes")
    assertEqual "unavailable" (← parsed "unavailable" (answer.parse ["--unavailable"])) none
    assertEqual "both" (← problemsOf "both" (answer.parse ["yes", "--unavailable"]))
      #["give the answer or --unavailable"]
    assertEqual "neither" (← problemsOf "neither" (answer.parse [])) #["give the answer or --unavailable"],

  test "every failure has a class, and each class one exit status above every outcome" do
    let cases : List (Error × String × UInt32) := [
      (.input "no entry matches x", "input", 65), (.environment "cannot run docker", "environment", 69),
      (.transport "timed out", "transient", 75), (.http 429 "slow down" (some 30000), "transient", 75),
      (.http 503 "down", "transient", 75), (.http 400 "bad request", "model", 76),
      (.http 401 "no key", "model", 76), (.protocol "not JSON", "model", 76),
      (.structuredOutput "no field", "model", 76), (.provider "refused", "model", 76),
      (.cache "unreadable", "storage", 74), (.storage "disk full", "storage", 74)]
    for (error, name, code) in cases do
      assertEqual s!"{error.describe} class" error.class.toString name
      assertEqual s!"{error.describe} exit" (Cli.exitFor error.class) code
      check (Cli.exitFor error.class > 4) "above every outcome status"
    assertEqual "usage" Cli.exitUsage 64
    assertEqual "an http failure's JSON" (Cli.errorJson (.http 429 "slow down" (some 30000))).compress
      "{\"error\":\"transient\",\"message\":\"http 429: slow down\",\"retry_after_ms\":30000,\"status\":429}"
    assertEqual "an input failure's JSON" (Cli.errorJson (.input "no entry matches x")).compress
      "{\"error\":\"input\",\"message\":\"no entry matches x\"}",

  test "every problem is reported at once" do
    let spec := Prod.mk <$> Cli.flag "count" .nat "how many" <*> Cli.flag "model" (.string "P:M") "the model"
    assertEqual "both" (← problemsOf "both" (spec.parse ["--count", "x"]))
      #["--count expects a whole number, got 'x'", "--model P:M is required: the model"],

  test "an environment variable fills an absent flag, and a flag wins over it" do
    let data := Cli.flagD "data" (.path "DIR") "runs" "the data directory" (env? := some "ALAYA_DATA")
    let env := fun var => if var == "ALAYA_DATA" then some "/runs" else none
    assertEqual "default" (← parsed "default" (data.parse [])) "runs"
    assertEqual "env" (← parsed "env" (data.parse [] env)) "/runs"
    assertEqual "flag" (← parsed "flag" (data.parse ["--data", "d"] env)) "d",

  test "a declaration mistake is found before anything runs" do
    let twice := Prod.mk <$> Cli.switch "json" "" <*> Cli.switch "json" ""
    assertEqual "twice" twice.check #["--json is declared twice"]
    let order := Prod.mk <$> Cli.arg? "A" .string "" <*> Cli.arg "B" .string ""
    assertEqual "order" order.check #["B is required but follows an optional argument"]
    let groups := Prod.mk <$> Provider.endpointCli <*> Executor.Docker.RunOptions.cli
    assertEqual "the shared groups are disjoint" groups.check #[],

  test "a command takes --json and --help, and says what it accepts" do
    let .ok (_, json) := sample.parse ["abc", "--count", "3", "--json"]
      | fail "sample did not parse"
    check json "--json is seen"
    assertEqual "usage" (sample.usage app) "alaya sample ENTRY --count N [OPTIONS]"
    let help := sample.help app
    for line in ["usage: alaya sample ENTRY --count N [OPTIONS]", "  --count N    how many (required)",
        "  --note TEXT  a note", "  alaya sample abc --count 3"] do
      check ((help.splitOn line).length > 1) s!"help lacks '{line}':\n{help}"
    let .ok commands := app.describe.getObjValAs? (Array Lean.Json) "commands" | fail "no commands"
    let .ok items := commands[0]!.getObjValAs? (Array Lean.Json) "items" | fail "no items"
    let names := items.filterMap fun i => (i.getObjValAs? String "name").toOption
    assertEqual "described" names #["ENTRY", "count", "note", "json", "help"]
]

def suites : Array Suite := #[taskSuite, specSuite]

end CliTests
