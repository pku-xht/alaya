import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Agents.Grader
import Alaya.Call
import Alaya.Settings

/-!
The programs a call can name, and how a call's configuration builds one: the agents, and the
grader.

A program's defaults are in code, in its definition. A call names a program (`alaya call ENTRY
NAME`) and overrides any of its fields on the command line (`--set FIELD=VALUE`), and the
call's opening in the log holds the complete configuration, from which every later command
builds the same program again. There are no configuration files.
-/

namespace Alaya.Agents.Catalog

open Lean (Json)
open Alaya (Result Error Uname)

/-- A program built from its configuration: the complete configuration, the routines it calls,
which its call enters under their names — the tools it offers a model, its sub-agents, the steps
of its workflows — and the program itself, for a call with a task, if it has one, on a machine
described by a `uname`; or why the call does not fit it. -/
structure Built where
  config : Json
  routines : Array (Routine.Entry Agent)
  program : Option String → Uname → Except String (Program Agent Json)

/-- A program a call can name, and how a configuration builds it. -/
structure Definition where
  name : String
  /-- The program a configuration describes: one that names this program, with any of its fields
  left out for their defaults. -/
  make : Json → Except String Built

/-- What an agent needs: a model, in its configuration, and a task, from its call. -/
private def agentCall (name : String) (model? : Option Models.Spec) (task? : Option String)
    (k : Models.Spec → String → Program Agent Json) : Except String (Program Agent Json) :=
  match model?, task? with
  | some model, some task => .ok (k model task)
  | none, _ => .error s!"{name} samples a model: name it with --set model=NAME"
  | _, none => .error s!"{name} works on a task: give it with --task or --task-file"

def miniSwe : Definition := {
  name := "mini-swe"
  make := fun json => match MiniSwe.Config.fromJson json with
    | .ok config =>
      .ok { config := config.toJson, routines := config.offered.map (·.entry)
            program := fun task? uname => agentCall "mini-swe" config.model? task?
              fun model task => MiniSwe.program config model uname task }
    | .error problem => .error problem }

def miniVero : Definition := {
  name := "mini-vero"
  make := fun json => match MiniVero.Config.fromJson json with
    | .ok config =>
      .ok { config := config.toJson, routines := config.base.offered.map (·.entry)
            program := fun task? uname => agentCall "mini-vero" config.base.model? task?
              fun model task => MiniVero.program config model uname task }
    | .error problem => .error problem }

def grader : Definition := {
  name := "grader"
  make := fun json => match Grader.Config.fromJson json with
    | .ok config =>
      .ok { config := config.toJson, routines := #[]
            program := fun task? _ =>
              if task?.isSome then .error "the grader takes no task"
              else if config.command.trimAscii.isEmpty then
                .error "the grader needs its command, which prints TAP: --set command=CMD"
              else .ok (Grader.program config) }
    | .error problem => .error problem }

def all : Array Definition := #[miniSwe, miniVero, grader]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The program a configuration describes, or what is wrong with it. -/
def build (json : Json) : Except String Built :=
  match json.getObjVal? "name" with
  | .ok (.str name) => match named? name with
    | some definition => match definition.make json with
      | .ok built => .ok built
      | .error message => .error s!"{name}: {message}"
    | none => .error s!"unknown program: {name} (use {names})"
  | _ => .error s!"a program's configuration needs a \"name\": one of {names}"

/-- The complete configuration of the program a configuration describes, or what is wrong with
it: every field, those left out at their defaults. -/
def complete (json : Json) : Result Json :=
  match build json with
  | .ok built => pure built.config
  | .error message => throw <| .input message

/-- The complete configuration of `config` with `settings` applied over it, one after another,
each result completed before the next when it is complete on its own: so `model=NAME` is that
model's whole spec, which a later `model.params.FIELD=VALUE` changes a field of, while settings
that are complete only together (`tools` and `question_types`) may come one after the other.
The result is checked as a configuration: an unknown key, or a value of the wrong type, is an
error naming it. -/
def applying (config : Json) (settings : Array Settings.Setting) : Result Json := do
  let applied ← settings.foldlM (init := config) fun config setting =>
    match Settings.apply config setting with
    | .ok config => tryCatch (complete config) fun _ => pure config
    | .error message => throw <| .input message
  complete applied

/-- The complete configuration of the program `name` with `settings` over its defaults. -/
def resolve (name : String) (settings : Array Settings.Setting) : Result Json := do
  applying (← complete (.mkObj [("name", name)])) settings

/-- The programs a run calls, by name: each built from its call's arguments, with the routines it
enters. -/
def programs : Programs Agent := fun name => (named? name).map fun _ arguments =>
  match CallConfig.fromJson arguments with
  | .error problem => .error s!"the call's arguments: {problem}"
  | .ok call =>
    if call.name != name then .error s!"a call of {name} configures {call.name}" else
    match build call.program with
    | .error problem => .error problem
    | .ok built =>
      match built.program call.task? call.environment.uname with
      | .ok program => .ok (program, Routines.of built.routines)
      | .error problem => .error problem

end Alaya.Agents.Catalog
