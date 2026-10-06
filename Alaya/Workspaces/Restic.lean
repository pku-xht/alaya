import Lean.Data.Json
import Alaya.Workspaces

/-!
Workspace snapshots in a restic repository (https://restic.net, 0.17 or later).

restic is a backup program: walking a directory, deciding what changed since the last snapshot,
and writing a snapshot back out are its business, and it records what a filesystem holds —
permissions, times, hard links, extended attributes, special files — rather than a model of it.
A workspace identifier is a restic snapshot ID. It covers the time of the snapshot and the
metadata of every file, so two snapshots of equal directories have different identifiers.

Every operation is one `restic` process, but `transfer`, which makes a new repository. The repository is unencrypted-by-password
(`--insecure-no-password`): it sits beside the entries, which are not encrypted either.
-/

namespace Alaya.Workspaces.Restic

/-- A repository and the program that reads and writes it. -/
structure Settings where
  repository : System.FilePath
  /-- Where `readFiles` restores to; emptied after each use. -/
  scratch : System.FilePath
  /-- What a snapshot may not capture and a restore may not overwrite: the repository, the
  scratch directory, and whatever else of the run's storage the caller names. -/
  kept : Array System.FilePath
  program : String := "restic"

private structure Finished where
  exitCode : UInt32
  stdout : ByteArray
  stderr : String

/-- Runs `restic` with the repository's flags. Standard output is kept as bytes, which
`jsonLines` decodes, and standard error is drained concurrently so neither pipe can fill. -/
private def run (settings : Settings) (args : Array String)
    (cwd? : Option System.FilePath := none) : Result Finished :=
  Result.fromIO Error.storage do
    let child ← IO.Process.spawn {
      cmd := settings.program
      args := #["--repo", settings.repository.toString, "--insecure-no-password", "--no-cache"] ++ args
      cwd := cwd?
      stdin := .null, stdout := .piped, stderr := .piped }
    let stderr ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
    let stdout ← child.stdout.readBinToEnd
    let exitCode ← child.wait
    let stderr ← IO.ofExcept stderr.get
    pure { exitCode, stdout, stderr }

private def failure (what : String) (finished : Finished) : Error :=
  .storage s!"restic {what} failed ({finished.exitCode}): {finished.stderr.trimAscii}"

private def succeed (what : String) (finished : Finished) : Result Finished :=
  if finished.exitCode == 0 then pure finished else throw (failure what finished)

/-- The JSON objects of a `--json` output: one per line, other lines ignored. -/
private def jsonLines (bytes : ByteArray) : Array Lean.Json :=
  let text := (String.fromUTF8? bytes).getD ""
  (text.splitOn "\n").toArray.filterMap fun line => (Lean.Json.parse line).toOption

private def stringField? (json : Lean.Json) (name : String) : Option String :=
  (json.getObjVal? name >>= Lean.Json.getStr?).toOption

private def idOf (what : String) (hex : String) : Result Snapshot :=
  if Hash.valid hex then pure ⟨hex⟩
  else throw <| .storage s!"restic {what} reported an unusable snapshot id: {hex}"

/-- Creates the repository on first use. -/
def init (settings : Settings) : Result Unit := do
  if ← Result.fromIO Error.storage (settings.repository / "config").pathExists then return
  let _ ← succeed "init" (← run settings #["init", "--quiet"])

/-- Snapshots `directory` from inside it, as `.`, so that paths in the snapshot are relative to
it whichever directory it was. A snapshot that could not read every file is a failure, not a
smaller snapshot. -/
def snapshot (settings : Settings) (directory : System.FilePath) : Result Snapshot := do
  refuseOverlap "snapshot" directory settings.kept
  let finished ← run settings
    #["backup", ".", "--json", "--quiet", "--no-scan", "--host", "alaya"] (cwd? := some directory)
  let finished ← succeed "backup" finished
  let summary? := (jsonLines finished.stdout).findSome? fun json =>
    if stringField? json "message_type" == some "summary" then stringField? json "snapshot_id"
    else none
  match summary? with
  | some id => idOf "backup" id
  | none => throw <| .storage "restic backup reported no snapshot"

/-- Restores in place: files whose content differs are rewritten, and what the snapshot does
not hold is deleted. -/
def materialize (settings : Settings) (id : Snapshot) (directory : System.FilePath) : Result Unit := do
  refuseOverlap "check out into" directory settings.kept
  Result.fromIO Error.storage (IO.FS.createDirAll directory)
  makeWritable directory
  let _ ← succeed "restore" (← run settings
    #["restore", id.hex, "--target", directory.toString, "--delete", "--overwrite", "always", "--quiet"])

/-- A path of `restic diff`, which is absolute within the snapshot and ends in `/` for a
directory, as a relative path and whether it is one. -/
private def relative (path : String) : String × Bool :=
  let directory := path.endsWith "/"
  let path := if directory then (path.dropEnd 1).toString else path
  ((path.dropWhile (· == '/')).toString, directory)

/-- Which of `paths` are directories in the snapshot. -/
private def directoriesAmong (settings : Settings) (id : Snapshot) (paths : Array String) :
    Result (Array String) := do
  if paths.isEmpty then return #[]
  let finished ← succeed "ls" (← run settings
    (#["ls", id.hex, "--json"] ++ paths.map ("/" ++ ·)))
  pure <| paths.filter fun path => (jsonLines finished.stdout).any fun json =>
    stringField? json "path" == some ("/" ++ path) && stringField? json "type" == some "dir"

/-- Content and type changes, without `--metadata`: a touched file is not a change. restic
lists every path under an added or removed directory; those are dropped, the directory standing
for them. A path that was a directory and is a file, or the reverse, restic reports as one type
change and nothing beneath it; here it is the removal of the one and the addition of the
other. A file that became a link, or the reverse, is a modification. -/
def diff (settings : Settings) (before after : Snapshot) : Result (Array Change) := do
  let finished ← succeed "diff" (← run settings #["diff", before.hex, after.hex, "--json"])
  let mut changes : Array Change := #[]
  -- Type changes whose new side is not a directory: the old side may have been one.
  let mut retyped : Array String := #[]
  for json in jsonLines finished.stdout do
    if stringField? json "message_type" != some "change" then continue
    let some path := stringField? json "path" | continue
    let some modifier := stringField? json "modifier" | continue
    -- The trailing slash describes the path in the second snapshot, or in the first if removed.
    let (path, directory) := relative path
    if path.isEmpty then continue
    if modifier.contains '+' then changes := changes.push { kind := .added, path, directory }
    else if modifier.contains '-' then changes := changes.push { kind := .removed, path, directory }
    else if modifier.contains 'T' then
      if directory then
        changes := changes ++ #[{ kind := .removed, path }, { kind := .added, path, directory := true }]
      else retyped := retyped.push path
    else if modifier.contains 'M' && !directory then changes := changes.push { kind := .modified, path }
  let wereDirectories ← directoriesAmong settings before retyped
  for path in retyped do
    if wereDirectories.contains path then
      changes := changes ++ #[{ kind := .removed, path, directory := true }, { kind := .added, path }]
    else changes := changes.push { kind := .modified, path }
  let roots (kind : ChangeKind) := changes.filterMap fun change =>
    if change.kind == kind && change.directory then some (change.path ++ "/") else none
  let covered (change : Change) := (roots change.kind).any (change.path.startsWith ·)
  let rank : ChangeKind -> Nat | .removed => 0 | .added => 1 | .modified => 2
  pure <| (changes.filter (!covered ·)).qsort fun a b =>
    a.path < b.path || (a.path == b.path && rank a.kind < rank b.kind)

/-- A path as a `restore --include` pattern that matches it alone. -/
private def literalPattern (path : String) : String :=
  "/" ++ path.foldl (init := "") fun escaped c =>
    if c == '\\' || c == '*' || c == '?' || c == '[' then escaped.push '\\' |>.push c else escaped.push c

/-- Lists one directory using only snapshot metadata. Passing the directory explicitly keeps
`restic ls` nonrecursive, even at the root; dependencies are not restored merely to browse. -/
def listEntries (settings : Settings) (id : Snapshot) (path : String) : Result (Array Entry) := do
  if !safeSnapshotPath path then
    throw <| .input "snapshot path must be a clean relative path"
  let finished ← succeed "ls" (← run settings #["ls", id.hex, "--json", "/" ++ path])
  let pathPrefix := if path.isEmpty then "/" else "/" ++ path ++ "/"
  let mut entries := #[]
  for json in jsonLines finished.stdout do
    let some absolute := stringField? json "path" | continue
    if !absolute.startsWith pathPrefix then continue
    let name := (absolute.drop pathPrefix.length).toString
    if name.isEmpty || name.contains '/' then continue
    let relative := if path.isEmpty then name else path ++ "/" ++ name
    -- Unrepresentable paths are not passed to filesystem reads by the browser.
    let kind := match stringField? json "type" with
      | some "dir" => EntryKind.directory
      | some "file" => .file
      | some "symlink" => .symlink
      | _ => .other
    let size := (json.getObjVal? "size" >>= Lean.Json.getNat?).toOption
    entries := entries.push ({ name, path := relative, kind, size } : Entry)
  pure (entries.qsort fun a b => a.path < b.path)

/-- Numbers this process's read directories. A clock alone is not enough: reads run
concurrently (the HTML report reads several snapshots at once), two can see the same tick, and
the first to finish would remove the directory the other is reading from. -/
private initialize readCounter : IO.Ref Nat ← IO.mkRef 0

/-- One `restore` of just these paths into a scratch directory, read back from there: a process
per file would spend most of a second each on deriving the repository key. -/
def readFiles (settings : Settings) (id : Snapshot) (paths : Array String) :
    Result (Array (Option ByteArray)) := do
  let wanted := paths.filter safeRelativePath
  if wanted.isEmpty then return paths.map fun _ => none
  let n ← Result.fromIO Error.storage (readCounter.modifyGet fun n => (n, n + 1))
  let scratch := settings.scratch / s!"read-{← Result.fromIO Error.storage IO.monoNanosNow}-{n}"
  Result.fromIO Error.storage (IO.FS.createDirAll scratch)
  try
    let mut rest := wanted
    while !rest.isEmpty do
      let includes := (rest.extract 0 200).foldl (init := #[]) fun args path =>
        args ++ #["--include", literalPattern path]
      let _ ← succeed "restore" (← run settings
        (#["restore", id.hex, "--target", scratch.toString, "--quiet"] ++ includes))
      rest := rest.extract 200 rest.size
    paths.mapM fun (path : String) => Result.fromIO Error.storage do
      let file := scratch / System.FilePath.mk path
      if !safeRelativePath path || !(← file.pathExists) then return none
      match (← file.symlinkMetadata).type with
      | .file => pure (some (← IO.FS.readBinFile file))
      | _ => pure none
  finally
    makeWritable scratch
    Result.fromIO Error.storage (IO.FS.removeDirAll scratch)

def retainOnly (settings : Settings) (keep : Array Snapshot) : Result Unit := do
  let finished ← succeed "snapshots" (← run settings #["snapshots", "--json"])
  let listed := match jsonLines finished.stdout with
    | #[.arr snapshots] => snapshots.filterMap (stringField? · "id")
    | _ => #[]
  let doomed := listed.filter fun id => !keep.any (·.hex == id)
  if doomed.isEmpty then return
  -- In batches, to stay under the command-line length limit.
  let mut rest := doomed
  while !rest.isEmpty do
    let _ ← succeed "forget" (← run settings (#["forget", "--quiet"] ++ rest.extract 0 200))
    rest := rest.extract 200 rest.size
  let _ ← succeed "prune" (← run settings #["prune", "--quiet"])

/-- A new repository at `location` that holds copies of `ids`: one `init` that takes this
repository's chunker parameters, so the copies share their data as the originals do, and one
`copy` a batch. A copy is a new snapshot, and restic records the one it copies as its
`original`, which is how each identifier here is found there. -/
def transfer (settings : Settings) (ids : Array Snapshot) (location : System.FilePath) :
    Result (Array Snapshot) := do
  refuseOverlap "copy snapshots into" location settings.kept
  let repository ← Result.fromIO Error.storage do
    IO.FS.createDirAll location
    IO.FS.realPath location
  let into := { settings with repository }
  let source := #["--from-repo", settings.repository.toString, "--from-insecure-no-password"]
  let _ ← succeed "init" (← run into (#["init", "--quiet", "--copy-chunker-params"] ++ source))
  let mut rest := ids.foldl (init := #[]) fun unique id =>
    if unique.contains id.hex then unique else unique.push id.hex
  while !rest.isEmpty do
    let _ ← succeed "copy" (← run into (#["copy", "--quiet"] ++ source ++ rest.extract 0 200))
    rest := rest.extract 200 rest.size
  let listed ← succeed "snapshots" (← run into #["snapshots", "--json"])
  let copies : Std.HashMap String String := match jsonLines listed.stdout with
    | #[.arr snapshots] => snapshots.foldl (init := {}) fun copies json =>
      match stringField? json "original", stringField? json "id" with
      | some original, some id => copies.insert original id
      | _, _ => copies
    | _ => {}
  ids.mapM fun id => match copies.get? id.hex with
    | some copy => idOf "copy" copy
    | none => throw <| .storage s!"restic copy did not copy the snapshot {id.hex}"

/-- The restic version as `(major, minor)`, or an environment error when it cannot be run. -/
def version (settings : Settings) : Result (Nat × Nat) := do
  let missing : Error := .environment <|
    s!"cannot run `{settings.program}`: install restic 0.17 or later (https://restic.net)"
  -- A program that does not exist shows as a failed exit on some platforms, not as an exception.
  let out ← match ← (Result.fromIO Error.storage
      (IO.Process.output { cmd := settings.program, args := #["version"] })).toBaseIO with
    | .ok out => if out.exitCode == 0 then pure out else throw missing
    | .error _ => throw missing
  -- "restic 0.17.3 compiled with go1.23 on darwin/arm64"
  let unrecognized : Error := .environment s!"unrecognized restic version: {out.stdout.trimAscii}"
  match (out.stdout.splitOn " ")[1]?.map (·.splitOn ".") with
  | some (major :: minor :: _) =>
    match major.toNat?, minor.toNat? with
    | some major, some minor => pure (major, minor)
    | _, _ => throw unrecognized
  | _ => throw unrecognized

/-- The snapshots kept in `repository`, which is created if it does not exist. Files read out of a
snapshot land in `scratch`, which the caller owns and removes. `keep` names the rest of the run's
storage, which like the repository no snapshot or checkout may overlap. -/
def «open» (repository scratch : System.FilePath) (keep : Array System.FilePath := #[])
    (program : String := "restic") : Result Workspaces := do
  -- Absolute, because `backup` runs from inside the directory it snapshots.
  let repository ← Result.fromIO Error.storage do
    IO.FS.createDirAll repository
    IO.FS.realPath repository
  let settings : Settings := { repository, scratch, kept := #[repository, scratch] ++ keep, program }
  let (major, minor) ← version settings
  if major == 0 && minor < 17 then
    throw <| .environment s!"restic {major}.{minor} is too old: 0.17 or later is needed"
  init settings
  pure {
    snapshot := snapshot settings
    materialize := materialize settings
    diff := diff settings
    readFiles := readFiles settings
    listEntries := listEntries settings
    retainOnly := retainOnly settings
    transfer := transfer settings }

end Alaya.Workspaces.Restic
