import Alaya.LLM.Chat.Schema
import Alaya.Base.Error

namespace Alaya.LLM.Chat

open Alaya.Base

structure ToolCall where
  id : String
  name : String
  arguments : Lean.Json
  /-- The raw `arguments` string when it was not valid JSON; `arguments` is then `.null`. -/
  invalidArguments? : Option String := none
  deriving Inhabited

inductive Message where
  | system (content : String)
  | user (content : String)
  /-- `reasoning?` is the reasoning as text: DeepSeek's `reasoning_content`, carried so it can be
  echoed back when a provider requires it, or the Responses API's summary. `reasoningItems` are
  the Responses API's reasoning items, opaque and encrypted, sent back as they were received. -/
  | assistant (content? : Option String := none) (toolCalls : Array ToolCall := #[])
      (reasoning? : Option String := none) (reasoningItems : Array Lean.Json := #[])
  | tool (callId : String) (content : Lean.Json)
  deriving Inhabited

namespace Message

private def toolCallToJson (call : ToolCall) : Lean.Json :=
  .mkObj [
    ("id", call.id),
    ("type", "function"),
    ("function", .mkObj [
      ("name", call.name),
      -- Invalid arguments are echoed back verbatim, exactly as they arrived.
      ("arguments", call.invalidArguments?.getD call.arguments.compress)
    ])
  ]

def toJson : Message -> Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  -- Reasoning items have no Chat Completions form; the Responses transport sends them.
  | .assistant content? toolCalls reasoning? _ =>
    let json := Lean.Json.mkObj [("role", "assistant")]
    let json := match content? with | some content => json.setObjVal! "content" content | none => json
    let json := match reasoning? with
      | some reasoning => json.setObjVal! "reasoning_content" reasoning | none => json
    if toolCalls.isEmpty then json else json.setObjVal! "tool_calls" (.arr <| toolCalls.map toolCallToJson)
  | .tool callId content =>
    -- A string tool result is sent as-is; structured results are compacted to a JSON string.
    let contentStr := match content with | .str s => s | other => other.compress
    .mkObj [("role", "tool"), ("tool_call_id", callId), ("content", contentStr)]

end Message

structure ToolDefinition where
  name : String
  description : String
  /-- Serialized in strict mode: every property required, no unspecified ones. -/
  parameters : JsonSchema
  deriving Inhabited

namespace ToolDefinition

def toJson (tool : ToolDefinition) : Lean.Json :=
  .mkObj [
    ("type", "function"),
    ("function", .mkObj [
      ("name", tool.name),
      ("description", tool.description),
      ("parameters", tool.parameters.toJson)
    ])
  ]

end ToolDefinition

inductive ToolChoice where
  | auto
  | none
  | required
  | function (name : String)
  deriving Repr, Inhabited

namespace ToolChoice

def toJson : ToolChoice -> Lean.Json
  | .auto => "auto"
  | .none => "none"
  | .required => "required"
  | .function name => .mkObj [("type", "function"), ("function", .mkObj [("name", name)])]

end ToolChoice

inductive StructuredOutput where
  | native
  | markdownCodeFence
  deriving Repr, Inhabited

namespace StructuredOutput

def toJson : StructuredOutput -> Lean.Json
  | .native => "native"
  | .markdownCodeFence => "markdown_code_fence"

end StructuredOutput

inductive ResponseFormat
  | text
  | jsonSchema (name : String) (schema : JsonSchema)
  deriving Repr, Inhabited

namespace ResponseFormat

def toJson : ResponseFormat -> Lean.Json
  | .text => .mkObj [("type", "text")]
  | .jsonSchema name schema => JsonSchema.responseFormat name schema

end ResponseFormat

/-- The provider-independent input to an OpenAI-compatible completion. -/
structure Request where
  messages : Array Message
  tools : Array ToolDefinition := #[]
  toolChoice : ToolChoice := .auto
  responseFormat : ResponseFormat := .text
  deriving Inhabited

namespace Request

private def fallbackInstruction (schema : JsonSchema) : String :=
  "\n\nReturn only JSON matching this schema, wrapped in a ```json code fence:\n" ++ schema.toJson.pretty

private def addFallbackInstruction (messages : Array Message) (schema : JsonSchema) : Array Message :=
  let rec addToLastUser : List Message -> List Message
    | [] => [.user <| fallbackInstruction schema]
    | .user content :: rest => .user (content ++ fallbackInstruction schema) :: rest
    | message :: rest => message :: addToLastUser rest
  (addToLastUser messages.toList.reverse).reverse.toArray

/-- The messages as sent with `structuredOutput`: a fenced-JSON instruction added when the
provider has no native structured output. -/
def messagesFor (request : Request) (structuredOutput : StructuredOutput) : Array Message :=
  match structuredOutput, request.responseFormat with
  | .markdownCodeFence, .jsonSchema _ schema => addFallbackInstruction request.messages schema
  | _, _ => request.messages

/-- The response format as sent with `structuredOutput`. -/
def responseFormatFor (request : Request) (structuredOutput : StructuredOutput) : ResponseFormat :=
  match structuredOutput with
  | .native => request.responseFormat
  | .markdownCodeFence => .text

def toJson (request : Request) (structuredOutput := StructuredOutput.native) : Lean.Json :=
  let messages := request.messagesFor structuredOutput
  let responseFormat := request.responseFormatFor structuredOutput
  let json := Lean.Json.mkObj [
    ("messages", .arr <| messages.map Message.toJson),
    ("response_format", responseFormat.toJson)
  ]
  if request.tools.isEmpty then json else
    json.setObjVal! "tools" (.arr <| request.tools.map ToolDefinition.toJson)
      |>.setObjVal! "tool_choice" request.toolChoice.toJson

end Request

/-- Provider-reported token counts. Fields are optional because providers differ in what they report. -/
structure TokenUsage where
  input? : Option Nat := none
  output? : Option Nat := none
  total? : Option Nat := none
  /-- Of the output, the tokens a reasoning model spent thinking, when it reports them: what a
  reasoning level costs. -/
  reasoning? : Option Nat := none
  /-- Of the input, the tokens the provider served from its prompt cache, when it reports them. -/
  cached? : Option Nat := none
  deriving Repr, Inhabited

/-- A parsed OpenAI-compatible assistant response: the fields the library reads. Anything else a
provider sends is dropped here; what is later wanted gets a named field, as `reasoning?` did. -/
structure Response where
  content? : Option String := none
  toolCalls : Array ToolCall := #[]
  usage? : Option TokenUsage := none
  /-- The provider's `finish_reason` for this choice, when reported. -/
  finishReason? : Option String := none
  /-- The reasoning as text, when the provider reports it (see `Message.assistant`). -/
  reasoning? : Option String := none
  /-- The Responses API's reasoning items, opaque (see `Message.assistant`). -/
  reasoningItems : Array Lean.Json := #[]
  structuredOutput : StructuredOutput := .native
  /-- How long the model took to give it, where that was measured: by the cache, which keeps it
  beside the draw, so a draw costs the time it took whenever it is read. No part of the response
  as stored: a log keeps it as the time of the sample's entry. -/
  elapsedMs? : Option Nat := none
  deriving Inhabited

namespace Response

/-- The assistant message a response is when sent back: everything a later request needs. -/
def message (r : Response) : Message := .assistant r.content? r.toolCalls r.reasoning? r.reasoningItems

private def liftJson (error : String) (result : Except String α) : Except String α :=
  result.mapError fun _ => error

private def parseToolCall (json : Lean.Json) : Except String ToolCall := do
  let id ← liftJson "tool call has no id" <| json.getObjVal? "id" >>= Lean.Json.getStr?
  let function ← liftJson "tool call has no function" <| json.getObjVal? "function"
  let name ← liftJson "tool call function has no name" <| function.getObjVal? "name" >>= Lean.Json.getStr?
  let raw ← liftJson "tool call function has no arguments" <|
    function.getObjVal? "arguments" >>= Lean.Json.getStr?
  match Lean.Json.parse raw with
  | .ok arguments => pure { id, name, arguments }
  | .error _ => pure { id, name, arguments := .null, invalidArguments? := some raw }

/-- The token counts of a response's `usage`, in Chat Completions' names or the Responses API's. -/
def usageFromJson? (raw : Lean.Json) : Option TokenUsage :=
  match raw.getObjVal? "usage" with
  | .ok usage =>
    let input? := (usage.getObjVal? "prompt_tokens" >>= Lean.Json.getNat?).toOption.orElse fun _ =>
      (usage.getObjVal? "input_tokens" >>= Lean.Json.getNat?).toOption
    let output? := (usage.getObjVal? "completion_tokens" >>= Lean.Json.getNat?).toOption.orElse fun _ =>
      (usage.getObjVal? "output_tokens" >>= Lean.Json.getNat?).toOption
    let total? := (usage.getObjVal? "total_tokens" >>= Lean.Json.getNat?).toOption
    let detail (outer inner : String) : Option Nat :=
      (usage.getObjVal? outer >>= (·.getObjVal? inner) >>= Lean.Json.getNat?).toOption
    let reasoning? := (detail "completion_tokens_details" "reasoning_tokens").orElse fun _ =>
      detail "output_tokens_details" "reasoning_tokens"
    -- OpenAI's Chat Completions form, DeepSeek's own, and the Responses API's.
    let cached? := (detail "prompt_tokens_details" "cached_tokens").orElse (fun _ =>
        (usage.getObjVal? "prompt_cache_hit_tokens" >>= Lean.Json.getNat?).toOption) |>.orElse fun _ =>
      detail "input_tokens_details" "cached_tokens"
    some { input?, output?, total?, reasoning?, cached? }
  | .error _ => none

private def fencedJson (content : String) : Except String String :=
  match content.splitOn "```" with
  | _ :: fenced :: _ =>
    let body := if fenced.startsWith "json\n" then fenced.drop 5 else fenced
    pure body.trimAscii.toString
  | _ => throw "response content has no markdown code fence"

/-- Parses and validates a structured assistant response against `schema`. -/
def structured (response : Response) (schema : JsonSchema) : Result Lean.Json :=
  Result.fromExcept Error.structuredOutput do
    let content ←
      match response.content? with
      | some content => pure content
      | none => throw "response has no message content"
    let content ← match response.structuredOutput with
      | .native => pure content
      | .markdownCodeFence => fencedJson content
    let json ← liftJson "response content is not valid JSON" <| Lean.Json.parse content
    schema.validate json
    pure json

def fromJsons (raw : Lean.Json) : Result (Array Response) :=
  Result.fromExcept Error.protocol do
    let choices ← liftJson "response has no choices" <| raw.getObjVal? "choices" >>= Lean.Json.getArr?
    let usage? := usageFromJson? raw
    choices.mapM fun choice => do
      let message ← liftJson "response choice has no message" <| choice.getObjVal? "message"
      let content? := (message.getObjVal? "content" >>= Lean.Json.getStr?).toOption
      let toolCalls ← match message.getObjVal? "tool_calls" with
        | .ok .null => pure #[]
        | .ok calls => calls.getArr?.bind fun calls => calls.mapM parseToolCall
        | .error _ => pure #[]
      let finishReason? := (choice.getObjVal? "finish_reason" >>= Lean.Json.getStr?).toOption
      let reasoning? := (message.getObjVal? "reasoning_content" >>= Lean.Json.getStr?).toOption
      pure { content?, toolCalls, usage?, finishReason?, reasoning? }

def fromJson (raw : Lean.Json) : Result Response := do
  let responses ← fromJsons raw
  match responses[0]? with
  | some response => pure response
  | none => throw <| .protocol "response has no choices"

end Response
/-- The tokens of a request with `messages`, estimated at four characters a token of their
JSON: what a request holds when no provider has said. -/
def estimateTokens (messages : Array Message) : Nat :=
  (messages.foldl (fun n m => n + m.toJson.compress.length) 0 + 3) / 4

end Alaya.LLM.Chat
