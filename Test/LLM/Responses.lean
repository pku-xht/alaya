import Test.Support.Framework
import Alaya

/-! The Responses transport: the request it sends, the response it reads, and the encrypted
reasoning it records and sends back as it was received. -/

namespace ResponsesTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App

private def json (text : String) : Lean.Json := (Lean.Json.parse text).toOption.getD .null

/-- A reasoning item as the API returns it, its encrypted payload shortened. -/
private def reasoningItem : Lean.Json := json
  "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"content\":[],\"encrypted_content\":\"gAAAA-opaque\",
    \"summary\":[{\"type\":\"summary_text\",\"text\":\"**Checking candidates**\"}]}"

/-- A turn that reasoned and called a tool, as apiyi answered for gpt-6-luna. -/
private def toolTurn : Lean.Json := json
  "{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"content\":[],
    \"encrypted_content\":\"gAAAA-opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"**Checking candidates**\"}]},
    {\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}],
    \"usage\":{\"input_tokens\":92,\"input_tokens_details\":{\"cached_tokens\":64},\"output_tokens\":319,
    \"output_tokens_details\":{\"reasoning_tokens\":224},\"total_tokens\":411}}"

private def bash : Chat.ToolDefinition :=
  { name := "bash", description := "Execute a bash command"
    parameters := .object #[("command", .string)] }

private def config (echoItems : Bool := true) (params : Lean.Json := .mkObj []) : Provider.Responses.Config :=
  { http := { provider := "test", baseUrl := "http://unused", apiKey := "k" }, name := "gpt-6-luna"
    identity := .null, params, echoItems }

private def typeOf (item : Lean.Json) : String :=
  (item.getObjVal? "type" >>= Lean.Json.getStr?).toOption.getD
    ((item.getObjVal? "role" >>= Lean.Json.getStr?).toOption.getD "?")

def suite : Suite := Testing.suite "llm/responses" #[
  test "a response is read into text, calls, reasoning items as received, a summary, and usage" do
    let r ← assertOk <| Provider.Responses.responseOf toolTurn
    assertEqual "calls" (r.toolCalls.map (·.name)) #["bash"]
    assertEqual "arguments" (r.toolCalls.map (·.arguments.compress)) #["{\"command\":\"ls\"}"]
    assertEqual "items as received" (r.reasoningItems.map (·.compress)) #[reasoningItem.compress]
    assertEqual "summary" r.reasoning? (some "**Checking candidates**")
    assertEqual "finish" r.finishReason? (some "tool_calls")
    assertEqual "reasoning tokens" (r.usage?.bind (·.reasoning?)) (some 224)
    assertEqual "cached tokens" (r.usage?.bind (·.cached?)) (some 64)
    let answer ← assertOk <| Provider.Responses.responseOf (json
      "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",
        \"content\":[{\"type\":\"output_text\",\"text\":\"17\"}]}]}")
    assertEqual "text" answer.content? (some "17")
    assertEqual "a stop" answer.finishReason? (some "stop")
    let cut ← assertOk <| Provider.Responses.responseOf (json
      "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}")
    assertEqual "cut at the limit" cut.finishReason? (some "length")
    assertError "failed" (Provider.Responses.responseOf (json "{\"status\":\"failed\",\"error\":{\"code\":\"x\"},\"output\":[]}"))
      fun | .protocol m => (m.splitOn "failed").length > 1 | _ => false,

  test "a request is input items in order, with each turn's reasoning items sent back byte for byte" do
    let r ← assertOk <| Provider.Responses.responseOf toolTurn
    let request : Chat.Request := {
      messages := #[.system "sys", .user "task", r.message, .tool "call_1" (.str "out")]
      tools := #[bash] }
    let payload := Provider.Responses.payload (config) request
    let input := (payload.getObjValAs? (Array Lean.Json) "input").toOption.getD #[]
    assertEqual "order" (input.map typeOf).toList ["system", "user", "reasoning", "function_call", "function_call_output"]
    assertEqual "the item as received" (input[2]?.map (·.compress)) (some reasoningItem.compress)
    assertEqual "stateless" ((payload.getObjVal? "store").toOption.map (·.compress)) (some "false")
    assertEqual "asks for the items" ((payload.getObjVal? "include").toOption.map (·.compress))
      (some "[\"reasoning.encrypted_content\"]")
    let tools := (payload.getObjValAs? (Array Lean.Json) "tools").toOption.getD #[]
    assertEqual "a flat, non-strict tool" ((tools.map fun t => ((t.getObjVal? "name").toOption.map (·.compress),
      (t.getObjVal? "strict").toOption.map (·.compress))).toList) [(some "\"bash\"", some "false")]
    -- Without echo, the items stay out, and none is asked for.
    let plain := Provider.Responses.payload (config (echoItems := false)) request
    let plainInput := (plain.getObjValAs? (Array Lean.Json) "input").toOption.getD #[]
    check (!(plainInput.map typeOf).contains "reasoning") "items sent without echo"
    check (plain.getObjVal? "include").toOption.isNone "items asked for without echo",

  test "params in Chat Completions' names are sent in the Responses API's" do
    let params := json "{\"reasoning_effort\":\"high\",\"max_tokens\":500,\"temperature\":0}"
    let payload := Provider.Responses.payload (config (params := params)) { messages := #[.user "hi"] }
    assertEqual "effort, beside the summary" ((payload.getObjVal? "reasoning").toOption.map (·.compress))
      (some "{\"effort\":\"high\",\"summary\":\"auto\"}")
    assertEqual "output limit" ((payload.getObjVal? "max_output_tokens").toOption.map (·.compress)) (some "500")
    assertEqual "as it is" ((payload.getObjVal? "temperature").toOption.map (·.compress)) (some "0")
    check (payload.getObjVal? "reasoning_effort").toOption.isNone "the Chat Completions name was sent",

  test "items are stored, and a request that differs only in them is another request" do
    let r ← assertOk <| Provider.Responses.responseOf toolTurn
    let again ← assertOk <| Result.fromExcept Error.storage (Chat.Response.ofStored r.toStored)
    assertEqual "stored" (again.reasoningItems.map (·.compress)) (r.reasoningItems.map (·.compress))
    let model : Model := { identity := .null, sample := fun _ => throw (.protocol "unused") }
    let request (r : Chat.Response) : Chat.Request := { messages := #[.user "task", r.message, .user "go on"] }
    let other := { r with reasoningItems := #[json "{\"type\":\"reasoning\",\"id\":\"rs_2\"}"] }
    check (model.cacheKey (request r) != model.cacheKey (request other)) "items do not key"
    let none_ := { r with reasoningItems := #[] }
    check (!((model.cacheKey (request none_)).splitOn "reasoning_items").length > 1)
      "a request with no items keys as before",

  test "a run that sends items back needs a Responses route, and apiyi serves gpt-6-luna through one" do
    let spec ← assertOk <| Models.fromJson "gpt-6-luna"
    assertEqual "luna sends items back" (toString spec.echoReasoning) "items"
    let some apiyi := Provider.named? "apiyi" | fail "no apiyi"
    let route ← assertOk <| Result.fromExcept Error.input (apiyi.route "gpt-6-luna")
    check (route.api == .responses) "apiyi's route for luna is not Responses"
    check (Provider.check apiyi spec route).toOption.isSome "apiyi refuses luna"
    let some yunwu := Provider.named? "yunwu" | fail "no yunwu"
    let chat ← assertOk <| Result.fromExcept Error.input (yunwu.route "gpt-6-luna")
    match Provider.check yunwu spec chat with
    | .error m => check ((m.splitOn "need the Responses API").length > 1) m
    | .ok _ => fail "luna through Chat Completions",

  iotest "echo_reasoning is none, text or items" do
    for (value, expected) in [("none", some "none"), ("text", some "text"), ("items", some "items"),
        ("\"true\"", none), ("true", none)] do
      let raw := if value.startsWith "\"" || value == "true" then value else s!"\"{value}\""
      let parsed := (Models.fromJson (json s!"\{\"name\":\"gpt-6-luna\",\"echo_reasoning\":{raw}}")).toBaseIO
      match ← parsed, expected with
      | .ok spec, some name => if toString spec.echoReasoning != name then throw <| IO.userError s!"{value}: {spec.echoReasoning}"
      | .error _, none => pure ()
      | .ok _, none => throw <| IO.userError s!"{value} accepted"
      | .error e, some _ => throw <| IO.userError s!"{value}: {repr e}"
]

end ResponsesTests
