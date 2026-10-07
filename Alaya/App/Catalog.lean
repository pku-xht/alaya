import Alaya.Agents.Basic
import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Agents.HelpStudy
import Alaya.Agents.Grader
import Alaya.Base.Settings
import Alaya.LLM.Provider

/-!
What this installation offers a person by name: the programs a call can name, the agents and
the grader; the models an agent's configuration can name, with their defaults; and the
providers that serve them. A program is its agent's routine, and how its configuration is
completed: a model named alone becomes its whole spec here, so a log holds complete specs and
reads back without this list.

A program's defaults are in code, in its definition. A call names a program (`alaya call ENTRY
NAME`) and overrides any of its fields on the command line (`--set FIELD=VALUE`), and the
call's opening in the log holds the name and the complete configuration, from which every later
command builds the same program again. There are no configuration files.
-/

namespace Alaya.App.Catalog

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.Agents

open Lean (Json)

/-- A program a call can name: the routine a call of it runs, as its agent defines it, and how
its configuration is completed, which the command line needs before any call is made. -/
structure Definition where
  routine : Routine Agent
  /-- The complete configuration a configuration describes, every field it leaves out at its
  default, or what is wrong with it. -/
  complete : Json → Except String Json

def Definition.name (definition : Definition) : String := definition.routine.name

/-! ## Models and providers -/

/-- The models a person can name, with their defaults. A size left `none` is not known;
`--set` gives it. -/
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

def modelNames : String := ", ".intercalate (models.map (·.name)).toList

def model? (name : String) : Option Models.Spec := models.find? (·.name == name)

/-- The providers a person can name with `--provider`. -/
def providers : Array Provider.Provider := #[
  { name := "yunwu", baseUrl := "https://yunwu.ai/v1", baseUrlVar? := some "YUNWU_BASE_URL",
    keyVar := "YUNWU_API_KEY" },
  { name := "closeai", baseUrl := "https://api.openai-proxy.org/v1", keyVar := "CLOSEAI_API_KEY" },
  { name := "xmcp", baseUrl := "https://llm.xmcp.ltd", keyVar := "XMCP_API_KEY"
    routes := [("deepseek-v4.1-flash", { name := "ds/deepseek-v4-flash" }),
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

def providerNames : String := ", ".intercalate (providers.map (·.name)).toList

def provider? (name : String) : Option Provider.Provider := providers.find? (·.name == name)

/-- A configuration's `model` as a person gives it, completed: a name alone, or a name with the
fields it changes, over that model's defaults. A model this list does not name is refused by
name alone, and kept as it is written when its spec is whole, as a log holds it. -/
def completeModel (config : Json) : Except String Json :=
  match config.getObjVal? "model" with
  | .ok (.str name) => match model? name with
    | some spec => .ok (config.setObjVal! "model" spec.toJson)
    | none => .error s!"'model': unknown model: {name} (use {modelNames})"
  | .ok json@(.obj _) => match json.getObjVal? "name" with
    | .ok (.str name) => match model? name with
      | some defaults => match Models.Spec.fromJson json defaults with
        | .ok spec => .ok (config.setObjVal! "model" spec.toJson)
        | .error problem => .error s!"'model': {name}: {problem}"
      | none => .ok config
    | _ => .error s!"'model': a model needs a \"name\": one of {modelNames}"
  | _ => .ok config

/-! ## Programs -/

def basic : Definition :=
  { routine := Basic.routine, complete := fun json => (Basic.Config.fromJson json).map (·.toJson) }

def miniSwe : Definition :=
  { routine := MiniSwe.routine, complete := fun json => (MiniSwe.Config.fromJson json).map (·.toJson) }

def miniVero : Definition :=
  { routine := MiniVero.routine, complete := fun json => (MiniVero.Config.fromJson json).map (·.toJson) }

def grader : Definition :=
  { routine := Grader.routine, complete := fun json => (Grader.Config.fromJson json).map (·.toJson) }

def helpStudy : Definition :=
  { routine := HelpStudy.routine, complete := fun json => (HelpStudy.Config.fromJson json).map (·.toJson) }

def helpProbe : Definition :=
  { routine := HelpStudy.probe, complete := fun json =>
      if json == Lean.Json.mkObj [] then .ok json else .error "help-probe accepts no configuration" }

def all : Array Definition := #[basic, miniSwe, miniVero, grader, helpStudy, helpProbe]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The complete configuration of the program `name` that `json` describes, or what is wrong
with it: every field, those left out at their defaults. -/
def complete (name : String) (json : Json) : Result Json :=
  match named? name with
  | none => throw <| .input s!"unknown program: {name} (use {names})"
  | some definition => match completeModel json >>= definition.complete with
    | .ok config => pure config
    | .error message => throw <| .input s!"{name}: {message}"

/-- The complete configuration of the program `name`, `config` with `settings` applied over it,
one after another, each result completed before the next when it is complete on its own: so
`model=NAME` is that model's whole spec, which a later `model.params.FIELD=VALUE` changes a field
of, while settings that are complete only together (`tools` and `question_types`) may come one
after the other. The result is checked as a configuration: an unknown key, or a value of the
wrong type, is an error naming it. -/
def applying (name : String) (config : Json) (settings : Array Settings.Setting) : Result Json := do
  let applied ← settings.foldlM (init := config) fun config setting =>
    match Settings.apply config setting with
    | .ok config => tryCatch (complete name config) fun _ => pure config
    | .error message => throw <| .input message
  complete name applied

/-- The programs a run calls: the session's scope. -/
def scope : Scope Agent := Scope.of (all.map (·.routine))

/-- The complete configuration of the program `name` with `settings` over its defaults. -/
def resolve (name : String) (settings : Array Settings.Setting) : Result Json := do
  applying name (← complete name (.mkObj [])) settings

/-- How a person gives a field of a configuration on the command line. -/
private def givenAs : List (String × String) :=
  [("model", "--set model=NAME"), ("task", "--set task=TEXT or --set-file task=FILE"), ("command", "--set command=CMD")]

/-- Whether a call fits the program it names: what `alaya call` checks before it appends one. The
program says so itself: a call it cannot run on fails at once, with why. For a field its
configuration leaves empty, the command line adds how to give it. -/
def check (call : RoutineCall) : Except String Unit :=
  match named? call.name with
  | none => .error s!"unknown program: {call.name} (use {names})"
  | some definition => match completeModel call.arguments >>= definition.complete with
    | .error message => .error s!"{call.name}: {message}"
    | .ok config => match definition.routine.body config with
      | .fail failure =>
        let empty (field : String) := match config.getObjVal? field with
          | .ok .null | .ok (.str "") => true
          | _ => false
        match givenAs.find? fun (field, _) => empty field with
        | some (_, flag) => .error s!"{failure.reason}: give it with {flag}"
        | none => .error failure.reason
      | _ => .ok ()

end Alaya.App.Catalog
