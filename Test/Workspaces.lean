import Test.Framework
import Test.DirectoryWorkspaces
import Alaya

/-! The `Workspaces` contract — what the trajectory relies on, and the filesystem cases a
snapshot store has to get right — run against restic, and against the directory copies that
stand in for it in the other tests, so that those test against something faithful. -/

namespace WorkspacesTests

open Testing Alaya
open Alaya.Workspaces (Change ChangeKind)
open Alaya.Trajectory (createRoot commit diffLines evaluate getState removeSubtree)

private structure Backend where
  name : String
  /-- The store over a fresh location under the test's scratch directory. -/
  «open» : TestM Workspaces

private def backends : Array Backend := #[
  { name := "restic", «open» := do assertOk <| Workspaces.Restic.open ((← scratch) / "restic") },
  { name := "copies", «open» := Testing.workspaces }]

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
      String.fromUTF8?) (some "def main := 1")
]

def pathSuite : Suite := Testing.suite "workspaces.paths" #[
  test "safeRelativePath accepts only clean relative paths" do
    for good in ["a", "a/b.txt", ".hidden/x", "run\nme.sh"] do
      check (Workspaces.safeRelativePath good) s!"{good.quote} should be accepted"
    for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "./a"] do
      check (!Workspaces.safeRelativePath bad) s!"{bad.quote} should be rejected"
]

/-- The trajectory's own operations over a real repository, where the other suites use copies. -/
def trajectorySuite : Suite := Testing.suite "workspaces.trajectory" #[
  test "a root, a commit, its diff, an evaluation and a removal, over restic" do
    let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
    let workspaces ← assertOk <| Workspaces.Restic.open ((← scratch) / "restic")
    let project ← source
    writeSpec project baseSpec
    let root ← assertOk <| createRoot store workspaces #[] project (some "t")
    IO.FS.writeFile (project / "README.md") "readme, by hand"
    writeSpec project #[("tests/extra.txt", "extra")]
    let child ← assertOk <| commit store workspaces root project (some "by hand") (tell? := some "look")
    assertEqual "diff" (← assertOk <| diffLines store workspaces root child) #["M README.md", "+ tests"]
    assertEqual "notice" ((← assertOk <| getState store child).intervention?.map (·.changed))
      (some #["M README.md", "+ tests"])
    let verdict ← assertOk <| evaluate store workspaces ((← scratch) / "eval") child
      "test -f {checkout}/tests/extra.txt && echo seen > {out}/log.txt"
    let evaluation? := (← assertOk <| getState store verdict).evaluation?
    assertEqual "passed" (evaluation?.map (·.passed)) (some true)
    let some evidence := evaluation?.bind (·.evidence?) | fail "the grader's output was not kept"
    assertEqual "evidence" ((← assertOk <| workspaces.readFile? evidence "log.txt").bind String.fromUTF8?)
      (some "seen\n")
    -- Removing the commit's subtree drops its snapshots and keeps the root's.
    assertEqual "removed" (← assertOk <| removeSubtree store workspaces child) 2
    let out := (← scratch) / "out"
    assertOk <| workspaces.materialize (← assertOk <| getState store root).workspace out
    assertEqual "root intact" (← IO.FS.readFile (out / "README.md")) "readme"
    assertError "dropped" (workspaces.materialize evidence out) fun
      | .storage _ => true
      | _ => false
]

end WorkspacesTests
