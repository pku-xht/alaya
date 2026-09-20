import Test.Framework
import Alaya.Trajectory.Store

/-! The state store: one file per state, named by the hash of its bytes. -/

namespace StoreTests

open Testing
open Alaya
open Alaya.Trajectory (Store)

private def withStore : TestM Store := do
  assertOk <| Store.create ((← scratch) / "states")

def suite : Suite := Testing.suite "trajectory.store" #[
  test "bytes are stored under their hash, once" do
    let store ← withStore
    let bytes := "{\"kind\":\"root\"}".toUTF8
    let hash ← assertOk <| store.put bytes
    assertEqual "named by content" hash (Hash.ofBytes bytes)
    assertEqual "roundtrip" ((← assertOk <| store.get? hash).map (·.toList)) (some bytes.toList)
    assertEqual "stable name" (← assertOk <| store.put bytes) hash
    assertEqual "one file" (← (← scratch) / "states" |>.readDir).size 1
    assertEqual "absent" (← assertOk <| store.get? ⟨String.ofList (List.replicate 64 'a')⟩) none,

  test "list is the stored states, sorted, and nothing else in the directory" do
    let store ← withStore
    let hashes ← #["one", "two", "three"].mapM fun text => assertOk <| store.put text.toUTF8
    IO.FS.writeFile ((← scratch) / "states" / "notes.txt") "stray"
    IO.FS.writeFile ((← scratch) / "states" / ".half-written.tmp") "stray"
    assertEqual "listed" (← assertOk store.list) (hashes.qsort fun a b => a.hex < b.hex),

  test "delete removes one state and is idempotent" do
    let store ← withStore
    let kept ← assertOk <| store.put "kept".toUTF8
    let gone ← assertOk <| store.put "gone".toUTF8
    assertOk <| store.delete gone
    assertOk <| store.delete gone
    assertEqual "listed" (← assertOk store.list) #[kept]
    assertEqual "unreadable" (← assertOk <| store.get? gone) none,

  test "a hostile name never reaches the directory" do
    let store ← withStore
    let outside := (← scratch) / "outside.json"
    IO.FS.writeFile outside "outside"
    check (!Hash.valid "../outside") "a path is not a digest"
    check (!Hash.valid (String.ofList (List.replicate 64 'G'))) "uppercase is not a digest"
    assertEqual "get" (← assertOk <| store.get? ⟨"../outside"⟩) none
    assertOk <| store.delete ⟨"../outside"⟩
    check (← outside.pathExists) "a file outside the store was deleted"
]

end StoreTests
