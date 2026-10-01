import Alaya.Model

namespace Alaya.Provider.ChatCompletions

structure Config where
  provider : String
  baseUrl : String
  apiKey : String
  /-- The provider's name for the model. -/
  name : String
  /-- What the model is, independent of the provider: its recorded spec, which the cache keys on. -/
  identity : Lean.Json
  /-- Request fields merged into every payload as they are: temperature, reasoning effort, …;
  nothing else is sent, so a field left out takes the provider's default. -/
  params : Lean.Json := .mkObj []
  structuredOutput : Chat.StructuredOutput := .native
  nativeBatching : Bool := true
  /-- Abort the whole request after this many milliseconds so a stalled provider cannot hang. -/
  requestTimeoutMs : Nat := 600000
  /-- Abort connection establishment after this many milliseconds. -/
  connectTimeoutMs : Nat := 30000
  /-- Give every assistant message a `reasoning_content`, as DeepSeek's thinking mode requires:
  one that carried a recorded trace already sends it, as it was received, and one that did not —
  another model's turn, a person's — sends the empty string. Off, no field is added. -/
  echoReasoning : Bool := false

private def validateResponses (config : Config) (request : Chat.Request)
    (responses : Array Chat.Response) : Result (Array Chat.Response) :=
  responses.mapM fun response => do
    let response := { response with structuredOutput := config.structuredOutput }
    match request.responseFormat with
    | .text => pure response
    | .jsonSchema _ schema =>
      let _ ← response.structured schema
      pure response

private structure CurlResponse where
  exitCode : UInt32
  statusOutput : String
  stderr : String
  body : String
  headers : String

/-- Formats a millisecond duration as the decimal seconds string curl expects for its timeouts. -/
private def secondsArg (ms : Nat) : String :=
  let whole := ms / 1000
  let frac := ms % 1000
  let fracStr :=
    if frac < 10 then s!"00{frac}"
    else if frac < 100 then s!"0{frac}"
    else toString frac
  s!"{whole}.{fracStr}"

private def curlConfig (apiKey : String) : String :=
  let escape (value : String) := (value.replace "\\" "\\\\").replace "\"" "\\\""
  s!"header = \"Content-Type: application/json\"\nheader = \"Authorization: Bearer {escape apiKey}\"\n"

private def requestIO (config : Config) (payload : String) : IO CurlResponse :=
  IO.FS.withTempDir fun directory => do
    let configPath := directory / "curl.conf"
    let payloadPath := directory / "request.json"
    let bodyPath := directory / "response.json"
    let headersPath := directory / "response.headers"
    IO.FS.writeFile configPath <| curlConfig config.apiKey
    IO.FS.writeFile payloadPath payload
    let result ← IO.Process.output {
      cmd := "curl"
      args := #[
        "--silent", "--show-error", "--config", configPath.toString,
        "--connect-timeout", secondsArg config.connectTimeoutMs,
        "--max-time", secondsArg config.requestTimeoutMs,
        "--request", "POST", "--data", s!"@{payloadPath}",
        "--output", bodyPath.toString, "--dump-header", headersPath.toString,
        "--write-out", "%{http_code}", s!"{config.baseUrl}/chat/completions"
      ]
    }
    let body ← if ← bodyPath.pathExists then IO.FS.readFile bodyPath else pure ""
    let headers ← if ← headersPath.pathExists then IO.FS.readFile headersPath else pure ""
    pure { exitCode := result.exitCode, statusOutput := result.stdout, stderr := result.stderr, body, headers }

/-- Extracts a provider throttling delay: `retry-after-ms` (milliseconds, used by some
providers, preferred as the more precise) or the integer-seconds form of `retry-after`. -/
private def retryAfterMs? (headers : String) : Option Nat :=
  -- The dump can hold several responses (redirects); reversing makes the final response win.
  -- Lowercasing leaves the digits intact, so values can be parsed from the normalized lines.
  let lines := (headers.splitOn "\n").reverse.map fun line => line.trimAscii.toString.toLower
  let value? (name : String) : Option Nat :=
    lines.findSome? fun line =>
      if line.startsWith s!"{name}:" then
        line.drop (name.length + 1) |>.trimAscii.toString.toNat?
      else none
  (value? "retry-after-ms").orElse fun _ => (value? "retry-after").map (· * 1000)

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
  let result ← Result.fromIO Error.transport <| requestIO config payload.compress
  -- curl exit code 28 is a connect or total-request timeout; treat delivery as unknown.
  if result.exitCode == 28 then
    throw <| .transport s!"{config.provider} request timed out after {secondsArg config.requestTimeoutMs}s"
  if result.exitCode != 0 then
    throw <| .transport s!"{config.provider} request failed: {result.stderr}\n{result.body}"
  let status ← match result.statusOutput.trimAscii.toString.toNat? with
    | some status => pure status
    | none => throw <| .transport s!"{config.provider} returned no HTTP status"
  if status < 200 || status >= 300 then throw <| .http status result.body (retryAfterMs? result.headers)
  let raw ← Result.fromExcept Error.protocol <| Lean.Json.parse result.body
  let responses ← Chat.Response.fromJsons raw
  validateResponses config request responses

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

end Alaya.Provider.ChatCompletions
