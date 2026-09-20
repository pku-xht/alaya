import Alaya.Hash
import Alaya.Error

/-!
Where a trajectory keeps the directories its states refer to.

A state names its workspace by an identifier and never looks inside it: the trajectory asks to
snapshot a directory, to write a snapshot back out, to say what changed between two snapshots,
and to read one file of one. `Workspaces` is that contract, and `Workspaces.Restic` keeps it
with a restic repository. See `docs/trajectory-schema.md` §5.
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

end Workspaces

/-- A store of directory snapshots. An identifier is 64 hexadecimal digits and means something
only to the store that issued it: equal directories need not get equal identifiers, and no
caller compares them. A snapshot keeps at least the contents of a directory's regular files,
their executable bits, its symbolic links, and its directory structure. -/
structure Workspaces where
  /-- Captures `directory` as it is now. The snapshot is kept until `retainOnly` drops it. -/
  snapshot : System.FilePath -> Result Hash
  /-- Makes `directory` hold exactly the snapshot, replacing whatever is there. -/
  materialize : Hash -> System.FilePath -> Result Unit
  /-- What changed from the first snapshot to the second, ordered by path. -/
  diff : Hash -> Hash -> Result (Array Workspaces.Change)
  /-- The bytes of the regular file at each path, in order; `none` where the snapshot has no
  such file. Several at once, because a store may pay per request rather than per file. -/
  readFiles : Hash -> Array String -> Result (Array (Option ByteArray))
  /-- Drops every snapshot not listed, and reclaims their space. -/
  retainOnly : Array Hash -> Result Unit

namespace Workspaces

/-- The bytes of the regular file at `path`; `none` when there is no such file. -/
def readFile? (workspaces : Workspaces) (id : Hash) (path : String) : Result (Option ByteArray) := do
  pure ((← workspaces.readFiles id #[path])[0]?.join)

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
