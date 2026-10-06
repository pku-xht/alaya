import Lean.Data.Json
import Alaya.Executor

/-! A call: a program a person starts on a log, with what it is called with — its configuration,
an agent's model among it, its task when it takes one, and where its commands run. A call is
the arguments of its opening in the log, so every later command builds the same program from
the log alone. See `docs/agent-api.md` §9. -/

namespace Alaya

open Lean (Json)

/-- Where a call's commands run: a pinned image, the path the workspace is mounted at, and that
machine's `uname`, which an agent may tell its model. -/
structure Environment where
  image : String
  workdir : String
  uname : Uname
  deriving Inhabited, BEq

def Uname.toJson (uname : Uname) : Json :=
  .mkObj [("system", uname.system), ("machine", uname.machine)]

def Uname.fromJson (json : Json) : Except String Uname := do
  let field (name : String) := json.getObjVal? name >>= Json.getStr?
  pure { system := ← field "system", machine := ← field "machine" }

def Environment.toJson (environment : Environment) : Json :=
  .mkObj [("image", environment.image), ("workdir", environment.workdir),
    ("uname", environment.uname.toJson)]

def Environment.fromJson (json : Json) : Except String Environment := do
  pure { image := ← json.getObjVal? "image" >>= Json.getStr?
         workdir := ← json.getObjVal? "workdir" >>= Json.getStr?
         uname := ← json.getObjVal? "uname" >>= Uname.fromJson }

/-- What a program is called with. -/
structure CallConfig where
  /-- The program's complete configuration: its `name` and every field, an agent's model among
  them. -/
  program : Json
  /-- The task, for an agent. -/
  task? : Option String := none
  environment : Environment
  deriving Inhabited

/-- The program's name, as its configuration has it. -/
def CallConfig.name (config : CallConfig) : String :=
  (config.program.getObjVal? "name" >>= Json.getStr?).toOption.getD ""

def CallConfig.toJson (config : CallConfig) : Json :=
  .mkObj [("program", config.program), ("task", config.task?.map Json.str |>.getD .null),
    ("environment", config.environment.toJson)]

def CallConfig.fromJson (json : Json) : Except String CallConfig := do
  let task? ← match json.getObjVal? "task" with
    | .ok .null | .error _ => pure none
    | .ok task => some <$> task.getStr?
  pure { program := ← json.getObjVal? "program", task?
         environment := ← json.getObjVal? "environment" >>= Environment.fromJson }

end Alaya
