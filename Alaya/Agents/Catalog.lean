import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Agents.Grader
import Alaya.Base.Settings
import Alaya.Runtime.Calls

/-!
The programs a call can name, and how a call's configuration builds one: the agents, and the
grader.

A program's defaults are in code, in its definition. A call names a program (`alaya call ENTRY
NAME`) and overrides any of its fields on the command line (`--set FIELD=VALUE`), and the
call's opening in the log holds the name and the complete configuration, from which every later
command builds the same program again. There are no configuration files.
-/

namespace Alaya.Agents.Catalog

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-- A program built from its configuration: the complete configuration, and its computation, or
why the configuration does not make one. -/
structure Built where
  config : Json
  computation : Except String (Computation Agent Json)

/-- A program a call can name: the routine a call of it runs, and how its configuration is read,
which the command line needs before any call is made. -/
structure Definition where
  routine : Routine Agent
  /-- The program a configuration describes, with any of its fields left out for their
  defaults. -/
  make : Json → Except String Built

def Definition.name (definition : Definition) : String := definition.routine.name

/-- The computation of a call of the program `name`, whose configuration `make` reads: its
arguments, the configuration; or why there is none. -/
private def computationOf (name : String) (make : Json → Except String Built) (arguments : Json) :
    Except String (Computation Agent Json) :=
  match make arguments with
  | .error problem => .error s!"{name}: {problem}"
  | .ok built => match built.computation with
    | .error problem => .error s!"{name}: {problem}"
    | .ok computation => .ok computation

/-- The program `name`, whose configuration `make` reads. Its routine's computation is the one
`make` builds from the call's configuration, failing in its frame when it does not fit; its scope
is `routines`, its tools, and itself, which a sub-agent calls. -/
def Definition.of (name : String) (make : Json → Except String Built)
    (routines : Array (Routine Agent) := #[]) : Definition :=
  let body (arguments : Json) : Computation Agent Json :=
    match computationOf name make arguments with
    | .ok computation => computation
    | .error problem => .fail problem
  { routine := { name, body, scope := Scope.fix fun scope => routines.push { name, body, scope } }
    make }

/-- What an agent needs of its configuration: a model, and a task. -/
private def agentCall (model? : Option Models.Spec) (task? : Option String)
    (k : Models.Spec → String → Computation Agent Json) : Except String (Computation Agent Json) :=
  match model?, task? with
  | some model, some task => .ok (k model task)
  | none, _ => .error s!"it samples a model: name it with --set model=NAME"
  | _, none => .error s!"it works on a task: give it with --set task=TEXT or --set-file task=FILE"

def miniSwe : Definition := .of "mini-swe" (routines := Tools.routines) fun json =>
  match MiniSwe.Config.fromJson json with
  | .ok config =>
    .ok { config := config.toJson
          computation := agentCall config.model? config.task? fun model task =>
            MiniSwe.computation config model task ("mini-swe", config.toJson) }
  | .error problem => .error problem

def miniVero : Definition := .of "mini-vero" (routines := Tools.routines) fun json =>
  match MiniVero.Config.fromJson json with
  | .ok config =>
    .ok { config := config.toJson
          computation := agentCall config.base.model? config.base.task? fun model task =>
            MiniVero.computation config model task ("mini-vero", config.toJson) }
  | .error problem => .error problem

def grader : Definition := .of "grader" fun json =>
  match Grader.Config.fromJson json with
  | .ok config =>
    .ok { config := config.toJson
          computation :=
            if config.command.trimAscii.isEmpty then
              .error "it needs its command, which prints TAP: --set command=CMD"
            else .ok (Grader.computation config) }
  | .error problem => .error problem

def all : Array Definition := #[miniSwe, miniVero, grader]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The program `name` as the configuration `json` describes it, or what is wrong with it. -/
def build (name : String) (json : Json) : Except String Built :=
  match named? name with
  | some definition => match definition.make json with
    | .ok built => .ok built
    | .error message => .error s!"{name}: {message}"
  | none => .error s!"unknown program: {name} (use {names})"

/-- The complete configuration of the program `name` that `json` describes, or what is wrong
with it: every field, those left out at their defaults. -/
def complete (name : String) (json : Json) : Result Json :=
  match build name json with
  | .ok built => pure built.config
  | .error message => throw <| .input message

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

/-- The complete configuration of the program `name` with `settings` over its defaults. -/
def resolve (name : String) (settings : Array Settings.Setting) : Result Json := do
  applying name (← complete name (.mkObj [])) settings

/-- Whether a call fits the program it names: what `alaya call` checks before it appends one. -/
def check (call : RoutineCall) : Except String Unit :=
  match named? call.name with
  | none => .error s!"unknown program: {call.name} (use {names})"
  | some definition => match computationOf definition.name definition.make call.arguments with
    | .ok _ => .ok ()
    | .error problem => .error problem

/-- The programs a run calls: the run's scope. -/
def scope : Scope Agent := Scope.of (all.map (·.routine))

/-- The run of the catalog's programs. -/
def run : Routine Agent := session scope

end Alaya.Agents.Catalog
