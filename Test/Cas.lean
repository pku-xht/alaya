import Test.Framework
import Alaya.Cas
import Alaya.Cas.Legacy

/-! Behavior tests for native Git snapshots: commits and history, index and checkout
semantics, independent workspaces, refs, and explicit legacy imports. -/

namespace CasTests

open Testing
open Alaya
open Alaya.Cas

private def isStorage : Error -> Bool
  | .storage _ => true
  | _ => false

private def storageMentions (key : String) : Error -> Bool
  | .storage message => (message.splitOn key).length > 1
  | _ => false

private def shellLiteral (value : String) : String :=
  "'" ++ value.replace "'" "'\\''" ++ "'"

private def withStore : TestM Store := do
  assertOk <| Store.create ((← scratch) / "store")

/-- A small tree with nesting, duplicate content (`c.txt` = `dup.txt`), and a sibling
directory that most tests leave untouched. -/
private def baseSpec : Array (String × String) := #[
  ("a/b/c.txt", "content-c"), ("a/b/d.txt", "content-d"), ("a/e.txt", "content-e"),
  ("dup.txt", "content-c"), ("shared/s.txt", "content-s")]

private def sourceDir : TestM System.FilePath := return (← scratch) / "source"

private def snapshotSpec (store : Store) (spec : Array (String × String)) : TestM Hash := do
  let source ← sourceDir
  writeSpec source spec
  assertOk <| store.snapshot source

private def command (cmd : String) (args : Array String) : TestM String := do
  let out ← IO.Process.output { cmd, args }
  assertEqual s!"{cmd}: {out.stderr}" out.exitCode 0
  pure out.stdout

private def git (store : Store) (args : Array String) : TestM String :=
  command "git" (#["--git-dir", store.gitDir.toString] ++ args)

private def projectGit (directory : System.FilePath) (args : Array String) : TestM String :=
  command "git" (#["-C", directory.toString] ++ args)

private def commitProject (directory : System.FilePath) (message : String) : TestM Hash := do
  let _ ← projectGit directory #["add", "-A"]
  let _ ← projectGit directory #["-c", "user.name=Alaya test", "-c", "user.email=test@example.invalid",
    "-c", "commit.gpgsign=false", "commit", "-q", "-m", message]
  pure ⟨(← projectGit directory #["rev-parse", "HEAD"]).trimAscii.toString⟩

/-- Compare checkout contents without reading Git's binary database or repository-local
configuration. Those are tested through Git's own interfaces instead. -/
private partial def readWorktreeInto (base : System.FilePath) (relative : String)
    (accumulated : Array (String × String)) : IO (Array (String × String)) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  (← directory.readDir).foldlM (init := accumulated) fun accumulated child => do
    if child.fileName == ".git" then return accumulated
    let path := if relative.isEmpty then child.fileName else s!"{relative}/{child.fileName}"
    match (← child.path.symlinkMetadata).type with
    | .dir => readWorktreeInto base path accumulated
    | .symlink => pure (accumulated.push (path, "-> " ++ (← readSymlink child.path)))
    | _ => pure (accumulated.push (path, ← IO.FS.readFile child.path))

private def readWorktree (base : System.FilePath) : IO (Array (String × String)) := do
  pure ((← readWorktreeInto base "" #[]).qsort fun a b => compare a.1 b.1 == .lt)

private def missingHash : Hash := ⟨String.ofList (List.replicate 40 'a')⟩

/-- Manufacture the historical on-disk format without using the new implementation. -/
private def legacyBlob (store : Store) (bytes : ByteArray) : TestM Hash := do
  let hash : Hash := ⟨Sha256.sumHex bytes⟩
  let parent := store.root / "blobs" / (hash.hex.take 2).toString
  IO.FS.createDirAll parent
  IO.FS.writeBinFile (parent / hash.hex) bytes
  pure hash

private def legacyTree (store : Store) (tree : Tree) : TestM Hash :=
  legacyBlob store tree.toJson.compress.toUTF8

/-! ## Objects and blobs -/

def objectSuite : Suite := suite "cas.objects" #[
  test "blob roundtrip and dedup" do
    let store ← withStore
    let bytes := "hello blobs".toUTF8
    let hash ← assertOk <| store.putBytes bytes
    assertEqual "roundtrip" ((← assertOk <| store.getBytes hash).map (·.toList))
      (some bytes.toList)
    let again ← assertOk <| store.putBytes bytes
    assertEqual "stable address" again hash
    assertEqual "native blob" (← git store #["cat-file", "-t", hash.hex]) "blob\n"
    assertEqual "object exists" (← assertOk <| store.hasBytes hash) true
    assertEqual "missing blob" (← assertOk <| store.getBytes missingHash) none,

  test "tree roundtrip preserves entries and types" do
    let store ← withStore
    let blob ← assertOk <| store.putBytes "x".toUTF8
    let tree := Tree.ofEntries #[
      { name := "z.txt", type := .file, hash := blob },
      { name := "run.sh", type := .executable, hash := blob },
      { name := "link", type := .symlink, hash := blob }]
    let hash ← assertOk <| store.putTree tree
    let loaded ← assertOk <| store.getTree hash
    assertEqual "canonical order survives" loaded tree
    assertEqual "sorted by name" (loaded.entries.map (·.name)) #["link", "run.sh", "z.txt"]
    assertEqual "native tree" (← git store #["cat-file", "-t", hash.hex]) "tree\n"
    assertEqual "default SHA-1 repository" (← git store #["rev-parse", "--show-object-format"]) "sha1\n"
    assertEqual "native SHA-1 object ID" hash.hex.length 40,

  test "tree parsing rejects hostile input" do
    let bad (json : String) : TestM Unit := do
      match Lean.Json.parse json with
      | .error _ => fail "test fixture is not JSON"
      | .ok json =>
        match Tree.fromJson json with
        | .ok _ => fail s!"accepted hostile tree: {json}"
        | .error _ => pure ()
    let hex := String.ofList (List.replicate 40 'a')
    let entry (name type hash : String) : String :=
      "{\"name\": \"" ++ name ++ "\", \"type\": \"" ++ type ++ "\", \"hash\": \"" ++ hash ++ "\"}"
    bad ("[" ++ entry "../x" "file" hex ++ "]")
    bad ("[" ++ entry "a/b" "file" hex ++ "]")
    bad ("[" ++ entry "x" "file" "../escape" ++ "]")
    bad ("[" ++ entry "x" "weird" hex ++ "]")
    bad ("[" ++ entry "x" "file" hex ++ ", " ++ entry "x" "dir" hex ++ "]"),

  test "missing tree is a storage error" do
    let store ← withStore
    assertError "getTree" (store.getTree missingHash) isStorage,

  test "binary blobs keep every byte" do
    let store ← withStore
    let bytes := deterministicBytes 42 65537
    let hash ← assertOk <| store.putBytes bytes
    assertEqual "binary roundtrip" ((← assertOk <| store.getBytes hash).map (·.toList))
      (some bytes.toList)
    let empty ← assertOk <| store.putBytes ByteArray.empty
    assertEqual "empty blob" ((← assertOk <| store.getBytes empty).map (·.size)) (some 0),

  test "invalid hashes cannot address paths or git options" do
    let store ← withStore
    for value in ["../outside", "--help", "HEAD", "", "deadbeef"] do
      assertError "getBytes" (store.getBytes ⟨value⟩) isStorage
      assertError "getTree" (store.getTree ⟨value⟩) isStorage
]

/-! ## Feature 2: Merkle trees -/

def merkleSuite : Suite := suite "cas.merkle" #[
  test "snapshot is deterministic and content dedupes" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let again ← assertOk <| store.snapshot (← sourceDir)
    assertEqual "same root hash" again root
    assertEqual "native snapshot commit" (← git store #["cat-file", "-t", root.hex]) "commit\n"
    assertEqual "HEAD is the snapshot" (← projectGit (← sourceDir) #["rev-parse", "HEAD"])
      (root.hex ++ "\n")
    assertEqual "the real index matches the commit tree"
      (← projectGit (← sourceDir) #["write-tree"])
      (← git store #["rev-parse", root.hex ++ "^{tree}"])
    assertEqual "staging and worktree are clean"
      (← projectGit (← sourceDir) #["status", "--porcelain"]) ""
    let c ← assertOk <| store.entryAt? root "a/b/c.txt"
    let dup ← assertOk <| store.entryAt? root "dup.txt"
    assertEqual "identical content shares a blob" (c.map (·.hash)) (dup.map (·.hash)),

  test "unchanged subtrees keep their hash across snapshots" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    writeSpec (← sourceDir) #[("a/b/c.txt", "changed-c")]
    let v2 ← assertOk <| store.snapshot (← sourceDir)
    check (v1 != v2) "root must change"
    let sharedBefore ← assertOk <| store.entryAt? v1 "shared"
    let sharedAfter ← assertOk <| store.entryAt? v2 "shared"
    assertEqual "sibling subtree shared" sharedAfter sharedBefore
    let changedBefore ← assertOk <| store.entryAt? v1 "a"
    let changedAfter ← assertOk <| store.entryAt? v2 "a"
    check (changedBefore != changedAfter) "changed spine must differ",

  test "empty directories are not tracked by Git" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("keep.txt", "k")]
    IO.FS.createDirAll (source / "empty" / "nested")
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "empty path is absent" (← assertOk <| store.entryAt? root "empty") none
    check (!(← (destination / "empty").pathExists)) "checkout has no empty directory",

  test "snapshots survive closing the handle and losing the original workspace" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "keep" root
    IO.FS.removeDirAll (← sourceDir)
    let reopened ← assertOk <| Store.create store.root
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize root destination
    assertEqual "restored after reopen" (← readWorktree destination) baseSpec
]

/-! ## Feature 2: diff -/

def diffSuite : Suite := suite "cas.diff" #[
  test "identical snapshots have an empty diff" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertEqual "no changes" (← assertOk <| store.diff root root) #[],

  test "add, remove, and modify are reported with paths" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let source ← sourceDir
    IO.FS.removeFile (source / "a" / "e.txt")
    writeSpec source #[("a/b/c.txt", "changed-c"), ("new/n.txt", "brand new")]
    let v2 ← assertOk <| store.snapshot source
    let changes ← assertOk <| store.diff v1 v2
    let names := (changes.map (·.path)).qsort (compare · · == .lt)
    assertEqual "changed paths" names #["a/b/c.txt", "a/e.txt", "new"]
    for change in changes do
      match change with
      | .modified path type _ =>
        assertEqual "modified path" path "a/b/c.txt"
        assertEqual "modified type" type .file
      | .removed path type =>
        assertEqual "removed path" path "a/e.txt"
        assertEqual "removed type" type .file
      | .added path type _ =>
        assertEqual "added path" path "new"
        assertEqual "added dir stands for its subtree" type .directory,

  test "a type change is a removal plus an addition" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("x", "i was a file")]
    let v1 ← assertOk <| store.snapshot source
    IO.FS.removeFile (source / "x")
    writeSpec source #[("x/inner.txt", "now a directory")]
    let v2 ← assertOk <| store.snapshot source
    let changes ← assertOk <| store.diff v1 v2
    assertEqual "two changes" changes.size 2
    check (changes.any fun c => c matches .removed "x" .file) "file removed"
    check (changes.any fun c => c matches .added "x" .directory _) "directory added"
]

/-! ## Git checkout and independent workspaces -/

def materializeSuite : Suite := suite "cas.materialize" #[
  test "roundtrip reproduces tracked source contents" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "specs equal" (← readWorktree destination) (← readWorktree (← sourceDir)),

  test "a second materialize removes files absent from the new snapshot" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    let source ← sourceDir
    IO.FS.removeFile (source / "dup.txt")
    writeSpec source #[("a/b/c.txt", "changed-c")]
    let v2 ← assertOk <| store.snapshot source
    assertOk <| store.materialize v2 destination
    assertEqual "destination matches v2" (← readWorktree destination) (← readWorktree source),

  test "an untracked non-empty destination errors when asked to" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "do not delete")]
    assertError "materialize" (store.materialize root destination { onExisting := .error })
      isStorage
    assertEqual "destination untouched"
      (← IO.FS.readFile (destination / "precious.txt")) "do not delete"
    -- The default checks out the commit and cleans ordinary untracked files.
    assertOk <| store.materialize root destination
    assertEqual "replaced" (← readWorktree destination) (← readWorktree (← sourceDir)),

  test "a checkout into a directory that was removed writes the whole snapshot" do
    let store ← assertOk <| Store.create ((← scratch) / "store")
    let source := (← scratch) / "source"
    writeSpec source #[("keep.txt", "same"), ("change.txt", "one")]
    let v1 ← assertOk <| store.snapshot source
    writeSpec source #[("change.txt", "two")]
    let v2 ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    IO.FS.removeDirAll destination
    assertOk <| store.materialize v2 destination
    assertEqual "whole snapshot" (← readWorktree destination)
      #[("change.txt", "two"), ("keep.txt", "same")],

  test "restoring repairs tampering without modifying the stored snapshot" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    IO.FS.writeFile (destination / "shared" / "s.txt") "tampered"
    writeSpec destination #[("extra/abandoned.txt", "from another branch")]
    assertOk <| store.materialize v1 destination
    assertEqual "exact restored contents" (← readWorktree destination) baseSpec,

  test "materialized files are independent editable copies" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    IO.FS.writeFile (destination / "a" / "e.txt") "agent edited this"
    assertEqual "stored blob unchanged"
      ((← assertOk <| store.readPath root "a/e.txt").map (String.fromUTF8? ·))
      (some (some "content-e")),

  test "binary data and unusual UTF-8 paths are restored verbatim" do
    let store ← withStore
    let source ← sourceDir
    let names := #["中文 文件.txt", "line\nbreak.txt", "tab\tname.txt", "-leading-option"]
    IO.FS.createDirAll source
    let bytes := ByteArray.mk #[0, 255, 128, 13, 10, 0, 42]
    for name in names do IO.FS.writeBinFile (source / name) bytes
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    for name in names do
      assertEqual s!"raw bytes for {name}" (← IO.FS.readBinFile (destination / name)).toList bytes.toList
    assertEqual "only captured names besides Git metadata"
      ((← destination.readDir).filter (·.fileName != ".git")).size names.size,

  test "restoring replaces file-directory conflicts and does not follow destination links" do
    let store ← withStore
    let root ← snapshotSpec store #[("dir/child.txt", "inside"), ("file.txt", "plain")]
    let destination := (← scratch) / "out"
    let outside := (← scratch) / "outside"
    writeSpec outside #[("child.txt", "do not touch")]
    writeSpec destination #[("file.txt/was-a-directory.txt", "old")]
    createSymlink (← IO.FS.realPath outside).toString (destination / "dir")
    assertOk <| store.materialize root destination
    assertEqual "destination contents" (← readWorktree destination)
      #[("dir/child.txt", "inside"), ("file.txt", "plain")]
    assertEqual "outside untouched" (← IO.FS.readFile (outside / "child.txt")) "do not touch",

  test "a missing snapshot leaves an existing destination intact" do
    let store ← withStore
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "keep me")]
    assertError "missing snapshot" (store.materialize missingHash destination) isStorage
    assertEqual "destination preserved" (← readWorktree destination) #[("precious.txt", "keep me")],

  test "snapshots and materializations cannot overlap the store" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertError "capture store itself" (store.snapshot store.root) isStorage
    assertError "capture ancestor" (store.snapshot (← scratch)) isStorage
    assertError "restore store itself" (store.materialize root store.root) isStorage
    assertError "restore descendant" (store.materialize root (store.root / "nested")) isStorage
    assertError "restore ancestor" (store.materialize root (← scratch)) isStorage
    assertEqual "snapshot still readable" ((← assertOk <| store.readPath root "dup.txt").map
      (String.fromUTF8? ·)) (some (some "content-c")),

  test "destination aliases are normalized before overlap checks and replacement" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let base ← scratch
    for target in #[store.root / ".", store.root / "missing" / "..",
        base / "missing" / ".." / "store", store.root / ".."] do
      assertError s!"restore alias {target}" (store.materialize root target) isStorage
    check (!(← (store.root / "missing").pathExists)) "no store-side directory created"
    check (!(← (base / "missing").pathExists)) "no future ancestor created"
    let destination := base / "out"
    writeSpec destination #[("old.txt", "replace me")]
    assertOk <| store.materialize root (destination / ".")
    assertEqual "dot destination" (← readWorktree destination) baseSpec
    IO.FS.writeFile (destination / "dup.txt") "tampered"
    assertOk <| store.materialize root (destination / "missing" / "..")
    assertEqual "dot-dot destination" (← readWorktree destination) baseSpec
    let alias := base / "alias"
    createSymlink destination.toString alias
    assertError "final symlink" (store.materialize root alias) isStorage
    assertError "final symlink with trailing slash"
      (store.materialize root ⟨alias.toString ++ "/"⟩) isStorage
    assertEqual "link target preserved" (← readWorktree destination) baseSpec
    assertEqual "store preserved" ((← assertOk <| store.readPath root "dup.txt").map
      (String.fromUTF8? ·)) (some (some "content-c"))
]

/-! ## Feature 5: metadata -/

def metadataSuite : Suite := suite "cas.metadata" #[
  test "the executable bit survives a roundtrip" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("run.sh", "#!/bin/sh\necho hi\n"), ("plain.txt", "text")]
    setExecutable (source / "run.sh")
    let root ← assertOk <| store.snapshot source
    assertEqual "captured as executable"
      ((← assertOk <| store.entryAt? root "run.sh").map (·.type)) (some .executable)
    assertEqual "plain stays a file"
      ((← assertOk <| store.entryAt? root "plain.txt").map (·.type)) (some .file)
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    check (← isExecutable (destination / "run.sh")) "restored executable"
    check (!(← isExecutable (destination / "plain.txt"))) "restored non-executable",

  test "symlinks roundtrip as links, including dangling and cyclic ones" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("target.txt", "pointed at")]
    createSymlink "target.txt" (source / "alias")
    createSymlink "does-not-exist" (source / "dangling")
    createSymlink "." (source / "self")  -- would recurse forever if followed
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "relative link" (← readSymlink (destination / "alias")) "target.txt"
    assertEqual "dangling link" (← readSymlink (destination / "dangling")) "does-not-exist"
    assertEqual "cyclic link" (← readSymlink (destination / "self")) ".",

  test "symlink targets retain leading and trailing whitespace" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let target := " target with spaces\t\n"
    createSymlink target (source / "link")
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    -- readlink adds one newline; keep the target's own whitespace distinct from it.
    assertEqual "target bytes" (← command "readlink" #[(destination / "link").toString]) (target ++ "\n")
]

/-! ## Native index, ignores, and attributes -/

def ignoreSuite : Suite := suite "cas.ignore" #[
  test "gitignore excludes untracked files but tracked ignored files stay tracked" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[
      (".gitignore", "*.log\nbuild/\n"), ("keep.txt", "tracked")]
    let first ← assertOk <| store.snapshot source
    writeSpec source #[
      (".gitignore", "*.log\nbuild/\nkeep.txt\n"), ("keep.txt", "tracked edit"),
      ("debug.log", "noise"), ("build/out.bin", "artifact")]
    let root ← assertOk <| store.snapshot source
    check (first != root) "tracked edits create a commit"
    assertEqual "only tracked files" ((← assertOk <| store.listPaths root).map (·.1))
      #[".gitignore", "keep.txt"]
    assertEqual "tracked ignored file is updated" ((← assertOk <| store.readPath root "keep.txt").map
      (String.fromUTF8? ·)) (some (some "tracked edit"))
    assertEqual "ignored file is absent" (← assertOk <| store.readPath root "debug.log") none,

  test "repeated native index captures record deletion rename and newly included files" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[(".gitignore", "later.txt\n"), ("delete.txt", "delete"),
      ("old.txt", "move"), ("later.txt", "include later")]
    let first ← assertOk <| store.snapshot source
    IO.FS.removeFile (source / "delete.txt")
    IO.FS.rename (source / "old.txt") (source / "renamed.txt")
    writeSpec source #[(".gitignore", ""), ("new.txt", "added")]
    let second ← assertOk <| store.snapshot source
    assertEqual "index has no stale paths" ((← assertOk <| store.listPaths second).map (·.1))
      #[".gitignore", "later.txt", "new.txt", "renamed.txt"]
    assertEqual "unchanged index reuses HEAD" (← assertOk <| store.snapshot source) second
    let destination := (← scratch) / "out"
    assertOk <| store.materialize second destination
    assertEqual "checkout agrees with current files" (← readWorktree destination) (← readWorktree source)
    assertEqual "earlier snapshot retains deleted file" ((← assertOk <| store.readPath first "delete.txt").map
      (String.fromUTF8? ·)) (some (some "delete")),

  test "checkout removes untracked files and retains ignored files" do
    let store ← withStore
    let root ← snapshotSpec store #[(".gitignore", "cache/\n"), ("keep.txt", "saved")]
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    writeSpec destination #[("keep.txt", "edit"), ("junk.txt", "untracked"),
      ("cache/result.txt", "ignored cache")]
    assertOk <| store.materialize root destination
    assertEqual "tracked file restored" (← IO.FS.readFile (destination / "keep.txt")) "saved"
    check (!(← (destination / "junk.txt").pathExists)) "untracked file cleaned"
    assertEqual "ignored file retained" (← IO.FS.readFile (destination / "cache" / "result.txt"))
      "ignored cache",

  test "native attributes normalize content in the index and checkout" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[(".gitattributes", "*.txt text eol=lf\n"), ("message.txt", "one\r\ntwo\r\n")]
    let root ← assertOk <| store.snapshot source
    assertEqual "Git stores normalized content" ((← assertOk <| store.readPath root "message.txt").map
      (String.fromUTF8? ·)) (some (some "one\ntwo\n"))
    assertEqual "add does not rewrite source file" (← IO.FS.readFile (source / "message.txt")) "one\r\ntwo\r\n"
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "checkout applies attributes" (← IO.FS.readFile (destination / "message.txt")) "one\ntwo\n",

  test "snapshot rejects external clean filters before they can run on the host" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "git" #["init", "-q", source.toString]
    writeSpec source #[(".gitattributes", "*.txt filter=probe\n"), ("message.txt", "unfiltered content\n")]
    let marker := (← IO.FS.realPath (← scratch)) / "clean-ran"
    let _ ← projectGit source #["config", "filter.probe.clean",
      "printf clean > " ++ shellLiteral marker.toString ++ "; cat"]
    let _ ← projectGit source #["config", "filter.probe.required", "true"]
    assertError "external clean filter" (store.snapshot source) (storageMentions "filter.probe.clean")
    check (!(← marker.pathExists)) "rejected clean command was not executed"
    assertEqual "source content is intact" (← IO.FS.readFile (source / "message.txt")) "unfiltered content\n",

  test "checkout rejects external smudge filters and disables fsmonitor commands" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[(".gitattributes", "*.txt filter=probe\n"), ("message.txt", "saved content\n")]
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    let base ← IO.FS.realPath (← scratch)
    let smudgeMarker := base / "smudge-ran"
    let _ ← projectGit destination #["config", "filter.probe.smudge",
      "printf smudge > " ++ shellLiteral smudgeMarker.toString ++ "; cat"]
    let _ ← projectGit destination #["config", "filter.probe.required", "true"]
    IO.FS.removeFile (destination / "message.txt")
    assertError "external smudge filter" (store.materialize root destination)
      (storageMentions "filter.probe.smudge")
    check (!(← smudgeMarker.pathExists)) "rejected smudge command was not executed"
    let _ ← projectGit destination #["config", "--unset", "filter.probe.smudge"]
    let _ ← projectGit destination #["config", "--unset", "filter.probe.required"]
    let monitorMarker := base / "fsmonitor-ran"
    let monitor := base / "fsmonitor-probe.sh"
    IO.FS.writeFile monitor ("#!/bin/sh\nprintf fsmonitor > " ++ shellLiteral monitorMarker.toString ++ "\n")
    setExecutable monitor
    let _ ← projectGit source #["config", "core.fsmonitor", monitor.toString]
    let _ ← projectGit destination #["config", "core.fsmonitor", monitor.toString]
    writeSpec source #[("message.txt", "updated content\n")]
    let updated ← assertOk <| store.snapshot source
    check (!(← monitorMarker.pathExists)) "capture did not execute the configured fsmonitor"
    assertOk <| store.materialize updated destination
    check (!(← monitorMarker.pathExists)) "checkout did not execute the configured fsmonitor"
    assertEqual "normal checkout still succeeds" (← IO.FS.readFile (destination / "message.txt")) "updated content\n",

  test "checkout rejects redirects of the snapshot store and permits ordinary remotes" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "git" #["init", "-q", source.toString]
    let _ ← projectGit source #["config", "remote.origin.url", "https://example.invalid/project.git"]
    writeSpec source #[("message.txt", "snapshot content")]
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    IO.FS.createDirAll destination
    let _ ← command "git" #["init", "-q", destination.toString]
    writeSpec destination #[("message.txt", "existing tracked content")]
    let original ← commitProject destination "Existing destination history"
    let wrong := (← IO.FS.realPath (← scratch)) / "nonexistent-remote"
    let key := "url." ++ wrong.toString ++ ".insteadOf"
    for pathPrefix in #[store.gitDir.toString, ""] do
      let _ ← projectGit destination #["config", key, pathPrefix]
      assertError "internal store URL redirect" (store.materialize root destination)
        (storageMentions "redirects the snapshot store")
      assertEqual "rejected checkout retains tracked content"
        (← IO.FS.readFile (destination / "message.txt")) "existing tracked content"
      assertEqual "rejected checkout retains HEAD" (← projectGit destination #["rev-parse", "HEAD"])
        (original.hex ++ "\n")
]

/-! ## Native project history and independent repository roots -/

def isolationSuite : Suite := suite "cas.isolation" #[
  test "snapshot and resume preserve project branches and commit ancestry" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "git" #["init", "-q", "--initial-branch=project-main", source.toString]
    writeSpec source #[("file.txt", "original")]
    let original ← commitProject source "Project history"
    assertEqual "unchanged project HEAD is reused" (← assertOk <| store.snapshot source) original
    writeSpec source #[("file.txt", "agent edit")]
    let snapshot ← assertOk <| store.snapshot source
    assertEqual "snapshot has original parent" (← projectGit source #["rev-parse", snapshot.hex ++ "^"])
      (original.hex ++ "\n")
    assertEqual "project branch has not moved" (← projectGit source #["rev-parse", "project-main"])
      (original.hex ++ "\n")
    let _ ← projectGit source #["checkout", "-q", "-b", "user-work"]
    writeSpec source #[("user.txt", "user commit")]
    let userCommit ← commitProject source "User work after snapshot"
    let latest ← assertOk <| store.snapshot source
    assertEqual "user commit reused" latest userCommit
    assertOk <| store.setRef "latest" latest
    let _ ← projectGit source #["config", "alaya.fixture", "local config"]
    assertOk <| store.restore original source
    assertEqual "existing branch still points to newer user work"
      (← projectGit source #["rev-parse", "user-work"]) (userCommit.hex ++ "\n")
    assertEqual "repository config is retained" (← projectGit source #["config", "alaya.fixture"])
      "local config\n"
    assertEqual "old files are checked out" (← IO.FS.readFile (source / "file.txt")) "original"
    let reopened ← assertOk <| Store.create store.root
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize latest destination
    assertEqual "resumed HEAD" (← projectGit destination #["rev-parse", "HEAD"]) (latest.hex ++ "\n")
    assertEqual "complete ancestor chain" (← projectGit destination #["rev-list", "--count", "HEAD"]) "3\n"
    assertEqual "original project commit is available"
      (← projectGit destination #["cat-file", "-t", original.hex]) "commit\n"
    assertEqual "new user work is available" (← IO.FS.readFile (destination / "user.txt")) "user commit",

  test "forked workspaces keep independent working trees and Git histories" do
    let store ← withStore
    let root ← snapshotSpec store #[("file.txt", "root")]
    let left := (← scratch) / "left"
    let right := (← scratch) / "right"
    assertOk <| store.materialize root left
    assertOk <| store.materialize root right
    writeSpec left #[("file.txt", "left")]
    let leftCommit ← assertOk <| store.snapshot left
    writeSpec right #[("file.txt", "right")]
    let rightCommit ← assertOk <| store.snapshot right
    check (leftCommit != rightCommit) "branches produce different commits"
    assertEqual "left parent" (← projectGit left #["rev-parse", "HEAD^"]) (root.hex ++ "\n")
    assertEqual "right parent" (← projectGit right #["rev-parse", "HEAD^"]) (root.hex ++ "\n")
    assertOk <| store.restore root left
    assertEqual "right files are untouched" (← IO.FS.readFile (right / "file.txt")) "right"
    assertEqual "right HEAD is untouched" (← projectGit right #["rev-parse", "HEAD"])
      (rightCommit.hex ++ "\n"),

  test "a workspace root does not capture or reuse an ancestor repository" do
    let store ← withStore
    let outer := (← scratch) / "outer"
    IO.FS.createDirAll outer
    let _ ← command "git" #["init", "-q", outer.toString]
    writeSpec outer #[("outside.txt", "outer repository")]
    let original ← commitProject outer "Outer history"
    let source := outer / "workspace"
    writeSpec source #[("inside.txt", "workspace only")]
    let root ← assertOk <| store.snapshot source
    assertEqual "only workspace paths" ((← assertOk <| store.listPaths root).map (·.1)) #["inside.txt"]
    assertEqual "workspace owns its repository" (← projectGit source #["rev-parse", "--show-toplevel"])
      ((← IO.FS.realPath source).toString ++ "\n")
    assertEqual "ancestor HEAD unchanged" (← projectGit outer #["rev-parse", "HEAD"])
      (original.hex ++ "\n"),

  test "mismatched object formats fail for capture and checkout" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "git" #["init", "-q", "--object-format=sha256", source.toString]
    writeSpec source #[("keep.txt", "SHA-256 project")]
    assertError "capture format mismatch" (store.snapshot source) isStorage
    let plain := (← scratch) / "plain"
    writeSpec plain #[("file.txt", "SHA-1 snapshot")]
    let root ← assertOk <| store.snapshot plain
    assertError "checkout format mismatch" (store.materialize root source) isStorage
    assertEqual "rejected checkout retains existing files" (← IO.FS.readFile (source / "keep.txt"))
      "SHA-256 project",

  test "an existing SHA-256 store uses matching native project repositories" do
    let storeRoot := (← scratch) / "store256"
    IO.FS.createDirAll storeRoot
    let _ ← command "git" #["init", "-q", "--bare", "--object-format=sha256", (storeRoot / "git").toString]
    let store ← assertOk <| Store.create storeRoot
    let source ← sourceDir
    writeSpec source #[("file.txt", "SHA-256 content")]
    let root ← assertOk <| store.snapshot source
    assertEqual "native SHA-256 ID" root.hex.length 64
    assertEqual "project matches store" (← projectGit source #["rev-parse", "--show-object-format"]) "sha256\n"
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "checkout matches store" (← projectGit destination #["rev-parse", "--show-object-format"]) "sha256\n"
    assertEqual "matching format roundtrip" (← IO.FS.readFile (destination / "file.txt")) "SHA-256 content",

  test "nested repositories are native gitlinks and are not recursively captured" do
    let store ← withStore
    let source ← sourceDir
    let nested := source / "dependency"
    IO.FS.createDirAll nested
    let _ ← command "git" #["init", "-q", nested.toString]
    writeSpec nested #[("internal.txt", "nested history")]
    let nestedCommit ← commitProject nested "Dependency commit"
    writeSpec source #[("main.txt", "parent project")]
    let root ← assertOk <| store.snapshot source
    assertEqual "gitlink points to dependency commit" (← assertOk <| store.entryAt? root "dependency")
      (some { name := "dependency", type := .gitlink, hash := nestedCommit })
    assertEqual "no recursive dependency paths" ((← assertOk <| store.listPaths root).map (·.1))
      #["dependency", "main.txt"]
    assertEqual "gitlink has no file body" (← assertOk <| store.readPath root "dependency") none
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    check (!(← (destination / "dependency" / "internal.txt").pathExists))
      "checkout does not initialize a dependency repository"
]

/-! ## Feature 7: refs and garbage collection -/

def gcSuite : Suite := suite "cas.gc" #[
  test "refs roundtrip and validate their names" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "main" root
    assertEqual "read back" (← assertOk <| store.getRef? "main") (some root)
    assertEqual "absent ref" (← assertOk <| store.getRef? "other") none
    assertOk <| store.setRef "v1.0" root
    assertEqual "listed sorted" ((← assertOk store.listRefs).map (·.1)) #["main", "v1.0"]
    assertOk <| store.deleteRef "v1.0"
    assertEqual "deleted" (← assertOk <| store.getRef? "v1.0") none
    for bad in ["", "..", "a/b", "with space"] do
      assertError s!"ref name {bad}" (store.setRef bad root) isStorage,

  test "gc keeps everything reachable from refs and drops the rest" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "keep" root
    let orphan ← assertOk <| store.putBytes "orphaned bytes".toUTF8
    assertOk store.gc
    assertEqual "orphan unreadable" (← assertOk <| store.getBytes orphan) none
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "snapshot fully intact" (← readWorktree destination) (← readWorktree (← sourceDir))
    let _ ← git store #["fsck", "--full", "--no-reflogs"]
    pure (),

  test "deleting the ref releases the snapshot" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "main" root
    assertOk store.gc
    assertOk <| store.deleteRef "main"
    assertOk store.gc
    assertError "tree gone" (store.getTree root) isStorage,

  test "an unchanged project can repopulate an unpinned collected snapshot" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk store.gc
    assertError "unpinned snapshot collected" (store.getTree root) isStorage
    let reopened ← assertOk <| Store.create store.root
    assertEqual "project HEAD survives and is fetched again"
      (← assertOk <| reopened.snapshot (← sourceDir)) root
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize root destination
    assertEqual "recovered snapshot contents" (← readWorktree destination) baseSpec,

  test "collecting one branch preserves shared objects referenced by its sibling" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "a/e.txt" "fork content".toUTF8
    assertOk <| store.setRef "original" root
    assertOk <| store.setRef "fork" forked
    assertOk <| store.deleteRef "original"
    assertOk store.gc
    let reopened ← assertOk <| Store.create store.root
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize forked destination
    assertEqual "shared bytes survive" (← IO.FS.readFile (destination / "dup.txt")) "content-c"
    assertEqual "fork bytes survive" (← IO.FS.readFile (destination / "a" / "e.txt")) "fork content"
]

/-! ## Historical raw data requires explicit import -/

def legacySuite : Suite := suite "cas.legacy" #[
  test "legacy bytes require an explicit compatibility read or import" do
    let store ← withStore
    let bytes := ByteArray.mk #[0, 255, 10, 128, 42]
    let blob ← legacyBlob store bytes
    assertError "ordinary reads reject legacy IDs" (store.getBytes blob) isStorage
    assertEqual "explicit legacy bytes" (← assertOk <| Legacy.getBytes store blob).toList bytes.toList
    let imported ← assertOk <| Legacy.importBlob store blob
    assertEqual "native imported bytes" ((← assertOk <| store.getBytes imported).map (·.toList))
      (some bytes.toList)
    assertEqual "repeated blob import is stable" (← assertOk <| Legacy.importBlob store blob) imported
    assertEqual "old blob is unchanged"
      (← IO.FS.readBinFile (store.root / "blobs" / (blob.hex.take 2).toString / blob.hex)).toList bytes.toList,

  test "explicit legacy snapshot imports are stable and preserve original archive files" do
    let store ← withStore
    let bytes := ByteArray.mk #[0, 255, 10, 128, 42]
    let blob ← legacyBlob store bytes
    let empty ← legacyTree store Tree.empty
    let child ← legacyTree store (Tree.ofEntries #[{ name := "data.bin", type := .file, hash := blob }])
    let oldTree := Tree.ofEntries #[
      { name := "empty", type := .directory, hash := empty },
      { name := "nested", type := .directory, hash := child }]
    let root ← legacyTree store oldTree
    assertError "ordinary tree reads reject legacy IDs" (store.getTree root) isStorage
    let tree ← assertOk <| Legacy.importTree store root
    assertEqual "explicit tree import produces a native tree" (← git store #["cat-file", "-t", tree.hex]) "tree\n"
    let imported ← assertOk <| Legacy.importSnapshot store root
    assertEqual "snapshot import produces a commit" (← git store #["cat-file", "-t", imported.hex]) "commit\n"
    assertEqual "imported snapshot contains imported tree" (← assertOk <| store.treeHash imported) tree
    assertEqual "legacy bytes through native snapshot" ((← assertOk <| store.readPath imported "nested/data.bin").map
      (·.toList)) (some bytes.toList)
    let destination := (← scratch) / "out"
    assertOk <| store.materialize imported destination
    assertEqual "binary legacy materialization" (← IO.FS.readBinFile (destination / "nested" / "data.bin")).toList bytes.toList
    check (!(← (destination / "empty").pathExists)) "empty directories are outside native Git snapshots"
    assertOk store.gc
    let reopened ← assertOk <| Store.create store.root
    assertEqual "repeated tree import after reopen and GC is stable"
      (← assertOk <| Legacy.importTree reopened root) tree
    assertEqual "repeated snapshot import after reopen and GC is stable"
      (← assertOk <| Legacy.importSnapshot reopened root) imported
    assertEqual "recapture reuses imported commit" (← assertOk <| reopened.snapshot destination) imported
    assertEqual "old raw tree file unchanged"
      (← IO.FS.readBinFile (store.root / "blobs" / (root.hex.take 2).toString / root.hex)).toList
      oldTree.toJson.compress.toUTF8.toList
    let metadata ← legacyTree store (Tree.ofEntries #[{ name := ".git", type := .directory, hash := child }])
    assertError "legacy repository metadata requires deliberate migration"
      (Legacy.importSnapshot reopened metadata) isStorage
]

/-! ## Pure path operations (cheap branching) -/

def pathOpsSuite : Suite := suite "cas.pathops" #[
  test "writePath forks a snapshot without touching the original" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "a/b/c.txt" "forked".toUTF8
    check (forked != root) "fork has a new root"
    assertEqual "pure write produces a commit" (← git store #["cat-file", "-t", forked.hex]) "commit\n"
    assertEqual "pure write retains parent" (← git store #["rev-parse", forked.hex ++ "^"]) (root.hex ++ "\n")
    assertEqual "fork sees the write"
      ((← assertOk <| store.readPath forked "a/b/c.txt").map (String.fromUTF8? ·))
      (some (some "forked"))
    assertEqual "original unchanged"
      ((← assertOk <| store.readPath root "a/b/c.txt").map (String.fromUTF8? ·))
      (some (some "content-c"))
    assertEqual "sibling entry shared"
      (← assertOk <| store.entryAt? forked "shared") (← assertOk <| store.entryAt? root "shared"),

  test "writePath creates missing directories" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "brand/new/leaf.txt" "deep".toUTF8
    assertEqual "deep read"
      ((← assertOk <| store.readPath forked "brand/new/leaf.txt").map (String.fromUTF8? ·))
      (some (some "deep"))
    assertEqual "intermediate is a directory"
      ((← assertOk <| store.entryAt? forked "brand/new").map (·.type)) (some .directory),

  test "writePath refuses to descend through a file" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertError "descend through file" (store.writePath root "dup.txt/inner" "x".toUTF8)
      isStorage
    assertError "unsafe path" (store.writePath root "../escape" "x".toUTF8) isStorage
    assertError "directory type" (store.writePath root "d" "x".toUTF8 (type := .directory))
      isStorage,

  test "removePath removes and is idempotent" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let removed ← assertOk <| store.removePath root "a/b/c.txt"
    assertEqual "pure removal produces a commit" (← git store #["cat-file", "-t", removed.hex]) "commit\n"
    assertEqual "pure removal retains parent" (← git store #["rev-parse", removed.hex ++ "^"]) (root.hex ++ "\n")
    assertEqual "gone" (← assertOk <| store.readPath removed "a/b/c.txt") none
    assertEqual "sibling kept"
      ((← assertOk <| store.readPath removed "a/b/d.txt").map (String.fromUTF8? ·))
      (some (some "content-d"))
    assertEqual "absent removal is the identity"
      (← assertOk <| store.removePath removed "no/such/path") removed,

  test "a forked snapshot materializes like any other" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "new.sh" "#!/bin/sh\n".toUTF8 (type := .executable)
    let destination := (← scratch) / "out"
    assertOk <| store.materialize forked destination
    check (← isExecutable (destination / "new.sh")) "pure write carries its type"
    assertEqual "rest intact" (← IO.FS.readFile (destination / "dup.txt")) "content-c",

  test "readPath and entryAt? answer none for absent paths and directories" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertEqual "absent" (← assertOk <| store.readPath root "nope.txt") none
    assertEqual "directory read" (← assertOk <| store.readPath root "a/b") none
    assertEqual "listPaths types" ((← assertOk <| store.listPaths root).filter
      (·.2 == .directory)).size 3
]

def suites : Array Suite := #[
  objectSuite, merkleSuite, diffSuite, materializeSuite,
  metadataSuite, ignoreSuite, isolationSuite, gcSuite, legacySuite, pathOpsSuite]

end CasTests
