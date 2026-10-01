import Alaya.Cli
import Alaya.Models
import Alaya.Provider.ChatCompletions
import Alaya.Provider.Dgx

/-!
Who serves a model: chosen per invocation (`resume --provider NAME`), never recorded. A provider
is data — its API key variable, its URL, and how it serves particular models — and serving a
model through one first checks the model's recorded requirements against what the provider
declares, so that changing providers either sends the model the same requests or fails before
any is sent. The agent may behave differently with different models; never with different
providers.
-/

namespace Alaya.Provider

open Alaya (Result Error Model)

/-- Whether an API wants earlier reasoning sent back. -/
inductive EchoSupport where
  | required
  | accepted
  | rejected
  deriving BEq, Repr, Inhabited

/-- How a provider serves one model. -/
structure Route where
  /-- The provider's name for the model. -/
  name : String
  nativeBatching : Bool := true
  structuredOutput : Chat.StructuredOutput := .native
  reasoningEcho : EchoSupport := .accepted
  /-- The largest context this route accepts, in tokens; `none` when it is not known. -/
  contextTokens? : Option Nat := none
  /-- The longest response it returns, in tokens; `none` when it is not known. -/
  outputTokens? : Option Nat := none
  deriving Inhabited

/-- Where requests go. -/
structure Provider where
  name : String
  baseUrl : String
  /-- An environment variable that overrides `baseUrl`, when set. -/
  baseUrlVar? : Option String := none
  keyVar : String
  /-- The key when `keyVar` is unset, for a server that needs no real credential. -/
  defaultKey? : Option String := none
  /-- How it serves particular models, by model name, where that differs from serving the model
  under its own name. -/
  routes : List (String × Route) := []
  /-- Whether it serves every model under its own name, or only those in `routes`. -/
  anyModel : Bool := true
  deriving Inhabited

def all : Array Provider := #[
  { name := "yunwu", baseUrl := "https://yunwu.ai/v1", baseUrlVar? := some "YUNWU_BASE_URL",
    keyVar := "YUNWU_API_KEY" },
  { name := "closeai", baseUrl := "https://api.openai-proxy.org/v1", keyVar := "CLOSEAI_API_KEY" },
  { name := "xmcp", baseUrl := "https://llm.xmcp.ltd", keyVar := "XMCP_API_KEY"
    routes := [("deepseek-v4.1-flash", { name := "ds/deepseek-v4-flash" }),
      ("gpt-5.6-luna", { name := "closeai/gpt-5.6-luna" })] },
  { name := "apiyi", baseUrl := "https://api.apiyi.com/v1", baseUrlVar? := some "APIYI_BASE_URL",
    keyVar := "APIYI_API_KEY" },
  { name := "fireworks", baseUrl := "https://api.fireworks.ai/inference/v1",
    baseUrlVar? := some "FIREWORKS_BASE_URL", keyVar := "FIREWORKS_API_KEY", anyModel := false
    routes := [("deepseek-v4.1-flash", { name := "accounts/fireworks/models/deepseek-v4p1-flash" })] },
  -- A DGX Spark's vLLM server, which needs no credential; `--url`/`--port` address it.
  { name := "dgx", baseUrl := ({} : Dgx.Endpoint).baseUrl, baseUrlVar? := some "DGX_BASE_URL",
    keyVar := "DGX_API_KEY", defaultKey? := some "EMPTY" }]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Provider := all.find? (·.name == name)

/-- How `provider` serves `model`, or why it does not. -/
def Provider.route (provider : Provider) (model : String) : Except String Route :=
  match provider.routes.lookup model with
  | some route => pure route
  | none =>
    if provider.anyModel then pure { name := model }
    else throw s!"{provider.name} does not serve {model} (it serves {", ".intercalate (provider.routes.map (·.1))})"

/-- What a route must meet of a recorded model, or the first requirement it does not. -/
def check (provider : Provider) (spec : Models.Spec) (route : Route) : Except String Unit := do
  match route.reasoningEcho, spec.echoReasoning with
  | .required, false =>
    throw s!"{provider.name} needs {spec.name}'s earlier reasoning sent back, which this run does not do"
  | .rejected, true =>
    throw s!"this run sends {spec.name} its earlier reasoning, which {provider.name} rejects"
  | _, _ => pure ()
  if let (some capacity, some needed) := (route.contextTokens?, spec.contextTokens?) then
    if capacity < needed then
      throw s!"{provider.name} accepts a context of {capacity} tokens for {spec.name}, short of the run's {needed}"
  if let (some capacity, some needed) := (route.outputTokens?, spec.outputTokens?) then
    if capacity < needed then
      throw s!"{provider.name} returns {capacity} tokens for {spec.name}, short of the run's {needed}"

/-- The model a recorded spec names, served by `provider`: the bare transport, before retry and
cache. Its identity is the spec alone, so the cache does not depend on the provider. `baseUrl?`
addresses this invocation's server, overriding the provider's own. -/
def serve (provider : Provider) (spec : Models.Spec) (baseUrl? : Option String := none) :
    Result Model := do
  let route ← Result.fromExcept Error.input (provider.route spec.name)
  Result.fromExcept Error.input (check provider spec route)
  let env (var : String) : Result (Option String) :=
    Result.fromIO Error.environment do pure ((← IO.getEnv var).filter (!·.isEmpty))
  let apiKey ← match (← env provider.keyVar), provider.defaultKey? with
    | some key, _ => pure key
    | none, some fallback => pure fallback
    | none, none => throw <| .environment s!"{provider.keyVar} is not set"
  let baseUrl ← match baseUrl?, provider.baseUrlVar? with
    | some url, _ => pure url
    | none, some var => pure ((← env var).getD provider.baseUrl)
    | none, none => pure provider.baseUrl
  pure <| ChatCompletions.model {
    provider := provider.name, baseUrl, apiKey, name := route.name, identity := spec.toJson
    params := spec.params, echoReasoning := spec.echoReasoning
    structuredOutput := route.structuredOutput, nativeBatching := route.nativeBatching }

/-- `--url` and `--port`: where this invocation's `dgx` server listens. -/
def endpointCli : Cli.Spec (Option Dgx.Endpoint) :=
  let endpoint : Cli.Value Dgx.Endpoint := ⟨"URL", fun url =>
    (Dgx.Endpoint.ofUrl url).mapError (s!"is not an endpoint: {·}")⟩
  (fun url? port? => match port? with
      | none => url?
      | some port => some { url?.getD {} with port })
    <$> Cli.flag? "url" endpoint "with --provider dgx: the server, e.g. spark.local:9000"
    <*> Cli.flag? "port" .nat "with --provider dgx: its port, overriding the one in --url"

end Alaya.Provider
