import Test.LLM.Support

/-! Models built from models: draws made concurrently, with a bound on how many are in flight,
and models whose streams share, or do not share, their draws. -/

namespace ModelTests

open Testing LLMSupport
open Alaya Alaya.Base Alaya.LLM

private def contents (responses : Array Chat.Response) : Array String :=
  responses.map (·.content?.getD "?")

def suite : Suite := Testing.suite "llm/model" #[
  test "a batch draws concurrently, never more in flight than its bound, and a bound of none is refused" do
    let inFlight ← IO.mkRef 0
    let peak ← IO.mkRef 0
    let base : Model := {
      identity := .mkObj [("model", "limit-test")]
      sample := fun _ => pure { next := do
        let current ← Result.fromIO Error.cache <| inFlight.modifyGet fun n => (n + 1, n + 1)
        let _ ← Result.fromIO Error.cache <| peak.modify fun p => max p current
        let _ ← Result.fromIO Error.cache <| IO.sleep 20
        let _ ← Result.fromIO Error.cache <| inFlight.modify (· - 1)
        pure <| response 0 } }
    let concurrent ← assertOk <| base.batch (.concurrent (some 2))
    let responses ← assertOk <| (← assertOk <| concurrent.sample request).nextN 6
    assertEqual "every draw" responses.size 6
    check ((← peak.get) ≤ 2) s!"at most two in flight, not {← peak.get}"
    assertInput "a bound of zero" (base.batch (.concurrent (some 0))) "maxInFlight",

  test "a repeatable model's streams of one request replay one sequence, and a new stream starts it over" do
    let (base, samples) ← countingModel
    let repeatable ← assertOk base.repeatable
    let s1 ← assertOk <| repeatable.sample request
    let s2 ← assertOk <| repeatable.sample request
    let mut seen := #[]
    for stream in [s1, s2, s1, s2, s1] do
      seen := seen.push ((← assertOk stream.next).content?.getD "?")
    assertEqual "both streams see the same draws" seen #["0", "0", "1", "1", "2"]
    assertEqual "three draws made" (← samples) 3
    let again ← assertOk <| repeatable.sample request
    assertEqual "a new stream from the start" (← assertOk again.next).content? (some "0"),

  test "an independent model's sequence goes on across its repeatable views" do
    let (base, samples) ← countingModel
    let shared ← assertOk (← assertOk base.repeatable).independent
    let mut draws : Array String := #[]
    for _ in [0:2] do
      let view ← assertOk shared.repeatable
      let a ← assertOk <| view.sample request
      let b ← assertOk <| view.sample request
      draws := draws ++ contents #[← assertOk a.next, ← assertOk b.next, ← assertOk a.next]
    assertEqual "a later view draws afresh" draws #["0", "0", "1", "2", "2", "3"]
    assertEqual "four draws made" (← samples) 4
]

end ModelTests
