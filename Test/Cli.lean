import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! Command-line parsing and the DGX Spark endpoint syntax. -/

namespace CliTests

open Testing
open Alaya

private def endpoint (url : String) : Option Provider.Dgx.Endpoint :=
  (Provider.Dgx.Endpoint.ofUrl url).toOption

private def parsed (label : String) (result : Except (Array String) α) : TestM α :=
  match result with
  | .ok a => pure a
  | .error problems => fail s!"{label}: {problems}"

private def problemsOf (label : String) (result : Except (Array String) α) : TestM (Array String) :=
  match result with
  | .ok _ => fail s!"{label}: parsed, but should have been refused"
  | .error problems => pure problems

private def baseUrlOf (argv : List String) : Except (Array String) (Option String) := do
  let options ← Provider.Options.cli.parse argv
  pure (options.dgxEndpoint?.map (·.baseUrl))

private def task (argv : List String) : TestM (Result String) := do
  let source ← parsed "task" <| ((Cli.text "task" "the task").required "a task is required").parse argv
  pure (source.read "task")

def taskSuite : Suite := suite "cli.task" #[
  test "a task file's middle reaches the first serialized model request as it is" do
    let path := (← scratch) / "MINIVERO_TASK.md"
    let contents := String.ofList (List.replicate 6500 '界') ++
      "\nDONE: implement every API and prove every fixed specification.\n" ++
      String.ofList (List.replicate 6500 '🦉') ++ "\n"
    IO.FS.writeFile path contents
    let task ← assertOk (← task ["--task-file", path.toString])
    assertEqual "verbatim, trailing newline included" task contents
    let uname : Uname := { system := "Linux", release := "test", version := "test", machine := "test" }
    let logs := #[Agent.MiniSwe.initialLog {} task uname,
      Agent.MiniVero.initialLog { mode := .proof } task uname,
      Agent.MiniVero.initialLog { mode := .codeproof } task uname]
    for log in logs do
      let request : Chat.Request := { messages := Agent.MiniSwe.view {} log, tools := Agent.MiniSwe.tools {} }
      let json := request.toJson .native
      let .ok messages := json.getObjValAs? (Array Lean.Json) "messages"
        | fail "serialized request is missing messages"
      let .ok content := messages[1]!.getObjValAs? String "content"
        | fail "serialized request is missing initial task"
      check ((content.splitOn contents).length == 2) "the whole file must occur once in the first model input",

  test "a task is given as text or as a file, one of the two, and the file must be readable UTF-8" do
    let configuration (label : String) (result : Result String) (expected : String -> Bool) : TestM Unit :=
      assertError label result fun
        | .input m => expected m
        | _ => false
    assertEqual "text" (← assertOk (← task ["--task", "fix it"])) "fix it"
    let refused (label : String) (argv : List String) : TestM (Array String) :=
      problemsOf label <| ((Cli.text "task" "the task").required "a task is required").parse argv
    assertEqual "neither" (← refused "neither" []) #["a task is required"]
    assertEqual "both" (← refused "both" ["--task", "a", "--task-file", "f"])
      #["give either --task TEXT or --task-file FILE, not both"]
    check ((← refused "empty" ["--task", ""])[0]!.startsWith "--task needs a value") "empty text"
    check ((← refused "missing" ["--task-file"])[0]!.startsWith "--task-file needs a value") "missing value"
    assertEqual "- is a file like any other" (← parsed "dash" ((Cli.text "task" "").parse ["--task-file", "-"]))
      (some (.file "-"))
    let path := (← scratch) / "missing"
    configuration "missing file" (← task ["--task-file", path.toString]) (·.startsWith "cannot read the task file")
    IO.FS.writeBinFile path ⟨#[255, 254]⟩
    configuration "invalid UTF-8" (← task ["--task-file", path.toString]) (·.endsWith "is not valid UTF-8")
]

def endpointSuite : Suite := suite "cli.endpoint" #[
  test "the default endpoint is the Spark's own address" do
    assertEqual "baseUrl" ({} : Provider.Dgx.Endpoint).baseUrl "http://10.42.0.1:8000/v1",

  test "a URL fills in only what it specifies" do
    assertEqual "full" ((endpoint "http://192.168.1.5:9000/v1").map (·.baseUrl))
      (some "http://192.168.1.5:9000/v1")
    assertEqual "host:port" ((endpoint "192.168.1.5:9000").map (·.baseUrl))
      (some "http://192.168.1.5:9000/v1")
    assertEqual "host only" ((endpoint "spark.local").map (·.baseUrl))
      (some "http://spark.local:8000/v1")
    assertEqual "https and path" ((endpoint "https://spark.local/openai/v1").map (·.baseUrl))
      (some "https://spark.local:8000/openai/v1")
    assertEqual "trailing slash" ((endpoint "http://spark.local:9000/").map (·.baseUrl))
      (some "http://spark.local:9000/v1"),

  test "a malformed URL is rejected" do
    assertEqual "no host" (endpoint ":9000").isSome false
    assertEqual "bad port" (endpoint "spark.local:http").isSome false
    assertEqual "empty" (endpoint "  ").isSome false,

  test "--port overrides the port from --url, and works on its own" do
    assertEqual "port only" (← parsed "port" (baseUrlOf ["--port", "9001"]))
      (some "http://10.42.0.1:9001/v1")
    assertEqual "url and port" (← parsed "url" (baseUrlOf ["--url", "spark.local:9000", "--port", "7000"]))
      (some "http://spark.local:7000/v1")
    assertEqual "neither" (← parsed "neither" (baseUrlOf [])) none
    let problems ← problemsOf "bad url" (baseUrlOf ["--url", ":9000"])
    check (problems.size == 1 && problems[0]!.startsWith "--url is not an endpoint") s!"{problems}",

  test "an unknown provider names the ones that exist" do
    assertError "unknown" (Provider.fromSpec "nope:x" 0.0) fun
      | .input m => m.startsWith "unknown provider: nope"
      | _ => false
    assertError "not a spec" (Provider.fromSpec "dgx" 0.0) fun
      | .input m => m.endsWith "(e.g. dgx:gpt-oss-120b)"
      | _ => false
]

private def compressed (json : Lean.Json) : String := json.compress

def agentsSuite : Suite := suite "cli.agents" #[
  test "each family's default file reads back as itself, complete" do
    for family in Agent.Families.all do
      let path := ("agents" : System.FilePath) / s!"{family.name}-default.json"
      let built ← assertOk <| Agent.Families.fromFile path
      let .ok onDisk := Lean.Json.parse (← IO.FS.readFile path) | fail s!"{path} is not JSON"
      assertEqual s!"{family.name} defaults" (compressed built.config) (compressed onDisk)
      -- A file naming only the family is the same agent: the file lists every default.
      let minimal ← assertOk <| Agent.Families.instanceOf (.mkObj [("family", family.name)])
      assertEqual s!"{family.name} minimal" (compressed minimal.config) (compressed onDisk),

  test "a configuration may leave fields out, but not misname or mistype one" do
    let refused (label : String) (json : Lean.Json) (expected : String) : TestM Unit :=
      assertError label (Agent.Families.instanceOf json) fun
        | .input m => (m.splitOn expected).length > 1
        | _ => false
    refused "no family" (.mkObj [("step_limit", 1)]) "needs a \"family\""
    refused "unknown family" (.mkObj [("family", "mini-swf")]) "unknown agent family"
    refused "typo" (.mkObj [("family", "mini-swe"), ("step_limt", 1)]) "unknown field 'step_limt'"
    refused "type" (.mkObj [("family", "mini-swe"), ("recover_output", "yes")]) "must be true or false"
    refused "mode" (.mkObj [("family", "mini-vero"), ("mode", "both")]) "unknown mode"
    refused "nested" (.mkObj [("family", "mini-swe"), ("executor", .mkObj [("timeout", 1)])]) "unknown field 'timeout'"
    let file := (← scratch) / "arm.json"
    IO.FS.writeFile file "{\"family\": \"mini-vero\", \"mode\": \"codeproof\", \"recover_output\": true}"
    let built ← assertOk <| Agent.Families.fromFile file
    assertEqual "tools follow the file" (built.tools.map (·.name)) #["bash", "submit", "read_output", "time_budget"]
    assertError "missing file" (Agent.Families.fromFile ((← scratch) / "none.json")) fun
      | .input m => m.startsWith "cannot read"
      | _ => false,

  test "a root records its agent, and every state of the run finds it there" do
    let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
    let workspaces ← Testing.workspaces
    let project := (← scratch) / "proj"
    IO.FS.createDirAll project
    let built ← assertOk <| Agent.Families.instanceOf (.mkObj [("family", "mini-swe"), ("step_limit", 7)])
    let root ← assertOk <| Trajectory.createRoot store workspaces #[] project (← testImage) (some "t")
      (agent := built.config)
    let child ← assertOk <| Trajectory.tell store root "hello"
    assertEqual "root" (compressed (← assertOk <| Trajectory.agentOf store root)) (compressed built.config)
    assertEqual "child" (compressed (← assertOk <| Trajectory.agentOf store child)) (compressed built.config)
    check (← assertOk <| Trajectory.getState store child).agent?.isNone "a child carries no record itself"
    let lines ← assertOk <| Trajectory.showLines store root
    check (lines.any fun l => l.startsWith "agent    " && (l.splitOn "\"step_limit\":7").length > 1) "show prints it"
    let tree ← assertOk <| Trajectory.treeLines store
    check (tree.any fun l => (l.splitOn "root  [mini-swe]").length > 1) s!"tree names the family: {tree}"
]

private def view : Cli.Spec (Bool × String) :=
  Prod.mk <$> Cli.switch "view" "show the view" <*> Cli.arg "HASH" .string "the state"

private def sample : Cli.Command where
  name := "sample"
  summary := "A command for the tests."
  examples := #["alaya sample abc --count 3"]
  spec := (fun (_ : String × Nat × Option String) (_ : Cli.Out) => (pure 0 : Result UInt32))
    <$> (Prod.mk <$> Cli.arg "HASH" .string "the state"
      <*> (Prod.mk <$> Cli.flag "count" .nat "how many" <*> Cli.flag? "note" .string "a note"))

private def app : Cli.App := { name := "alaya", summary := "Tests.", commands := #[sample] }

def specSuite : Suite := suite "cli.spec" #[
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
    let reply := Prod.mk <$> Cli.arg "HASH" .string "" <*> Cli.arg "TEXT" .string ""
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
      (.input "no state matches x", "input", 65), (.environment "cannot run docker", "environment", 69),
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
    assertEqual "an input failure's JSON" (Cli.errorJson (.input "no state matches x")).compress
      "{\"error\":\"input\",\"message\":\"no state matches x\"}",

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
    let groups := Prod.mk <$> (Prod.mk <$> Provider.Choice.cli <*> Executor.Docker.RunOptions.cli)
      <*> Cli.text "task" ""
    assertEqual "the shared groups are disjoint" groups.check #[],

  test "a command takes --json and --help, and says what it accepts" do
    let .ok (_, json) := sample.parse ["abc", "--count", "3", "--json"]
      | fail "sample did not parse"
    check json "--json is seen"
    assertEqual "usage" (sample.usage app) "alaya sample HASH --count N [OPTIONS]"
    let help := sample.help app
    for line in ["usage: alaya sample HASH --count N [OPTIONS]", "  --count N    how many (required)",
        "  --note TEXT  a note", "  alaya sample abc --count 3"] do
      check ((help.splitOn line).length > 1) s!"help lacks '{line}':\n{help}"
    let .ok commands := app.describe.getObjValAs? (Array Lean.Json) "commands" | fail "no commands"
    let .ok items := commands[0]!.getObjValAs? (Array Lean.Json) "items" | fail "no items"
    let names := items.filterMap fun i => (i.getObjValAs? String "name").toOption
    assertEqual "described" names #["HASH", "count", "note", "json", "help"]
]

def suites : Array Suite := #[taskSuite, specSuite, endpointSuite, agentsSuite]

end CliTests
