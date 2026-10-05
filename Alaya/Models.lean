import Alaya.Agents.Config
import Alaya.Error
import Alaya.Settings

/-!
The models a run can use, independent of who serves them. A model is named by its ID as its
creator publishes it (`gpt-oss-120b`, `deepseek-v4.1-flash`), and its defaults are in this
table. A run names one (`new --model NAME`), overrides any field on the command line
(`--set model.FIELD=VALUE`), and the run's configuration holds the complete spec, from which every later
command builds the same model again, through whichever provider serves it (`Alaya.Provider`).
-/

namespace Alaya.Models

open Alaya (Result Error)

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

private def orNull (value? : Option Nat) : Lean.Json := value?.map (fun n => (n : Lean.Json)) |>.getD .null

/-- The complete spec, every field written. -/
def Spec.toJson (spec : Spec) : Lean.Json :=
  .mkObj [("name", spec.name), ("params", spec.params),
    ("echo_reasoning", toString spec.echoReasoning), ("context_tokens", orNull spec.contextTokens?),
    ("output_tokens", orNull spec.outputTokens?)]

private def natOrNull (object : Agents.ConfigJson.Object) (key : String) (default : Option Nat) :
    Except String (Option Nat) := do
  match ← object.field? key with
  | none => pure default
  | some .null => pure none
  | some value => match value.getNat? with
    | .ok n => pure (some n)
    | .error _ => throw s!"'{key}' must be a non-negative integer or null, not {value.compress}"

/-- Reads a spec over `defaults`: a field left out is the default's, an unknown one is an error,
and `params` must be an object with none of `protectedParams`. -/
def Spec.fromJson (json : Lean.Json) (defaults : Spec) : Except String Spec := do
  let object ← Agents.ConfigJson.object json #["name", "params", "echo_reasoning", "context_tokens", "output_tokens"]
  let params ← match ← object.field? "params" with
    | none => pure defaults.params
    | some params@(.obj _) => pure params
    | some other => throw s!"'params' must be an object of request fields, not {other.compress}"
  for key in protectedParams do
    if (params.getObjVal? key).isOk then throw s!"params cannot set '{key}': alaya sets it itself"
  pure {
    name := defaults.name, params
    echoReasoning := ← match ← object.field? "echo_reasoning" with
      | none => pure defaults.echoReasoning
      | some (.str name) => match Echo.all.find? (toString · == name) with
        | some echo => pure echo
        | none => throw s!"'echo_reasoning' must be none, text or items, not {name}"
      | some other => throw s!"'echo_reasoning' must be none, text or items, not {other.compress}"
    contextTokens? := ← natOrNull object "context_tokens" defaults.contextTokens?
    outputTokens? := ← natOrNull object "output_tokens" defaults.outputTokens? }

/-- The models alaya knows, with their defaults. A size left `none` is not known; `--set`
gives it. -/
def all : Array Spec := #[
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

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Spec := all.find? (·.name == name)

/-- The spec a recorded or given configuration describes, or what is wrong with it. -/
def read (json : Lean.Json) : Except String Spec := do
  let name ← match json.getObjVal? "name" with
    | .ok (.str name) => pure name
    | _ => throw s!"a model needs a \"name\": one of {names}"
  let some defaults := named? name
    | throw s!"unknown model: {name} (use {names})"
  match Spec.fromJson json defaults with
  | .ok spec => pure spec
  | .error message => throw s!"{name}: {message}"

/-- `read`, as a command reads a configuration: what is wrong with it is the caller's to fix. -/
def fromJson (json : Lean.Json) : Result Spec :=
  Result.fromExcept Error.input (read json)

/-- The model `name` with the model's settings applied over its complete defaults. -/
def resolve (name : String) (settings : Array Settings.Setting) : Result Spec := do
  let defaults ← fromJson (.mkObj [("name", name)])
  match Settings.apply .model defaults.toJson settings with
  | .ok json => fromJson json
  | .error message => throw <| .input message

end Alaya.Models
