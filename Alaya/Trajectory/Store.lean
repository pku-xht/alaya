import Alaya.Hash
import Alaya.Error

/-! Where a trajectory's states are kept: a directory with one file per state, `<hash>.json`,
named by the SHA-256 of its bytes. A state never changes, so there is nothing to lock, and the
set of files *is* the forest. -/

namespace Alaya.Trajectory

structure Store where
  dir : System.FilePath

namespace Store

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

private def extension : String := ".json"

private def file (store : Store) (hash : Hash) : System.FilePath :=
  store.dir / (hash.hex ++ extension)

/-- Opens the store at `dir`, creating the directory if needed. -/
def create (dir : System.FilePath) : Result Store := io do
  IO.FS.createDirAll dir
  pure { dir }

/-- Stores `bytes` under their hash and returns it; nothing is written when they are already
there. The write is a rename of a finished temporary file, so a crash leaves no partial state
and concurrent writers of the same state are harmless. -/
def put (store : Store) (bytes : ByteArray) : Result Hash := io do
  let hash := Hash.ofBytes bytes
  let destination := store.file hash
  if ← destination.pathExists then return hash
  let temporary := store.dir / s!".{hash.hex}.{← IO.monoNanosNow}.tmp"
  IO.FS.writeBinFile temporary bytes
  IO.FS.rename temporary destination
  pure hash

/-- The bytes stored under `hash`, or `none`. -/
def get? (store : Store) (hash : Hash) : Result (Option ByteArray) := io do
  if !Hash.valid hash.hex then return none
  let path := store.file hash
  if ← path.pathExists then pure (some (← IO.FS.readBinFile path)) else pure none

/-- The hash of every stored state, sorted. -/
def list (store : Store) : Result (Array Hash) := io do
  let hashes := (← store.dir.readDir).filterMap fun entry =>
    let name := entry.fileName
    let hex := (name.dropEnd extension.length).toString
    if name.endsWith extension && Hash.valid hex then some (⟨hex⟩ : Hash) else none
  pure (hashes.qsort fun a b => a.hex < b.hex)

/-- Removes the state stored under `hash`; succeeds whether or not it was there. -/
def delete (store : Store) (hash : Hash) : Result Unit := io do
  if !Hash.valid hash.hex then return
  let path := store.file hash
  if ← path.pathExists then IO.FS.removeFile path

end Store

end Alaya.Trajectory
