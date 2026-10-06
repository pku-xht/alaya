import Test.App.Cli
import Test.App.Render
import Test.App.Html
import Test.App.Commands
import Test.Support.Needs

/-! The tests of `Alaya.App`: the command line, the catalog and the session, and what is shown. -/

namespace AppTests

open Testing

def suites : Array Suite := #[
  CliTests.specSuite, CliTests.taskSuite, CliTests.agentsSuite, RenderTests.suite,
  { HtmlTests.suite with needs := #[node] }, { CommandsTests.suite with needs := #[binary, docker] }]

end AppTests
