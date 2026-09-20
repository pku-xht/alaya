import Alaya.Error

/-! Binary-safe Git execution without a shell. Repository-local configuration applies;
ambient repository/index overrides and global configuration do not. -/

namespace Alaya.Cas.Git

structure Output where
  exitCode : UInt32
  stdout : ByteArray
  stderr : String

/-- Do not inherit Git's repository, object-directory, index, config, or tracing overrides.
Only executable lookup and the platform's process-launch environment are passed through. -/
private def environment : IO (Array (String × Option String)) := do
  let mut env := #[
    ("LC_ALL", some "C"), ("GIT_CONFIG_NOSYSTEM", some "1"),
    ("GIT_CONFIG_GLOBAL", some "/dev/null"), ("GIT_CONFIG_SYSTEM", some "/dev/null"),
    ("GIT_ATTR_NOSYSTEM", some "1"), ("GIT_TERMINAL_PROMPT", some "0"),
    ("GIT_ALLOW_PROTOCOL", some "file")]
  for key in #["PATH", "SystemRoot", "SYSTEMROOT", "TMPDIR", "TEMP", "TMP"] do
    if let some value ← IO.getEnv key then env := env.push (key, some value)
  pure env

def run (args : Array String) (input : ByteArray := .empty) : Result Output :=
  Result.fromIO Error.storage do
    let child ← IO.Process.spawn {
      cmd := "git", args, inheritEnv := false, env := ← environment
      stdin := .piped, stdout := .piped, stderr := .piped }
    let (stdin, child) ← child.takeStdin
    let stdout ← IO.asTask child.stdout.readBinToEnd .dedicated
    let stderr ← IO.asTask child.stderr.readToEnd .dedicated
    -- The task owns stdin, so returning from it closes the pipe before wait.
    let writer ← IO.asTask (do stdin.write input; stdin.flush) .dedicated
    let exitCode ← child.wait
    let out ← IO.ofExcept stdout.get
    let err ← IO.ofExcept stderr.get
    if exitCode == 0 then let _ ← IO.ofExcept writer.get
    pure { exitCode, stdout := out, stderr := err }

def checked (args : Array String) (input : ByteArray := .empty) : Result ByteArray := do
  let out ← run args input
  if out.exitCode != 0 then
    throw <| .storage s!"git {args[0]?.getD ""} failed ({out.exitCode}): {out.stderr}"
  pure out.stdout

def text (bytes : ByteArray) : Result String :=
  match String.fromUTF8? bytes with
  | some text => pure text
  | none => throw <| .storage "Git returned invalid UTF-8 metadata"

end Alaya.Cas.Git
