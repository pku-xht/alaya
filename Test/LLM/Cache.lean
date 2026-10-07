import Test.LLM.Support

/-! The persistent cache: a request's draws kept on disk in order, replayed from the start by
every new stream, drawn afresh only past their end, and shared with another directory as links. -/

namespace CacheTests

open Testing LLMSupport
open Alaya Alaya.Base Alaya.LLM

private def cacheIn (base : Model) (readOnly := false) : TestM Model := do
  assertOk <| Cache.persistent base { directory := (← scratch) / "cache", readOnly }

def suite : Suite := Testing.suite "llm/cache" #[
  test "every new stream replays the draws kept, with the time each took, and draws only past them" do
    let (base, samples) ← countingModel
    let cached ← cacheIn base
    let first ← assertOk (← assertOk <| cached.sample request).next
    let second ← assertOk (← assertOk <| cached.sample request).next
    assertEqual "the same draw" second.content? first.content?
    check first.elapsedMs?.isSome "a draw's time is measured"
    assertEqual "and kept with it" second.elapsedMs? first.elapsedMs?
    assertEqual "one draw made" (← samples) 1
    -- Three draws where one is kept: two more are made, and all three are kept.
    let three ← assertOk <| (← assertOk <| cached.sample request).nextN 3
    assertEqual "in order" (three.map (·.content?.getD "?")) #["0", "1", "2"]
    assertEqual "two more made" (← samples) 3
    let (other, otherSamples) ← countingModel
    let reread ← assertOk <| (← assertOk <| (← cacheIn other).sample request).nextN 3
    assertEqual "another process reads them from disk" (reread.map (·.content?.getD "?")) #["0", "1", "2"]
    assertEqual "drawing nothing" (← otherSamples) 0,

  test "a read-only cache refuses to draw, and a corrupt entry is a miss that is written again" do
    let (base, _) ← countingModel
    let readOnly ← cacheIn base (readOnly := true)
    assertError "a miss" ((← assertOk <| readOnly.sample request).next) fun
      | .cache _ => true
      | _ => false
    let cached ← cacheIn base
    let _ ← assertOk (← assertOk <| cached.sample request).next
    let directory := (← scratch) / "cache"
    for entry in ← directory.readDir do
      IO.FS.writeFile entry.path "{ not json"
    let (fresh, samples) ← countingModel
    let again ← assertOk (← assertOk <| (← cacheIn fresh).sample request).next
    assertEqual "drawn afresh" again.content? (some "0")
    assertEqual "by the model" (← samples) 1
    let (third, thirdSamples) ← countingModel
    let _ ← assertOk (← assertOk <| (← cacheIn third).sample request).next
    assertEqual "and written again" (← thirdSamples) 0,

  test "the cache is shared as links, and a write in either directory leaves the other as it was" do
    let source := (← scratch) / "cache"
    IO.FS.createDirAll source
    IO.FS.writeFile (source / "a.json") "first"
    IO.FS.writeFile (source / "a.json.1-2.tmp") "half-written"
    let target := (← scratch) / "linked"
    assertOk <| Cache.link source target
    assertEqual "the entries, not a save in progress" ((← target.readDir).map (·.fileName)) #["a.json"]
    assertEqual "the same content" (← IO.FS.readFile (target / "a.json")) "first"
    -- As `save` writes: a new file renamed over the name.
    IO.FS.writeFile (target / "a.json.tmp") "second"
    IO.FS.rename (target / "a.json.tmp") (target / "a.json")
    assertEqual "the source unchanged" (← IO.FS.readFile (source / "a.json")) "first"
    assertEqual "the target changed" (← IO.FS.readFile (target / "a.json")) "second"
    assertOk <| Cache.link ((← scratch) / "nowhere") ((← scratch) / "empty")
    assertEqual "no source is an empty cache" ((← ((← scratch) / "empty").readDir).size) 0
]

end CacheTests
