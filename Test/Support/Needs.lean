import Test.Support.Container

/-! What suites need from the machine beyond Lean, each with how to tell it is missing. A pure
suite needs none of them, and runs anywhere. -/

namespace Testing

/-- A program on the path, by what `--version` (or `args`) says when it runs. -/
private def program (cmd : String) (args : Array String := #["--version"]) : IO (Option String) := do
  match ← (IO.Process.output { cmd, args }).toBaseIO with
  | .ok out => pure (if out.exitCode == 0 then none else some s!"`{cmd}` is missing or fails (exit {out.exitCode})")
  | .error _ => pure (some s!"`{cmd}` is not installed")

/-- A docker daemon, and the test image in it. -/
def docker : Need := { name := "docker", problem? := dockerProblem? }

/-- The restic binary, which keeps workspaces. -/
def restic : Need := { name := "restic", problem? := program "restic" #["version"] }

/-- Node, which runs the report's script in a fake DOM. -/
def node : Need := { name := "node", problem? := program "node" }

/-- The `alaya` binary as `lake build alaya` leaves it, up to date with its sources, as Lake
judges by their contents: a test of a stale binary tests old code. File times would not do, as a
build restored from a cache is older than the sources checked out after it. -/
def binary : Need where
  name := "the alaya binary"
  problem? := do
    if !(← (".lake" / "build" / "bin" / "alaya" : System.FilePath).pathExists) then
      return some "not built: `lake build alaya`"
    let built ← IO.Process.output { cmd := "lake", args := #["build", "alaya", "--no-build"] }
    if built.exitCode == 0 then return none
    return some s!"older than its sources: `lake build alaya` ({built.exitCode})"

end Testing
