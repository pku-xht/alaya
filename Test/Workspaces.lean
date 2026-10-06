import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Test.Scripted
import Alaya

/-! The `Workspaces` contract — what the log's snapshots rely on, and the filesystem cases a
snapshot store has to get right — run against restic, and against the directory copies that
stand in for it in the other tests, so that those test against something faithful. -/

namespace WorkspacesTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Alaya.Runtime.Workspaces (Change ChangeKind)

private structure Backend where
  name : String
  /-- The store over a fresh location under the test's scratch directory. -/
  «open» : TestM Workspaces
  /-- The store of the same kind at `location`, where `transfer` made one. -/
  reopen : System.FilePath → TestM Workspaces

private def backends : Array Backend := #[
  { name := "restic", «open» := do assertOk <| Workspaces.Restic.open ((← scratch) / "restic") ((← scratch) / "restic-scratch")
    reopen := fun location => do assertOk <| Workspaces.Restic.open location ((← scratch) / "restic-scratch") },
  { name := "copies", «open» := Testing.workspaces, reopen := fun location => pure (directoryWorkspaces location) }]

private def run (args : Array String) : TestM Unit := do
  let out ← IO.Process.output { cmd := args[0]!, args := args.extract 1 args.size }
  check (out.exitCode == 0) s!"{args} failed: {out.stderr}"

private def source : TestM System.FilePath := do
  let directory := (← scratch) / "source"
  IO.FS.createDirAll directory
  pure directory

private def baseSpec : Array (String × String) := #[
  ("README.md", "readme"), ("src/main.lean", "def main := 1"), ("src/lib/util.lean", "util")]

private def summary (changes : Array Change) : Array (ChangeKind × String × Bool) :=
  changes.map fun change => (change.kind, change.path, change.directory)

/-- One case per backend, named `name`. -/
private def onEach (name : String) (body : Workspaces -> TestM Unit) : Array Case :=
  backends.map fun backend =>
    test s!"{backend.name}: {name}" do body (← backend.open)

/-- One case per backend, named `name`, given the backend itself. -/
private def onEachBackend (name : String) (body : Backend -> TestM Unit) : Array Case :=
  backends.map fun backend =>
    test s!"{backend.name}: {name}" do body backend

def suite : Suite := Testing.suite "workspaces" <| Array.flatten #[
  onEach "a snapshot materializes as the directory it was taken of" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    IO.FS.createDirAll (source / "empty")
    setExecutable (source / "src/main.lean")
    run #["ln", "-s", "README.md", (source / "link").toString]
    let id ← assertOk <| workspaces.snapshot source
    let out := (← scratch) / "out"
    assertOk <| workspaces.materialize id out
    assertEqual "files" (← readSpec out) (← readSpec source)
    check (← (out / "empty").isDir) "an empty directory should survive"
    let listing ← IO.Process.output { cmd := "ls", args := #["-l", (out / "src/main.lean").toString] }
    check (listing.stdout.startsWith "-rwx") s!"the executable bit should survive: {listing.stdout}",

  onEach "materialize replaces whatever the directory held" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let id ← assertOk <| workspaces.snapshot source
    let out := (← scratch) / "out"
    writeSpec out #[("stale.txt", "stale"), ("src/main.lean", "edited"), ("junk/deep/file", "x")]
    assertOk <| workspaces.materialize id out
    assertEqual "files" (← readSpec out) (← readSpec source),

  onEach "materialize replaces a tree holding read-only directories" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let id ← assertOk <| workspaces.snapshot source
    let out := (← scratch) / "out"
    -- As Go's module cache is: files and directories without write permission.
    writeSpec out #[("cache/mod/pkg.go", "package pkg")]
    run #["chmod", "-R", "a-w", (out / "cache").toString]
    let result ← (workspaces.materialize id out).toBaseIO
    run #["chmod", "-R", "u+w", out.toString]  -- so the scratch directory can be cleaned
    match result with
    | .ok _ => assertEqual "files" (← readSpec out) (← readSpec source)
    | .error error => fail s!"could not replace a read-only tree: {error.describe}",

  onEach "an edit that keeps a file's size and modification time is captured" fun workspaces => do
    let source ← source
    let file := source / "node_modules/pkg/package.json"
    writeSpec source #[("node_modules/pkg/package.json", "{\"version\":\"1.0.0\"}")]
    -- npm gives every installed file this time, whatever the version.
    run #["touch", "-t", "198510260815.00", file.toString]
    let _ ← assertOk <| workspaces.snapshot source
    IO.FS.writeFile file "{\"version\":\"1.0.1\"}"
    run #["touch", "-t", "198510260815.00", file.toString]
    let id ← assertOk <| workspaces.snapshot source
    let bytes? ← assertOk <| workspaces.readFile? id "node_modules/pkg/package.json"
    assertEqual "content" (bytes?.bind String.fromUTF8?) (some "{\"version\":\"1.0.1\"}"),

  onEach "an executable with a newline in its name keeps its bit" fun workspaces => do
    let source ← source
    let name := "run\nme.sh"
    writeSpec source #[(name, "#!/bin/sh\n")]
    setExecutable (source / name)
    let id ← assertOk <| workspaces.snapshot source
    let out := (← scratch) / "out"
    assertOk <| workspaces.materialize id out
    let listing ← IO.Process.output { cmd := "ls", args := #["-l", (out / name).toString] }
    check (listing.stdout.startsWith "-rwx") s!"the executable bit was lost: {listing.stdout}",

  onEach "diff reports added, removed and modified paths, a directory for its subtree" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let before ← assertOk <| workspaces.snapshot source
    IO.FS.writeFile (source / "README.md") "readme, edited"
    IO.FS.removeDirAll (source / "src/lib")
    writeSpec source #[("docs/a.md", "a"), ("docs/deep/b.md", "b"), ("new.txt", "new")]
    let after ← assertOk <| workspaces.snapshot source
    assertEqual "changes" (summary (← assertOk <| workspaces.diff before after)) #[
      (.modified, "README.md", false), (.added, "docs", true), (.added, "new.txt", false),
      (.removed, "src/lib", true)]
    assertEqual "no changes" (summary (← assertOk <| workspaces.diff after after)) #[],

  onEach "a file replaced by a directory, or the reverse, is a removal and an addition" fun workspaces => do
    let source ← source
    writeSpec source #[("toDir", "file"), ("toEmptyDir", "file"), ("toFile/inner.txt", "inner"),
      ("toLink", "file"), ("keep", "keep")]
    let before ← assertOk <| workspaces.snapshot source
    IO.FS.removeFile (source / "toDir")
    writeSpec source #[("toDir/new.txt", "new")]
    IO.FS.removeFile (source / "toEmptyDir")
    IO.FS.createDirAll (source / "toEmptyDir")
    IO.FS.removeDirAll (source / "toFile")
    IO.FS.writeFile (source / "toFile") "now a file"
    IO.FS.removeFile (source / "toLink")
    run #["ln", "-s", "keep", (source / "toLink").toString]
    let after ← assertOk <| workspaces.snapshot source
    assertEqual "changes" (summary (← assertOk <| workspaces.diff before after)) #[
      (.removed, "toDir", false), (.added, "toDir", true),
      (.removed, "toEmptyDir", false), (.added, "toEmptyDir", true),
      (.removed, "toFile", true), (.added, "toFile", false),
      (.modified, "toLink", false)],

  onEach "a touched file is not a change" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let before ← assertOk <| workspaces.snapshot source
    run #["touch", "-t", "200001010000.00", (source / "README.md").toString]
    let after ← assertOk <| workspaces.snapshot source
    assertEqual "changes" (summary (← assertOk <| workspaces.diff before after)) #[],

  onEach "readFile? answers none for a directory and for an absent path" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let id ← assertOk <| workspaces.snapshot source
    let text (path : String) : TestM (Option String) := do
      pure ((← assertOk <| workspaces.readFile? id path).bind String.fromUTF8?)
    assertEqual "file" (← text "src/lib/util.lean") (some "util")
    assertEqual "directory" (← text "src") none
    assertEqual "absent" (← text "src/missing.lean") none
    assertEqual "escaping" (← text "../source/README.md") none,

  onEach "readFile? returns a binary file's bytes unchanged" fun workspaces => do
    let source ← source
    let bytes := deterministicBytes 7 70000
    IO.FS.writeBinFile (source / "blob.bin") bytes
    let id ← assertOk <| workspaces.snapshot source
    assertEqual "bytes" ((← assertOk <| workspaces.readFile? id "blob.bin").map (·.size)) (some bytes.size)
    check ((← assertOk <| workspaces.readFile? id "blob.bin") == some bytes) "bytes differ",

  onEach "list gives a directory's entries by name, hidden ones included, with kinds and sizes" fun workspaces => do
    let source ← source
    writeSpec source (baseSpec.push (".hidden", "h"))
    createSymlink "README.md" (source / "link")
    let id ← assertOk <| workspaces.snapshot source
    let describe (entries : Array Workspaces.Entry) :=
      entries.map fun e => (e.path, e.kind.toString, e.size)
    assertEqual "root" (describe (← assertOk <| workspaces.list id))
      #[(".hidden", "file", some 1), ("README.md", "file", some 6), ("link", "symlink", none),
        ("src", "directory", none)]
    assertEqual "nested" (describe (← assertOk <| workspaces.list id "src"))
      #[("src/lib", "directory", none), ("src/main.lean", "file", some 13)]
    assertError "a file is not a directory" (workspaces.list id "README.md") fun
      | .input m => (m.splitOn "not a directory").length > 1
      | _ => false,

  onEach "read gives a file's bytes; a directory, a link, or an absent path is an error" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let bytes := deterministicBytes 11 5000
    IO.FS.writeBinFile (source / "src" / "blob.bin") bytes
    createSymlink "README.md" (source / "link")
    let id ← assertOk <| workspaces.snapshot source
    check ((← assertOk <| workspaces.read id "src/blob.bin") == bytes) "bytes differ"
    assertEqual "text" (String.fromUTF8? (← assertOk <| workspaces.read id "src/lib/util.lean")) (some "util")
    for (path, message) in [("src", "not a regular file"), ("link", "not a regular file"),
        ("missing.txt", "no such path"), ("src/missing.txt", "no such path")] do
      assertError path (workspaces.read id path) fun
        | .input m => (m.splitOn message).length > 1
        | _ => false,

  onEach "a path through a symbolic link is refused, even to a directory in the snapshot" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    createSymlink "src" (source / "alias")
    let id ← assertOk <| workspaces.snapshot source
    for path in ["alias/main.lean", "alias/lib/util.lean"] do
      assertError path (workspaces.read id path) fun
        | .input m => (m.splitOn "crosses a non-directory").length > 1
        | _ => false
    assertError "listing" (workspaces.list id "alias") fun
      | .input m => (m.splitOn "not a directory").length > 1
      | _ => false,

  onEach "a path that is not clean and relative is refused" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let id ← assertOk <| workspaces.snapshot source
    for path in ["../README.md", "/README.md", "src/../README.md", "./README.md", "src//main.lean",
        "src/", "src\\main.lean"] do
      assertError path (workspaces.read id path) fun
        | .input m => (m.splitOn "not a clean relative path").length > 1
        | _ => false,

  onEach "retainOnly keeps the listed snapshots usable" fun workspaces => do
    let source ← source
    writeSpec source baseSpec
    let first ← assertOk <| workspaces.snapshot source
    IO.FS.writeFile (source / "README.md") "second"
    let second ← assertOk <| workspaces.snapshot source
    assertOk <| workspaces.retainOnly #[second]
    let out := (← scratch) / "out"
    assertOk <| workspaces.materialize second out
    assertEqual "kept" (← IO.FS.readFile (out / "README.md")) "second"
    -- The dropped snapshot's space is the backend's to reclaim; it must not take the kept one's.
    let _ := first
    assertEqual "still readable" ((← assertOk <| workspaces.readFile? second "src/main.lean").bind
      String.fromUTF8?) (some "def main := 1"),

  onEachBackend "transfer copies the snapshots named into a new store, each under a name of its own there" fun backend => do
    let workspaces ← backend.open
    let source ← source
    writeSpec source baseSpec
    let first ← assertOk <| workspaces.snapshot source
    -- Two snapshots of one directory as it is: each is copied, and neither stands for the other.
    let twin ← assertOk <| workspaces.snapshot source
    let before ← readSpec source
    IO.FS.writeFile (source / "README.md") "second"
    let second ← assertOk <| workspaces.snapshot source
    let after ← readSpec source
    let _ ← assertOk <| workspaces.snapshot source
    let location := (← scratch) / "moved"
    let copies ← assertOk <| workspaces.transfer #[first, second, twin, first] location
    assertEqual "a name each, in order" copies.size 4
    assertEqual "one snapshot named twice, one copy" copies[3]! copies[0]!
    check (copies[0]! != copies[2]!) "two snapshots, two copies"
    let moved ← backend.reopen location
    let out := (← scratch) / "out"
    assertOk <| moved.materialize copies[1]! out
    assertEqual "the second, as it was" (← readSpec out) after
    assertOk <| moved.materialize copies[2]! out
    assertEqual "the twin, as it was" (← readSpec out) before
    assertEqual "a diff in the new store" (summary (← assertOk <| moved.diff copies[0]! copies[1]!))
      #[(.modified, "README.md", false)]
    -- Only what was named: the store holds four snapshots, of which three were copied.
    assertError "a snapshot that was not named" (moved.materialize (← assertOk <| workspaces.snapshot source) out)
      fun _ => true
]

def pathSuite : Suite := Testing.suite "workspaces.paths" #[
  test "a path that does not exist yet resolves against the directories that do" do
    let base ← IO.FS.realPath (← scratch)
    assertEqual "absolute" (← Workspaces.resolved ((← scratch) / "new" / "deeper")) (base / "new" / "deeper")
    -- A bare name, such as a data directory given as `--data runs`, is relative to where we are.
    assertEqual "bare name" (← Workspaces.resolved "no-such-directory-here")
      ((← IO.FS.realPath (← IO.currentDir)) / "no-such-directory-here")
    check (Workspaces.overlap (base / "p") (base / "p" / "runs")) "a directory overlaps what it holds"
    check (!Workspaces.overlap (base / "p") (base / "p2")) "a shared name prefix is not an overlap",

  test "safeRelativePath accepts only clean relative paths" do
    for good in ["a", "a/b.txt", ".hidden/x", "run\nme.sh"] do
      check (Workspaces.safeRelativePath good) s!"{good.quote} should be accepted"
    for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "./a"] do
      check (!Workspaces.safeRelativePath bad) s!"{bad.quote} should be rejected"
]

/-- What only the real store can get wrong. -/
def resticSuite : Suite := Testing.suite "workspaces.restic" #[
  test "the run's own storage is refused as a checkout target and as a snapshot source" do
    let data := (← scratch) / "data"
    let store ← assertOk <| Store.create (data / "entries")
    let workspaces ← assertOk <| Workspaces.Restic.open (data / "restic") (data / "restic-scratch") (keep := #[store.dir])
    let project ← source
    writeSpec project baseSpec
    let id ← assertOk <| workspaces.snapshot project
    let refused (label : String) (action : Result Unit) : TestM Unit :=
      assertError label action fun | .input _ => true | _ => false
    -- `restore --delete` into any of these would delete the entries or the repository.
    for target in [data, (← scratch), data / "entries", data / "restic", data / "restic" / "inside"] do
      refused s!"checkout into {target}" (workspaces.materialize id target)
    check (!(← (data / "restic" / "inside").pathExists)) "a refused target was created"
    refused "snapshot of the data directory" (discard <| workspaces.snapshot data)
    refused "snapshot of a project holding it" (discard <| workspaces.snapshot (← scratch))
    -- Nothing was touched, and a directory beside the storage is still fine.
    check (← (data / "entries").isDir) "the entries survive"
    assertOk <| workspaces.materialize id (data / "work")
    assertEqual "checked out" (← readSpec (data / "work")) (← readSpec project)
]

/-- A run's own operations over a real repository, where the other suites use copies. -/
def runSuite : Suite := Testing.suite "workspaces.run" #[
  test "a run, a person's change, a grader, and a removal, over restic" do
    let store ← assertOk <| Store.create ((← scratch) / "entries")
    let workspaces ← assertOk <| Workspaces.Restic.open ((← scratch) / "restic") ((← scratch) / "restic-scratch")
    let project ← source
    writeSpec project baseSpec
    -- An agent that waits for a message: it runs no command.
    let run := Scripted.runOf fun _ => do
      let _ ← await fun _ notice => notice matches .said _
      return "done"
    let work := (← scratch) / "work"
    IO.FS.createDirAll work
    let executor ← containerExecutor
    let rt : Driver.Runtime := {
      store, workspaces, workDir := work, outputsDir := (← scratch) / "outputs"
      executor := fun _ => pure executor, model := fun _ => throw <| .input "no model" }
    let (root, _) ← assertOk <| Notices.create store workspaces project
    let (called, _) ← assertOk <| Driver.append store run root (Scripted.callAgent)
    let (tip, stop) ← assertOk <| Driver.drive rt run called
    check (stop matches .waits ⟪"agent"⟫ none) "the agent waits for a message"
    IO.FS.writeFile (project / "README.md") "readme, by hand"
    writeSpec project #[("tests/extra.txt", "extra")]
    let event ← assertOk <| Notices.changed store workspaces tip project
    let .arrived (.changed after summary) := event | fail "a change is a notice"
    assertEqual "what changed" summary "M README.md\n+ tests"
    let (changed, _) ← assertOk <| Driver.append store run tip event
    -- Graded there: the agent is stopped, and the grader reads the person's files.
    let grader := Scripted.graderCall "test -f tests/extra.txt && printf '1..1\\nok 1\\n'" (← testImage)
    let (graded, verdict) ← Scripted.grade rt run changed grader
    assertEqual "the verdict" (Agents.Grader.verdictStatus verdict) "pass"
    -- The point before the change, graded by the same grader, where the file is not there: the
    -- script prints nothing, which is an error.
    let (_, verdict) ← Scripted.grade rt run tip grader
    assertEqual "graded without the person's file" (Agents.Grader.verdictStatus verdict) "error"
    let log ← assertOk <| store.log (← assertOk store.forest) graded
    -- Removing from the change drops its snapshots and keeps the root's.
    -- The change, the stop, the grader's call, its read, its opening, its command, and its return.
    assertEqual "removed" (← assertOk <| Notices.remove store workspaces changed) 7
    let out := (← scratch) / "out"
    assertOk <| workspaces.materialize ((workspace? (log.extract 0 1)).getD default) out
    assertEqual "root intact" (← IO.FS.readFile (out / "README.md")) "readme"
    assertError "dropped" (workspaces.materialize after out) fun
      | .storage _ => true
      | _ => false
]

end WorkspacesTests
