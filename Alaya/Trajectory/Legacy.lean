import Alaya.Trajectory
import Alaya.Cas.Legacy

/-! Explicit migration of extracted legacy trajectories. Normal reads never consult the old
raw-object store. The old objects, refs, archive, and model cache are kept unchanged. -/

namespace Alaya.Trajectory.Legacy

open Cas (Store Hash)

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

private def readState (store : Store) (hash : Hash) : Result State := do
  let bytes ← Cas.Legacy.getBytes store hash
  let text ← Cas.Git.text bytes
  let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
  Result.fromExcept Error.storage (State.fromJson json)

private def mappingRef (hash : Hash) : String := "refs/alaya-legacy/state/" ++ hash.hex

private def savedMapping? (store : Store) (hash : Hash) : Result (Option Hash) := do
  let text ← Cas.Git.text (← store.git #["for-each-ref", "--format=%(objectname)", mappingRef hash])
  let value := text.trimAscii.toString
  if value.isEmpty then return none
  if !Cas.validHex value then throw <| .storage s!"invalid legacy state mapping for {hash.hex}"
  pure (some ⟨value⟩)

/-- Import parents first, without altering any recorded event or provenance field. -/
private partial def importState (store : Store) (hash : Hash) (ancestors : Array Hash)
    (mappings : IO.Ref (Array (Hash × Hash))) : Result Hash := do
  if ancestors.contains hash then
    throw <| .storage s!"cycle in legacy state parent chain at {hash.hex}"
  if let some (_, imported) := (← io mappings.get).find? (fun entry => entry.1 == hash) then
    return imported
  -- Validate the original state even when a previous import has a mapping. A corrupt source
  -- must not be reported as successfully imported merely because native objects survived.
  let state ← readState store hash
  let parent? ← state.parent?.mapM fun parent =>
    importState store parent (ancestors.push hash) mappings
  let workspace ← Cas.Legacy.importSnapshot store state.workspace
  let evaluation? ← state.evaluation?.mapM fun evaluation => do
    let evidence? ← evaluation.evidence?.mapM (Cas.Legacy.importSnapshot store)
    pure { evaluation with evidence? }
  let migrated := { state with parent?, workspace, evaluation? }
  let imported ← putState store migrated
  if let some previous ← savedMapping? store hash then
    if previous != imported then
      throw <| .storage s!"legacy state mapping changed for {hash.hex}: {previous.hex} -> {imported.hex}"
  let _ ← store.git #["update-ref", mappingRef hash, imported.hex]
  io <| mappings.modify (·.push (hash, imported))
  pure imported

/-- Migrate every legacy `state.*` ref plus its ancestors. Original raw files remain in place.
The returned mapping includes ancestors that were reachable without their own state ref. -/
def importStates (store : Store) : Result (Array (Hash × Hash)) := do
  let refs := store.root / "refs"
  if !(← io refs.pathExists) then
    throw <| .storage s!"no legacy refs directory: {refs}"
  let mappings ← io <| IO.mkRef #[]
  let entries := (← io refs.readDir).qsort fun a b => compare a.fileName b.fileName == .lt
  for entry in entries do
    if !entry.fileName.startsWith "state." then continue
    let hash : Hash := ⟨(← io <| IO.FS.readFile entry.path).trimAscii.toString⟩
    if hash.hex.length != 64 || !Cas.validHex hash.hex || entry.fileName != "state." ++ hash.hex then
      throw <| .storage s!"invalid legacy state ref: {entry.path}"
    let _ ← importState store hash #[] mappings
  pure ((← io mappings.get).qsort fun a b => compare a.1.hex b.1.hex == .lt)

/-- A reviewable, deterministic old/new address list; not a replay or a rewritten archive. -/
def mappingJson (mappings : Array (Hash × Hash)) : Lean.Json :=
  .mkObj [
    ("version", 1),
    ("states", .arr (mappings.map fun (old, imported) =>
      .mkObj [("legacy", old.hex), ("state", imported.hex)]))]

/-- Import an extracted data directory and atomically publish its complete address mapping.
A failure can leave reusable native objects, but never a newly written success manifest. -/
def importData (data : System.FilePath) : Result (Array (Hash × Hash)) := do
  let store ← Store.create (data / "store")
  let mappings ← importStates store
  io <| store.atomicWrite (data / "legacy-import.json") (mappingJson mappings).pretty.toUTF8
  pure mappings

end Alaya.Trajectory.Legacy
