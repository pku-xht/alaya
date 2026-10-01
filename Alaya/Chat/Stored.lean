import Alaya.Chat.Protocol

/-!
How Alaya stores chat data: tool calls, token usage, responses and messages, as JSON. The model
cache and the trajectory's states both use these, so a response reads the same wherever it is
kept. The wire format sent to a provider is another thing, and stays in `Protocol`.

Every field is written, `null` where it does not apply, and read strictly: a field missing or
of another type is an error, never a default.
-/

namespace Alaya.Chat

private def nullable (json : Lean.Json) (name : String) (read : Lean.Json → Except String α) :
    Except String (Option α) := do
  match ← json.getObjVal? name with
  | .null => pure none
  | value => some <$> read value

private def orNull (value? : Option α) (write : α → Lean.Json) : Lean.Json :=
  value?.map write |>.getD .null

namespace ToolCall

def toStored (call : ToolCall) : Lean.Json :=
  .mkObj [("id", call.id), ("name", call.name), ("arguments", call.arguments),
    ("invalid_arguments", orNull call.invalidArguments? .str)]

def ofStored (json : Lean.Json) : Except String ToolCall := do
  pure {
    id := ← json.getObjVal? "id" >>= Lean.Json.getStr?
    name := ← json.getObjVal? "name" >>= Lean.Json.getStr?
    arguments := ← json.getObjVal? "arguments"
    invalidArguments? := ← nullable json "invalid_arguments" Lean.Json.getStr? }

end ToolCall

private def callsOfStored (json : Lean.Json) : Except String (Array ToolCall) := do
  (← json.getObjVal? "tool_calls" >>= Lean.Json.getArr?).mapM ToolCall.ofStored

namespace TokenUsage

def toStored (usage : TokenUsage) : Lean.Json :=
  .mkObj [("input", orNull usage.input? (fun n => (n : Lean.Json))),
    ("output", orNull usage.output? (fun n => (n : Lean.Json))),
    ("total", orNull usage.total? (fun n => (n : Lean.Json))),
    ("reasoning", orNull usage.reasoning? (fun n => (n : Lean.Json))),
    ("cached", orNull usage.cached? (fun n => (n : Lean.Json)))]

def ofStored (json : Lean.Json) : Except String TokenUsage := do
  pure {
    input? := ← nullable json "input" Lean.Json.getNat?
    output? := ← nullable json "output" Lean.Json.getNat?
    total? := ← nullable json "total" Lean.Json.getNat?
    reasoning? := ← nullable json "reasoning" Lean.Json.getNat?
    cached? := ← nullable json "cached" Lean.Json.getNat? }

end TokenUsage

namespace Response

/-- A response as stored. Its structured-output mode is the model's, stamped where it is read. -/
def toStored (r : Response) : Lean.Json :=
  .mkObj [("content", orNull r.content? .str), ("tool_calls", .arr (r.toolCalls.map (·.toStored))),
    ("reasoning", orNull r.reasoning? .str), ("finish_reason", orNull r.finishReason? .str),
    ("usage", orNull r.usage? (·.toStored))]

def ofStored (json : Lean.Json) : Except String Response := do
  pure {
    content? := ← nullable json "content" Lean.Json.getStr?
    toolCalls := ← callsOfStored json
    reasoning? := ← nullable json "reasoning" Lean.Json.getStr?
    finishReason? := ← nullable json "finish_reason" Lean.Json.getStr?
    usage? := ← nullable json "usage" TokenUsage.ofStored }

end Response

namespace Message

def toStored : Message → Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? toolCalls reasoning? => .mkObj [("role", "assistant"),
      ("content", orNull content? .str), ("reasoning", orNull reasoning? .str),
      ("tool_calls", .arr (toolCalls.map (·.toStored)))]
  | .tool callId content => .mkObj [("role", "tool"), ("tool_call_id", callId), ("content", content)]

def ofStored (json : Lean.Json) : Except String Message := do
  match ← json.getObjVal? "role" >>= Lean.Json.getStr? with
  | "system" => .system <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "user" => .user <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "assistant" =>
    pure (.assistant (← nullable json "content" Lean.Json.getStr?) (← callsOfStored json)
      (← nullable json "reasoning" Lean.Json.getStr?))
  | "tool" =>
    pure (.tool (← json.getObjVal? "tool_call_id" >>= Lean.Json.getStr?) (← json.getObjVal? "content"))
  | other => throw s!"unknown message role: {other}"

end Message

end Alaya.Chat
