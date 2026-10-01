import Alaya.Model
import Alaya.Provider.Http
import Alaya.Provider.ChatCompletions

/-! The OpenAI Responses API as a transport: the same `Chat.Request` in, the same
`Chat.Response` out, as Chat Completions. What it adds is the reasoning of an OpenAI reasoning
model, which it returns as encrypted items: recorded as they are, and sent back with every
later request, so the model keeps its chain of thought across tool calls. Requests are
stateless (`store: false`): the log holds everything, and the provider nothing. -/

namespace Alaya.Provider.Responses

open Alaya (Result Error Model)

structure Config where
  http : Http.Config
  /-- The provider's name for the model. -/
  name : String
  /-- What the model is, independent of the provider: its recorded spec, which the cache keys on. -/
  identity : Lean.Json
  /-- Request fields in Chat Completions' names, as a spec gives them; `toResponsesParams` says
  which are named otherwise here. -/
  params : Lean.Json := .mkObj []
  structuredOutput : Chat.StructuredOutput := .native
  /-- Ask for the model's reasoning as encrypted items, and send each earlier turn's back. -/
  echoItems : Bool := false

private def text (content : Lean.Json) : String :=
  match content with | .str s => s | other => other.compress

private def callJson (call : Chat.ToolCall) : Lean.Json :=
  .mkObj [("type", "function_call"), ("call_id", call.id), ("name", call.name),
    -- Invalid arguments are sent back verbatim, exactly as they arrived.
    ("arguments", call.invalidArguments?.getD call.arguments.compress)]

/-- The input items a message is. An assistant turn is its reasoning items, as they were
received, then its text, then its tool calls: the order the model produced them in. -/
def inputItems (echoItems : Bool) : Chat.Message → Array Lean.Json
  | .system content => #[.mkObj [("role", "system"), ("content", content)]]
  | .user content => #[.mkObj [("role", "user"), ("content", content)]]
  | .assistant content? calls _ items =>
    (if echoItems then items else #[]) ++
      (match content? with
        | some content => if content.isEmpty then #[] else #[.mkObj [("role", "assistant"), ("content", content)]]
        | none => #[]) ++
      calls.map callJson
  | .tool callId content =>
    #[.mkObj [("type", "function_call_output"), ("call_id", callId), ("output", text content)]]

private def toolJson (tool : Chat.ToolDefinition) : Lean.Json :=
  -- Not strict, as with Chat Completions, where a tool is not strict unless it says so.
  .mkObj [("type", "function"), ("name", tool.name), ("description", tool.description),
    ("parameters", tool.parameters.toJson), ("strict", false)]

private def toolChoiceJson : Chat.ToolChoice → Lean.Json
  | .function name => .mkObj [("type", "function"), ("name", name)]
  | choice => choice.toJson

/-- Merges `extra` into `json`, object fields recursively, so `reasoning.effort` from the
params and `reasoning.summary` from the transport end up in one `reasoning`. -/
private partial def merge (json extra : Lean.Json) : Lean.Json :=
  match json, extra with
  | .obj _, .obj fields => fields.foldl (init := json) fun acc key value =>
    acc.setObjVal! key (match acc.getObjVal? key with | .ok old => merge old value | .error _ => value)
  | _, _ => extra

/-- A spec's params, in Chat Completions' names, in the Responses API's: the reasoning effort
and the output limit are named otherwise; every other field is sent as it is. -/
def toResponsesParams (params : Lean.Json) : Lean.Json :=
  match params with
  | .obj fields => fields.foldl (init := .mkObj []) fun acc key value =>
    match key with
    | "reasoning_effort" => merge acc (.mkObj [("reasoning", .mkObj [("effort", value)])])
    | "max_tokens" | "max_completion_tokens" => acc.setObjVal! "max_output_tokens" value
    | _ => merge acc (.mkObj [(key, value)])
  | other => other

/-- The request body for `request`. -/
def payload (config : Config) (request : Chat.Request) : Lean.Json :=
  let messages := request.messagesFor config.structuredOutput
  let json := Lean.Json.mkObj [("model", config.name),
    ("input", .arr (messages.flatMap (inputItems config.echoItems))), ("store", false)]
  let json := if request.tools.isEmpty then json else
    json.setObjVal! "tools" (.arr (request.tools.map toolJson))
      |>.setObjVal! "tool_choice" (toolChoiceJson request.toolChoice)
  let json := match request.responseFormatFor config.structuredOutput with
    | .text => json
    | .jsonSchema name schema => json.setObjVal! "text" (.mkObj [("format", .mkObj [
        ("type", "json_schema"), ("name", name), ("strict", true), ("schema", schema.toJson)])])
  -- The summary is what `show` and the report can read of reasoning that is otherwise encrypted.
  let json := if config.echoItems then
      json.setObjVal! "include" (.arr #["reasoning.encrypted_content"])
        |>.setObjVal! "reasoning" (.mkObj [("summary", "auto")])
    else json
  merge json (toResponsesParams config.params)

private def liftJson (error : String) (result : Except String α) : Except String α :=
  result.mapError fun _ => error

private def callOf (item : Lean.Json) : Except String Chat.ToolCall := do
  let id ← liftJson "function call has no call_id" <| item.getObjVal? "call_id" >>= Lean.Json.getStr?
  let name ← liftJson "function call has no name" <| item.getObjVal? "name" >>= Lean.Json.getStr?
  let raw ← liftJson "function call has no arguments" <| item.getObjVal? "arguments" >>= Lean.Json.getStr?
  match Lean.Json.parse raw with
  | .ok arguments => pure { id, name, arguments }
  | .error _ => pure { id, name, arguments := .null, invalidArguments? := some raw }

/-- Reads a response: its text, tool calls, reasoning items and their summaries, usage, and a
finish reason in Chat Completions' terms (`tool_calls`, `stop`, `length`), which agents read. -/
def responseOf (raw : Lean.Json) : Result Chat.Response :=
  Result.fromExcept Error.protocol do
    let status := (raw.getObjVal? "status" >>= Lean.Json.getStr?).toOption.getD "completed"
    if status == "failed" then
      throw s!"the response failed: {((raw.getObjVal? "error").toOption.getD .null).compress}"
    let output ← liftJson "response has no output" <| raw.getObjVal? "output" >>= Lean.Json.getArr?
    let mut texts : Array String := #[]
    let mut summaries : Array String := #[]
    let mut items : Array Lean.Json := #[]
    let mut calls : Array Chat.ToolCall := #[]
    for item in output do
      match (item.getObjVal? "type" >>= Lean.Json.getStr?).toOption with
      | some "reasoning" =>
        items := items.push item
        for part in ((item.getObjVal? "summary" >>= Lean.Json.getArr?).toOption.getD #[]) do
          if let .ok summary := part.getObjVal? "text" >>= Lean.Json.getStr? then
            summaries := summaries.push summary
      | some "message" =>
        for part in ((item.getObjVal? "content" >>= Lean.Json.getArr?).toOption.getD #[]) do
          let part? := (part.getObjVal? "text").toOption <|> (part.getObjVal? "refusal").toOption
          if let some (.str text) := part? then texts := texts.push text
      | some "function_call" => calls := calls.push (← callOf item)
      | _ => pure ()
    let finishReason := match status with
      | "incomplete" =>
        match (raw.getObjVal? "incomplete_details" >>= (·.getObjVal? "reason") >>= Lean.Json.getStr?).toOption with
        | some "max_output_tokens" => "length"
        | some reason => reason
        | none => "incomplete"
      | "completed" => if calls.isEmpty then "stop" else "tool_calls"
      | other => other
    pure {
      content? := if texts.isEmpty then none else some (String.join texts.toList)
      toolCalls := calls
      reasoning? := if summaries.isEmpty then none else some ("\n\n".intercalate summaries.toList)
      reasoningItems := items
      finishReason? := some finishReason
      usage? := Chat.Response.usageFromJson? raw }

private def complete (config : Config) (request : Chat.Request) : Result Chat.Response := do
  let raw ← Http.post config.http "responses" (payload config request)
  let response ← responseOf raw
  let responses ← ChatCompletions.validateResponses config.structuredOutput request #[response]
  match responses[0]? with
  | some response => pure response
  | none => throw <| .protocol "provider returned no response"

/-- A transport model for the Responses API. It has no `n`, so draws are separate requests. -/
def model (config : Config) : Model := {
  identity := config.identity
  structuredOutput := config.structuredOutput
  sample := fun request => pure (Model.Stream.ofNext (complete config request)) }

end Alaya.Provider.Responses
