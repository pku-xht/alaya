import Lean.Data.Json
import Alaya.Error

/-! A JSON POST to a provider, through `curl`: its timeouts, its errors, and its throttling
delay. Every transport sends its requests this way. -/

namespace Alaya.Provider.Http

open Alaya (Result Error)

structure Config where
  provider : String
  baseUrl : String
  apiKey : String
  /-- Abort the whole request after this many milliseconds so a stalled provider cannot hang. -/
  requestTimeoutMs : Nat := 600000
  /-- Abort connection establishment after this many milliseconds. -/
  connectTimeoutMs : Nat := 30000

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

private def requestIO (config : Config) (path payload : String) : IO CurlResponse :=
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
        "--write-out", "%{http_code}", s!"{config.baseUrl}/{path}"
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

/-- Posts `payload` to `path` under the provider's base URL and returns the JSON it answers. -/
def post (config : Config) (path : String) (payload : Lean.Json) : Result Lean.Json := do
  let result ← Result.fromIO Error.transport <| requestIO config path payload.compress
  -- curl exit code 28 is a connect or total-request timeout; treat delivery as unknown.
  if result.exitCode == 28 then
    throw <| .transport s!"{config.provider} request timed out after {secondsArg config.requestTimeoutMs}s"
  if result.exitCode != 0 then
    throw <| .transport s!"{config.provider} request failed: {result.stderr}\n{result.body}"
  let status ← match result.statusOutput.trimAscii.toString.toNat? with
    | some status => pure status
    | none => throw <| .transport s!"{config.provider} returned no HTTP status"
  if status < 200 || status >= 300 then throw <| .http status result.body (retryAfterMs? result.headers)
  Result.fromExcept Error.protocol <| Lean.Json.parse result.body

end Alaya.Provider.Http
