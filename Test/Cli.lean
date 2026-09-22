import Test.Framework
import Test.DirectoryWorkspaces
import Alaya

/-! Command-line parsing and the DGX Spark endpoint syntax. -/

namespace CliTests

open Testing
open Alaya

private def parse (argv : List String) : Cli.Args :=
  Cli.parse argv (aliases := [("-m", "note")])

private def endpoint (url : String) : Option Provider.Dgx.Endpoint :=
  (Provider.Dgx.Endpoint.ofUrl url).toOption

private def baseUrlOf (argv : List String) : Result (Option String) := do
  let options ← Provider.Options.ofArgs (Cli.parse argv)
  pure (options.dgxEndpoint?.map (·.baseUrl))

def argsSuite : Suite := suite "cli.args" #[
  test "positionals and flags interleave" do
    let args := parse ["commit", "abc", "dir", "--data", "d", "-m", "note text"]
    assertEqual "positional" args.positional #["commit", "abc", "dir"]
    assertEqual "data" (args.getD "data" "") "d"
    assertEqual "alias" (args.getD "note" "") "note text",

  test "a repeated flag keeps every value, and get? takes the last" do
    let args := parse ["--model", "a:1", "--model", "b:2", "--count", "4"]
    assertEqual "all" (args.all "model") #["a:1", "b:2"]
    assertEqual "last" (args.getD "model" "") "b:2"
    assertEqual "positional" args.positional #[],

  test "a flag before another flag, or at the end, is a valueless switch" do
    let args := parse ["--concurrent", "--count", "8"]
    assertEqual "switch" (args.getD "concurrent" "unset") ""
    assertEqual "isSet" (args.isSet "concurrent") true
    assertEqual "count" (args.getD "count" "") "8"
    assertEqual "trailing switch" ((parse ["--concurrent"]).isSet "concurrent") true,

  test "numeric flags report the flag name on bad input" do
    let args := parse ["--count", "x"]
    assertEqual "default" (← assertOk (args.natD "missing" 8)) 8
    assertError "count" (args.natD "count" 8) fun
      | .configuration m => m.startsWith "--count expects a whole number"
      | _ => false
    let temperature ← assertOk ((parse ["--temperature", "0.25"]).floatD "temperature" 0.0)
    assertEqual "float" temperature 0.25,

  test "a value-taking flag given without a value is an error" do
    assertEqual "absent" (← assertOk ((parse []).valueD "data" ".alaya")) ".alaya"
    assertEqual "given" (← assertOk ((parse ["--data", "d"]).valueD "data" ".alaya")) "d"
    assertError "switch" ((parse ["--data"]).valueD "data" ".alaya") fun
      | .configuration m => m == "--data needs a value"
      | _ => false,

  test "require fails when a flag is missing or empty" do
    assertError "missing" ((parse []).require "model" "hint") fun
      | .configuration m => m.startsWith "--model is required"
      | _ => false
    assertError "empty" ((parse ["--model"]).require "model" "hint") fun
      | .configuration m => m.startsWith "--model needs a value"
      | _ => false,

  test "a task file's middle reaches the first serialized model request as it is" do
    let path := (← scratch) / "MINIVERO_TASK.md"
    let contents := String.ofList (List.replicate 6500 '界') ++
      "\nDONE: implement every API and prove every fixed specification.\n" ++
      String.ofList (List.replicate 6500 '🦉') ++ "\n"
    IO.FS.writeFile path contents
    let task ← assertOk ((parse ["--task-file", path.toString]).taskOf "usage")
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
        | .configuration m => expected m
        | _ => false
    assertEqual "text" (← assertOk ((parse ["--task", "fix it"]).taskOf "usage")) "fix it"
    -- The project may come before or after the flag; the value is the next token whatever it is.
    for argv in [["root", "--task", "fix it", "./proj"], ["root", "./proj", "--task", "fix it"]] do
      assertEqual "positional" (parse argv).positional #["root", "./proj"]
    configuration "neither" ((parse []).taskOf "usage") (· == "usage")
    configuration "both" ((parse ["--task", "a", "--task-file", "f"]).taskOf "usage") (·.startsWith "give either")
    configuration "empty text" ((parse ["--task"]).taskOf "usage") (·.startsWith "--task needs a value")
    configuration "missing value" ((parse ["--task-file"]).taskOf "usage") (·.startsWith "--task-file needs a value")
    let path := (← scratch) / "missing"
    configuration "missing file" ((parse ["--task-file", path.toString]).taskOf "usage") (·.startsWith "cannot read")
    IO.FS.writeBinFile path ⟨#[255, 254]⟩
    configuration "invalid UTF-8" ((parse ["--task-file", path.toString]).taskOf "usage") (·.endsWith "is not valid UTF-8")
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
    assertEqual "port only" (← assertOk (baseUrlOf ["--port", "9001"]))
      (some "http://10.42.0.1:9001/v1")
    assertEqual "url and port" (← assertOk (baseUrlOf ["--url", "spark.local:9000", "--port", "7000"]))
      (some "http://spark.local:7000/v1")
    assertEqual "neither" (← assertOk (baseUrlOf [])) none
    assertError "bad url" (baseUrlOf ["--url", ":9000"]) fun
      | .configuration m => m.startsWith "--url:"
      | _ => false,

  test "an unknown provider names the ones that exist" do
    assertError "unknown" (Provider.fromSpec "nope:x" 0.0) fun
      | .configuration m => m.startsWith "unknown provider: nope"
      | _ => false
    assertError "not a spec" (Provider.fromSpec "dgx" 0.0) fun
      | .configuration m => m.endsWith "(e.g. dgx:gpt-oss-120b)"
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
        | .configuration m => (m.splitOn expected).length > 1
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
    assertEqual "tools follow the file" (built.tools.map (·.name)) #["bash", "submit", "read_output"]
    assertError "missing file" (Agent.Families.fromFile ((← scratch) / "none.json")) fun
      | .configuration m => m.startsWith "cannot read"
      | _ => false,

  test "a root records its agent, and every state of the run finds it there" do
    let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
    let workspaces ← Testing.workspaces
    let project := (← scratch) / "proj"
    IO.FS.createDirAll project
    let built ← assertOk <| Agent.Families.instanceOf (.mkObj [("family", "mini-swe"), ("step_limit", 7)])
    let root ← assertOk <| Trajectory.createRoot store workspaces #[] project (some "t") (agent := built.config)
    let child ← assertOk <| Trajectory.tell store root "hello"
    assertEqual "root" ((← assertOk <| Trajectory.agentOf store root).map compressed) (some (compressed built.config))
    assertEqual "child" ((← assertOk <| Trajectory.agentOf store child).map compressed) (some (compressed built.config))
    check (← assertOk <| Trajectory.getState store child).agent?.isNone "a child carries no record itself"
    let lines ← assertOk <| Trajectory.showLines store root
    check (lines.any fun l => l.startsWith "agent    " && (l.splitOn "\"step_limit\":7").length > 1) "show prints it"
    let tree ← assertOk <| Trajectory.treeLines store
    check (tree.any fun l => (l.splitOn "root  [mini-swe]").length > 1) s!"tree names the family: {tree}"
]

def suites : Array Suite := #[argsSuite, endpointSuite, agentsSuite]

end CliTests
