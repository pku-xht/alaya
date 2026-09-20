import Alaya.Cas.Store
import Alaya.Cas.Sha256

/-! Explicit conversion of historical raw SHA-256 objects to native Git objects.
Original blobs and reference files are read-only. Typed Git refs retain the conversion
results and make repeated imports stable, including the snapshot commit identifier. -/

namespace Alaya.Cas.Legacy

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

private def checkOldHash (hash : Hash) : Result Unit :=
  if hash.hex.length == 64 && validHex hash.hex then pure ()
  else throw <| .storage s!"invalid legacy SHA-256 address: {hash.hex}"

/-- Read and verify an original raw object; missing or corrupt content is an explicit error. -/
def getBytes (store : Store) (old : Hash) : Result ByteArray := do
  checkOldHash old
  let path := store.root / "blobs" / (old.hex.take 2).toString / old.hex
  if !(← io path.pathExists) then
    throw <| .storage s!"missing legacy raw object: {old.hex}"
  let bytes ← io <| IO.FS.readBinFile path
  if Sha256.sumHex bytes != old.hex then
    throw <| .storage s!"corrupt legacy raw object: {old.hex}"
  pure bytes

/-- Decode an original JSON tree without migrating or changing its address. -/
def getTree (store : Store) (old : Hash) : Result Tree := do
  let bytes ← getBytes store old
  let some text := String.fromUTF8? bytes
    | throw <| .storage s!"legacy tree is not UTF-8: {old.hex}"
  let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
  Result.fromExcept Error.storage (Tree.fromJson json)

private def mappingRef (kind : String) (old : Hash) : String :=
  s!"refs/alaya-legacy/{kind}/{old.hex}"

private def mapped? (store : Store) (old : Hash) (kind objectType : String) :
    Result (Option Hash) := do
  checkOldHash old
  let ref := mappingRef kind old
  let text ← store.gitText #["cat-file", "--batch-check=%(objectname) %(objecttype)"]
    (ref ++ "\n").toUTF8
  match text.trimAscii.toString.splitOn " " with
  | [_, "missing"] => pure none
  | [hex, actualType] =>
    if !validHex hex || actualType != objectType then
      throw <| .storage s!"invalid legacy {kind} mapping for {old.hex}"
    pure (some ⟨hex⟩)
  | _ => throw <| .storage s!"invalid legacy {kind} mapping response for {old.hex}"

private def saveMapping (store : Store) (old : Hash) (kind : String) (native : Hash) :
    Result Unit := do
  let _ ← store.git #["update-ref", mappingRef kind old, native.hex]
  pure ()

/-- Copy a verified raw blob to Git and retain the original-to-native mapping. -/
def importBlob (store : Store) (old : Hash) : Result Hash := do
  if let some hash ← mapped? store old "blob" "blob" then return hash
  let hash ← store.putBytes (← getBytes store old)
  saveMapping store old "blob" hash
  pure hash

private partial def importTreeWithEmpty (store : Store) (old : Hash) : Result (Hash × Bool) := do
  if let some hash ← mapped? store old "tree" "tree" then
    return (hash, (← store.getTree hash).entries.isEmpty)
  let tree ← getTree store old
  let mut entries := #[]
  for entry in tree.entries do
    if entry.name == ".git" then
      throw <| .storage s!"legacy tree {old.hex} contains .git; migrate the original repository separately"
    match entry.type with
    | .directory =>
      let (hash, empty) ← importTreeWithEmpty store entry.hash
      if !empty then entries := entries.push { entry with hash }
    | .gitlink =>
      throw <| .storage s!"legacy tree {old.hex} has an unsupported gitlink: {entry.name}"
    | _ =>
      entries := entries.push { entry with hash := ← importBlob store entry.hash }
  let hash ← store.putTree (Tree.ofEntries entries)
  saveMapping store old "tree" hash
  pure (hash, entries.isEmpty)

/-- Import a historical tree explicitly. Git metadata is rejected and empty directories
are omitted, matching the native Git snapshot contract. -/
def importTree (store : Store) (old : Hash) : Result Hash := do
  pure (← importTreeWithEmpty store old).1

/-- Import a historical workspace as a native commit. The retained mapping makes the
result stable across repeated calls even though commit timestamps are real timestamps. -/
def importSnapshot (store : Store) (old : Hash) : Result Hash := do
  if let some hash ← mapped? store old "snapshot" "commit" then return hash
  let hash ← store.commitTree (← importTree store old)
  saveMapping store old "snapshot" hash
  pure hash

end Alaya.Cas.Legacy
