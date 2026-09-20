import Lean.Data.Json

/-!
The API view of Git blobs, trees and snapshot commits. New identifiers are native Git object
IDs; the separate legacy importer accepts original raw SHA-256 addresses.

Because each directory is its own object referencing children by hash, an unchanged subtree
keeps its address across snapshots. Only changed content adds new objects, and diffing skips
identical subtrees. Git's index manages working-tree change detection.
-/

namespace Alaya.Cas

/-- A Git SHA-1/SHA-256 object ID or legacy SHA-256 address, in lowercase hexadecimal. -/
structure Hash where
  hex : String
  deriving BEq, Hashable, Repr, Inhabited

private def hexDigit (c : Char) : Bool :=
  c.isDigit || (97 <= c.toNat && c.toNat <= 102)

/-- A well-formed lowercase Git object ID. Anything else must be rejected before it reaches
the blob layout, where a hostile "digest" like `../../x` would escape the store root. -/
def validHex (hex : String) : Bool :=
  (hex.length == 40 || hex.length == 64) && hex.all hexDigit

/-- A valid single path component: what an `Entry` may be named. -/
def validName (name : String) : Bool :=
  !name.isEmpty && name != "." && name != ".." && !name.any (fun c => c == '/' || c == '\x00')

/-- Accepts only clean relative paths: no absolute roots and no empty, `.`, or `..`
components. Anything else must be rejected before it reaches a filesystem join, where an
absolute path replaces the destination directory entirely and `..` escapes it. -/
def safeRelativePath (path : String) : Bool :=
  !path.startsWith "/" && (path.splitOn "/").all validName

/-- What a tree entry names, and therefore what its hash addresses. -/
inductive EntryType where
  /-- A regular file; the hash addresses its content blob. -/
  | file
  /-- A regular file with the executable bit set; the hash addresses its content blob. -/
  | executable
  /-- A symbolic link; the hash addresses a blob holding the link target string. -/
  | symlink
  /-- A directory; the hash addresses its serialized `Tree` object. -/
  | directory
  /-- A submodule commit pointer. Git manages its separate checkout; Alaya does not recurse. -/
  | gitlink
  deriving BEq, Repr, Inhabited

def EntryType.tag : EntryType -> String
  | .file => "file"
  | .executable => "exec"
  | .symlink => "link"
  | .directory => "dir"
  | .gitlink => "gitlink"

def EntryType.fromTag : String -> Except String EntryType
  | "file" => pure .file
  | "exec" => pure .executable
  | "link" => pure .symlink
  | "dir" => pure .directory
  | "gitlink" => pure .gitlink
  | other => throw s!"unknown entry type: {other}"

/-- One name in a directory. -/
structure Entry where
  name : String
  type : EntryType
  hash : Hash
  deriving BEq, Repr, Inhabited

/-- One directory: its entries, kept sorted by name so the serialization — and therefore the
directory's content address — is canonical. -/
structure Tree where
  entries : Array Entry
  deriving BEq, Repr, Inhabited

namespace Tree

def empty : Tree := { entries := #[] }

/-- Builds a tree from entries, imposing the canonical name ordering. -/
def ofEntries (entries : Array Entry) : Tree :=
  { entries := entries.qsort fun a b => compare a.name b.name == .lt }

/-- The entry named `name`, found by binary search over the sorted entries. -/
def find? (tree : Tree) (name : String) : Option Entry :=
  tree.entries.binSearch { name, type := .file, hash := ⟨""⟩ }
    (fun a b => compare a.name b.name == .lt)

/-- A copy of the tree with `name` bound to `entry` (replacing any previous binding). -/
def insert (tree : Tree) (entry : Entry) : Tree :=
  ofEntries ((tree.entries.filter fun existing => existing.name != entry.name).push entry)

/-- A copy of the tree without `name`. -/
def erase (tree : Tree) (name : String) : Tree :=
  { entries := tree.entries.filter fun existing => existing.name != name }

def toJson (tree : Tree) : Lean.Json :=
  .arr <| tree.entries.map fun entry =>
    .mkObj [("name", entry.name), ("type", entry.type.tag), ("hash", entry.hash.hex)]

def fromJson (json : Lean.Json) : Except String Tree := do
  let array ← json.getArr?
  let entries ← array.mapM fun value => do
    let name ← value.getObjVal? "name" >>= Lean.Json.getStr?
    let tag ← value.getObjVal? "type" >>= Lean.Json.getStr?
    let hex ← value.getObjVal? "hash" >>= Lean.Json.getStr?
    if !validName name then throw s!"invalid entry name: {name}"
    if !validHex hex then throw s!"invalid hash for {name}: {hex}"
    pure ({ name, type := ← EntryType.fromTag tag, hash := ⟨hex⟩ } : Entry)
  let tree := ofEntries entries
  for i in [1:tree.entries.size] do
    if tree.entries[i - 1]!.name == tree.entries[i]!.name then
      throw s!"duplicate entry name: {tree.entries[i]!.name}"
  pure tree

end Tree

/-- One difference between two snapshots, as a `/`-separated path relative to their roots.
An added or removed directory stands for its whole subtree; `modified` is only emitted for
leaf entries (a changed file body, link target, type, or executable bit). -/
inductive Change where
  | added (path : String) (type : EntryType) (hash : Hash)
  | removed (path : String) (type : EntryType)
  | modified (path : String) (type : EntryType) (hash : Hash)
  deriving BEq, Repr, Inhabited

def Change.path : Change -> String
  | .added path _ _ => path
  | .removed path _ => path
  | .modified path _ _ => path

end Alaya.Cas
