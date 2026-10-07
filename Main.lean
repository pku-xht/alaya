import Alaya

/-! `alaya`: Alaya's application, its commands over its own catalog. See `docs/cli.md`. -/

/-- Exit 0 when a command succeeded. `resume` exits, when no call runs, 0 when the last call
returned or was stopped and 1 when it failed; 3 when a call waits for a person, and 4 when it
paused at a limit. A failure exits with its class's status, above all of these (`Cli.exitFor`):
64 a command line that does not parse, 65 input, 69 environment, 74 storage, 75 transient, 76
model. -/
def main (argv : List String) : IO UInt32 :=
  (Alaya.App.Commands.app "alaya" Alaya.App.Builtin.catalog).run argv
