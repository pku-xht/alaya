import Test.Framework
import Test.Container
import Test.Legacy
import Test.Sha256
import Test.Store
import Test.Lock
import Test.MiniSwe
import Test.Trajectory
import Test.MiniVero
import Test.Workspaces
import Test.Cli
import Test.Docker
import Test.OutputFiles
import Test.Context
import Test.Responses
import Test.AskUser
import Test.Preview
import Test.Tap
import Test.Grader
import Test.Effects

/-! The test runner. `lake exe tests` runs everything; `lake exe tests <substring>` keeps
only the cases whose `suite/case` name contains the substring. The tests need a running docker
daemon: every command they run, runs in a container. -/

def main (args : List String) : IO UInt32 := do
  let suites := #[LegacyTests.suite, Sha256Tests.suite, StoreTests.suite, LockTests.suite] ++ MiniSweTests.suites ++ #[TrajectoryTests.suite] ++ CliTests.suites ++ #[MiniVeroTests.suite, MiniVeroTests.timeSuite, WorkspacesTests.pathSuite, WorkspacesTests.suite, WorkspacesTests.resticSuite, WorkspacesTests.trajectorySuite, OutputFilesTests.suite, ContextTests.suite, ResponsesTests.suite, AskUserTests.suite, PreviewTests.suite, DockerTests.suite, TapTests.specSuite, TapTests.fixtureSuite, GraderTests.suite, EffectsTests.suite]
  if let some problem ← Testing.dockerProblem? then
    IO.eprintln s!"The tests run every command in a container, and cannot start: {problem}."
    return 1
  try Testing.runSuites suites args.head?
  finally Testing.removeTestContainers
