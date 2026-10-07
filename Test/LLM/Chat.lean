import Test.LLM.Support

/-! The chat protocol: a response as a provider sends it, its tool calls, and structured output
read against a schema. -/

namespace ChatTests

open Testing Lean
open Alaya Alaya.Base Alaya.LLM
open Alaya.LLM.Chat

private def completion (message : Json) (usage : Option Json := none) : Json :=
  .mkObj ([("choices", .arr #[.mkObj [("message", message)]])] ++ (usage.map ("usage", ·)).toList)

def suite : Suite := Testing.suite "llm/chat" #[
  test "a response reads its content and its usage" do
    let parsed ← assertOk <| Chat.Response.fromJson (completion (.mkObj [("content", "hello")])
      (some (.mkObj [("prompt_tokens", 7), ("completion_tokens", 3), ("total_tokens", 10)])))
    assertEqual "content" parsed.content? (some "hello")
    assertEqual "tokens" (parsed.usage?.bind (·.input?), parsed.usage?.bind (·.output?)) (some 7, some 3),

  test "tool calls: none when the field is null, each with its arguments read from their JSON text" do
    let none ← assertOk <| Chat.Response.fromJson (completion (.mkObj [("content", "hi"), ("tool_calls", .null)]))
    assertEqual "a null list is empty" none.toolCalls.size 0
    let call ← assertOk <| Chat.Response.fromJson (completion (.mkObj [("content", .null), ("tool_calls", .arr #[
      .mkObj [("id", "call_1"), ("type", "function"),
        ("function", .mkObj [("name", "get_weather"), ("arguments", "{\"city\":\"Paris\"}")])]])]))
    assertEqual "one call" (call.toolCalls.map fun c => (c.id, c.name)) #[("call_1", "get_weather")]
    assertEqual "its arguments" (call.toolCalls[0]?.bind fun c => (c.arguments.getObjVal? "city" >>= Json.getStr?).toOption) (some "Paris"),

  test "structured output: read natively or from a fenced block, and refused when it breaks the schema" do
    let schema := JsonSchema.object #[("city", .string)]
    let city (value : Json) := (value.getObjVal? "city" >>= Json.getStr?).toOption
    assertEqual "native" (city (← assertOk <| ({ content? := some "{\"city\": \"Paris\"}" } : Chat.Response).structured schema)) (some "Paris")
    let fenced : Chat.Response := { content? := some "Sure:\n```json\n{\"city\": \"Paris\"}\n```\nDone.", structuredOutput := .markdownCodeFence }
    assertEqual "fenced" (city (← assertOk <| fenced.structured schema)) (some "Paris")
    for (label, content) in [("against the schema", "{\"city\": 7}"), ("no JSON at all", "not JSON")] do
      assertError label (({ content? := some content } : Chat.Response).structured schema) fun
        | .structuredOutput _ => true
        | _ => false,

  test "text that is no JSON is a protocol error" do
    assertError "not JSON" (Result.fromExcept Error.protocol (Json.parse "not json")) fun
      | .protocol _ => true
      | _ => false
]

end ChatTests
