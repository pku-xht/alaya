import Lean.Data.Json
import Alaya.Error

/-! Where shell commands run: in a container, with the working directory bind-mounted (see
`Alaya.Executor.Docker`, the one implementation). Nothing an agent or a grader asks for runs on
the host. The command semantics are described in `docs/miniswe.md` §7. -/

namespace Alaya

open Alaya (Result Error)

/-- The result of executing one command. -/
structure Output where
  /-- Stdout and stderr, merged, as far as the command got. -/
  output : String
  /-- The exit status, or `none` when the command did not run to completion: it could not be
  started, or it was killed at the timeout. -/
  exitCode? : Option UInt32 := none
  /-- Why there is no exit status, when there is none. -/
  error? : Option String := none
  deriving Repr, Inhabited, BEq

namespace Output

/-- The observation a shell agent records. -/
def toJson (o : Output) : Lean.Json :=
  .mkObj [("output", o.output),
          ("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null),
          ("error", o.error?.map Lean.Json.str |>.getD .null)]

def fromJson? (json : Lean.Json) : Option Output := do
  let output ← (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
  let exitCode? := (json.getObjVal? "exit_code" >>= Lean.Json.getNat?).toOption.map (·.toUInt32)
  let error? := (json.getObjVal? "error" >>= Lean.Json.getStr?).toOption
  pure { output, exitCode?, error? }

end Output

/-- The `uname` fields of the machine commands run on. -/
structure Uname where
  system : String
  release : String
  version : String
  machine : String
  deriving Repr, Inhabited, BEq

namespace Executor

/-- How commands are run: how long one may take, and what is added to its environment. -/
structure Config where
  /-- Per-command wall-clock timeout in seconds; 0 disables it. -/
  timeoutSeconds : Nat := 30
  /-- Environment overrides layered onto the inherited environment. -/
  env : Array (String × String) := #[]
  deriving Inhabited

end Executor

/-- Where commands run. `exec` runs a shell script (the argv's first element; the rest are its
positional arguments) in a working directory with stderr merged; `display` is the command as it
appears in messages. -/
structure Executor where
  exec : (workDir : System.FilePath) -> (argv : Array String) -> (display : String) -> IO Output
  /-- `uname` where the commands run. -/
  uname : IO Uname
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

/-- The observation for a command that could not be run at all. -/
def failed (message : String) : Output :=
  { output := "", error? := some message }

/-- Runs one string command as a shell script. -/
def bash (executor : Executor) (workDir : System.FilePath) (command : String) : IO Output :=
  executor.exec workDir #[command] command

end Executor
end Alaya
