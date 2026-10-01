import Alaya.Error

/-!
One writer at a time in a directory: an exclusive `flock` on `DIR/lock`, held while a command
writes and released when it ends. The operating system drops the lock when the process exits,
however it exits, so a crash or a kill leaves none behind. A second writer is refused at once,
not made to wait: a command that would block for as long as another `resume` runs is better told
so. Readers take no lock.
-/

namespace Alaya

/-- An exclusive hold on a directory. Keep it until the writing is done, then `release` it. -/
structure Lock where
  private handle : IO.FS.Handle

namespace Lock

private def lockFile (dir : System.FilePath) : System.FilePath := dir / "lock"

/-- Who holds the lock: written by the holder alone, since a process that has not got the lock
must not touch what the holder wrote. -/
private def holderFile (dir : System.FilePath) : System.FilePath := dir / "lock.holder"

/-- Takes the lock on `dir`, which must exist, or fails with `Error.busy` naming the process that
holds it. -/
def acquire (dir : System.FilePath) : Result Lock := do
  let io {α} (action : IO α) : Result α := Result.fromIO Error.storage action
  -- Append, which creates the file and never truncates it.
  let handle ← io (IO.FS.Handle.mk (lockFile dir) .append)
  if !(← io handle.tryLock) then
    let holder ← io do
      try pure (some (← IO.FS.readFile (holderFile dir)).trimAscii.toString) catch _ => pure none
    let who := match holder with
      | some pid => if pid.isEmpty then "another alaya command" else s!"another alaya command (pid {pid})"
      | none => "another alaya command"
    throw <| .busy s!"the data directory {dir} is in use by {who}: try again when it ends"
  io (IO.FS.writeFile (holderFile dir) s!"{← (IO.Process.getPID : BaseIO UInt32)}\n")
  pure { handle }

def release (lock : Lock) : Result Unit :=
  Result.fromIO Error.storage lock.handle.unlock

end Lock

end Alaya
