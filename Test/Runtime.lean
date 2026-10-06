import Test.Runtime.Log
import Test.Runtime.Store
import Test.Runtime.Workspaces
import Test.Runtime.Preview
import Test.Runtime.Driver
import Test.Runtime.Routines
import Test.Runtime.Rebase
import Test.Runtime.Docker
import Test.Runtime.Data
import Test.Agents.MiniSwe
import Test.Support.Needs

/-! The tests of `Alaya.Runtime`: the log, the store, workspaces, executors and the driver. -/

namespace RuntimeTests

open Testing

def suites : Array Suite := #[
  LogTests.suite, StoreTests.suite, WorkspacesTests.pathSuite,
  { WorkspacesTests.suite with needs := #[restic] }, { WorkspacesTests.resticSuite with needs := #[restic] },
  { PreviewTests.suite with needs := #[restic] }, DriverTests.suite,
  RoutinesTests.suite, RebaseTests.suite, DataTests.suite,
  { WorkspacesTests.runSuite with needs := #[restic, docker] },
  DockerTests.settingsSuite, { DockerTests.suite with needs := #[docker] },
  { DockerTests.execSuite with needs := #[docker] }]

end RuntimeTests
