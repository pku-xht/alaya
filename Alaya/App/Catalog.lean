import Alaya.Agents.MiniSwe
import Alaya.Agents.MiniVero
import Alaya.Agents.Grader
import Alaya.Base.Settings
import Alaya.Runtime.Walk

/-!
The programs a call can name, and how a call's configuration builds one: the agents, and the
grader.

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

def miniSwe : Definition :=
  { routine := MiniSwe.routine, complete := fun json => (MiniSwe.Config.fromJson json).map (·.toJson) }

def miniVero : Definition :=
  { routine := MiniVero.routine, complete := fun json => (MiniVero.Config.fromJson json).map (·.toJson) }

def grader : Definition :=
  { routine := Grader.routine, complete := fun json => (Grader.Config.fromJson json).map (·.toJson) }

def all : Array Definition := #[miniSwe, miniVero, grader]

def names : String := ", ".intercalate (all.map (·.name)).toList

def named? (name : String) : Option Definition := all.find? (·.name == name)

/-- The complete configuration of the program `name` that `json` describes, or what is wrong
with it: every field, those left out at their defaults. -/
def complete (name : String) (json : Json) : Result Json :=
  match named? name with
  | none => throw <| .input s!"unknown program: {name} (use {names})"
  | some definition => match definition.complete json with
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
  | some definition => match definition.complete call.arguments with
    | .error message => .error s!"{call.name}: {message}"
    | .ok config => match definition.routine.body config with
      | .fail problem =>
        let empty (field : String) := match config.getObjVal? field with
          | .ok .null | .ok (.str "") => true
          | _ => false
        match givenAs.find? fun (field, _) => empty field with
        | some (_, flag) => .error s!"{problem}: give it with {flag}"
        | none => .error problem
      | _ => .ok ()

/-! ## The session

A run that `alaya new` starts is a call of `session`: in its frame, `session`, it waits for a
person to call a program, calls it in a frame of its own (`session/mini-swe`), and when the call
ends waits for the next. Whether a run waits for a call, whether a call runs, and which call a
stop ends are what the session makes of them; the runtime knows none of it. -/

/-- The run of programs of `scope`: it waits for a person to call one, calls it, and waits
again. A call's failure, or its break, is the call's: the run goes on to wait for the next. -/
def session (scope : Scope Agent) : Routine Agent where
  name := "session"
  body _ := iter (fun (_ : Unit) => do
    match ← await (one := true) fun _ notice => notice matches .called _ with
    | .called call :: _ => Computation.call call fun _ => pure (.inl ())
    | _ => throw "the wait for a call ended without one") ()
  scope

/-- The programs a run calls: the session's scope. -/
def scope : Scope Agent := Scope.of (all.map (·.routine))

/-- What a run's call may name: the session over the programs, or a program alone. -/
def run : Scope Agent := Scope.of (#[session scope] ++ all.map (·.routine))

/-- The call that starts a run of `alaya new`. -/
def sessionCall : RoutineCall := { name := "session", arguments := .null }

/-- The session's frame. -/
def sessionFrame : Frame := #[{ name := "session" }]

/-- Whether the run waits for a person to call a program: the session waits, with no question. -/
def idle : Next Agent → Bool
  | .waits frame none => frame == sessionFrame
  | _ => false

/-- Whether a call of the session's runs where a log ends: what the run does next is in its frame
or inside it, the call opened already. -/
def running : Next Agent → Bool
  | .ask call => call.frame.size ≥ 2
  | .mark (.opened frame _) => frame.size > 2
  | .mark event => event.frame?.any (·.size ≥ 2)
  | .waits frame _ => frame.size ≥ 2
  | _ => false

/-- Whether a person may call a program where the run does `next`: only where the session waits
for one, no call running and none read yet. -/
def admitsCall (next : Next Agent) : Result Unit := do
  if running next then
    throw <| .input "a call is running: a program is called once it is over; `alaya stop` ends it first"
  if next matches .ended _ then throw <| .input "the run is over: it calls nothing more"
  if !idle next then throw <| .input "the run has a call to make here already: `alaya resume` makes it"

/-- Whether a person's notice — a message, a change, a reply — has a reader where the run does
`next`: only while a call runs. -/
def admitsNotice (next : Next Agent) : Result Unit := do
  if !running next then
    throw <| .input "no call is running: nothing would read a notice appended here; append it at an entry before the call's end"

/-- The frame a stop ends by default: the session's call open at an entry, given the calls open
there, outermost first. -/
def callToStop (open' : Array OpenCall) : Result Frame := do
  let some call := open'.find? (·.frame.size == 2)
    | throw <| .input "no call is running: there is nothing to stop"
  pure call.frame

end Alaya.App.Catalog
