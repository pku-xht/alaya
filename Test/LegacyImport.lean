import Test.Framework
import Alaya.Trajectory.Legacy

namespace LegacyImportTests

open Testing Alaya Alaya.Cas Alaya.Trajectory

private def rawObject (store : System.FilePath) (bytes : ByteArray) : IO Hash := do
  let hash : Hash := ⟨Sha256.sumHex bytes⟩
  let directory := store / "blobs" / (hash.hex.take 2).toString
  IO.FS.createDirAll directory
  IO.FS.writeBinFile (directory / hash.hex) bytes
  pure hash

private def rawTree (store : System.FilePath) (files : Array (String × String)) : IO Hash := do
  let entries ← files.mapM fun (name, contents) => do
    pure ({ name, type := .file, hash := ← rawObject store contents.toUTF8 } : Entry)
  rawObject store (Tree.ofEntries entries).toJson.compress.toUTF8

private def rawState (store : System.FilePath) (state : State) (pin : Bool := true) : IO Hash := do
  let hash ← rawObject store state.toJson.compress.toUTF8
  if pin then
    IO.FS.createDirAll (store / "refs")
    IO.FS.writeFile (store / "refs" / ("state." ++ hash.hex)) (hash.hex ++ "\n")
  pure hash

private def mapped (mappings : Array (Hash × Hash)) (old : Hash) : TestM Hash := do
  match mappings.find? (fun entry => entry.1 == old) with
  | some (_, imported) => pure imported
  | none => fail s!"missing mapping for {old.hex}"

def suite : Suite := Testing.suite "legacy-import" #[
  test "migrates parent chains and evidence without changing logs or original files" do
    let data := (← scratch) / "data"
    let raw := data / "store"
    let initial ← rawTree raw #[("source.txt", "before\n")]
    let updated ← rawTree raw #[("source.txt", "after\n")]
    let evidence ← rawTree raw #[("verdict.json", "{\"passed\":true}\n")]
    let rootLog : Agent.Log := #[.message (.system "system"), .message (.user "complete task")]
    let turnLog : Agent.Log := #[
      .response { content? := some "recorded answer", usage? := some { input? := some 10, output? := some 2 } },
      .observation "original-call" (.mkObj [("output", "original tool bytes"), ("returncode", 0)])]
    let root ← rawState raw {
      parent? := none, workspace := initial, kind := .root
      appended := rootLog, note? := some "original task", image? := some "sha256:original-image" } false
    let turn ← rawState raw {
      parent? := some root, workspace := updated, kind := .turn
      appended := turnLog, note? := some "historical:model", image? := some "sha256:original-image" } false
    let evaluation ← rawState raw {
      parent? := some turn, workspace := updated, kind := .evaluation
      appended := #[], evaluation? := some {
        grader := "original grader", returncode := 0
        elapsedMs := 37, output := "PASS", evidence? := some evidence } }
    let originalBlobs ← readSpec (raw / "blobs")
    let originalRefs ← readSpec (raw / "refs")
    let cache := deterministicBytes 42 100
    IO.FS.createDirAll (data / "cache" / "v1")
    IO.FS.writeBinFile (data / "cache" / "v1" / "recorded-response") cache
    let mappings ← assertOk <| Trajectory.Legacy.importData data
    assertEqual "all ancestors included" mappings.size 3
    let store ← assertOk <| Store.create raw
    let newRoot ← mapped mappings root
    let newTurn ← mapped mappings turn
    let newEvaluation ← mapped mappings evaluation
    let rootState ← assertOk <| getState store newRoot
    let turnState ← assertOk <| getState store newTurn
    let evaluationState ← assertOk <| getState store newEvaluation
    assertEqual "root" rootState.parent? none
    assertEqual "turn parent" turnState.parent? (some newRoot)
    assertEqual "evaluation parent" evaluationState.parent? (some newTurn)
    assertEqual "original model provenance" turnState.note? (some "historical:model")
    assertEqual "original image" turnState.image? (some "sha256:original-image")
    let log ← assertOk <| logOf store newEvaluation
    assertEqual "full recorded log" (log.map (eventToJson · |>.compress))
      ((rootLog ++ turnLog).map (eventToJson · |>.compress))
    assertEqual "root workspace" (← assertOk <| store.readPath rootState.workspace "source.txt")
      (some "before\n".toUTF8)
    assertEqual "turn workspace" (← assertOk <| store.readPath turnState.workspace "source.txt")
      (some "after\n".toUTF8)
    let some verdict := evaluationState.evaluation? | fail "missing evaluation"
    let some newEvidence := verdict.evidence? | fail "missing migrated evidence"
    assertEqual "grader result" verdict.output "PASS"
    assertEqual "evidence bytes" (← assertOk <| store.readPath newEvidence "verdict.json")
      (some "{\"passed\":true}\n".toUTF8)
    assertEqual "original blobs" (← readSpec (raw / "blobs")) originalBlobs
    assertEqual "original refs" (← readSpec (raw / "refs")) originalRefs
    assertEqual "recorded model cache" (← IO.FS.readBinFile (data / "cache" / "v1" / "recorded-response")) cache
    assertEqual "new state refs" (← assertOk <| allStates store).size 3,

  test "repeated import is stable and corrupt source fails explicitly" do
    let data := (← scratch) / "data"
    let raw := data / "store"
    let workspace ← rawTree raw #[("source.txt", "preserved")]
    let old ← rawState raw { parent? := none, workspace, kind := .root, appended := #[] }
    let first ← assertOk <| Trajectory.Legacy.importData data
    let manifest ← IO.FS.readBinFile (data / "legacy-import.json")
    let second ← assertOk <| Trajectory.Legacy.importData data
    assertEqual "same old/new addresses" second first
    assertEqual "same manifest bytes" (← IO.FS.readBinFile (data / "legacy-import.json")) manifest
    let store ← assertOk <| Store.create raw
    assertEqual "no duplicate state refs" (← assertOk <| allStates store).size 1
    IO.FS.writeFile (raw / "blobs" / (old.hex.take 2).toString / old.hex) "corrupt"
    assertError "corrupt raw state" (Trajectory.Legacy.importData data) fun
      | .storage text => (text.splitOn "corrupt legacy").length > 1
      | _ => false
    assertEqual "failed import does not publish a new manifest"
      (← IO.FS.readBinFile (data / "legacy-import.json")) manifest
]

end LegacyImportTests
