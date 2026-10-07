import Alaya.Base.Fields
import Alaya.Base.Error

/-!
A model, independent of who serves it: its spec, what a run records. A model is named by its ID
as its creator publishes it (`gpt-oss-120b`, `deepseek-v4.1-flash`), and a call holds its
complete spec, from which every later command builds the same model again, through whichever
provider serves it (`Alaya.LLM.Provider`). Which models a person can name, with their defaults,
is the app's (`Alaya.App.Catalog`).
-/

namespace Alaya.LLM.Models

open Alaya.Base

/-- What of a model's earlier reasoning each request sends back. -/
inductive Echo where
  /-- Nothing: each turn's reasoning is the model's alone. -/
  | none
  /-- The reasoning as text, as DeepSeek's thinking mode requires: every earlier assistant
  message gets a `reasoning_content`, its recorded trace as received, or the empty string. -/
  | text
  /-- The Responses API's reasoning items, opaque and encrypted, as they were received: how an
  OpenAI reasoning model keeps its chain of thought across tool calls. -/
  | items
  deriving BEq, Repr, Inhabited

def Echo.all : List Echo := [.none, .text, .items]

instance : ToString Echo where
  toString | .none => "none" | .text => "text" | .items => "items"

/-- Which model, independent of who serves it: what a run records. -/
structure Spec where
  /-- The model's ID as its creator publishes it, with no provider prefix. -/
  name : String
  /-- Request fields that change the model's behaviour (`temperature`, `reasoning_effort`, …),
  merged into every request as they are. A field left out takes the provider's default. -/
  params : Lean.Json := .mkObj []
  /-- What of its earlier reasoning the model is sent back. -/
  echoReasoning : Echo := .none
  /-- The model's context window, in tokens; not sent to the API. -/
  contextTokens? : Option Nat := none
  /-- The longest response the model returns, in tokens; not sent to the API. -/
  outputTokens? : Option Nat := none
  deriving Inhabited

/-- Request fields that Alaya sets itself, which `params` may not. -/
def protectedParams : Array String :=
  #["model", "messages", "tools", "tool_choice", "response_format", "n", "stream"]

/-- A spec's fields, each written whole: its name, its request fields, what of its reasoning it
is sent back, and its sizes, `null` where not known. -/
def Spec.fields : Fields Spec := #[
  .of "name" .string (·.name) fun v s => { s with name := v },
  .of "params" .object (·.params) fun v s => { s with params := v },
  .of "echo_reasoning" (.enum toString Echo.all) (·.echoReasoning) fun v s => { s with echoReasoning := v },
  .of "context_tokens" (.option .nat) (·.contextTokens?) fun v s => { s with contextTokens? := v },
  .of "output_tokens" (.option .nat) (·.outputTokens?) fun v s => { s with outputTokens? := v }]

/-- The complete spec, every field written. -/
def Spec.toJson (spec : Spec) : Lean.Json := Spec.fields.toJson spec

/-- Reads a spec over `defaults`: a field left out is the default's, an unknown one is an error,
and `params` may set none of `protectedParams`. -/
def Spec.fromJson (json : Lean.Json) (defaults : Spec) : Except String Spec := do
  let spec ← Spec.fields.read json defaults
  for key in protectedParams do
    if (spec.params.getObjVal? key).isOk then throw s!"params cannot set '{key}': alaya sets it itself"
  pure spec

/-- A spec as a configuration or a log holds it: its name, and the fields it sets, each one left
out at the spec's own default. No list of models is consulted: the spec is what is written,
whoever wrote it. -/
def Spec.read (json : Lean.Json) : Except String Spec := do
  let name ← match json.getObjVal? "name" with
    | .ok (.str name) => pure name
    | _ => throw "a model needs a \"name\""
  Spec.fromJson json { name }

/-- A spec as a configuration holds it: whole, with its name. -/
def Spec.codec : Codec Spec where
  write := Spec.toJson
  read json := (Spec.read json).mapError (s!"must be a model's spec: {·}")

end Alaya.LLM.Models
