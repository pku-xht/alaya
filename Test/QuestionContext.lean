import Test.Framework
import Alaya.Trajectory.QuestionContext
import Alaya.Workspaces.Restic

namespace QuestionContextTests

open Testing Alaya Alaya.Trajectory
open Alaya.Trajectory.QuestionContext

private def store : TestM Store := do
  assertOk <| Store.create ((← scratch) / "states")

private def workspace : Hash := Hash.ofBytes "test snapshot".toUTF8

private def question (store : Store) (workspace : Hash) (parent? : Option Hash := none)
    (appended : Agent.Log := #[]) : TestM Hash :=
  assertOk <| putState store {
    parent?, workspace, kind := .question, appended,
    question? := some { callId := "ask-1", text := "What next?" } }

private def field (json : Lean.Json) (name : String) : TestM Lean.Json :=
  assertOk <| Result.fromExcept Error.protocol (json.getObjVal? name)

private def string (json : Lean.Json) (name : String) : TestM String :=
  assertOk <| Result.fromExcept Error.protocol (json.getObjVal? name >>= Lean.Json.getStr?)

private def array (json : Lean.Json) (name : String) : TestM (Array Lean.Json) :=
  assertOk <| Result.fromExcept Error.protocol (json.getObjVal? name >>= Lean.Json.getArr?)

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
      { name := "large", path := "large", kind := .file, size := some (maxFileBytes + 1) },
      { name := "limit", path := "limit", kind := .file, size := some maxFileBytes },
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
    | "limit" => pure (some ⟨Array.replicate maxFileBytes 65⟩)
    | _ => throw <| .storage "read a metadata-only entry"

def suite : Suite := Testing.suite "question_context" #[
  test "history contains exactly root to question, with original events intact" do
    let store ← store
    let originalTask := "Full task\n" ++ String.ofList (List.replicate 20000 'x')
    let rootLog : Agent.Log := #[.message (.system "system instruction"),
      .message (.user originalTask), .message (.user "second user message")]
    let root ← assertOk <| putState store {
      parent? := none, workspace, kind := .root, appended := rootLog }
    let middleLog : Agent.Log := #[
      .response { content? := some "I inspected the source", toolCalls := #[
        { id := "read-1", name := "bash", arguments := .mkObj [("command", "cat code")] }] },
      .observation "read-1" (.mkObj [("output", "the full recorded result\nline 2")])]
    let middle ← assertOk <| putState store {
      parent? := some root, workspace, kind := .turn, appended := middleLog }
    let questionLog : Agent.Log := #[.response { toolCalls := #[
      { id := "ask-1", name := "ask_user", arguments := .mkObj [("question", "What next?")] }] }]
    let asked ← question store workspace (some middle) questionLog
    let _ ← assertOk <| putState store {
      parent? := some root, workspace, kind := .turn, appended := #[.message (.user "SIBLING SECRET")] }
    let _ ← assertOk <| putState store {
      parent? := some asked, workspace, kind := .reply,
      appended := #[.observation "ask-1" (.str "LATER ANSWER")] }
    let _ ← assertOk <| putState store {
      parent? := some asked, workspace, kind := .evaluation,
      appended := #[.message (.user "HIDDEN GRADER")],
      evaluation? := some { grader := "hidden", returncode := 0, elapsedMs := 1, output := "secret" } }
    let result ← assertOk <| context store asked
    assertEqual "original task is complete" (← string result "task") originalTask
    let history ← array result "history"
    assertEqual "states" (← history.mapM (string · "state")) #[root.hex, middle.hex, asked.hex]
    assertEqual "kinds" (← history.mapM (string · "kind")) #["root", "turn", "question"]
    for index in [:history.size] do
      let expected := #[rootLog, middleLog, questionLog][index]!
      assertEqual "all recorded events" ((← array history[index]! "events").map Lean.Json.compress)
        ((expected.map eventToJson).map Lean.Json.compress)
    assertError "non-question" (context store root) configError,

  test "missing original task is explicit and evaluation ancestry fails closed" do
    let store ← store
    let root ← assertOk <| putState store {
      parent? := none, workspace, kind := .root, appended := #[], note? := some "not the task" }
    let asked ← question store workspace (some root) #[.message (.user "later text")]
    assertEqual "missing task" (← field (← assertOk <| context store asked) "task").compress "null"
    let evaluation ← assertOk <| putState store {
      parent? := some root, workspace, kind := .evaluation, appended := #[] }
    let invalid ← question store workspace (some evaluation)
    assertError "no evaluator history" (context store invalid) fun
      | .storage _ => true
      | _ => false,

  test "binary, large, and nonregular entries have explicit preview kinds" do
    let store ← store
    let asked ← question store workspace
    let reads ← IO.mkRef #[]
    let listings ← IO.mkRef #[]
    let workspaces := fakeWorkspaces reads listings
    for (path, expected) in #[
        ("text", "text"), ("nul", "binary"), ("invalid", "binary"), ("large", "too_large"),
        ("link", "symlink"), ("pipe", "other"), ("dir", "other")] do
      let result ← assertOk <| file store workspaces asked path
      assertEqual "preview kind" (← string result "kind") expected
      if expected == "text" then assertEqual "text" (← string result "content") "hello"
      else assertEqual "no content" (← field result "content").compress "null"
    let limit ← assertOk <| file store workspaces asked "limit"
    assertEqual "exact 1 MiB accepted" (← string limit "kind") "text"
    assertEqual "complete boundary content" (← string limit "content").utf8ByteSize maxFileBytes
    assertEqual "metadata-only entries were never read" (← reads.get) #["text", "nul", "invalid", "limit"],

  test "unsafe paths and symlink ancestors never reach file reads" do
    let store ← store
    let asked ← question store workspace
    let reads ← IO.mkRef #[]
    let listings ← IO.mkRef #[]
    let workspaces := fakeWorkspaces reads listings
    for path in #["../outside", "a/../b", "/etc/passwd", "a//b", "./a", "a\\b", "C:/x", "a:x", "x\x00y"] do
      assertError "unsafe file path" (file store workspaces asked path) configError
      assertError "unsafe directory path" (directory store workspaces asked path) configError
    assertEqual "invalid paths rejected before listing" (← listings.get) #[]
    assertError "symlink ancestor" (file store workspaces asked "link/secret") configError
    assertError "symlink directory" (directory store workspaces asked "link") configError
    assertEqual "no file reads" (← reads.get) #[]
    assertEqual "never list through a link" (← listings.get) #["", ""],

  test "files and directories stay pinned to the question snapshot" do
    let store ← store
    let workspaces ← assertOk <| Workspaces.Restic.open ((← scratch) / "restic")
    let source := (← scratch) / "source"
    writeSpec source #[ ("code.lean", "old code"), ("nested/proof.lean", "old proof"),
      (".hidden/config", "hidden"), ("literal[1]*?.txt", "literal filename") ]
    IO.FS.createDirAll (source / "empty")
    let outside := (← scratch) / "outside"
    writeSpec outside #[("secret", "never show this")]
    createSymlink outside.toString (source / "link")
    createSymlink "code.lean" (source / "file-link")
    let old ← assertOk <| workspaces.snapshot source
    let asked ← question store old
    writeSpec source #[("code.lean", "new code"), ("after.txt", "later continuation")]
    let newer ← assertOk <| workspaces.snapshot source
    let later ← question store newer
    let result ← assertOk <| file store workspaces asked "code.lean"
    assertEqual "old snapshot" (← string result "content") "old code"
    assertEqual "new snapshot" (← string (← assertOk <| file store workspaces later "code.lean") "content") "new code"
    assertEqual "literal include pattern" (← string
      (← assertOk <| file store workspaces asked "literal[1]*?.txt") "content") "literal filename"
    let listing ← assertOk <| directory store workspaces asked
    let entries ← array listing "entries"
    assertEqual "root entries include hidden and empty dirs" (← entries.mapM (string · "name"))
      #[".hidden", "code.lean", "empty", "file-link", "link", "literal[1]*?.txt", "nested"]
    assertEqual "nested listing" (← (← array (← assertOk <| directory store workspaces asked "nested")
      "entries").mapM (string · "path")) #["nested/proof.lean"]
    assertEqual "hidden file" (← string (← assertOk <| file store workspaces asked ".hidden/config") "content") "hidden"
    assertError "later file absent" (file store workspaces asked "after.txt") configError
    assertEqual "link is not read" (← string (← assertOk <| file store workspaces asked "file-link") "kind") "symlink"
    assertError "outside link not traversed" (file store workspaces asked "link/secret") configError
    assertEqual "live working copy was not overwritten" (← IO.FS.readFile (source / "code.lean")) "new code"
]

end QuestionContextTests
