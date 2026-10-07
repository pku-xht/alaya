import Test.Core.Prototype
import Test.Core.Replay

/-! The tests of `Alaya.Core`: pure, over signatures of their own. -/

namespace CoreTests

open Testing

def suites : Array Suite := ReplayTests.suites ++ #[PrototypeTests.suite]

end CoreTests
