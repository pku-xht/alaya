import Test.LLM.Chat
import Test.LLM.Model
import Test.LLM.Retry
import Test.LLM.Cache
import Test.LLM.Responses
import Test.LLM.Providers

/-! The tests of `Alaya.LLM`: the chat protocol, models, retries, the cache and providers, with
no network. -/

namespace LLMTests

open Testing

def suites : Array Suite :=
  #[ChatTests.suite, ModelTests.suite, RetryTests.suite, CacheTests.suite, ResponsesTests.suite, ProvidersTests.suite]

end LLMTests
