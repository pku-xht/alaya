import Alaya.Hash
import Alaya.Error

/-!
Where the versions of a run's workspace are kept.

A log names a version of the workspace by an identifier and never looks inside it: the driver
and the commands of a person ask to snapshot a directory, to write a snapshot back out, to say
what changed between two snapshots, to read one file of one, and to copy some into a new store. `Workspaces` is that contract,
and `Workspaces.Restic` keeps it with a restic repository. See `docs/log-schema.md` §5.
-/

namespace Alaya

namespace Workspaces

/-- Accepts only clean relative paths: no absolute roots and no empty, `.`, or `..` components.
Anything else must be rejected before it reaches a filesystem join, where an absolute path
replaces the directory entirely and `..` leaves it. -/
def safeRelativePath (path : String) : Bool :=
  !path.startsWith "/" && (path.splitOn "/").all fun name =>
    !name.isEmpty && name != "." && name != ".."

inductive ChangeKind where
  | added
  | removed
  | modified
  deriving BEq, Repr, Inhabited

/-- One path that differs between two snapshots. An added or removed directory stands for its
whole subtree; `modified` is only reported for files and links. -/
structure Change where
  kind : ChangeKind
  /-- `/`-separated, relative to the snapshot's root. -/
  path : String
  directory : Bool := false
  deriving BEq, Repr, Inhabited

/-- The kind of an entry in an immutable workspace snapshot. Links are never directories. -/
inductive EntryKind where
  | directory | file | symlink | other
  deriving BEq, Repr, Inhabited

def EntryKind.toString : EntryKind -> String
  | .directory => "directory"
  | .file => "file"
  | .symlink => "symlink"
  | .other => "other"

/-- Metadata for an immediate child of a directory, without reading its content. -/
structure Entry where
  name : String
  path : String
  kind : EntryKind
  /-- Byte count for regular files; unavailable metadata remains `none`. -/
  size : Option Nat := none
  deriving BEq, Repr, Inhabited

/-- Browser paths are portable, clean relative paths. The empty path names the snapshot root.
Backslashes, drive/stream colons, and NUL cannot reach platform-dependent filesystem joins. -/
def safeSnapshotPath (path : String) : Bool :=
  (path.isEmpty || safeRelativePath path) &&
    !path.contains '\\' && !path.contains ':' && !path.contains '\x00'

end Workspaces

/-- A store of directory snapshots. An identifier is 64 hexadecimal digits and means something
only to the store that issued it: equal directories need not get equal identifiers, and no
caller compares them. A snapshot keeps at least the contents of a directory's regular files,
their executable bits, its symbolic links, and its directory structure. -/
structure Workspaces where
  /-- Captures `directory` as it is now. The snapshot is kept until `retainOnly` drops it. -/
  snapshot : System.FilePath -> Result Snapshot
  /-- Makes `directory` hold exactly the snapshot, replacing whatever is there. -/
  materialize : Snapshot -> System.FilePath -> Result Unit
  /-- What changed from the first snapshot to the second, ordered by path. -/
  diff : Snapshot -> Snapshot -> Result (Array Workspaces.Change)
  /-- The bytes of the regular file at each path, in order; `none` where the snapshot has no
  such file. Several at once, because a store may pay per request rather than per file. -/
  readFiles : Snapshot -> Array String -> Result (Array (Option ByteArray))
  /-- Immediate directory entries, including hidden entries, from the named snapshot. `""`
  names its root. Never materializes a live workspace. Callers verify each ancestor is a
  directory before following a requested path (`entryAt`). -/
  listEntries : Snapshot -> String -> Result (Array Workspaces.Entry)
  /-- Drops every snapshot not listed, and reclaims their space. -/
  retainOnly : Array Snapshot -> Result Unit
  /-- Makes `location`, where no store is yet, a store of the same kind that holds these
  snapshots, and gives the identifier each has there, in order. Only these are copied, and the
  store opened at `location` reads them by the new identifiers. -/
  transfer : Array Snapshot -> System.FilePath -> Result (Array Snapshot)

namespace Workspaces

/-- The bytes of the regular file at `path`; `none` when there is no such file. -/
def readFile? (workspaces : Workspaces) (id : Snapshot) (path : String) : Result (Option ByteArray) := do
  pure ((← workspaces.readFiles id #[path])[0]?.join)

/-- The entry at `path` in snapshot `id`, found by listing each ancestor in turn: a symbolic link
on the way is never followed, even when its target is inside the snapshot. The empty path is the
snapshot's root. -/
def entryAt (workspaces : Workspaces) (id : Snapshot) (path : String) : Result Entry := do
  if !safeSnapshotPath path then
    throw <| .input s!"not a clean relative path in a snapshot: {path}"
  if path.isEmpty then return { name := "", path := "", kind := .directory }
  let mut directory := ""
  let parts := (path.splitOn "/").toArray
  let mut found : Entry := default
  for index in [:parts.size] do
    let name := parts[index]!
    let expected := if directory.isEmpty then name else directory ++ "/" ++ name
    let entries ← workspaces.listEntries id directory
    let some entry := entries.find? fun entry => entry.name == name && entry.path == expected
      | throw <| .input s!"no such path in the snapshot: {path}"
    if index + 1 < parts.size && entry.kind != .directory then
      throw <| .input s!"the snapshot path crosses a non-directory: {expected}"
    found := entry
    directory := expected
  pure found

/-- The entries of the directory at `path` in snapshot `id`, by name. -/
def list (workspaces : Workspaces) (id : Snapshot) (path : String := "") : Result (Array Entry) := do
  let entry ← workspaces.entryAt id path
  if entry.kind != .directory then
    throw <| .input s!"not a directory in the snapshot: {path}"
  pure ((← workspaces.listEntries id path).qsort (·.name < ·.name))

/-- The bytes of the regular file at `path` in snapshot `id`. A link is not followed. -/
def read (workspaces : Workspaces) (id : Snapshot) (path : String) : Result ByteArray := do
  let entry ← workspaces.entryAt id path
  if entry.kind != .file then
    throw <| .input s!"not a regular file in the snapshot ({entry.kind.toString}): {path}"
  let some bytes ← workspaces.readFile? id path
    | throw <| .storage s!"the snapshot file could not be read: {path}"
  pure bytes

/-- The largest file a preview shows, in bytes. -/
def previewBytes : Nat := 1024 * 1024

/-- What a reader may show of an entry: UTF-8 text up to `previewBytes` verbatim, and of
anything else only what it is. -/
structure Preview where
  /-- `text`, `binary`, `too_large`, `symlink`, `directory` or `other`. -/
  kind : String
  content? : Option String := none
  size? : Option Nat := none
  deriving BEq, Repr, Inhabited

/-- A preview of the entry at `path` in snapshot `id`. A link is described, never followed, and
only a regular file within the limit is read. -/
def preview (workspaces : Workspaces) (id : Snapshot) (path : String) : Result Preview := do
  let entry ← workspaces.entryAt id path
  match entry.kind with
  | .file =>
    let some size := entry.size
      | throw <| .storage s!"snapshot file has no size metadata: {path}"
    if size > previewBytes then return { kind := "too_large", size? := some size }
    let some bytes ← workspaces.readFile? id path
      | throw <| .storage s!"the snapshot file could not be read: {path}"
    let size? := some bytes.size
    if bytes.size > previewBytes then return { kind := "too_large", size? }
    if bytes.data.contains 0 then return { kind := "binary", size? }
    match String.fromUTF8? bytes with
    | some text => pure { kind := "text", content? := some text, size? }
    | none => pure { kind := "binary", size? }
  | kind => pure { kind := kind.toString, size? := entry.size }

/-- `path` with its symbolic links resolved, as far as it exists: the rest is appended as given,
so a directory that is yet to be created can be compared with ones that are there. -/
partial def resolved (path : System.FilePath) : IO System.FilePath := do
  if ← path.pathExists then IO.FS.realPath path
  else
    -- A bare relative name has no parent to climb to; the current directory is one.
    let here ← IO.currentDir
    let path := if path.isAbsolute then path else here / path
    match path.parent, path.fileName with
    | some parent, some name => pure ((← resolved parent) / name)
    | _, _ => pure path

/-- Whether one of the two paths is the other or lies inside it. -/
def overlap (a b : System.FilePath) : Bool :=
  let inside (inner outer : String) := inner == outer || inner.startsWith (outer ++ "/")
  inside a.toString b.toString || inside b.toString a.toString

/-- Refuses a directory that overlaps one of `kept`: snapshotting such a directory would
capture the storage itself, and materializing into it deletes what the snapshot does not
hold, which is that storage. Nothing is touched before the refusal. -/
def refuseOverlap (verb : String) (directory : System.FilePath) (kept : Array System.FilePath) :
    Result Unit := do
  let target ← Result.fromIO Error.storage (resolved directory)
  for path in kept do
    let path ← Result.fromIO Error.storage (resolved path)
    if overlap target path then
      throw <| .input <|
        s!"cannot {verb} {target}: it overlaps {path}, where alaya keeps this run. " ++
        "Use a directory outside the data directory, or a data directory (--data) outside it"

/-- Gives the owner write permission throughout `directory`, when it exists. Replacing a tree
means deleting from its directories, and tools leave read-only ones behind — Go's module cache
is one — that neither restic nor `rm -r` can empty. -/
def makeWritable (directory : System.FilePath) : Result Unit :=
  Result.fromIO Error.storage do
    if !(← directory.isDir) then return
    let out ← IO.Process.output { cmd := "chmod", args := #["-R", "u+w", directory.toString] }
    if out.exitCode != 0 then
      throw <| IO.userError s!"cannot make {directory} writable: {out.stderr.trimAscii}"

end Workspaces

end Alaya
