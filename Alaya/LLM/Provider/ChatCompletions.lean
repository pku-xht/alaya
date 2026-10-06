import Alaya.LLM.Model
import Alaya.LLM.Provider.Http

namespace Alaya.LLM.Provider.ChatCompletions

open Alaya.Base

structure Config where
  http : Http.Config
  /-- The provider's name for the model. -/
  name : String
  /-- What the model is, independent of the provider: its recorded spec, which the cache keys on. -/
  identity : Lean.Json
  /-- Request fields merged into every payload as they are: temperature, reasoning effort, …;
  nothing else is sent, so a field left out takes the provider's default. -/
  params : Lean.Json := .mkObj []
  structuredOutput : Chat.StructuredOutput := .native
  nativeBatching : Bool := true
  /-- Give every assistant message a `reasoning_content`, as DeepSeek's thinking mode requires:
  one that carried a recorded trace already sends it, as it was received, and one that did not —
  another model's turn, a person's — sends the empty string. Off, no field is added. -/
  echoReasoning : Bool := false

def validateResponses (structuredOutput : Chat.StructuredOutput) (request : Chat.Request)
    (responses : Array Chat.Response) : Result (Array Chat.Response) :=
  responses.mapM fun response => do
    let response := { response with structuredOutput }
    match request.responseFormat with
    | .text => pure response
    | .jsonSchema _ schema =>
      let _ ← response.structured schema
      pure response

/-- Gives every assistant message of a payload a `reasoning_content`, the empty string where it
has none. A recorded trace is never changed, so a message reads the same on every request and
the provider can keep reusing the prefix it has cached. -/
def echoReasoning (payload : Lean.Json) : Lean.Json :=
  match payload.getObjVal? "messages" with
  | .ok (.arr messages) =>
    payload.setObjVal! "messages" <| .arr <| messages.map fun message =>
      let assistant := (message.getObjVal? "role" >>= Lean.Json.getStr?).toOption == some "assistant"
      if assistant && !(message.getObjVal? "reasoning_content").isOk then
        message.setObjVal! "reasoning_content" ""
      else message
  | _ => payload

private def complete (config : Config) (request : Chat.Request) (n : Nat) :
    Result (Array Chat.Response) := do
  let payload := request.toJson config.structuredOutput |>.setObjVal! "model" config.name
  let payload := match config.params with
    | .obj fields => fields.foldl (fun payload key value => payload.setObjVal! key value) payload
    | _ => payload
  let payload := if config.echoReasoning then echoReasoning payload else payload
  -- Omit `n` for single completions so providers without multi-sample support stay compatible.
  let payload := if n == 1 then payload else payload.setObjVal! "n" n
  let raw ← Http.post config.http "chat/completions" payload
  let responses ← Chat.Response.fromJsons raw
  validateResponses config.structuredOutput request responses

/-- Creates a one-response transport model for an OpenAI-compatible chat-completions API. -/
def model (config : Config) : Model := {
  identity := config.identity
  structuredOutput := config.structuredOutput
  sample := fun request =>
    let next : Result Chat.Response := do
      let responses ← complete config request 1
      match responses[0]? with
      | some response => pure response
      | none => throw <| .protocol "provider returned no responses"
    pure <| if config.nativeBatching
      then Model.Stream.withNative next (complete config request)
      else Model.Stream.ofNext next }

end Alaya.LLM.Provider.ChatCompletions
