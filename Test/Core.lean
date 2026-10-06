import Test.Core.Prototype

/-! The tests of `Alaya.Core`: pure, over signatures of their own. -/

namespace CoreTests

open Testing

def suites : Array Suite := #[PrototypeTests.suite]

end CoreTests
