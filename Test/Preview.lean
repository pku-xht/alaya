import Test.Framework
import Alaya.Trajectory
import Alaya.Workspaces.Restic

/-! What `cat --json` shows of a snapshot entry, and what `show --json` takes a branch to be. -/

namespace PreviewTests

open Testing Alaya Alaya.Trajectory

private def workspace : Hash := Hash.ofBytes "test snapshot".toUTF8

private def configError : Error -> Bool
  | .configuration _ => true
  | _ => false

/-- These metadata deliberately include an apparent descendant under a link. A reader must
reject the link before calling either `listEntries` there or `readFiles` for its descendant. -/
private def fakeWorkspaces (reads listings : IO.Ref (Array String)) : Workspaces where
  snapshot _ := pure workspace
  materialize _ _ := throw <| .storage "unexpected materialization"
  diff _ _ := pure #[]
  retainOnly _ := pure ()
  listEntries _ path := do
    Result.fromIO Error.storage <| listings.modify (·.push path)
    if path.isEmpty then return #[
      { name := "text", path := "text", kind := .file, size := some 5 },
      { name := "nul", path := "nul", kind := .file, size := some 3 },
      { name := "invalid", path := "invalid", kind := .file, size := some 2 },
      { name := "large", path := "large", kind := .file, size := some (Workspaces.previewBytes + 1) },
      { name := "limit", path := "limit", kind := .file, size := some Workspaces.previewBytes },
      { name := "link", path := "link", kind := .symlink },
      { name := "pipe", path := "pipe", kind := .other },
      { name := "dir", path := "dir", kind := .directory }]
    if path == "link" then throw <| .storage "followed a symlink ancestor"
    pure #[]
  readFiles _ paths := paths.mapM fun path => do
    Result.fromIO Error.storage <| reads.modify (·.push path)
    match path with
    | "text" => pure (some "hello".toUTF8)
    | "nul" => pure (some ⟨#[65, 0, 66]⟩)
    | "invalid" => pure (some ⟨#[255, 254]⟩)
    | "limit" => pure (some ⟨Array.replicate Workspaces.previewBytes 65⟩)
    | _ => throw <| .storage "read a metadata-only entry"

def suite : Suite := Testing.suite "preview" #[
  test "binary, large, and nonregular entries have explicit preview kinds" do
    let reads ← IO.mkRef #[]
    let listings ← IO.mkRef #[]
    let workspaces := fakeWorkspaces reads listings
    for (path, expected) in #[
        ("text", "text"), ("nul", "binary"), ("invalid", "binary"), ("large", "too_large"),
        ("link", "symlink"), ("pipe", "other"), ("dir", "directory")] do
      let preview ← assertOk <| workspaces.preview workspace path
      assertEqual s!"{path} kind" preview.kind expected
      assertEqual s!"{path} content" preview.content? (if expected == "text" then some "hello" else none)
    let limit ← assertOk <| workspaces.preview workspace "limit"
    assertEqual "exact 1 MiB accepted" limit.kind "text"
    assertEqual "complete boundary content" (limit.content?.map (·.utf8ByteSize)) (some Workspaces.previewBytes)
    assertEqual "metadata-only entries were never read" (← reads.get) #["text", "nul", "invalid", "limit"],

  test "unsafe paths and symlink ancestors never reach file reads" do
    let reads ← IO.mkRef #[]
    let listings ← IO.mkRef #[]
    let workspaces := fakeWorkspaces reads listings
    for path in #["../outside", "a/../b", "/etc/passwd", "a//b", "./a", "a\\b", "C:/x", "a:x", "x\x00y"] do
      assertError "unsafe file path" (workspaces.preview workspace path) configError
      assertError "unsafe directory path" (workspaces.list workspace path) configError
    assertEqual "invalid paths rejected before listing" (← listings.get) #[]
    assertError "symlink ancestor" (workspaces.preview workspace "link/secret") configError
    assertError "symlink directory" (workspaces.list workspace "link") configError
    assertEqual "no file reads" (← reads.get) #[]
    assertEqual "never list through a link" (← listings.get) #["", ""],

  test "previews and listings read the snapshot, never the live directory" do
    let workspaces ← assertOk <| Workspaces.Restic.open ((← scratch) / "restic") ((← scratch) / "restic-scratch")
    let source := (← scratch) / "source"
    writeSpec source #[ ("code.lean", "old code"), ("nested/proof.lean", "old proof"),
      (".hidden/config", "hidden"), ("literal[1]*?.txt", "literal filename") ]
    IO.FS.createDirAll (source / "empty")
    let outside := (← scratch) / "outside"
    writeSpec outside #[("secret", "never show this")]
    createSymlink outside.toString (source / "link")
    createSymlink "code.lean" (source / "file-link")
    let old ← assertOk <| workspaces.snapshot source
    writeSpec source #[("code.lean", "new code"), ("after.txt", "later continuation")]
    let newer ← assertOk <| workspaces.snapshot source
    let text (id : Hash) (path : String) : TestM (Option String) := do
      pure (← assertOk <| workspaces.preview id path).content?
    assertEqual "old snapshot" (← text old "code.lean") (some "old code")
    assertEqual "new snapshot" (← text newer "code.lean") (some "new code")
    assertEqual "literal include pattern" (← text old "literal[1]*?.txt") (some "literal filename")
    assertEqual "root entries include hidden and empty dirs, by name"
      ((← assertOk <| workspaces.list old).map (·.name))
      #[".hidden", "code.lean", "empty", "file-link", "link", "literal[1]*?.txt", "nested"]
    assertEqual "nested listing" ((← assertOk <| workspaces.list old "nested").map (·.path))
      #["nested/proof.lean"]
    assertEqual "hidden file" (← text old ".hidden/config") (some "hidden")
    assertError "later file absent" (workspaces.preview old "after.txt") configError
    assertEqual "link is not read" (← assertOk <| workspaces.preview old "file-link").kind "symlink"
    assertError "outside link not traversed" (workspaces.preview old "link/secret") configError
    assertEqual "live working copy was not overwritten" (← IO.FS.readFile (source / "code.lean")) "new code",

  test "a branch is the states from the root to a state, with nothing from siblings" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    let put (parent? : Option Hash) (kind : Kind) (text : String) : TestM Hash :=
      assertOk <| putState store {
        image := recordedImage, workdir := recordedWorkdir, parent? := parent?
        workspace := workspace, kind := kind, appended := #[.message (.user text)]
        agent? := if parent?.isNone then some testAgent else none }
    let root ← put none .root "task"
    let middle ← put (some root) .turn "middle"
    let _ ← put (some root) .turn "sibling"
    let leaf ← put (some middle) .message "leaf"
    let branch ← assertOk <| branchOf store leaf
    assertEqual "states" (branch.map (·.1)) #[root, middle, leaf]
    assertEqual "kinds" (branch.map (·.2.kind.toString)) #["root", "turn", "message"]
]

end PreviewTests
