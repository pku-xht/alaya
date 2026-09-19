import Test.Framework
import Alaya

namespace OutputReadTests

open Testing Alaya Alaya.Agent Alaya.Trajectory
open Alaya.Agent.MiniSwe

private def str (j : Lean.Json) (key : String) : String :=
  (j.getObjVal? key >>= Lean.Json.getStr?).toOption.getD ""

private def nat (j : Lean.Json) (key : String) : Nat :=
  (j.getObjVal? key >>= Lean.Json.getNat?).toOption.getD 0

private def arguments (ref : String) (offset limit : Nat) : Lean.Json :=
  .mkObj [("ref", ref), ("offset", offset), ("limit", limit)]

private def fullText : String :=
  String.ofList (List.replicate 6000 '始') ++ "MID😀é\nexact middle" ++
  String.ofList (List.replicate 16000 '终')

private def rawLog (text : String) : Log :=
  #[.observation "original" ({ output := text, exitCode? := some 0 } : Output).toJson]

private def readCall (ref : String) (offset limit : Nat) : Chat.ToolCall :=
  { id := "page", name := "read_output", arguments := arguments ref offset limit }

private def bashCall : Chat.ToolCall :=
  { id := "original", name := "bash", arguments := .mkObj [("command", "produce output")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def fixed (r : Chat.Response) : Model := {
  identity := .mkObj [("model", "scripted-output-read")]
  sample := fun _ => pure { next := pure r }
}

private def fakeExecutor (text : String := fullText) : Executor := {
  exec := fun _ _ _ => pure { output := text, exitCode? := some 0 }
  uname := pure { system := "Linux", release := "test", version := "test", machine := "test" }
}

private def getObservation (log : Log) (id : String) : TestM Lean.Json := do
  match log.reverse.findSome? (fun | .observation i content => if i == id then some content else none | _ => none) with
  | some content => pure content
  | none => fail s!"missing observation {id}"

/-- A subprocess entry point used only by the test runner. No output text is supplied by the
parent process: the child must reopen the trajectory and recover the page through its driver. -/
def recoveryWorker (storePath workPath stateHex ref : String) : IO UInt32 := do
  let recover : Result Cas.Hash := do
    let store ← Cas.Store.create storePath
    let original ← resolve store stateHex
    let executor := fakeExecutor
    let rt : Runtime := {
      store, workDir := workPath, executor,
      agent := agent executor { task := "t" }, model := fixed (response #[readCall ref 6000 18]) }
    let child ← stepOnce rt "new-process-read" original
    let log : Log ← logOf store child
    let page? := log.reverse.findSome? fun
      | .observation "page" content => some content
      | _ => none
    let some page := page? | throw <| Error.protocol "new process did not record a page"
    if str page "content" != String.ofList (fullText.toList.drop 6000 |>.take 18) then
      throw <| Error.protocol "new process did not recover the original middle"
    pure child
  let child ← recover.toUserIO
  IO.println child.hex
  pure 0

def suite : Suite := Testing.suite "output-read" #[
  test "preview reference recovers the omitted middle without changing raw JSON" do
    let raw : Output := { output := fullText, exitCode? := some 0 }
    let shown := observation raw
    check ((shown.getObjVal? "truncated" >>= Lean.Json.getBool?).toOption == some true) "truncation marked"
    check ((shown.getObjVal? "displayed_ranges").toOption ==
      some (.arr #[.arr #[0, 5000], .arr #[((fullText.length - 5000 : Nat) : Lean.Json), (fullText.length : Lean.Json)]]))
      "exact head and tail ranges"
    let ref := str shown "output_ref"
    assertEqual "content identity" ref (OutputRead.reference fullText)
    let page := OutputRead.read (rawLog fullText) (arguments ref 6000 18)
    assertEqual "exact middle" (str page "content") (String.ofList (fullText.toList.drop 6000 |>.take 18))
    assertEqual "original JSON still full" (str raw.toJson "output") fullText
    assertEqual "raw structured consumer" (Output.fromJson? raw.toJson) (some raw)
    match view #[.observation "page" page] with
    | #[.tool "page" (.str text)] => assertEqual "page is not reprocessed" text page.pretty
    | _ => fail "expected unchanged page"
    let fullPage := OutputRead.read (rawLog fullText) (arguments ref 5000 OutputRead.pageLimit)
    match view #[.observation "full-page" fullPage] with
    | #[.tool "full-page" (.str text)] =>
      check (text.length > outputLimit) "page metadata makes the serialized payload exceed the preview limit"
      let .ok decoded := Lean.Json.parse text | fail "page is not valid serialized JSON"
      assertEqual "maximum Unicode page survives the view intact" (str decoded "content")
        (String.ofList (fullText.toList.drop 5000 |>.take OutputRead.pageLimit))
    | _ => fail "expected intact maximum-size page",

  test "pages reach EOF exactly with Unicode and a very long single line" do
    let text := String.join (List.replicate 7001 "😀中é") ++ "THE_END"
    let log := rawLog text
    let ref := OutputRead.reference text
    let mut offset := 0
    let mut joined := ""
    let mut pages := 0
    while offset < text.length do
      let page := OutputRead.read log (arguments ref offset 997)
      let content := str page "content"
      check (!content.isEmpty && content.length <= 997) "each page makes bounded progress"
      joined := joined ++ content
      offset := nat page "end_offset"
      pages := pages + 1
      if offset < text.length then assertEqual "next offset" (nat page "next_offset") offset
      else
        check ((page.getObjVal? "next_offset").toOption == some .null) "terminal next offset is null"
        assertEqual "EOF" (page.getObjVal? "eof" >>= Lean.Json.getBool?).toOption (some true)
    assertEqual "all characters recovered" joined text
    check (pages > 20) "multiple full pages"
    let endPage := OutputRead.read log (arguments ref text.length 1)
    assertEqual "reading at EOF" (str endPage "content") ""
    assertEqual "at EOF flag" (endPage.getObjVal? "eof" >>= Lean.Json.getBool?).toOption (some true),

  test "unknown reference historical lost output and invalid ranges are honest errors" do
    let ref := OutputRead.reference fullText
    let missing := OutputRead.read #[] (arguments ref 0 10)
    check ((str missing "error").startsWith "Full output unavailable") "missing full text reported"
    let legacy : Log := #[.observation "old" (.mkObj [("output_head", "head"), ("output_tail", "tail"), ("elided_chars", 9000)])]
    let lost := OutputRead.read legacy (arguments ref 0 10)
    check (!(str lost "error").isEmpty) "cannot fabricate lost historical middle"
    for args in #[arguments ref 0 0, arguments ref 0 10001, arguments ref (fullText.length + 1) 1,
      .mkObj [("ref", ref), ("offset", (-1 : Int)), ("limit", 3)]] do
      let page := OutputRead.read (rawLog fullText) args
      check (!(str page "error").isEmpty) "bad request is explicit"
      check (!(page.getObjVal? "content").isOk) "no fabricated page",

  test "short and exact-limit outputs stay complete while MiniSwe accepts read_output alone" do
    for text in #["", "short 😀\n", String.ofList (List.replicate 10000 'x')] do
      let shown := observation { output := text, exitCode? := some 0 }
      assertEqual "complete output" (str shown "output") text
      check (!(shown.getObjVal? "output_ref").isOk) "no unnecessary output reference"
    let c := readCall (OutputRead.reference fullText) 6000 10
    match parseActions (response #[c]) with
    | .actions #[.readOutput "page"] => pure ()
    | _ => fail "read_output should be accepted by mini-swe"
    match next { task := "t" } #[.response (response #[c])] with
    | .act call => assertEqual "next read" call.name "read_output"
    | _ => fail "read_output should act",

  test "the reference loop supplies retained output to a later read without a store" do
    let samples ← IO.mkRef 0
    let ref := OutputRead.reference fullText
    let replies := #[response #[bashCall], response #[readCall ref 6000 10],
      response #[{ id := "done", name := "submit", arguments := .mkObj [("message", "done")] }]]
    let sample : Dialogue -> Result Chat.Response := fun _ => do
      let i ← Result.fromIO Error.storage (samples.modifyGet fun n => (n, n + 1))
      pure replies[i]!
    let (log, _) ← assertOk <| Agent.run (agent fakeExecutor { task := "t" })
      { dir := ← scratch } sample #[]
    assertEqual "reference loop page" (str (← getObservation log "page") "content")
      (String.ofList (fullText.toList.drop 6000 |>.take 10)),

  test "omitted output need not be read before another command or submission" do
    for anotherCommand in #[false, true] do
      let samples ← IO.mkRef 0
      let executions ← IO.mkRef 0
      let executor : Executor := { fakeExecutor with exec := fun _ _ _ => do
        executions.modify (· + 1)
        pure { output := fullText, exitCode? := some 0 } }
      let submit : Chat.ToolCall := {
        id := "done", name := "submit", arguments := .mkObj [("message", "done without rereading")] }
      let replies := #[response #[bashCall]] ++
        (if anotherCommand then #[response #[{ bashCall with id := "later" }]] else #[]) ++
        #[response #[submit]]
      let sample : Dialogue -> Result Chat.Response := fun _ => do
        let i ← Result.fromIO Error.storage (samples.modifyGet fun n => (n, n + 1))
        let some reply := replies[i]? | throw <| .protocol "unexpected forced continuation"
        pure reply
      let (log, stop) ← assertOk <| Agent.run (agent executor { task := "t" })
        { dir := ← scratch } sample #[]
      match stop with
      | .outcome outcome => assertEqual "submission accepted" outcome.status "Submitted"
      | .question _ _ => fail "output recovery must not require an answer"
      assertEqual "only selected model turns" (← samples.get) replies.size
      assertEqual "only selected commands" (← executions.get) (if anotherCommand then 2 else 1)
      check (!(log.calls.any (·.name == "read_output"))) "no recovery call was injected"
      assertEqual "unread raw output preserved" (str (← getObservation log "original") "output") fullText,

  test "a sibling cannot recover another branch's output even with its reference" do
    let base ← scratch
    let project := base / "project"
    IO.FS.createDirAll project
    let store ← assertOk <| Cas.Store.create (base / "store")
    let rt : Runtime := {
      store, workDir := base / "work", executor := fakeExecutor,
      agent := agent fakeExecutor { task := "t" }, model := fixed (response #[bashCall]) }
    let root ← assertOk <| createRoot store #[] project
    let ancestor ← assertOk <| stepOnce rt "shared-output" root
    let leftText := fullText ++ "\nLEFT_ONLY"
    let leftExecutor := fakeExecutor leftText
    let leftRuntime : Runtime := { rt with
      executor := leftExecutor
      agent := agent leftExecutor { task := "t" }
      model := fixed (response #[{ bashCall with id := "left-output" }]) }
    let left ← assertOk <| stepOnce leftRuntime "left" ancestor
    let rightExecutor := fakeExecutor "RIGHT_ONLY"
    let rightRuntime : Runtime := { rt with
      executor := rightExecutor
      agent := agent rightExecutor { task := "t" }
      model := fixed (response #[{ bashCall with id := "right-output" }]) }
    let right ← assertOk <| stepOnce rightRuntime "right" ancestor
    for branch in #[left, right] do
      assertEqual "branches share the same parent" (← assertOk (getState store branch)).parent? (some ancestor)
    let privateOutput ← getObservation (← assertOk <| logOf store left) "left-output"
    let privateRef := str (observation ((Output.fromJson? privateOutput).get!)) "output_ref"
    let readPrivate := { (readCall privateRef (fullText.length + 1) 9) with id := "private-page" }
    let readAncestor := { (readCall (OutputRead.reference fullText) 6000 18) with id := "ancestor-page" }
    let reading : Runtime := { rt with model := fixed (response #[readPrivate, readAncestor]) }
    let leftRead ← assertOk <| stepOnce reading "read-left" left
    let rightRead ← assertOk <| stepOnce reading "read-right" right
    let expected := String.ofList (fullText.toList.drop 6000 |>.take 18)
    let leftLog ← assertOk <| logOf store leftRead
    let rightLog ← assertOk <| logOf store rightRead
    assertEqual "producer branch can recover" (str (← getObservation leftLog "private-page") "content") "LEFT_ONLY"
    let denied ← getObservation rightLog "private-page"
    check ((str denied "error").startsWith "Full output unavailable") "sibling reference must be unavailable"
    check (!(denied.getObjVal? "content").isOk) "no sibling content may be returned"
    for log in #[leftLog, rightLog] do
      assertEqual "common ancestor remains readable" (str (← getObservation log "ancestor-page") "content") expected,

  test "a new process resumes and recovers output without the original execution directory" do
    let base ← IO.FS.realPath (← scratch)
    let project := base / "project"
    let work := base / "work"
    IO.FS.createDirAll project
    let store ← assertOk <| Cas.Store.create (base / "store")
    let rt : Runtime := {
      store, workDir := work, executor := fakeExecutor,
      agent := agent fakeExecutor { task := "t" }, model := fixed (response #[bashCall]) }
    let root ← assertOk <| createRoot store #[] project
    let original ← assertOk <| stepOnce rt "original-process" root
    IO.FS.removeDirAll work
    let child ← IO.Process.output {
      cmd := (← IO.appPath).toString,
      args := #["--output-recovery-worker", store.root.toString, (base / "new-work").toString,
        original.hex, OutputRead.reference fullText] }
    check (child.exitCode == 0) s!"recovery subprocess failed: {child.stderr}"
    let resumed ← assertOk <| resolve store child.stdout.trimAscii.toString
    assertEqual "new process continued the recorded state"
      (← assertOk (getState store resumed)).parent? (some original)
    let page ← getObservation (← assertOk <| logOf store resumed) "page"
    assertEqual "subprocess persisted the exact middle" (str page "content")
      (String.ofList (fullText.toList.drop 6000 |>.take 18)),

  test "fork and resume reopen CAS with the identical output after deleting execution files" do
    let base ← scratch
    let project := base / "project"
    let work := base / "work"
    IO.FS.createDirAll project
    IO.FS.createDirAll work
    let store ← assertOk <| Cas.Store.create (base / "store")
    let rt : Runtime := {
      store, workDir := work, executor := fakeExecutor,
      agent := agent fakeExecutor { task := "t" }, model := fixed (response #[bashCall]) }
    let root ← assertOk <| createRoot store #[] project
    let original ← assertOk <| stepOnce rt "original" root
    let originalLog ← assertOk <| logOf store original
    let ref := str (observation ((Output.fromJson? (← getObservation originalLog "original")).get!)) "output_ref"
    IO.FS.removeDirAll work
    let reopened ← assertOk <| Cas.Store.create (base / "store")
    let _ ← assertOk reopened.gc
    let reading : Runtime := { rt with store := reopened, model := fixed (response #[readCall ref 6000 10]) }
    let left ← assertOk <| stepOnce reading "left" original
    let right ← assertOk <| stepOnce reading "right" original
    check (left != right) "two fork children"
    for branch in #[left, right] do
      assertEqual "page on fork" (str (← getObservation (← assertOk <| logOf reopened branch) "page") "content")
        (String.ofList (fullText.toList.drop 6000 |>.take 10))
    let finishing : Runtime := { reading with model := fixed (response #[{
      id := "done", name := "submit", arguments := .mkObj [("message", "finished")] }]) }
    let ended ← assertOk <| resume finishing "resume" right (fun _ => pure ())
    assertEqual "resumed outcome" ((← assertOk (getState reopened ended)).outcome?.map (·.status)) (some "Submitted"),

  test "failed state persistence never sends a preview claiming recoverable output" do
    let base ← scratch
    let project := base / "project"
    let work := base / "work"
    IO.FS.createDirAll project
    IO.FS.createDirAll work
    let store ← assertOk <| Cas.Store.create (base / "store")
    let root ← assertOk <| createRoot store #[] project
    let calls ← IO.mkRef 0
    let model : Model := { identity := .null, sample := fun request => do
      Result.fromIO Error.storage <| calls.modify (· + 1)
      if !request.messages.isEmpty then throw <| .protocol "unexpected later preview"
      pure { next := pure (response #[bashCall]) } }
    let breakingExecutor : Executor := { fakeExecutor with exec := fun _ _ _ => do
      IO.FS.removeDirAll (store.root / "tmp")
      IO.FS.writeFile (store.root / "tmp") "block writes after command execution"
      pure { output := fullText, exitCode? := some 0 } }
    let rt : Runtime := {
      store, workDir := work, executor := breakingExecutor,
      agent := agent breakingExecutor { task := "t" }, model }
    assertError "persistence failure" (resume rt "failure" root (fun _ => pure ()))
      (fun | .storage _ => true | _ => false)
    assertEqual "only pre-execution request" (← calls.get) 1
    assertEqual "no output state published" (← assertOk <| allStates store) #[root],

  test "new tool schema separates cache keys and read-only replay never calls a provider" do
    let calls ← IO.mkRef 0
    let source : Model := {
      identity := .mkObj [("model", "cache-policy-test")]
      sample := fun _ => do
        Result.fromIO Error.cache <| calls.modify (· + 1)
        pure { next := pure { content? := some "cached" } } }
    let directory := (← scratch) / "cache"
    let oldRequest : Chat.Request := {
      messages := view (rawLog "short output"), tools := #[bashTool, submitTool] }
    let recording ← assertOk <| Cache.persistent source { directory }
    let first ← assertOk <| do (← recording.sample oldRequest).next
    assertEqual "recorded result" first.content? (some "cached")
    let replay ← assertOk <| Cache.persistent source { directory, readOnly := true }
    let cached ← assertOk <| do (← replay.sample oldRequest).next
    assertEqual "same old request hits" cached.content? (some "cached")
    assertError "new schema must not impersonate old request"
      (do (← replay.sample { oldRequest with tools }).next)
      (fun | .cache _ => true | _ => false)
    assertEqual "no read-only provider calls" (← calls.get) 1,

  test "missing or corrupt state blocks recovery explicitly" do
    let base ← scratch
    let project := base / "project"
    IO.FS.createDirAll project
    let store ← assertOk <| Cas.Store.create (base / "store")
    let root ← assertOk <| createRoot store (rawLog fullText) project
    IO.FS.writeFile (store.blobFile root) "corrupt"
    assertError "corrupt state" (logOf store root) (fun | .storage _ => true | _ => false)
    IO.FS.removeFile (store.blobFile root)
    assertError "missing state" (logOf store root) (fun | .storage _ => true | _ => false)
]

end OutputReadTests
