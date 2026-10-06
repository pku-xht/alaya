import Lean.Data.Json
import Alaya.Executor

/-! A call of a program: its name, and its arguments — its configuration, an agent's model and
task among it, and, when a person calls it, where its commands run. Every program is called the
same way. A call is the opening in the log, so every later command builds the same program from
the log alone. See `docs/agent-api.md` §9. -/

namespace Alaya

open Lean (Json)

/-- Where a call's commands run: a pinned image, and the path the workspace is mounted at. -/
structure Environment where
  image : String
  workdir : String
  deriving Inhabited, BEq

def Environment.toJson (environment : Environment) : Json :=
  .mkObj [("image", environment.image), ("workdir", environment.workdir)]

def Environment.fromJson (json : Json) : Except String Environment := do
  pure { image := ← json.getObjVal? "image" >>= Json.getStr?
         workdir := ← json.getObjVal? "workdir" >>= Json.getStr? }

/-- What a program is called with: its configuration, and, when a person calls it, where its
commands run. A program a program calls, a sub-agent, runs where its caller's commands do, and
is given its configuration alone. -/
structure ProgramArguments where
  /-- The program's complete configuration, an agent's model and task among it. -/
  config : Json
  environment? : Option Environment := none
  deriving Inhabited

def ProgramArguments.toJson (arguments : ProgramArguments) : Json :=
  .mkObj ([("config", arguments.config)] ++
    (arguments.environment?.map fun environment => ("environment", environment.toJson)).toList)

def ProgramArguments.fromJson (json : Json) : Except String ProgramArguments := do
  let environment? ← match json.getObjVal? "environment" with
    | .ok environment => some <$> Environment.fromJson environment
    | .error _ => pure none
  pure { config := ← json.getObjVal? "config", environment? }

end Alaya
