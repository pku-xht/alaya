import Test.Framework
import Test.Legacy
import Test.Sha256
import Test.Cas
import Test.Mini
import Test.MiniAsk
import Test.Cli
import Test.Docker
import Test.OutputRead

/-! The test runner. `lake exe tests` runs everything; `lake exe tests <substring>` keeps
only the cases whose `suite/case` name contains the substring. -/

def main (args : List String) : IO UInt32 := do
  let suites := #[LegacyTests.suite, CasTests.Sha256.suite] ++ CasTests.suites ++ MiniTests.suites ++ CliTests.suites ++ #[DockerTests.suite, MiniAskTests.suite, OutputReadTests.suite]
  Testing.runSuites suites args.head?
