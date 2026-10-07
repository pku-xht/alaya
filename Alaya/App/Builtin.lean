import Alaya.App.Catalog
import Alaya.Agents.Basic
import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Agents.Grader
import Alaya.Agents.HelpStudy

/-! What Alaya itself offers: its programs, the agents and the grader; the models it knows, with
their defaults; and the providers that serve them. An application of its own builds on
`catalog`, adding to it or leaving it out. -/

namespace Alaya.App.Builtin

open Alaya.Base Alaya.LLM Alaya.Agents

def basic : Program := .ofFields Basic.routine Basic.fields {}
def miniSwe : Program := .ofFields MiniSwe.routine MiniSwe.fields {}
def miniVero : Program := .ofFields MiniVero.routine MiniVero.fields {}
def grader : Program := .ofFields Grader.routine Grader.fields {}

def helpStudy : Program := .ofFields HelpStudy.routine HelpStudy.fields {}
def helpProbe : Program :=
  { routine := HelpStudy.probe, complete := fun json =>
      if json == Lean.Json.mkObj [] then .ok json else .error "help-probe accepts no configuration" }

def programs : Array Program := #[basic, miniSwe, miniVero, grader, helpStudy, helpProbe]

/-- The models a person can name, with their defaults. -/
def models : Array Models.Spec := #[
  { name := "gpt-oss-120b", contextTokens? := some 131072 },
  { name := "gpt-5.6-luna" },
  -- OpenAI's light GPT-6, released 2026-09-22: 1,050,000 tokens of context, of which up to
  -- 128,000 may be output. An OpenAI reasoning model, so it keeps its reasoning across tool
  -- calls only through the Responses API, which returns it as encrypted items to send back.
  { name := "gpt-6-luna", echoReasoning := .items, contextTokens? := some 1050000,
    outputTokens? := some 128000 },
  -- A thinking-mode DeepSeek model: with tool calls, its API rejects a request whose earlier
  -- assistant messages lack their reasoning, and a gateway may need it on every reasoned turn
  -- to reconstruct the conversation. 1,000,000 tokens of context, per DeepSeek's documentation.
  { name := "deepseek-v4.1-flash", echoReasoning := .text, contextTokens? := some 1000000 }]

/-- The providers a person can name with `--provider`. -/
def providers : Array Provider.Provider := #[
  { name := "yunwu", baseUrl := "https://yunwu.ai/v1", baseUrlVar? := some "YUNWU_BASE_URL",
    keyVar := "YUNWU_API_KEY" },
  { name := "closeai", baseUrl := "https://api.openai-proxy.org/v1", keyVar := "CLOSEAI_API_KEY" },
  { name := "xmcp", baseUrl := "https://llm.xmcp.ltd", keyVar := "XMCP_API_KEY"
    routes := [("deepseek-v4.1-flash", { name := "ds/deepseek-flash" }),
      ("gpt-5.6-luna", { name := "closeai/gpt-5.6-luna" })] },
  { name := "apiyi", baseUrl := "https://api.apiyi.com/v1", baseUrlVar? := some "APIYI_BASE_URL",
    keyVar := "APIYI_API_KEY"
    routes := [("gpt-6-luna", { name := "gpt-6-luna", api := .responses })] },
  { name := "fireworks", baseUrl := "https://api.fireworks.ai/inference/v1",
    baseUrlVar? := some "FIREWORKS_BASE_URL", keyVar := "FIREWORKS_API_KEY", anyModel := false
    routes := [("deepseek-v4.1-flash", { name := "accounts/fireworks/models/deepseek-v4p1-flash" })] },
  -- A DGX Spark's vLLM server, which needs no credential; `--url`/`--port` address it.
  { name := "dgx", baseUrl := ({} : Provider.Dgx.Endpoint).baseUrl, baseUrlVar? := some "DGX_BASE_URL",
    keyVar := "DGX_API_KEY", defaultKey? := some "EMPTY" }]

/-- Alaya's catalog: its programs, models and providers. -/
def catalog : Catalog := { programs, models, providers }

end Alaya.App.Builtin
