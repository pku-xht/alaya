import Std.Data.HashSet
import Alaya.Cas.Store

/-!
Moving real directories in and out of the store.

`snapshot` stores file bytes and directory trees in Git without applying Git ignore rules or
content filters. `materialize` builds a complete independent checkout beside the destination
before replacing it. There is no Alaya stat cache or incremental checkout cache.
-/

namespace Alaya.Cas

private def io (action : IO α) : Result α :=
  Result.fromIO Error.storage action

/-- How symlinks encountered during capture are handled. -/
inductive SymlinkPolicy where
  /-- Record the link itself (target string), so restore reproduces the link. -/
  | capture
  /-- Fail the capture: snapshots must not contain links. -/
  | reject
  deriving BEq, Repr, Inhabited

structure CaptureConfig where
  /-- Skips every file or directory for which this returns true; receives the `/`-separated
  tree-relative path. A skipped directory is pruned without being read. See `ignoring` for a
  pattern-based helper. -/
  ignore : String -> Bool := fun _ => false
  symlinks : SymlinkPolicy := .capture
  /-- Detect executable files (one `find` sweep per capture) and record them as
  `.executable` entries so restore can reproduce the bit. -/
  execBits : Bool := true

/-- What materialize does when the destination is non-empty. -/
inductive OnExisting where
  | replace
  | error
  deriving BEq, Repr, Inhabited

structure MaterializeConfig where
  onExisting : OnExisting := .replace

/-! ## Ignore patterns -/

private def globComponent (pattern component : String) : Bool :=
  match pattern.splitOn "*" with
  | [exact] => component == exact
  | [before, after] =>
    decide (component.length >= before.length + after.length) &&
      component.startsWith before && component.endsWith after
  | _ => false

/-- A gitignore-flavoured matcher for `CaptureConfig.ignore`. Rules:
- `name` (no slash) skips any file or directory component equal to it; one `*` wildcard is
  supported, so `*.log` skips by extension.
- `dir/` (trailing slash) skips the directory at that relative path and its subtree.
- `a/b` (embedded slash) skips exactly that relative path and anything below it. -/
def ignoring (patterns : Array String) : String -> Bool := fun path =>
  patterns.any fun pattern =>
    if pattern.endsWith "/" then
      s!"{path}/" == pattern || path.startsWith pattern
    else if pattern.any (· == '/') then
      path == pattern || path.startsWith s!"{pattern}/"
    else
      (path.splitOn "/").any fun component => globComponent pattern component

/-! ## Shared helpers -/

private def runCommand (cmd : String) (args : Array String) : IO String := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw <| IO.userError s!"{cmd} failed: {out.stderr}"
  pure out.stdout

private def nul : String := String.singleton (Char.ofNat 0)

private def withoutTerminator (text terminator : String) : Result String := do
  if !text.endsWith terminator then
    throw <| .storage "filesystem command returned an unterminated path"
  pure (String.ofList text.toList.dropLast)

private def beneath (parent child : System.FilePath) : Bool :=
  parent == child || child.toString.startsWith
    (if parent.toString.endsWith "/" then parent.toString else s!"{parent}/")

/-- The store and workspace may not contain each other. Call this with resolved paths. -/
private def checkDisjoint (store : Store) (target : System.FilePath) (verb : String) :
    Result Unit := do
  let root ← io (IO.FS.realPath store.root)
  if beneath root target || beneath target root then
    throw <| .storage s!"cannot {verb} {target}: it overlaps the store at {root}"

private def metadata? (path : System.FilePath) : Result (Option IO.FS.Metadata) := do
  match ← path.symlinkMetadata.toBaseIO with
  | .ok metadata => pure (some metadata)
  | .error (.noFileOrDirectory ..) => pure none
  | .error error => throw <| .storage error.toString

private def executableRights : IO.FileRight := {
  user := { read := true, write := true, execution := true }
  group := { read := true, execution := true }
  other := { read := true, execution := true }
}

private def regularRights : IO.FileRight := {
  user := { read := true, write := true }
  group := { read := true }
  other := { read := true }
}

/-! ## Capture -/

/-- One NUL-delimited `find` sweep records executable bits, including paths with newlines. -/
private def findExecutables (source : System.FilePath) : Result (Std.HashSet String) := io do
  let out ← runCommand "find" #[source.toString, "-type", "f", "-perm", "-100", "-print0"]
  let sourcePrefix := s!"{source}/"
  pure <| (out.splitOn nul).foldl (init := {}) fun set path =>
    if path.startsWith sourcePrefix then
      set.insert (path.drop sourcePrefix.length).toString
    else set

private partial def captureTree (store : Store) (config : CaptureConfig)
    (execSet : Std.HashSet String) (base : System.FilePath) (relative : String) :
    Result Hash := do
  let directory := if relative.isEmpty then base else base / relative
  let children ← io directory.readDir
  let sorted := children.qsort fun a b => compare a.fileName b.fileName == .lt
  let mut entries : Array Entry := #[]
  for child in sorted do
    let name := child.fileName
    let path := if relative.isEmpty then name else s!"{relative}/{name}"
    if config.ignore path then continue
    let metadata ← io child.path.symlinkMetadata
    let captured : EntryType × Hash ← match metadata.type with
      | .dir => pure (.directory, ← captureTree store config execSet base path)
      | .file =>
        let bytes ← io (IO.FS.readBinFile child.path)
        pure (if execSet.contains path then .executable else .file, ← store.putBytes bytes)
      | .symlink =>
        if config.symlinks == .reject then
          throw <| .storage s!"cannot capture symlink {path}"
        let output ← io (runCommand "readlink" #[child.path.toString])
        let target ← withoutTerminator output "\n"
        pure (.symlink, ← store.putBytes target.toUTF8)
      | .other => throw <| .storage s!"cannot capture special file {path}"
    entries := entries.push { name, type := captured.1, hash := captured.2 }
  store.putTree (Tree.ofEntries entries)

/-- Captures all non-ignored bytes as native Git blobs and trees, returning a tree OID.
Every capture reads the files; Git handles object hashing and deduplication. Empty directories,
symlinks and `.git` contents are preserved. Pin the result with `setRef` to survive `gc`. -/
def Store.snapshot (store : Store) (directory : System.FilePath)
    (config : CaptureConfig := {}) : Result Hash := do
  let source ← io (IO.FS.realPath directory)
  checkDisjoint store source "capture"
  let execSet ← if config.execBits then findExecutables source else pure {}
  captureTree store config execSet source ""

/-! ## Diff -/

private partial def diffTrees (store : Store) (relative : String) (old new : Hash) :
    Result (Array Change) := do
  if old == new then return #[]
  let oldTree ← store.getTree old
  let newTree ← store.getTree new
  let join (name : String) : String :=
    if relative.isEmpty then name else s!"{relative}/{name}"
  let mut changes : Array Change := #[]
  let mut i := 0
  let mut j := 0
  while i < oldTree.entries.size || j < newTree.entries.size do
    let before? := oldTree.entries[i]?
    let after? := newTree.entries[j]?
    match before?, after? with
    | some before, after? =>
      if after?.all fun after => compare before.name after.name == .lt then
        changes := changes.push (.removed (join before.name) before.type)
        i := i + 1
      else if after?.all fun after => compare before.name after.name == .gt then
        let after := after?.get!
        changes := changes.push (.added (join after.name) after.type after.hash)
        j := j + 1
      else
        let after := after?.get!
        if before.type == .directory && after.type == .directory then
          if before.hash != after.hash then
            changes := changes ++ (← diffTrees store (join before.name) before.hash after.hash)
        else if before.type == .directory || after.type == .directory then
          changes := changes.push (.removed (join before.name) before.type)
          changes := changes.push (.added (join after.name) after.type after.hash)
        else if before.type != after.type || before.hash != after.hash then
          changes := changes.push (.modified (join after.name) after.type after.hash)
        i := i + 1
        j := j + 1
    | none, some after =>
      changes := changes.push (.added (join after.name) after.type after.hash)
      j := j + 1
    | none, none => pure ()
  pure changes

/-- Every difference between two snapshots, in traversal order. Identical subtrees are
skipped wholesale by hash, so the cost scales with the size of the change. -/
def Store.diff (store : Store) (old new : Hash) : Result (Array Change) :=
  diffTrees store "" old new

/-! ## Materialize -/

private def writeLeaf (store : Store) (type : EntryType) (hash : Hash)
    (target : System.FilePath) : Result Unit := do
  let some bytes ← store.getBytes hash
    | throw <| .storage s!"missing blob {hash.hex} for {target}"
  match type with
  | .directory => throw <| .storage "internal: writeLeaf on a directory"
  | .symlink =>
    let some linkTarget := String.fromUTF8? bytes
      | throw <| .storage s!"symlink target {hash.hex} is not valid UTF-8"
    if linkTarget.isEmpty || linkTarget.contains (Char.ofNat 0) then
      throw <| .storage s!"invalid symlink target {hash.hex}"
    let _ ← io (runCommand "ln" #["-s", "--", linkTarget, target.toString])
  | _ =>
    io (IO.FS.writeBinFile target bytes)
    io <| IO.setAccessRights target
      (if type == .executable then executableRights else regularRights)

private partial def writeSubtree (store : Store) (root : Hash)
    (destination : System.FilePath) : Result Unit := do
  io (IO.FS.createDirAll destination)
  let tree ← store.getTree root
  for entry in tree.entries do
    let target := destination / entry.name
    if entry.type == .directory then
      writeSubtree store entry.hash target
    else
      writeLeaf store entry.type entry.hash target

/-- Resolve existing ancestors and append missing components without creating directories.
Resolving each existing ancestor before `..` preserves symlink path semantics. -/
private def resolveFutureDirectory (directory : System.FilePath) : Result System.FilePath := do
  let absolute ← if directory.isAbsolute then pure directory
    else pure ((← io IO.currentDir) / directory)
  let mut current : System.FilePath := "/"
  for component in absolute.toString.splitOn "/" do
    if component.isEmpty || component == "." then continue
    if component == ".." then
      current := current.parent.getD current
      continue
    let next := current / component
    match ← metadata? next with
    | none => current := next
    | some _ =>
      let resolved ← io (IO.FS.realPath next)
      if !(← io resolved.isDir) then
        throw <| .storage s!"{next} is not a directory"
      current := resolved
  pure current

/-- Resolve an existing or future directory without creating it. Reject a destination that
is itself a symlink, so restoration never follows it and overwrites an unrelated directory. -/
private def destinationPath (store : Store) (directory : System.FilePath) :
    Result System.FilePath := do
  if directory.toString.isEmpty then throw <| .storage "empty materialize destination"
  let trimmed := String.ofList ((directory.toString.toList.reverse.dropWhile (· == '/')).reverse)
  let requested : System.FilePath := ⟨if trimmed.isEmpty then "/" else trimmed⟩
  let absolute ← if requested.isAbsolute then pure requested
    else pure ((← io IO.currentDir) / requested)
  let destination ← match absolute.fileName with
    | some name =>
      let parent ← resolveFutureDirectory (absolute.parent.getD "/")
      pure (parent / name)
    | none => resolveFutureDirectory absolute
  if let some metadata ← metadata? destination then
    if metadata.type != .dir then
      throw <| .storage s!"cannot materialize into {destination}: destination is not a directory"
  checkDisjoint store destination "materialize into"
  pure destination

private def checkDestination (destination : System.FilePath) (config : MaterializeConfig) :
    Result Bool := do
  match ← metadata? destination with
  | none => pure false
  | some metadata =>
    if metadata.type != .dir then
      throw <| .storage s!"cannot materialize into {destination}: destination is not a directory"
    if config.onExisting == .error && !(← io destination.readDir).isEmpty then
      throw <| .storage s!"{destination} is not empty"
    pure true

/-- Restores the exact snapshot using independent files. All referenced trees and blobs are
read into a fresh sibling directory before touching the destination. A failed object read
leaves the old directory intact; a failed replacement rolls its rename back. No checkout or
stat-cache record is trusted. Callers must not concurrently mutate the destination path. -/
def Store.materialize (store : Store) (root : Hash) (directory : System.FilePath)
    (config : MaterializeConfig := {}) : Result Unit := do
  let destination ← destinationPath store directory
  let _ ← checkDestination destination config
  let _ ← store.getTree root
  let some parent := destination.parent
    | throw <| .storage s!"cannot materialize into {destination}: no parent directory"
  io (IO.FS.createDirAll parent)
  let output ← io (runCommand "mktemp" #["-d", (parent / ".alaya-restore.XXXXXX").toString])
  let staging : System.FilePath := ⟨← withoutTerminator output "\n"⟩
  let fresh := staging / "new"
  let previous := staging / "previous"
  let result ← (do
    writeSubtree store root fresh
    let existed ← checkDestination destination config
    if existed then io (IO.FS.rename destination previous)
    match ← (IO.FS.rename fresh destination).toBaseIO with
    | .ok _ => pure ()
    | .error error =>
      if existed then
        match ← (IO.FS.rename previous destination).toBaseIO with
        | .ok _ => pure ()
        | .error rollback =>
          throw <| .storage s!"restore failed: {error}; rollback failed: {rollback}; original directory remains at {previous}"
      throw <| .storage s!"restore failed: {error}"
    : Result Unit).toBaseIO
  match result with
  | .ok _ => io (IO.FS.removeDirAll staging)
  | .error error =>
    -- A rollback failure must retain the original directory for manual recovery.
    if (← metadata? previous).isNone then io (IO.FS.removeDirAll staging)
    throw error

/-- Restores the snapshot at `id` into `directory`; see `materialize`. -/
def Store.restore (store : Store) (id : Hash) (directory : System.FilePath)
    (config : MaterializeConfig := {}) : Result Unit :=
  store.materialize id directory config

/-! ## Pure path operations

Reading and editing snapshots without materializing anything — the basis for cheap
branching: fork a snapshot by writing to it, getting a new root back. -/

private partial def entryAt (store : Store) (treeHash : Hash) (components : List String) :
    Result (Option Entry) := do
  let tree ← store.getTree treeHash
  match components with
  | [] => pure none
  | [name] => pure (tree.find? name)
  | name :: rest =>
    match tree.find? name with
    | some entry =>
      if entry.type == .directory then entryAt store entry.hash rest else pure none
    | none => pure none

/-- The entry at a `/`-separated path within the snapshot at `root`, if present. -/
def Store.entryAt? (store : Store) (root : Hash) (path : String) : Result (Option Entry) := do
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  entryAt store root (path.splitOn "/")

/-- The content blob at `path` (for a symlink, its target string), or `none` when the path
is absent or names a directory. -/
def Store.readPath (store : Store) (root : Hash) (path : String) :
    Result (Option ByteArray) := do
  match ← store.entryAt? root path with
  | some entry =>
    if entry.type == .directory then pure none else store.getBytes entry.hash
  | none => pure none

private partial def writeAt (store : Store) (treeHash? : Option Hash)
    (components : List String) (type : EntryType) (blob : Hash) : Result Hash := do
  let tree ← match treeHash? with
    | some hash => store.getTree hash
    | none => pure Tree.empty
  match components with
  | [] => throw <| .storage "internal: empty path in writeAt"
  | [name] => store.putTree (tree.insert { name, type, hash := blob })
  | name :: rest =>
    let below? ← match tree.find? name with
      | some entry =>
        if entry.type == .directory then pure (some entry.hash)
        else throw <| .storage s!"{name} is not a directory"
      | none => pure none
    let below ← writeAt store below? rest type blob
    store.putTree (tree.insert { name, type := .directory, hash := below })

/-- Returns a new snapshot root equal to `root` with `bytes` at `path` (missing parent
directories are created); the store gains at most the new blob and the trees along the
path. `type` selects a regular, executable, or symlink entry. -/
def Store.writePath (store : Store) (root : Hash) (path : String) (bytes : ByteArray)
    (type : EntryType := .file) : Result Hash := do
  if type == .directory then throw <| .storage "writePath cannot write a directory"
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  let blob ← store.putBytes bytes
  writeAt store (some root) (path.splitOn "/") type blob

private partial def removeAt (store : Store) (treeHash : Hash) (components : List String) :
    Result Hash := do
  let tree ← store.getTree treeHash
  match components with
  | [] => throw <| .storage "internal: empty path in removeAt"
  | [name] => store.putTree (tree.erase name)
  | name :: rest =>
    match tree.find? name with
    | some entry =>
      if entry.type == .directory then
        let below ← removeAt store entry.hash rest
        store.putTree (tree.insert { name, type := .directory, hash := below })
      else pure treeHash
    | none => pure treeHash

/-- Returns a new snapshot root equal to `root` without `path`. Removing an absent path
returns the root unchanged. -/
def Store.removePath (store : Store) (root : Hash) (path : String) : Result Hash := do
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  removeAt store root (path.splitOn "/")

private partial def listInto (store : Store) (relative : String) (treeHash : Hash)
    (accumulated : Array (String × EntryType)) : Result (Array (String × EntryType)) := do
  let tree ← store.getTree treeHash
  tree.entries.foldlM (init := accumulated) fun accumulated entry => do
    let path := if relative.isEmpty then entry.name else s!"{relative}/{entry.name}"
    let accumulated := accumulated.push (path, entry.type)
    if entry.type == .directory then listInto store path entry.hash accumulated
    else pure accumulated

/-- Every path in the snapshot at `root` with its entry type, in depth-first canonical
order (directories precede their contents). -/
def Store.listPaths (store : Store) (root : Hash) : Result (Array (String × EntryType)) :=
  listInto store "" root #[]

end Alaya.Cas
