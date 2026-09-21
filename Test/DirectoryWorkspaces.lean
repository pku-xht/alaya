import Test.Framework
import Alaya

/-! A `Workspaces` for tests of everything above it: a snapshot is a copy of the directory. It
keeps the contract `Test/Workspaces.lean` checks, costs no `restic` process — each of which
spends most of a second deriving the repository key — and so keeps trajectory tests about
the trajectory. -/

namespace Testing

open Alaya
open Alaya.Workspaces (Change)

private def storageIO (action : IO α) : Result α := Result.fromIO Error.storage action

private def copy (source destination : System.FilePath) : IO Unit := do
  IO.FS.createDirAll destination
  let out ← IO.Process.output { cmd := "cp", args := #["-Rp", s!"{source}/.", destination.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"cp failed: {out.stderr}"

/-- What is at each path under `base`: `none` for a directory, otherwise what identifies the
content — a link's target, a file's bytes. -/
private partial def listing (base : System.FilePath) (relative : String := "")
    (found : Array (String × Option String) := #[]) : IO (Array (String × Option String)) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  let mut found := found
  for child in ← directory.readDir do
    let path := if relative.isEmpty then child.fileName else s!"{relative}/{child.fileName}"
    match (← child.path.symlinkMetadata).type with
    | .dir =>
      found := found.push (path, none)
      found ← listing base path found
    | .symlink =>
      let out ← IO.Process.output { cmd := "readlink", args := #[child.path.toString] }
      found := found.push (path, some s!"link {out.stdout}")
    | _ => found := found.push (path, some s!"file {Sha256.sumHex (← IO.FS.readBinFile child.path)}")
  pure found

private def under (roots : Array String) (path : String) : Bool :=
  roots.any fun root => path.startsWith (root ++ "/")

def directoryWorkspaces (root : System.FilePath) : Workspaces where
  snapshot directory := storageIO do
    let id : Hash := ⟨Sha256.sumHex s!"{directory} {← IO.monoNanosNow}".toUTF8⟩
    copy directory (root / id.hex)
    pure id
  materialize id directory := do
    Workspaces.makeWritable directory
    storageIO do
      if !(← (root / id.hex).isDir) then throw <| IO.userError s!"no snapshot {id.hex}"
      if ← directory.pathExists then IO.FS.removeDirAll directory
      copy (root / id.hex) directory
  diff before after := storageIO do
    let old := Std.HashMap.ofList (← listing (root / before.hex)).toList
    let new := Std.HashMap.ofList (← listing (root / after.hex)).toList
    -- A path that was a directory and is not, or the reverse, is a removal and an addition.
    let retyped (path : String) : Bool :=
      match old.get? path, new.get? path with
      | some was, some now => was.isNone != now.isNone
      | _, _ => false
    let removed := old.toArray.filter fun (path, _) => !new.contains path || retyped path
    let added := new.toArray.filter fun (path, _) => !old.contains path || retyped path
    let fold (kind : Workspaces.ChangeKind) (entries : Array (String × Option String)) :=
      let roots := entries.filterMap fun (path, content) => if content.isNone then some path else none
      entries.filterMap fun (path, content) =>
        if under roots path then none
        else some ({ kind, path, directory := content.isNone } : Change)
    let modified := new.toArray.filterMap fun (path, content) =>
      match old.get? path with
      | some was => if was != content && was.isSome && content.isSome
          then some ({ kind := .modified, path } : Change) else none
      | none => none
    let rank : Workspaces.ChangeKind -> Nat | .removed => 0 | .added => 1 | .modified => 2
    pure <| (fold .removed removed ++ fold .added added ++ modified).qsort fun a b =>
      a.path < b.path || (a.path == b.path && rank a.kind < rank b.kind)
  readFiles id paths := paths.mapM fun path => storageIO do
    if !Workspaces.safeRelativePath path then return none
    let file := root / id.hex / (path : System.FilePath)
    if !(← file.pathExists) then return none
    match (← file.symlinkMetadata).type with
    | .file => pure (some (← IO.FS.readBinFile file))
    | _ => pure none
  retainOnly keep := storageIO do
    if !(← root.isDir) then return
    for entry in ← root.readDir do
      if !keep.any (·.hex == entry.fileName) then
        let _ ← IO.Process.output { cmd := "chmod", args := #["-R", "u+w", entry.path.toString] }
        IO.FS.removeDirAll entry.path

/-- The test's own snapshot store, the same one however often it is asked for. -/
def workspaces : TestM Workspaces := do
  pure (directoryWorkspaces ((← scratch) / "snapshots"))

end Testing
