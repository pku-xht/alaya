import Lean.Data.Json
import Alaya.Workspaces

/-!
Workspace snapshots in a restic repository (https://restic.net, 0.17 or later).

restic is a backup program: walking a directory, deciding what changed since the last snapshot,
and writing a snapshot back out are its business, and it records what a filesystem holds —
permissions, times, hard links, extended attributes, special files — rather than a model of it.
A workspace identifier is a restic snapshot ID. It covers the time of the snapshot and the
metadata of every file, so two snapshots of equal directories have different identifiers.

Every operation is one `restic` process. The repository is unencrypted-by-password
(`--insecure-no-password`): it sits beside the states, which are not encrypted either.
-/

namespace Alaya.Workspaces.Restic

/-- A repository and the program that reads and writes it. -/
structure Settings where
  repository : System.FilePath
  /-- Where `readFiles` restores to; emptied after each use. -/
  scratch : System.FilePath
  program : String := "restic"

private structure Finished where
  exitCode : UInt32
  stdout : ByteArray
  stderr : String

/-- Runs `restic` with the repository's flags. Standard output is kept as bytes — `dump` writes
a file's content there — and standard error is drained concurrently so neither pipe can fill. -/
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

private def idOf (what : String) (hex : String) : Result Hash :=
  if Hash.valid hex then pure ⟨hex⟩
  else throw <| .storage s!"restic {what} reported an unusable snapshot id: {hex}"

/-- Creates the repository on first use. -/
def init (settings : Settings) : Result Unit := do
  if ← Result.fromIO Error.storage (settings.repository / "config").pathExists then return
  let _ ← succeed "init" (← run settings #["init", "--quiet"])

/-- Snapshots `directory` from inside it, as `.`, so that paths in the snapshot are relative to
it whichever directory it was. A snapshot that could not read every file is a failure, not a
smaller snapshot. -/
def snapshot (settings : Settings) (directory : System.FilePath) : Result Hash := do
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
def materialize (settings : Settings) (id : Hash) (directory : System.FilePath) : Result Unit := do
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

/-- Content and type changes, without `--metadata`: a touched file is not a change. restic
lists every path under an added or removed directory; those are dropped, the directory standing
for them. -/
def diff (settings : Settings) (before after : Hash) : Result (Array Change) := do
  let finished ← succeed "diff" (← run settings #["diff", before.hex, after.hex, "--json"])
  let mut changes : Array Change := #[]
  for json in jsonLines finished.stdout do
    if stringField? json "message_type" != some "change" then continue
    let some path := stringField? json "path" | continue
    let some modifier := stringField? json "modifier" | continue
    let (path, directory) := relative path
    if path.isEmpty then continue
    let kind? : Option ChangeKind :=
      if modifier.contains '+' then some .added
      else if modifier.contains '-' then some .removed
      else if directory then none
      else if modifier.contains 'M' || modifier.contains 'T' then some .modified
      else none
    if let some kind := kind? then changes := changes.push { kind, path, directory }
  let sorted := changes.qsort fun a b => a.path < b.path
  let mut kept : Array Change := #[]
  let mut covering : Option (String × ChangeKind) := none
  for change in sorted do
    let covered := match covering with
      | some (root, kind) => change.kind == kind && change.path.startsWith (root ++ "/")
      | none => false
    if covered then continue
    kept := kept.push change
    if change.directory then covering := some (change.path, change.kind)
  pure kept

/-- A path as a `restore --include` pattern that matches it alone. -/
private def literalPattern (path : String) : String :=
  "/" ++ path.foldl (init := "") fun escaped c =>
    if c == '\\' || c == '*' || c == '?' || c == '[' then escaped.push '\\' |>.push c else escaped.push c

/-- One `restore` of just these paths into a scratch directory, read back from there: a process
per file would spend most of a second each on deriving the repository key. -/
def readFiles (settings : Settings) (id : Hash) (paths : Array String) :
    Result (Array (Option ByteArray)) := do
  let wanted := paths.filter safeRelativePath
  if wanted.isEmpty then return paths.map fun _ => none
  let scratch := settings.scratch / s!"read-{← Result.fromIO Error.storage IO.monoNanosNow}"
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

def retainOnly (settings : Settings) (keep : Array Hash) : Result Unit := do
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

/-- The restic version as `(major, minor)`, or a configuration error when it cannot be run. -/
def version (settings : Settings) : Result (Nat × Nat) := do
  let missing : Error := .configuration <|
    s!"cannot run `{settings.program}`: install restic 0.17 or later (https://restic.net)"
  -- A program that does not exist shows as a failed exit on some platforms, not as an exception.
  let out ← match ← (Result.fromIO Error.storage
      (IO.Process.output { cmd := settings.program, args := #["version"] })).toBaseIO with
    | .ok out => if out.exitCode == 0 then pure out else throw missing
    | .error _ => throw missing
  -- "restic 0.17.3 compiled with go1.23 on darwin/arm64"
  let unrecognized : Error := .configuration s!"unrecognized restic version: {out.stdout.trimAscii}"
  match (out.stdout.splitOn " ")[1]?.map (·.splitOn ".") with
  | some (major :: minor :: _) =>
    match major.toNat?, minor.toNat? with
    | some major, some minor => pure (major, minor)
    | _, _ => throw unrecognized
  | _ => throw unrecognized

/-- The snapshots kept in `repository`, which is created if it does not exist. -/
def «open» (repository : System.FilePath) (program : String := "restic") : Result Workspaces := do
  -- Absolute, because `backup` runs from inside the directory it snapshots.
  let repository ← Result.fromIO Error.storage do
    IO.FS.createDirAll repository
    IO.FS.realPath repository
  let settings : Settings := { repository, scratch := repository.withFileName "restic-scratch", program }
  let (major, minor) ← version settings
  if major == 0 && minor < 17 then
    throw <| .configuration s!"restic {major}.{minor} is too old: 0.17 or later is needed"
  init settings
  pure {
    snapshot := snapshot settings
    materialize := materialize settings
    diff := diff settings
    readFiles := readFiles settings
    retainOnly := retainOnly settings }

end Alaya.Workspaces.Restic
