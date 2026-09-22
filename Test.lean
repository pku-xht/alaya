import Test.Framework
import Test.Legacy
import Test.Sha256
import Test.Store
import Test.Mini
import Test.MiniVero
import Test.Workspaces
import Test.Cli
import Test.Docker
import Test.OutputRead
import Test.AskUser

/-! The test runner. `lake exe tests` runs everything; `lake exe tests <substring>` keeps
only the cases whose `suite/case` name contains the substring. -/

def main (args : List String) : IO UInt32 := do
  let suites := #[LegacyTests.suite, Sha256Tests.suite, StoreTests.suite] ++ MiniTests.suites ++ CliTests.suites ++ #[MiniVeroTests.suite, WorkspacesTests.pathSuite, WorkspacesTests.suite, WorkspacesTests.resticSuite, WorkspacesTests.trajectorySuite, OutputReadTests.suite, AskUserTests.suite, DockerTests.suite]
  Testing.runSuites suites args.head?
