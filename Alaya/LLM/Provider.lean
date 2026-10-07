import Alaya.LLM.Models
import Alaya.LLM.Provider.ChatCompletions
import Alaya.LLM.Provider.Responses
import Alaya.LLM.Provider.Dgx

/-!
Who serves a model: chosen per invocation (`resume --provider NAME`), never recorded. A provider
is data — its API key variable, its URL, and how it serves particular models — and serving a
model through one first checks the model's recorded requirements against what the provider
declares, so that changing providers either sends the model the same requests or fails before
any is sent. The agent may behave differently with different models; never with different
providers. Which providers a person can name is the app's (`Alaya.App.Catalog`).
-/

namespace Alaya.LLM.Provider

open Alaya.Base

/-- The API a route speaks. -/
inductive Api where
  | chatCompletions
  /-- OpenAI's Responses API: what keeps an OpenAI reasoning model's reasoning across turns. -/
  | responses
  deriving BEq, Repr, Inhabited

/-- Whether an API wants earlier reasoning sent back as text. -/
inductive EchoSupport where
  | required
  | accepted
  | rejected
  deriving BEq, Repr, Inhabited

/-- How a provider serves one model. -/
structure Route where
  /-- The provider's name for the model. -/
  name : String
  api : Api := .chatCompletions
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

/-- How `provider` serves `model`, or why it does not. -/
def Provider.route (provider : Provider) (model : String) : Except String Route :=
  match provider.routes.lookup model with
  | some route => pure route
  | none =>
    if provider.anyModel then pure { name := model }
    else throw s!"{provider.name} does not serve {model} (it serves {", ".intercalate (provider.routes.map (·.1))})"

/-- What a route must meet of a recorded model, or the first requirement it does not. -/
def check (provider : Provider) (spec : Models.Spec) (route : Route) : Except String Unit := do
  match route.api, spec.echoReasoning with
  | .chatCompletions, .items =>
    throw s!"this run sends {spec.name} its earlier reasoning items, which need the Responses API; {provider.name} serves {spec.name} through Chat Completions"
  | .responses, .text =>
    throw s!"this run sends {spec.name} its earlier reasoning as text, which the Responses API {provider.name} serves it through has no field for"
  | .chatCompletions, echo =>
    match route.reasoningEcho, echo with
    | .required, .none =>
      throw s!"{provider.name} needs {spec.name}'s earlier reasoning sent back, which this run does not do"
    | .rejected, .text =>
      throw s!"this run sends {spec.name} its earlier reasoning, which {provider.name} rejects"
    | _, _ => pure ()
  | .responses, _ => pure ()
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
  let http : Http.Config := { provider := provider.name, baseUrl, apiKey }
  pure <| match route.api with
    | .chatCompletions => ChatCompletions.model {
        http, name := route.name, identity := spec.toJson, params := spec.params
        echoReasoning := spec.echoReasoning == .text
        structuredOutput := route.structuredOutput, nativeBatching := route.nativeBatching }
    | .responses => Responses.model {
        http, name := route.name, identity := spec.toJson, params := spec.params
        echoItems := spec.echoReasoning == .items, structuredOutput := route.structuredOutput }

end Alaya.LLM.Provider
