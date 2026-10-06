import Alaya.Base.Lock
import Alaya.Runtime.Store
import Alaya.Runtime.Workspaces.Restic

/-! The data directory: the forest of a set of runs, the workspaces their logs name, and the model
cache they sample through. Its layout is in `docs/log-schema.md` §5. A command opens it with
`Data.with`, which gives the command a scratch directory of its own. -/

namespace Alaya.Runtime

open Alaya.Base Alaya.Core

/-- An open data directory. -/
structure Data where
  path : System.FilePath
  store : Store
  workspaces : Workspaces
  /-- This command's scratch, `tmp/<id>`: its work directory, a grader's checkout, restic's
  restores. Nothing in it lasts past the command, and no other command shares it. -/
  scratch : System.FilePath

namespace Data

def cache (data : Data) : System.FilePath := data.path / "cache"

/-- Opens the data directory at `path` for one command and runs `f` on it. Only a new one is
created (`create`): otherwise it must exist, so a wrong path is an error rather than an empty
forest. A command that writes (`write`) holds the directory's lock throughout, so it is the only
writer, and is refused at once when another has it; one that only reads takes no lock. The
command's scratch directory is removed when it ends, however it ends. -/
def «with» (path : System.FilePath) (f : Data → Result α) (write := false) (create := false) :
    Result α := do
  if !create && !(← Result.fromIO Error.storage (path / "entries").isDir) then
    throw <| .input s!"no data directory at {path}"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  let lock? ← if write then some <$> Lock.acquire path else pure none
  try
    let store ← Store.create (path / "entries")
    let id := s!"{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}"
    let scratch := path / "tmp" / id
    Result.fromIO Error.storage (IO.FS.createDirAll scratch)
    try
      -- The entries and the model cache are as much the run as the repository is.
      let workspaces ← Workspaces.Restic.open (path / "restic") (scratch / "restic")
        (keep := #[store.dir, path / "cache"])
      f { path, store, workspaces, scratch }
    finally
      Workspaces.makeWritable scratch
      Result.fromIO Error.storage (IO.FS.removeDirAll scratch)
  finally
    if let some lock := lock? then lock.release

/-- The entry a reference names, and the forest. -/
def resolve (data : Data) (reference : String) : Result (Forest × Hash) := do
  let forest ← data.store.forest
  let hash ← Result.fromExcept Error.input (forest.resolve reference)
  pure (forest, hash)

/-- The log at the entry a reference names, read whole. -/
def entriesAt (data : Data) (reference : String) : Result (Forest × Hash × Array Entry) := do
  let (forest, hash) ← data.resolve reference
  pure (forest, hash, ← data.store.entries forest hash)

/-- The workspace a log has reached at its end. -/
def snapshotOf (entries : Array Entry) : Result Snapshot := do
  match workspace? (entries.map (·.event)) with
  | some snapshot => pure snapshot
  | none => throw <| .storage "the log names no workspace"

end Data

end Alaya.Runtime
