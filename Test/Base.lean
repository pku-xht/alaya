import Test.Base.Hash
import Test.Base.Lock
import Test.Base.Tap

/-! The tests of `Alaya.Base`: none needs more than Lean and the filesystem. -/

namespace BaseTests

open Testing

def suites : Array Suite :=
  #[HashTests.suite, LockTests.suite, TapTests.specSuite, TapTests.fixtureSuite]

end BaseTests
