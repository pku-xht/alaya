import Lean.Data.Json
import Alaya.Base.Error

/-! Where shell commands run: in a container, with the working directory bind-mounted (see
`Alaya.Runtime.Executor.Docker`, the one implementation). Nothing an agent or a grader asks for runs on
the host. The command semantics are described in `docs/agents.md` §4.4. -/

namespace Alaya.Runtime

open Alaya.Base

/-- The result of executing one command. -/
structure Output where
  /-- Stdout and stderr, merged, as far as the command got; stdout alone when the command was run
  with its stderr apart. -/
  output : String
  /-- Stderr, when the command was run with it apart. -/
  stderr? : Option String := none
  /-- The exit status, or `none` when the command did not run to completion: it could not be
  started, or it was killed at the timeout. -/
  exitCode? : Option UInt32 := none
  /-- Why there is no exit status, when there is none, in words an agent may be shown: they say
  nothing of the machine the command ran on. -/
  error? : Option String := none
  /-- What the machine said, when the command could not be run: for whoever reads the log, and
  never shown to an agent. -/
  detail? : Option String := none
  deriving Repr, Inhabited, BEq

namespace Output

/-- Why there is no exit status, for whoever reads the log: the error, and what the machine
said. -/
def failure? (o : Output) : Option String :=
  o.error?.map fun error => match o.detail? with
    | some detail => s!"{error}: {detail}"
    | none => error

/-- An output as the log keeps it. `detail` is there only when the command could not be run. -/
def toJson (o : Output) : Lean.Json :=
  .mkObj ([("output", (o.output : Lean.Json)),
           ("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null),
           ("error", o.error?.map Lean.Json.str |>.getD .null)] ++
          (o.stderr?.map fun stderr => ("stderr", Lean.Json.str stderr)).toList ++
          (o.detail?.map fun detail => ("detail", Lean.Json.str detail)).toList)

def fromJson? (json : Lean.Json) : Option Output := do
  let output ← (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
  let exitCode? := (json.getObjVal? "exit_code" >>= Lean.Json.getNat?).toOption.map (·.toUInt32)
  let error? := (json.getObjVal? "error" >>= Lean.Json.getStr?).toOption
  let detail? := (json.getObjVal? "detail" >>= Lean.Json.getStr?).toOption
  let stderr? := (json.getObjVal? "stderr" >>= Lean.Json.getStr?).toOption
  pure { output, stderr?, exitCode?, error?, detail? }

end Output

/-- What an agent may tell its model of where its commands run: the system and the
architecture, which are the image's. The kernel's release and version are left out: a container
has its host's kernel, so they would say which machine a run was created on. -/
structure Uname where
  system : String
  machine : String
  deriving Repr, Inhabited, BEq

def Uname.toJson (uname : Uname) : Lean.Json :=
  .mkObj [("system", uname.system), ("machine", uname.machine)]

def Uname.fromJson (json : Lean.Json) : Except String Uname := do
  let field (name : String) := json.getObjVal? name >>= Lean.Json.getStr?
  pure { system := ← field "system", machine := ← field "machine" }

/-- Where a call's commands run: a pinned image, and the path the workspace is mounted at. A
call names one as data (`RoutineCall.environment?`), which the driver reads as this. -/
structure Environment where
  image : String
  workdir : String
  deriving Inhabited, BEq

def Environment.toJson (environment : Environment) : Lean.Json :=
  .mkObj [("image", environment.image), ("workdir", environment.workdir)]

def Environment.fromJson (json : Lean.Json) : Except String Environment := do
  let field (name : String) := json.getObjVal? name >>= Lean.Json.getStr?
  pure { image := ← field "image", workdir := ← field "workdir" }

namespace Executor

/-- How a command is run: how long it may take, and what is added to its environment. Part of
the command, so it is recorded with it. -/
structure Config where
  /-- Wall-clock timeout in seconds; 0 disables it. -/
  timeoutSeconds : Nat := 30
  /-- Environment overrides layered onto the inherited environment. -/
  env : Array (String × String) := #[]
  /-- Whether the command sees the whole output of every earlier command of its branch, as
  files under `/alaya/outputs`; without it, that directory is empty. -/
  outputs : Bool := false
  /-- Whether stderr is merged into stdout, as an agent's commands have it; apart, it is kept
  beside stdout, as a grader's TAP needs. -/
  merge : Bool := true
  deriving Inhabited, BEq, Repr

def Config.toJson (config : Config) : Lean.Json :=
  .mkObj [("timeout_seconds", (config.timeoutSeconds : Lean.Json)),
          ("env", .arr (config.env.map fun (name, value) => .arr #[.str name, .str value])),
          ("outputs", config.outputs), ("merge", config.merge)]

def Config.fromJson (json : Lean.Json) : Except String Config := do
  let timeoutSeconds ← json.getObjVal? "timeout_seconds" >>= Lean.Json.getNat?
  let env ← (← json.getObjVal? "env" >>= Lean.Json.getArr?).mapM fun
    | .arr #[.str name, .str value] => pure (name, value)
    | other => throw s!"expected a [name, value] pair of strings, got {other.compress}"
  let outputs ← json.getObjVal? "outputs" >>= Lean.Json.getBool?
  let merge ← json.getObjVal? "merge" >>= Lean.Json.getBool?
  pure { timeoutSeconds, env, outputs, merge }

end Executor

/-- Where commands run. `exec` runs a shell script (the argv's first element; the rest are its
positional arguments) as `config` says, in a working directory; `display` is
the command as it appears in messages. -/
structure Executor where
  exec : (config : Executor.Config) -> (workDir : System.FilePath) -> (argv : Array String) ->
    (display : String) -> IO Output
  /-- Releases what the executor holds — a container, say — at the end of a run. -/
  close : IO Unit := pure ()

namespace Executor

/-- Decodes UTF-8, replacing each byte that does not start a valid character with U+FFFD. -/
def lossyDecodeUtf8 (bytes : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < bytes.size do
    match bytes.utf8DecodeChar? i with
    | some c =>
      out := out.push c
      i := i + c.utf8Size
    | none =>
      out := out.push '�'
      i := i + 1
  return out

/-- The observation for a command killed at the timeout, with what it printed before. -/
def timedOut (output display : String) (timeoutSeconds : Nat) : Output :=
  { output, error? := some s!"'{display}' timed out after {timeoutSeconds} seconds" }

/-- What an agent is told of a command that could not be run at all. -/
def couldNotRun : String := "the command could not be run"

/-- The observation for a command that could not be run at all. `message` is the machine's own
— docker's, with its container, its image, its paths — and is kept as the detail: the agent is
told only that the command could not be run. -/
def failed (message : String) : Output :=
  { output := "", error? := some couldNotRun, detail? := some message }

/-- Runs one string command as a shell script. -/
def bash (executor : Executor) (config : Config) (workDir : System.FilePath) (command : String) :
    IO Output :=
  executor.exec config workDir #[command] command

end Executor
end Alaya.Runtime
