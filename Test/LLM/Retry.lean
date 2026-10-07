import Test.LLM.Support

/-! Retries: which failures are tried again, how many times, and how long the waits may be. -/

namespace RetryTests

open Testing LLMSupport
open Alaya Alaya.Base Alaya.LLM

/-- No waiting: every delay is zero. -/
private def quick : Retry.Config := { initialDelayMs := 0, rateLimitFloorMs := 0 }

/-- Runs `action` under `config`, and gives how it ended and how many times it ran. -/
private def attempt (config : Retry.Config) (errors : List Error) : TestM (Except Error Nat × Nat) := do
  let (action, attempts) ← failing errors 42
  let result ← (Retry.run config action).toBaseIO
  pure (result, ← attempts)

private def assertRuns (label : String) (config : Retry.Config) (errors : List Error) (runs : Nat)
    (succeeds : Bool) : TestM Unit := do
  let (result, attempts) ← attempt config errors
  assertEqual s!"{label}: attempts" attempts runs
  check (result.toOption.isSome == succeeds) s!"{label}: {if succeeds then "should succeed" else "should fail"}"

def suite : Suite := Testing.suite "llm/retry" #[
  test "a transient failure is tried again until it succeeds or the attempts run out" do
    assertRuns "two rate limits, then success" { quick with maxAttempts := 3 } [.http 429 "" none, .http 429 "" none] 3 true
    assertRuns "an unavailable server, every time" { quick with maxAttempts := 3 } (List.replicate 5 (.http 503 "" none)) 3 false,

  test "only what may succeed on a second try is tried again" do
    for status in [408, 409, 425, 500, 502, 503] do
      assertRuns s!"HTTP {status}" { quick with maxAttempts := 2 } [.http status "" none] 2 true
    for status in [400, 401, 403, 404, 422] do
      assertRuns s!"HTTP {status}" { quick with maxAttempts := 3 } [.http status "" none] 1 false
    for (label, error) in [("a refusal for length", Error.contextExceeded "too long"), ("an input error", .input "bad"),
        ("a provider's own failure", .provider "no")] do
      assertRuns label { quick with maxAttempts := 3 } [error] 1 false,

  test "a delivery whose result is unknown, a malformed response and invalid structured output are tried again only when asked" do
    assertRuns "transport, by default" { quick with maxAttempts := 3 } [.transport "reset"] 1 false
    assertRuns "transport, asked" { quick with maxAttempts := 3, retryUnknownDelivery := true } [.transport "reset"] 2 true
    assertRuns "malformed, by default" { quick with maxAttempts := 3 } [.protocol "truncated"] 1 false
    assertRuns "malformed, asked" { quick with maxAttempts := 3, retryMalformedResponse := true } (List.replicate 3 (.protocol "truncated")) 3 false
    assertRuns "structured output, asked" { quick with maxAttempts := 2, retryStructuredOutput := true } [.structuredOutput "invalid"] 2 true,

  test "rate limits have a budget of their own, and each class counts its own failures" do
    assertRuns "five rate limits under a budget of six" { quick with maxAttempts := 3, rateLimitMaxAttempts := 6 }
      (List.replicate 4 (.http 429 "" none)) 5 true
    assertRuns "a budget of five, exhausted" { quick with maxAttempts := 2, rateLimitMaxAttempts := 5 }
      (List.replicate 9 (.http 429 "" none)) 5 false
    assertRuns "three rate limits leave the server's budget whole" { quick with maxAttempts := 3, rateLimitMaxAttempts := 8 }
      [.http 429 "" none, .http 429 "" none, .http 429 "" none, .http 503 "" none] 5 true,

  test "one attempt means none again, for every class, and none at all is refused" do
    assertRuns "a rate limit" { quick with maxAttempts := 1 } [.http 429 "" none] 1 false
    let (result, attempts) ← attempt { quick with maxAttempts := 0 } []
    check (result matches .error (.input _)) "zero attempts is an input error"
    assertEqual "and nothing ran" attempts 0,

  test "a server's Retry-After is waited for, and capped" do
    let started ← IO.monoMsNow
    assertRuns "a hostile delay, capped" { quick with maxAttempts := 2, maxDelayMs := 5, maxRetryAfterMs := 5 }
      [.http 429 "" (some 600000)] 2 true
    check ((← IO.monoMsNow) - started < 2000) "the ten-minute delay was not slept"
    let started ← IO.monoMsNow
    assertRuns "a delay the server asks for" { quick with maxAttempts := 2, maxRetryAfterMs := 1000 }
      [.http 503 "" (some 150)] 2 true
    check ((← IO.monoMsNow) - started ≥ 150) "no sooner than the server asked"
]

end RetryTests
