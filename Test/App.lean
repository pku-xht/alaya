import Test.App.Cli
import Test.App.Catalog
import Test.App.Session
import Test.App.Render
import Test.App.Html
import Test.App.Rebase
import Test.App.Commands
import Test.Support.Needs

/-! The tests of `Alaya.App`: the command line, the catalog and the session, what is shown, and
the `alaya` binary itself. -/

namespace AppTests

open Testing

def suites : Array Suite := #[
  CliTests.specSuite, CliTests.taskSuite, CatalogTests.suite, SessionTests.suite, RenderTests.suite, HtmlTests.suite,
  { HtmlTests.pageSuite with needs := #[node] }, AppRebaseTests.suite,
  { CommandsTests.suite with needs := #[binary, docker] }]

end AppTests
