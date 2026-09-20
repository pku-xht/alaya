import Alaya.Cas.Store

/-!
Moving real directories in and out of the store.

`snapshot` stages a project's files with Git and records a commit without advancing its
existing branch. `materialize` fetches and checks out that commit. Git owns the index,
ignore rules, attributes, modes and history; `.git` is repository metadata, not snapshot data.
-/

namespace Alaya.Cas

private def io (action : IO α) : Result α :=
  Result.fromIO Error.storage action

/-- What materialize does when the destination is non-empty. -/
inductive OnExisting where
  | replace
  | error
  deriving BEq, Repr, Inhabited

structure MaterializeConfig where
  onExisting : OnExisting := .replace

/-! ## Shared helpers -/

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

private def workspaceArgs (directory : System.FilePath) (command : Array String) : Array String :=
  #["-C", directory.toString, "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
    "-c", "core.fsmonitor=false", "-c", "commit.gpgSign=false", "-c", "submodule.recurse=false",
    "-c", "user.name=Alaya", "-c", "user.email=alaya@localhost"] ++ command

private def workspaceGit (directory : System.FilePath) (command : Array String) : Result String := do
  pure (← Git.text (← Git.checked (workspaceArgs directory command))).trimAscii.toString

private def parseHash (text : String) : Result Hash := do
  if !validHex text then throw <| .storage s!"invalid Git object hash: {text}"
  pure ⟨text⟩

/-- Workspace commands run on the host even when tools run in a container. Ask Git for its
effective configuration (including local includes), and refuse settings that would execute
workspace-selected programs. Built-in text/eol/encoding attributes remain native Git behavior. -/
private def checkHostConfiguration (store : Store) (directory : System.FilePath) : Result Unit := do
  let config ← workspaceGit directory #["config", "--null", "--list"]
  let localRemote := store.gitDir.toString
  for record in config.splitOn "\x00" do
    if record.isEmpty then continue
    let parts := record.splitOn "\n"
    let key := parts.head!.toLower
    let value := String.intercalate "\n" parts.tail!
    let filter := key.startsWith "filter." &&
      (key.endsWith ".clean" || key.endsWith ".smudge" || key.endsWith ".process")
    let remoteCommand := key.startsWith "remote." &&
      (key.endsWith ".uploadpack" || key.endsWith ".vcs")
    let redirectsStore := key == s!"remote.{localRemote.toLower}.url" ||
      (key.startsWith "url." && key.endsWith ".insteadof" && localRemote.startsWith value)
    if !value.isEmpty && (filter || remoteCommand || key == "core.alternaterefscommand" ||
        key == "uploadpack.packobjectshook") then
      throw <| .storage s!"cannot safely process {directory} on the host: Git configuration {key} selects an external command"
    if redirectsStore then
      throw <| .storage s!"cannot safely process {directory} on the host: Git configuration {key} redirects the snapshot store"

/-- Require a repository at this exact directory, not an enclosing repository. Linked
worktrees use a `.git` file pointing outside the workspace and cannot survive container
mounts or independent restoration, so they are rejected explicitly. -/
private def ensureRepository (store : Store) (directory : System.FilePath) : Result Unit := do
  let format := (← Git.text (← store.git #["rev-parse", "--show-object-format"])).trimAscii.toString
  match ← metadata? (directory / ".git") with
  | none =>
    let _ ← Git.checked #["init", "--quiet", "--template=", s!"--object-format={format}",
      directory.toString]
  | some metadata =>
    if metadata.type != .dir then
      throw <| .storage s!"cannot use {directory}: linked worktrees and non-directory .git paths are unsupported"
  checkHostConfiguration store directory
  let top ← Git.text (← Git.checked (workspaceArgs directory #["rev-parse", "--show-toplevel"]))
  if !top.endsWith "\n" then throw <| .storage "Git returned an unterminated repository path"
  let top := String.ofList top.toList.dropLast
  if (← io (IO.FS.realPath ⟨top⟩)) != directory then
    throw <| .storage s!"{directory} must be the repository root"
  let actual ← workspaceGit directory #["rev-parse", "--show-object-format"]
  if actual != format then
    throw <| .storage s!"Git object format mismatch: workspace uses {actual}, store uses {format}"

private def head? (directory : System.FilePath) : Result (Option Hash) := do
  let output ← Git.run (workspaceArgs directory #["rev-parse", "--verify", "--quiet", "HEAD"])
  if output.exitCode == 0 then
    let hash ← parseHash (← Git.text output.stdout).trimAscii.toString
    let _ ← workspaceGit directory #["rev-parse", "--verify", hash.hex ++ "^{commit}"]
    return some hash
  let symbolic ← Git.run (workspaceArgs directory #["symbolic-ref", "--quiet", "HEAD"])
  if output.exitCode == 1 && symbolic.exitCode == 0 then return none
  throw <| .storage s!"cannot read HEAD in {directory}: {output.stderr}"

private def pinSnapshot (directory : System.FilePath) (hash : Hash) : Result Unit := do
  let _ ← workspaceGit directory #["update-ref", s!"refs/alaya/snapshots/{hash.hex}", hash.hex]

/-! ## Capture -/

/-- Stage with Git's native ignore/attribute rules and return a snapshot commit. An unchanged
HEAD tree reuses HEAD. A changed tree gets a child commit on detached HEAD, preserving the
project's branch refs and ancestry. This uses the project's index and is not safe alongside
another writer. Empty directories and ignored untracked files are not captured. -/
def Store.snapshot (store : Store) (directory : System.FilePath) : Result Hash := do
  let source ← io (IO.FS.realPath directory)
  checkDisjoint store source "capture"
  ensureRepository store source
  let parent ← head? source
  let _ ← workspaceGit source #["add", "-A", "--", "."]
  let tree ← workspaceGit source #["write-tree"]
  let unchanged ← match parent with
    | some hash => pure ((← workspaceGit source #["rev-parse", hash.hex ++ "^{tree}"]) == tree)
    | none => pure false
  let commit ← if unchanged then pure parent.get!
    else do
      let args := #["commit-tree", tree] ++
        (parent.map (fun hash => #["-p", hash.hex])).getD #[] ++ #["-m", "Alaya snapshot"]
      parseHash (← workspaceGit source args)
  pinSnapshot source commit
  if !unchanged then
    let _ ← workspaceGit source #["update-ref", "--no-deref", "HEAD", commit.hex]
  let _ ← store.git #["fetch", "--no-tags", "--no-write-fetch-head",
    "--no-recurse-submodules", "--no-auto-maintenance", "--",
    source.toString, commit.hex]
  pure commit

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

/-- Fetch and check out a snapshot commit using Git's own index and checkout behavior.
Tracked changes are discarded, then `git clean -fd` removes untracked non-ignored files.
Ignored files and repository history remain; this is not an exact directory mirror or an
atomic replacement. Callers must not concurrently mutate the destination repository. -/
def Store.materialize (store : Store) (root : Hash) (directory : System.FilePath)
    (config : MaterializeConfig := {}) : Result Unit := do
  let _ ← parseHash root.hex
  let commit ← parseHash
    (← Git.text (← store.git #["rev-parse", "--verify", root.hex ++ "^{commit}"])).trimAscii.toString
  let destination ← destinationPath store directory
  let _ ← checkDestination destination config
  io (IO.FS.createDirAll destination)
  ensureRepository store destination
  let _ ← workspaceGit destination #["fetch", "--no-tags", "--no-write-fetch-head",
    "--no-recurse-submodules", "--no-auto-maintenance", "--",
    store.gitDir.toString, commit.hex]
  pinSnapshot destination commit
  let _ ← workspaceGit destination #["checkout", "--detach", "--force", commit.hex]
  let _ ← workspaceGit destination #["clean", "-fd"]

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
is absent, a directory, or a submodule gitlink. -/
def Store.readPath (store : Store) (root : Hash) (path : String) :
    Result (Option ByteArray) := do
  match ← store.entryAt? root path with
  | some entry =>
    if entry.type == .directory || entry.type == .gitlink then pure none else store.getBytes entry.hash
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

/-- Returns a child snapshot commit with `bytes` at `path` (missing parent directories are
created). The original commit remains its parent. `type` selects a regular, executable,
or symlink entry. Bare tree inputs are accepted without inventing a parent commit. -/
def Store.writePath (store : Store) (root : Hash) (path : String) (bytes : ByteArray)
    (type : EntryType := .file) : Result Hash := do
  if type == .directory || type == .gitlink then
    throw <| .storage "writePath requires a file, executable, or symlink entry"
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  let blob ← store.putBytes bytes
  let before ← store.treeHash root
  let tree ← writeAt store (some before) (path.splitOn "/") type blob
  if tree == before then pure root
  else store.commitTree tree (if root == before then none else some root)

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

/-- Returns a child snapshot commit without `path`. Removing an absent path returns the
original root unchanged. Bare tree inputs are accepted without inventing a parent commit. -/
def Store.removePath (store : Store) (root : Hash) (path : String) : Result Hash := do
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  let before ← store.treeHash root
  let tree ← removeAt store before (path.splitOn "/")
  if tree == before then pure root
  else store.commitTree tree (if root == before then none else some root)

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
