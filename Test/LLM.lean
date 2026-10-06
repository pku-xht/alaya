import Test.LLM.Legacy
import Test.LLM.Responses
import Test.App.Cli

/-! The tests of `Alaya.LLM`: models, providers, retries and the cache, with no network. -/

namespace LLMTests

open Testing

def suites : Array Suite := #[LegacyTests.suite, ResponsesTests.suite, CliTests.endpointSuite]

end LLMTests
