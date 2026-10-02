import Test.Framework
import Alaya.Trajectory.Render
import Alaya.Workspaces.Restic

/-! What `cat --json` shows of a snapshot entry, and what `show --json` takes a branch to be. -/

namespace PreviewTests

open Testing Alaya Alaya.Trajectory

private def workspace : Hash := Hash.ofBytes "test snapshot".toUTF8

/-- The kind of a root built by hand here: nothing runs in it. -/
private def testRoot : Kind :=
  .root { agent := testAgent, model := testModel, image := recordedImage, workdir := recordedWorkdir }

private def inputError : Error -> Bool
  | .input _ => true
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
      assertError "unsafe file path" (workspaces.preview workspace path) inputError
      assertError "unsafe directory path" (workspaces.list workspace path) inputError
    assertEqual "invalid paths rejected before listing" (← listings.get) #[]
    assertError "symlink ancestor" (workspaces.preview workspace "link/secret") inputError
    assertError "symlink directory" (workspaces.list workspace "link") inputError
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
    assertError "later file absent" (workspaces.preview old "after.txt") inputError
    assertEqual "link is not read" (← assertOk <| workspaces.preview old "file-link").kind "symlink"
    assertError "outside link not traversed" (workspaces.preview old "link/secret") inputError
    assertEqual "live working copy was not overwritten" (← IO.FS.readFile (source / "code.lean")) "new code",

  test "a branch is the states from the root to a state, with nothing from siblings" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    -- Each kind holds what it may: an opening and a workspace, a clock reading, a notice.
    let put (parent? : Option Hash) (kind : Kind) (appended : Agent.Log) : TestM Hash :=
      assertOk <| putState store { parent? := parent?, workspace := workspace, kind := kind, appended }
    let root ← put none testRoot #[.told (.user "task"), .placed workspace]
    let middle ← put (some root) .step #[.timed 1 none]
    let _ ← put (some root) .step #[.timed 2 none]
    let leaf ← put (some middle) (.intervention { message := "leaf" }) #[.told (.user "leaf")]
    let branch ← assertOk <| ancestors store leaf
    assertEqual "states" (branch.map (·.1)) #[root, middle, leaf]
    assertEqual "kinds" (branch.map (·.2.kind.toString)) #["root", "step", "intervention"]
    assertEqual "the log is theirs" ((← assertOk <| logOf store leaf).size) 4
    -- The branch is those states, and its log their events in order.
    let onBranch ← assertOk <| branchOf store leaf
    assertEqual "its tip" onBranch.tip.1 leaf
    assertEqual "its root" onBranch.root.1 root
    assertEqual "its log, a state at a time" (onBranch.states.map (·.2.appended.size)) #[2, 1, 1]
    assertEqual "the root" (← assertOk <| rootOf store leaf) root,

  test "usage keeps cached and reasoning tokens in either form, and a run's adds up from the root" do
    let parse (usage : Lean.Json) : TestM Chat.TokenUsage := do
      let raw := Lean.Json.mkObj [("choices", .arr #[.mkObj [("message", .mkObj [("content", "x")])]]),
        ("usage", usage)]
      let responses ← assertOk <| Chat.Response.fromJsons raw
      pure (responses[0]!.usage?.getD {})
    let openai ← parse (.mkObj [("prompt_tokens", (48211 : Nat)), ("completion_tokens", (1102 : Nat)),
      ("prompt_tokens_details", .mkObj [("cached_tokens", (41900 : Nat))]),
      ("completion_tokens_details", .mkObj [("reasoning_tokens", (800 : Nat))])])
    assertEqual "cached" openai.cached? (some 41900)
    assertEqual "reasoning" openai.reasoning? (some 800)
    let deepseek ← parse (.mkObj [("prompt_tokens", (500 : Nat)), ("completion_tokens", (20 : Nat)),
      ("prompt_cache_hit_tokens", (300 : Nat)), ("prompt_cache_miss_tokens", (200 : Nat))])
    assertEqual "DeepSeek's cache hits" deepseek.cached? (some 300)
    assertEqual "the text" (tokens openai) "in 48.2k, 41.9k cached; out 1.1k, 800 reasoning"
    let store ← assertOk <| Store.create ((← scratch) / "states")
    let turn (parent : Hash) (usage : Chat.TokenUsage) : TestM Hash :=
      assertOk <| putState store {
        parent? := some parent, workspace := workspace
        kind := .step, appended := #[.sampled default .turn { content? := some "x", usage? := some usage }] }
    let root ← assertOk <| putState store {
      parent? := none, workspace := workspace, kind := testRoot, appended := #[.placed workspace] }
    let first ← turn root openai
    let second ← turn first deepseek
    let run ← assertOk <| runUsage store second
    assertEqual "input" run.input? (some 48711)
    assertEqual "cached" run.cached? (some 42200)
    assertEqual "reasoning, where only one reported it" run.reasoning? (some 800)
    let tree ← assertOk <| treeLines store
    check (tree.any fun l => (l.splitOn "in 500, 300 cached; out 20").length > 1) s!"tree shows a turn's tokens: {tree}",

  test "parents that form a cycle are an error, not an endless walk" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    -- Content-addressed states cannot form a cycle; files edited by hand can.
    let a : Hash := ⟨"".pushn 'a' 64⟩
    let b : Hash := ⟨"".pushn 'b' 64⟩
    let state (parent : Hash) : State :=
      { parent? := some parent, workspace, kind := .step, appended := #[] }
    IO.FS.writeFile (store.dir / s!"{a.hex}.json") (state b).toJson.compress
    IO.FS.writeFile (store.dir / s!"{b.hex}.json") (state a).toJson.compress
    assertError "cycle" (ancestors store a) fun
      | .storage m => (m.splitOn "form a cycle").length > 1
      | _ => false
]

end PreviewTests
