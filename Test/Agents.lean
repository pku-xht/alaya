import Test.Agents.MiniSwe
import Test.Agents.MiniVero
import Test.Agents.AskUser
import Test.Agents.Context
import Test.Agents.Grader
import Test.Agents.Routines
import Test.Support.Needs

/-! The tests of `Alaya.Agents`: the programs, driven by scripted models. -/

namespace AgentsTests

open Testing

def suites : Array Suite := #[
  MiniSweTests.goldenSuite, MiniSweTests.parseSuite, MiniSweTests.dialogueSuite,
  { MiniSweTests.runSuite with needs := #[docker] },
  MiniVeroTests.suite, { MiniVeroTests.timeSuite with needs := #[docker] },
  AskUserTests.suite, ContextTests.suite, GraderTests.suite, AgentRoutinesTests.suite]

end AgentsTests
