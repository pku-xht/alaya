import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! Providers and models: the DGX Spark endpoint, which provider serves a model under which
name, and what a recorded model's spec says. -/

namespace ProvidersTests

open Testing
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App

private def endpoint (url : String) : Option Provider.Dgx.Endpoint :=
  (Provider.Dgx.Endpoint.ofUrl url).toOption

private def parsed (label : String) (result : Except (Array String) α) : TestM α :=
  match result with
  | .ok a => pure a
  | .error problems => fail s!"{label}: {problems}"

private def baseUrlOf (argv : List String) : Except (Array String) (Option String) := do
  pure ((← Provider.endpointCli.parse argv).map (·.baseUrl))

private def agentSet (path : List String) (value : Lean.Json) : Settings.Setting :=
  { path, value }

private def problemsOf (label : String) (result : Except (Array String) α) : TestM (Array String) :=
  match result with
  | .ok _ => fail s!"{label}: parsed, but should have been refused"
  | .error problems => pure problems

def suite : Suite := Testing.suite "llm/providers" #[
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

  test "a provider serves a model under its own name, or the name its route gives" do
    let route (provider model : String) : TestM (Except String Provider.Route) := do
      let some p := Provider.named? provider | fail s!"no provider {provider}"
      pure (p.route model)
    let nameOf (provider model : String) : TestM (Option String) := do
      pure ((← route provider model).toOption.map (·.name))
    assertEqual "apiyi, its own name" (← nameOf "apiyi" "deepseek-v4.1-flash") (some "deepseek-v4.1-flash")
    assertEqual "xmcp's name" (← nameOf "xmcp" "deepseek-v4.1-flash") (some "ds/deepseek-v4-flash")
    assertEqual "fireworks' name" (← nameOf "fireworks" "deepseek-v4.1-flash")
      (some "accounts/fireworks/models/deepseek-v4p1-flash")
    match ← route "fireworks" "gpt-oss-120b" with
    | .error m => check ((m.splitOn "does not serve gpt-oss-120b").length > 1) m
    | .ok _ => fail "fireworks serves only its routes",

  test "a route that cannot meet the recorded model refuses it before any request" do
    let some dgx := Provider.named? "dgx" | fail "no dgx"
    let spec : Models.Spec := { name := "m", echoReasoning := .text, contextTokens? := some 100000 }
    let refused (label : String) (route : Provider.Route) (expected : String) : TestM Unit := do
      match Provider.check dgx spec route with
      | .error m => check ((m.splitOn expected).length > 1) s!"{label}: {m}"
      | .ok _ => fail s!"{label}: accepted"
    refused "echo rejected" { name := "m", reasoningEcho := .rejected } "rejects"
    refused "short context" { name := "m", contextTokens? := some 32768 } "short of the run's 100000"
    refused "text through Responses" { name := "m", api := .responses } "has no field for"
    match Provider.check dgx { spec with echoReasoning := .items } { name := "m" } with
    | .error m => check ((m.splitOn "need the Responses API").length > 1) m
    | .ok _ => fail "items through Chat Completions"
    check (Provider.check dgx { spec with echoReasoning := .items } { name := "m", api := .responses }).toOption.isSome
      "items through Responses"
    match Provider.check dgx { spec with echoReasoning := .none } { name := "m", reasoningEcho := .required } with
    | .error m => check ((m.splitOn "needs m's earlier reasoning").length > 1) m
    | .ok _ => fail "echo required but not sent"
    check (Provider.check dgx spec { name := "m", contextTokens? := some 200000 }).toOption.isSome
      "a route with room enough serves it",

  test "echoed reasoning keeps every recorded trace, so a message reads the same on every request" do
    let assistant (content : String) (reasoning? : Option String) : Lean.Json :=
      Chat.Message.toJson (.assistant (some content) #[] reasoning?)
    let user : Lean.Json := Chat.Message.toJson (.user "go on")
    let payload (messages : Array Lean.Json) : Lean.Json := .mkObj [("messages", .arr messages)]
    let traceOf (json : Lean.Json) : Option String := (json.getObjVal? "reasoning_content" >>= Lean.Json.getStr?).toOption
    let early := #[user, assistant "a" (some "thought a"), user, assistant "b" none]
    let later := early ++ #[user, assistant "c" (some "thought c"), user, assistant "d" (some "thought d")]
    let messagesOf (json : Lean.Json) : Array Lean.Json := (json.getObjValAs? (Array Lean.Json) "messages").toOption.getD #[]
    let echoed := messagesOf (Provider.ChatCompletions.echoReasoning (payload later))
    assertEqual "traces as recorded, empty where none" (echoed.filterMap traceOf)
      #["thought a", "", "thought c", "thought d"]
    check (echoed.all fun m => (m.getObjVal? "role" >>= Lean.Json.getStr?).toOption != some "user" || traceOf m == none)
      "a user message carries no reasoning"
    let prefix_ := messagesOf (Provider.ChatCompletions.echoReasoning (payload early))
    assertEqual "a stable prefix" ((prefix_.map (·.compress)).toList)
      ((echoed.extract 0 prefix_.size).map (·.compress)).toList,

  test "a served model's identity is its recorded spec, whoever serves it" do
    let spec ← assertOk <| Models.fromJson (.mkObj [("name", "deepseek-v4.1-flash"),
      ("params", .mkObj [("reasoning_effort", "high")])])
    let some dgx := Provider.named? "dgx" | fail "no dgx"
    let viaDgx ← assertOk <| Provider.serve dgx spec
    let viaOther ← assertOk <| Provider.serve { dgx with name := "other", baseUrl := "http://elsewhere/v1" } spec
    assertEqual "identity" viaDgx.identity.compress spec.toJson.compress
    assertEqual "provider-independent" viaDgx.identity.compress viaOther.identity.compress
    assertError "a missing key" (Provider.serve { dgx with keyVar := "ALAYA_TEST_UNSET_KEY", defaultKey? := none } spec) fun
      | .environment m => (m.splitOn "ALAYA_TEST_UNSET_KEY is not set").length > 1
      | _ => false,

  test "a model's name alone is its defaults, and settings over an agent's model are checked" do
    let defaults ← assertOk <| Models.fromJson "gpt-oss-120b"
    assertEqual "context from the table" defaults.contextTokens? (some 131072)
    let modelOf (config : Lean.Json) : TestM Models.Spec := assertOk <| Models.fromJson
      ((config.getObjVal? "model").toOption.getD .null)
    let set ← modelOf (← assertOk <| Catalog.resolve "mini-swe"
      #[agentSet ["model"] "gpt-oss-120b", agentSet ["model", "params", "temperature"] (1 : Nat),
        agentSet ["model", "context_tokens"] (65536 : Nat)])
    assertEqual "params" set.params.compress "{\"temperature\":1}"
    assertEqual "context" set.contextTokens? (some 65536)
    for (label, settings, expected) in [
        ("unknown", #[agentSet ["model", "temperature"] (1 : Nat)], "unknown field 'temperature'"),
        ("protected", #[agentSet ["model", "params", "model"] "x"], "params cannot set 'model'"),
        ("name", #[agentSet ["name"] "x"], "unknown field 'name'")] do
      assertError label (Catalog.resolve "mini-swe" (#[agentSet ["model"] "gpt-oss-120b"] ++ settings)) fun
        | .input m => (m.splitOn expected).length > 1
        | _ => false
    assertError "unknown model" (Models.fromJson (.mkObj [("name", "nope")])) fun
      | .input m => m.startsWith "unknown model: nope"
      | _ => false
    match Settings.parse "model.params.reasoning_effort=high" with
    | .ok s => check (s.path == ["model", "params", "reasoning_effort"] && s.value == "high") "parsed"
    | .error m => fail m
]

end ProvidersTests
