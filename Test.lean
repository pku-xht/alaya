import Test.Base
import Test.Core
import Test.LLM
import Test.Runtime
import Test.Agents
import Test.App

/-! The test runner. `lake exe tests` runs everything; `lake exe tests FILTER …` keeps the cases
whose `suite/case` name contains any filter, as `core/` keeps a layer and `runtime/driver` a
module; `lake exe tests --list FILTER …` names them. Suites are by layer, as the library is
(`Test/Base`, `Test/Core`, …, `Test/App`), and each says what it needs beyond Lean: one whose
needs the machine does not meet is skipped, and said to be. The `app/commands` suite runs the
`alaya` binary as `lake build alaya` leaves it. -/

open Testing

def main (args : List String) : IO UInt32 := do
  let suites := BaseTests.suites ++ CoreTests.suites ++ LLMTests.suites ++ RuntimeTests.suites
    ++ AgentsTests.suites ++ AppTests.suites
  try runSuites suites (Options.parse args)
  finally
    if (← dockerProblem?).isNone then removeTestContainers
