import Test.Framework
import Alaya.Cas

/-! Behavior tests for Git-backed snapshots: native object identity, exact restoration,
filesystem metadata, isolation from the source repository, refs, and legacy reads. -/

namespace CasTests

open Testing
open Alaya
open Alaya.Cas

private def isStorage : Error -> Bool
  | .storage _ => true
  | _ => false

private def withStore : TestM Store := do
  assertOk <| Store.create ((← scratch) / "store")

/-- A small tree with nesting, duplicate content (`c.txt` = `dup.txt`), and a sibling
directory that most tests leave untouched. -/
private def baseSpec : Array (String × String) := #[
  ("a/b/c.txt", "content-c"), ("a/b/d.txt", "content-d"), ("a/e.txt", "content-e"),
  ("dup.txt", "content-c"), ("shared/s.txt", "content-s")]

private def sourceDir : TestM System.FilePath := return (← scratch) / "source"

private def snapshotSpec (store : Store) (spec : Array (String × String))
    (config : CaptureConfig := {}) : TestM Hash := do
  let source ← sourceDir
  writeSpec source spec
  assertOk <| store.snapshot source config

private def command (cmd : String) (args : Array String) : TestM String := do
  let out ← IO.Process.output { cmd, args }
  assertEqual s!"{cmd}: {out.stderr}" out.exitCode 0
  pure out.stdout

private def git (store : Store) (args : Array String) : TestM String :=
  command "git" (#["--git-dir", store.gitDir.toString] ++ args)

private def missingHash : Hash := ⟨String.ofList (List.replicate 64 'a')⟩

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
    assertEqual "SHA-256 repository" (← git store #["rev-parse", "--show-object-format"]) "sha256\n",

  test "tree parsing rejects hostile input" do
    let bad (json : String) : TestM Unit := do
      match Lean.Json.parse json with
      | .error _ => fail "test fixture is not JSON"
      | .ok json =>
        match Tree.fromJson json with
        | .ok _ => fail s!"accepted hostile tree: {json}"
        | .error _ => pure ()
    let hex := String.ofList (List.replicate 64 'a')
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

  test "empty directories are preserved" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("keep.txt", "k")]
    IO.FS.createDirAll (source / "empty" / "nested")
    let root ← assertOk <| store.snapshot source
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    check (← (destination / "empty" / "nested").isDir) "nested empty dir restored",

  test "same-size edits with identical mtime are captured" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("a.txt", "before")]
    let stamp := (← scratch) / "stamp"
    IO.FS.writeFile stamp "timestamp fixture"
    let _ ← command "touch" #["-t", "200001010000.00", stamp.toString]
    let _ ← command "touch" #["-r", stamp.toString, (source / "a.txt").toString]
    let before ← assertOk <| store.snapshot source
    IO.FS.writeFile (source / "a.txt") "after!"
    let _ ← command "touch" #["-r", stamp.toString, (source / "a.txt").toString]
    let after ← assertOk <| store.snapshot source
    check (before != after) "changed bytes change the snapshot even with the same size and mtime"
    assertEqual "new content" ((← assertOk <| store.readPath after "a.txt").map
      (String.fromUTF8? ·)) (some (some "after!"))
    assertEqual "old snapshot immutable" ((← assertOk <| store.readPath before "a.txt").map
      (String.fromUTF8? ·)) (some (some "before")),

  test "snapshots survive closing the handle and losing the original workspace" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    assertOk <| store.setRef "keep" root
    IO.FS.removeDirAll (← sourceDir)
    let reopened ← assertOk <| Store.create store.root
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize root destination
    assertEqual "restored after reopen" (← readSpec destination) baseSpec
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

/-! ## Exact and independent materialization -/

def materializeSuite : Suite := suite "cas.materialize" #[
  test "roundtrip reproduces the source exactly" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "specs equal" (← readSpec destination) (← readSpec (← sourceDir)),

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
    assertEqual "destination matches v2" (← readSpec destination) (← readSpec source),

  test "an untracked non-empty destination errors when asked to" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "do not delete")]
    assertError "materialize" (store.materialize root destination { onExisting := .error })
      isStorage
    assertEqual "destination untouched"
      (← IO.FS.readFile (destination / "precious.txt")) "do not delete"
    -- The default replaces it.
    assertOk <| store.materialize root destination
    assertEqual "replaced" (← readSpec destination) (← readSpec (← sourceDir)),

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
    assertEqual "whole snapshot" (← readSpec destination)
      #[("change.txt", "two"), ("keep.txt", "same")],

  test "restoring repairs tampering without modifying the stored snapshot" do
    let store ← withStore
    let v1 ← snapshotSpec store baseSpec
    let destination := (← scratch) / "out"
    assertOk <| store.materialize v1 destination
    IO.FS.writeFile (destination / "shared" / "s.txt") "tampered"
    writeSpec destination #[("extra/abandoned.txt", "from another branch")]
    assertOk <| store.materialize v1 destination
    assertEqual "exact restored contents" (← readSpec destination) baseSpec,

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
    assertEqual "only captured names" (← destination.readDir).size names.size,

  test "restoring replaces file-directory conflicts and does not follow destination links" do
    let store ← withStore
    let root ← snapshotSpec store #[("dir/child.txt", "inside"), ("file.txt", "plain")]
    let destination := (← scratch) / "out"
    let outside := (← scratch) / "outside"
    writeSpec outside #[("child.txt", "do not touch")]
    writeSpec destination #[("file.txt/was-a-directory.txt", "old")]
    createSymlink (← IO.FS.realPath outside).toString (destination / "dir")
    assertOk <| store.materialize root destination
    assertEqual "destination contents" (← readSpec destination)
      #[("dir/child.txt", "inside"), ("file.txt", "plain")]
    assertEqual "outside untouched" (← IO.FS.readFile (outside / "child.txt")) "do not touch",

  test "a missing snapshot leaves an existing destination intact" do
    let store ← withStore
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "keep me")]
    assertError "missing snapshot" (store.materialize missingHash destination) isStorage
    assertEqual "destination preserved" (← readSpec destination) #[("precious.txt", "keep me")],

  test "a missing child object leaves an existing destination intact" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let some entry ← assertOk <| store.entryAt? root "a/b/c.txt"
      | fail "missing fixture entry"
    -- Remove a real Git loose object to simulate a damaged store, not a nonexistent root.
    IO.FS.removeFile (store.gitDir / "objects" / (entry.hash.hex.take 2).toString /
      (entry.hash.hex.drop 2).toString)
    let destination := (← scratch) / "out"
    writeSpec destination #[("precious.txt", "keep me")]
    assertError "missing child" (store.materialize root destination) isStorage
    assertEqual "destination preserved" (← readSpec destination) #[("precious.txt", "keep me")],

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
    assertEqual "dot destination" (← readSpec destination) baseSpec
    IO.FS.writeFile (destination / "dup.txt") "tampered"
    assertOk <| store.materialize root (destination / "missing" / "..")
    assertEqual "dot-dot destination" (← readSpec destination) baseSpec
    let alias := base / "alias"
    createSymlink destination.toString alias
    assertError "final symlink" (store.materialize root alias) isStorage
    assertError "final symlink with trailing slash"
      (store.materialize root ⟨alias.toString ++ "/"⟩) isStorage
    assertEqual "link target preserved" (← readSpec destination) baseSpec
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

  test "exec detection can be disabled" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("run.sh", "#!/bin/sh\n")]
    setExecutable (source / "run.sh")
    let root ← assertOk <| store.snapshot source { execBits := false }
    assertEqual "recorded as a plain file"
      ((← assertOk <| store.entryAt? root "run.sh").map (·.type)) (some .file),

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
    assertEqual "target bytes" (← command "readlink" #[(destination / "link").toString]) (target ++ "\n"),

  test "the reject policy refuses symlinks" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("a.txt", "x")]
    createSymlink "a.txt" (source / "alias")
    assertError "snapshot" (store.snapshot source { symlinks := .reject }) isStorage
]

/-! ## Feature 6: ignore rules -/

def ignoreSuite : Suite := suite "cas.ignore" #[
  test "the ignoring matcher implements its documented rules" do
    let matcher := ignoring #["node_modules", "*.log", "build/", "docs/internal"]
    check (matcher "node_modules") "bare component at root"
    check (matcher "a/node_modules") "bare component nested"
    check (!matcher "node_modules_2") "component must match exactly"
    check (matcher "debug.log") "extension at root"
    check (matcher "a/b/debug.log") "extension nested"
    check (!matcher "log") "suffix pattern needs the suffix"
    check (matcher "build") "trailing-slash prunes the directory"
    check (!matcher "build.rs") "trailing-slash is not a prefix of names"
    check (matcher "docs/internal") "embedded slash matches the path"
    check (matcher "docs/internal/notes.md") "embedded slash matches below"
    check (!matcher "docs/internals") "embedded slash is path-exact",

  test "ignored paths are absent from the snapshot" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[
      ("src/main.c", "int main;"), ("src/junk.log", "noise"),
      ("build/out.bin", "artifact"), ("node_modules/dep/index.js", "js")]
    let root ← assertOk <| store.snapshot source
      { ignore := ignoring #["*.log", "build/", "node_modules"] }
    let paths := (← assertOk <| store.listPaths root).map (·.1)
    assertEqual "kept only sources" paths #["src", "src/main.c"],

  test "a custom predicate prunes directories before they are read" do
    let store ← withStore
    let source ← sourceDir
    writeSpec source #[("keep.txt", "k"), ("skip/deep/file.txt", "s")]
    let _ ← command "mkfifo" #[(source / "skip" / "special").toString]
    let root ← assertOk <| store.snapshot source { ignore := (· == "skip") }
    assertEqual "kept paths" ((← assertOk <| store.listPaths root).map (·.1)) #["keep.txt"]
]

/-! ## The task repository remains data, not the snapshot backend -/

def isolationSuite : Suite := suite "cas.isolation" #[
  test "capturing a Git project preserves its metadata and bypasses filters and ignores" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "git" #["init", "-q", source.toString]
    writeSpec source #[("staged.txt", "staged content\n")]
    let _ ← command "git" #["-C", source.toString, "add", "staged.txt"]
    let _ ← command "git" #["-C", source.toString, "config", "filter.must-not-run.clean", "false"]
    let _ ← command "git" #["-C", source.toString, "config", "filter.must-not-run.smudge", "false"]
    let _ ← command "git" #["-C", source.toString, "config", "filter.must-not-run.required", "true"]
    let _ ← command "git" #["-C", source.toString, "config", "core.autocrlf", "true"]
    writeSpec source #[
      (".gitignore", "ignored.txt\n"),
      (".gitattributes", "*.txt filter=must-not-run text eol=lf\n"),
      ("ignored.txt", "ignored but captured\r\n"),
      ("unstaged.txt", "raw CRLF\r\n"),
      (".git/hooks/post-checkout", "#!/bin/sh\nprintf ran > hook-ran\nexit 99\n")]
    setExecutable (source / ".git" / "hooks" / "post-checkout")
    let index ← IO.FS.readBinFile (source / ".git" / "index")
    let config ← IO.FS.readFile (source / ".git" / "config")
    let head ← IO.FS.readFile (source / ".git" / "HEAD")
    let root ← assertOk <| store.snapshot source
    assertEqual "source index unchanged" (← IO.FS.readBinFile (source / ".git" / "index")).toList index.toList
    assertEqual "source config unchanged" (← IO.FS.readFile (source / ".git" / "config")) config
    assertEqual "source HEAD unchanged" (← IO.FS.readFile (source / ".git" / "HEAD")) head
    let destination := (← scratch) / "out"
    assertOk <| store.materialize root destination
    assertEqual "captured index" (← IO.FS.readBinFile (destination / ".git" / "index")).toList index.toList
    assertEqual "captured config" (← IO.FS.readFile (destination / ".git" / "config")) config
    assertEqual "captured HEAD" (← IO.FS.readFile (destination / ".git" / "HEAD")) head
    assertEqual "ignored file kept verbatim" (← IO.FS.readFile (destination / "ignored.txt")) "ignored but captured\r\n"
    assertEqual "attributes did not transform bytes" (← IO.FS.readFile (destination / "unstaged.txt")) "raw CRLF\r\n"
    check (!(← (source / "hook-ran").pathExists)) "source hook did not run"
    check (!(← (destination / "hook-ran").pathExists)) "checkout hook did not run",

  test "capture rejects unsupported special files" do
    let store ← withStore
    let source ← sourceDir
    IO.FS.createDirAll source
    let _ ← command "mkfifo" #[(source / "fifo").toString]
    assertError "special file" (store.snapshot source) isStorage
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
    assertEqual "snapshot fully intact" (← readSpec destination) (← readSpec (← sourceDir))
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

/-! ## Historical hashes remain readable while new snapshots use Git objects -/

def legacySuite : Suite := suite "cas.legacy" #[
  test "legacy trees and blobs import without changing their original files or logical refs" do
    let store ← withStore
    let bytes := ByteArray.mk #[0, 255, 10, 128, 42]
    let blob ← legacyBlob store bytes
    let empty ← legacyTree store Tree.empty
    let child ← legacyTree store (Tree.ofEntries #[{ name := "data.bin", type := .file, hash := blob }])
    let oldTree := Tree.ofEntries #[
      { name := "empty", type := .directory, hash := empty },
      { name := "nested", type := .directory, hash := child }]
    let root ← legacyTree store oldTree
    IO.FS.createDirAll (store.root / "refs")
    IO.FS.writeFile (store.root / "refs" / "legacy") (root.hex ++ "\n")
    let reopened ← assertOk <| Store.create store.root
    assertEqual "legacy logical ref retained" (← assertOk <| reopened.getRef? "legacy") (some root)
    check ((← assertOk reopened.listRefs).contains ("legacy", root)) "legacy ref listed"
    assertEqual "legacy bytes" ((← assertOk <| reopened.getBytes blob).map (·.toList)) (some bytes.toList)
    let destination := (← scratch) / "out"
    assertOk <| reopened.materialize root destination
    assertEqual "binary legacy materialization" (← IO.FS.readBinFile (destination / "nested" / "data.bin")).toList bytes.toList
    check (← (destination / "empty").isDir) "legacy empty directory restored"
    let imported ← assertOk <| reopened.importTree root
    check (imported != root) "native tree has a different address from the JSON tree"
    assertEqual "imported object is a tree" (← git reopened #["cat-file", "-t", imported.hex]) "tree\n"
    let captured ← assertOk <| reopened.snapshot destination
    assertEqual "same native tree after recapture" captured imported
    assertEqual "migration is not a workspace change" (← assertOk <| reopened.diff root captured) #[]
    assertEqual "old raw tree file unchanged"
      (← IO.FS.readBinFile (store.root / "blobs" / (root.hex.take 2).toString / root.hex)).toList
      oldTree.toJson.compress.toUTF8.toList
    let edited ← assertOk <| reopened.writePath root "new.txt" "new branch".toUTF8
    assertEqual "old snapshot remains unchanged" (← assertOk <| reopened.readPath root "new.txt") none
    assertEqual "new branch can be read" ((← assertOk <| reopened.readPath edited "new.txt").map
      (String.fromUTF8? ·)) (some (some "new branch")),

  test "legacy refs survive reopen and Git garbage collection" do
    let store ← withStore
    let blob ← legacyBlob store "legacy contents".toUTF8
    let root ← legacyTree store (Tree.ofEntries #[{ name := "old.txt", type := .file, hash := blob }])
    IO.FS.createDirAll (store.root / "refs")
    IO.FS.writeFile (store.root / "refs" / "old") (root.hex ++ "\n")
    let reopened ← assertOk <| Store.create store.root
    assertOk <| reopened.setRef "also-old" root
    assertOk reopened.gc
    let again ← assertOk <| Store.create store.root
    assertEqual "old ref identity" (← assertOk <| again.getRef? "old") (some root)
    assertEqual "new ref can retain old logical identity" (← assertOk <| again.getRef? "also-old") (some root)
    let destination := (← scratch) / "out"
    assertOk <| again.materialize root destination
    assertEqual "legacy content after GC" (← IO.FS.readFile (destination / "old.txt")) "legacy contents"
]

/-! ## Pure path operations (cheap branching) -/

def pathOpsSuite : Suite := suite "cas.pathops" #[
  test "writePath forks a snapshot without touching the original" do
    let store ← withStore
    let root ← snapshotSpec store baseSpec
    let forked ← assertOk <| store.writePath root "a/b/c.txt" "forked".toUTF8
    check (forked != root) "fork has a new root"
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
