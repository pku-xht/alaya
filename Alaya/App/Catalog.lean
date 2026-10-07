import Alaya.Base.Fields
import Alaya.Base.Settings
import Alaya.LLM.Provider
import Alaya.Runtime.Agent

/-!
What an application offers a person by name: the programs a call can name, agents and graders;
the models an agent's configuration can name, with their defaults; and the providers that serve
them. A catalog is a value: Alaya's own is `Builtin.catalog`, and an application of its own adds
to it, or replaces it (`Commands.app`). A program is its routine, and how its configuration is
completed: a model named alone becomes its whole spec here, so a log holds complete specs and
reads back without the catalog.

A program's defaults are in code, in its definition. A call names a program (`alaya call ENTRY
NAME`) and overrides any of its fields on the command line (`--set FIELD=VALUE`), and the
call's opening in the log holds the name and the complete configuration, from which every later
command builds the same program again. There are no configuration files.
-/

namespace Alaya.App

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-- A program a call can name: the routine a call of it runs, and how its configuration is
completed, which the command line needs before any call is made. -/
structure Program where
  routine : Routine Agent
  /-- The complete configuration a configuration describes, every field it leaves out at its
  default, or what is wrong with it. -/
  complete : Json → Except String Json

def Program.name (program : Program) : String := program.routine.name

/-- The program of `routine`, its configuration read by `fields` over `defaults`. -/
def Program.ofFields (routine : Routine Agent) (fields : Fields σ) (defaults : σ) : Program :=
  { routine, complete := fun json => (fields.read json defaults).map fields.toJson }

/-- What an application offers by name: its programs, models and providers. -/
structure Catalog where
  programs : Array Program := #[]
  /-- The models a person can name, with their defaults. A size left `none` is not known;
  `--set` gives it. -/
  models : Array Models.Spec := #[]
  /-- The providers a person can name with `--provider`. -/
  providers : Array Provider.Provider := #[]

namespace Catalog

/-- `items` with `more` after them, an item of `more` in place of one of `items` of the same name. -/
private def overlay (items more : Array α) (name : α → String) : Array α :=
  items.filter (fun item => !more.any (name · == name item)) ++ more

/-- Two catalogs as one: the second's entries added to the first's, each in place of one of the
same name. -/
instance : Append Catalog where
  append a b := {
    programs := overlay a.programs b.programs (·.name)
    models := overlay a.models b.models (·.name)
    providers := overlay a.providers b.providers (·.name) }

def program? (catalog : Catalog) (name : String) : Option Program := catalog.programs.find? (·.name == name)
def programNames (catalog : Catalog) : String := ", ".intercalate (catalog.programs.map (·.name)).toList

def model? (catalog : Catalog) (name : String) : Option Models.Spec := catalog.models.find? (·.name == name)
def modelNames (catalog : Catalog) : String := ", ".intercalate (catalog.models.map (·.name)).toList

def provider? (catalog : Catalog) (name : String) : Option Provider.Provider := catalog.providers.find? (·.name == name)
def providerNames (catalog : Catalog) : String := ", ".intercalate (catalog.providers.map (·.name)).toList

/-- A configuration's `model` as a person gives it, completed: a name alone, or a name with the
fields it changes, over that model's defaults. A model the catalog does not name is refused by
name alone, and kept as it is written when its spec is whole, as a log holds it. -/
def completeModel (catalog : Catalog) (config : Json) : Except String Json :=
  match config.getObjVal? "model" with
  | .ok (.str name) => match catalog.model? name with
    | some spec => .ok (config.setObjVal! "model" spec.toJson)
    | none => .error s!"'model': unknown model: {name} (use {catalog.modelNames})"
  | .ok json@(.obj _) => match json.getObjVal? "name" with
    | .ok (.str name) => match catalog.model? name with
      | some defaults => match Models.Spec.fromJson json defaults with
        | .ok spec => .ok (config.setObjVal! "model" spec.toJson)
        | .error problem => .error s!"'model': {name}: {problem}"
      | none => .ok config
    | _ => .error s!"'model': a model needs a \"name\": one of {catalog.modelNames}"
  | _ => .ok config


/-- The complete configuration of the program `name` that `json` describes, or what is wrong
with it: every field, those left out at their defaults. -/
def complete (catalog : Catalog) (name : String) (json : Json) : Result Json :=
  match catalog.program? name with
  | none => throw <| .input s!"unknown program: {name} (use {catalog.programNames})"
  | some definition => match catalog.completeModel json >>= definition.complete with
    | .ok config => pure config
    | .error message => throw <| .input s!"{name}: {message}"

/-- The complete configuration of the program `name`, `config` with `settings` applied over it,
one after another, each result completed before the next when it is complete on its own: so
`model=NAME` is that model's whole spec, which a later `model.params.FIELD=VALUE` changes a field
of, while settings that are complete only together (`tools` and `question_types`) may come one
after the other. The result is checked as a configuration: an unknown key, or a value of the
wrong type, is an error naming it. -/
def applying (catalog : Catalog) (name : String) (config : Json) (settings : Array Settings.Setting) :
    Result Json := do
  let applied ← settings.foldlM (init := config) fun config setting =>
    match Settings.apply config setting with
    | .ok config => tryCatch (catalog.complete name config) fun _ => pure config
    | .error message => throw <| .input message
  catalog.complete name applied

/-- The programs a run calls: the session's scope. -/
def scope (catalog : Catalog) : Scope Agent := Scope.of (catalog.programs.map (·.routine))

/-- The complete configuration of the program `name` with `settings` over its defaults. -/
def resolve (catalog : Catalog) (name : String) (settings : Array Settings.Setting) : Result Json := do
  catalog.applying name (← catalog.complete name (.mkObj [])) settings

/-- How a person gives a field of a configuration on the command line. -/
private def givenAs : List (String × String) :=
  [("model", "--set model=NAME"), ("task", "--set task=TEXT or --set-file task=FILE"), ("command", "--set command=CMD")]

/-- Whether a call fits the program it names: what `alaya call` checks before it appends one. The
program says so itself: a call it cannot run on fails at once, with why. For a field its
configuration leaves empty, the command line adds how to give it. -/
def check (catalog : Catalog) (call : RoutineCall) : Except String Unit :=
  match catalog.program? call.name with
  | none => .error s!"unknown program: {call.name} (use {catalog.programNames})"
  | some definition => match catalog.completeModel call.arguments >>= definition.complete with
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

end Catalog

end Alaya.App
