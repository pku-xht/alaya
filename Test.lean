import Test.Framework
import Test.Legacy
import Test.Sha256
import Test.Cas
import Test.Mini
import Test.Cli
import Test.Docker
import Test.OutputRead

/-! The test runner. `lake exe tests` runs everything; `lake exe tests <substring>` keeps
only the cases whose `suite/case` name contains the substring. -/

def main (args : List String) : IO UInt32 := do
  match args with
  | ["--output-recovery-worker", storePath, workPath, state, ref] =>
    OutputReadTests.recoveryWorker storePath workPath state ref
  | "--output-recovery-worker" :: _ =>
    throw <| IO.userError "usage: tests --output-recovery-worker STORE WORK STATE OUTPUT_REF"
  | _ =>
    let suites := #[LegacyTests.suite, CasTests.Sha256.suite] ++ CasTests.suites ++ MiniTests.suites ++ CliTests.suites ++ #[DockerTests.suite, OutputReadTests.suite]
    Testing.runSuites suites args.head?
