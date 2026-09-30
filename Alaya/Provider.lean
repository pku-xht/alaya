import Alaya.Cli
import Alaya.Provider.ChatCompletions
import Alaya.Provider.CloseAI
import Alaya.Provider.XMCP
import Alaya.Provider.Yunwu
import Alaya.Provider.Apiyi
import Alaya.Provider.Dgx

/-! The provider table: turns a `PROVIDER:NAME` spec from the command line into a bare provider
model. -/

namespace Alaya.Provider

/-- The providers a spec may name. -/
def names : Array String := #["yunwu", "closeai", "xmcp", "apiyi", "dgx"]

/-- Settings that only some providers accept, gathered from the command line. -/
structure Options where
  /-- Endpoint for `dgx`; `none` keeps the built-in address and honours `DGX_BASE_URL`. -/
  dgxEndpoint? : Option Dgx.Endpoint := none
  /-- `--echo-reasoning`; see `ChatCompletions.Config.echoReasoning`. -/
  echoReasoning : Bool := false
  deriving Repr, Inhabited

/-- `--url` and `--port`, which address the DGX Spark, and `--echo-reasoning`. -/
def Options.cli : Cli.Spec Options :=
  let endpoint : Cli.Value Dgx.Endpoint := ⟨"URL", fun url =>
    (Dgx.Endpoint.ofUrl url).mapError (s!"is not an endpoint: {·}")⟩
  (fun url? port? echoReasoning =>
      let dgxEndpoint? := match port? with
        | none => url?
        | some port => some { url?.getD {} with port }
      { dgxEndpoint?, echoReasoning })
    <$> Cli.flag? "url" endpoint "the DGX Spark endpoint, e.g. spark.local:9000"
    <*> Cli.flag? "port" .nat "the DGX Spark port, overriding the one in --url"
    <*> Cli.switch "echo-reasoning" "send the model its earlier reasoning back"

/-- Splits a `PROVIDER:NAME` spec. The model name may itself contain colons. -/
def splitSpec (spec : String) : String × String :=
  match spec.splitOn ":" with
  | provider :: rest => (provider, ":".intercalate rest)
  | [] => (spec, "")

/-- Resolves a `PROVIDER:NAME` spec into a bare provider model — no retry, batching, or cache. -/
def fromSpec (spec : String) (temperature : Float) (options : Options := {}) : Result Model :=
  let (provider, name) := splitSpec spec
  if name.isEmpty then
    throw <| .configuration s!"'{spec}' is not a PROVIDER:NAME spec (e.g. dgx:gpt-oss-120b)"
  else match provider with
    | "yunwu" => Yunwu.model name temperature (echoReasoning := options.echoReasoning)
    | "closeai" => CloseAI.model name temperature (echoReasoning := options.echoReasoning)
    | "xmcp" => XMCP.model name temperature (echoReasoning := options.echoReasoning)
    | "apiyi" => Apiyi.model name temperature (echoReasoning := options.echoReasoning)
    | "dgx" => Dgx.model name temperature options.dgxEndpoint? (echoReasoning := options.echoReasoning)
    | other =>
      throw <| .configuration s!"unknown provider: {other} (use {"|".intercalate names.toList})"

/-- The model a continuation samples from, as the command line names it. -/
structure Choice where
  spec : String
  temperature : Float := 0.0
  options : Options := {}
  deriving Repr, Inhabited

def Choice.cli : Cli.Spec Choice :=
  Choice.mk
    <$> Cli.flag "model" (.string "P:M") s!"the model, PROVIDER:NAME, PROVIDER one of {"|".intercalate names.toList}"
    <*> Cli.flagD "temperature" .float 0.0 "the sampling temperature" (shown := "0")
    <*> Options.cli

end Alaya.Provider
