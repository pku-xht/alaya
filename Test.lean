import Test.Framework
import Test.Container
import Test.Legacy
import Test.Sha256
import Test.Lock
import Test.Prototype
import Test.Log
import Test.Store
import Test.Render
import Test.Runs
import Test.MiniSwe
import Test.MiniVero
import Test.Workspaces
import Test.Cli
import Test.Docker
import Test.Context
import Test.Responses
import Test.AskUser
import Test.Preview
import Test.Tap
import Test.Grader
import Test.Html
import Test.Commands

/-! The test runner. `lake exe tests` runs everything; `lake exe tests <substring>` keeps
only the cases whose `suite/case` name contains the substring. The tests need a running docker
daemon: every command they run, runs in a container. The `commands` suite runs the `alaya` binary
as it is built: `lake build alaya tests` builds it with the tests. -/

def main (args : List String) : IO UInt32 := do
  let suites := #[LegacyTests.suite, Sha256Tests.suite, LockTests.suite, PrototypeTests.suite,
    LogTests.suite, StoreTests.suite, RenderTests.suite, RunsTests.suite] ++ MiniSweTests.suites ++ CliTests.suites ++
    #[MiniVeroTests.suite, MiniVeroTests.timeSuite, WorkspacesTests.pathSuite, WorkspacesTests.suite,
      WorkspacesTests.resticSuite, WorkspacesTests.runSuite, ContextTests.suite, ResponsesTests.suite,
      AskUserTests.suite, PreviewTests.suite, DockerTests.suite, TapTests.specSuite,
      TapTests.fixtureSuite, GraderTests.suite, HtmlTests.suite, CommandsTests.suite]
  if let some problem ← Testing.dockerProblem? then
    IO.eprintln s!"The tests run every command in a container, and cannot start: {problem}."
    return 1
  try Testing.runSuites suites args.head?
  finally Testing.removeTestContainers
