import Test.Support.Container

/-! What suites need from the machine beyond Lean, each with how to tell it is missing. A pure
suite needs none of them, and runs anywhere. -/

namespace Testing

/-- A program on the path, by what `--version` (or `args`) says when it runs. -/
private def program (cmd : String) (args : Array String := #["--version"]) : IO (Option String) := do
  match ← (IO.Process.output { cmd, args }).toBaseIO with
  | .ok out => pure (if out.exitCode == 0 then none else some s!"`{cmd}` exits {out.exitCode}")
  | .error _ => pure (some s!"`{cmd}` is not installed")

/-- A docker daemon, and the test image in it. -/
def docker : Need := { name := "docker", problem? := dockerProblem? }

/-- The restic binary, which keeps workspaces. -/
def restic : Need := { name := "restic", problem? := program "restic" #["version"] }

/-- Node, which runs the report's script in a fake DOM. -/
def node : Need := { name := "node", problem? := program "node" }

/-- The newest modification time of the Lean sources under `dir`. -/
private partial def newestSource (dir : System.FilePath) : IO IO.FS.SystemTime := do
  let mut newest : IO.FS.SystemTime := ⟨0, 0⟩
  for entry in ← dir.readDir do
    let metadata ← entry.path.metadata
    let time ← if metadata.type == .dir then newestSource entry.path
      else if entry.path.extension == some "lean" then pure metadata.modified else pure ⟨0, 0⟩
    if time > newest then newest := time
  pure newest

/-- The `alaya` binary as `lake build alaya` leaves it, built after its sources last changed:
a test of a stale binary tests old code. -/
def binary : Need where
  name := "the alaya binary"
  problem? := do
    let path : System.FilePath := ".lake" / "build" / "bin" / "alaya"
    if !(← path.pathExists) then return some "not built: `lake build alaya`"
    let built := (← path.metadata).modified
    let sources ← newestSource "Alaya"
    let main := (← ("Main.lean" : System.FilePath).metadata).modified
    if built < sources || built < main then return some "older than its sources: `lake build alaya`"
    pure none

end Testing
