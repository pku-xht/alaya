import Test.Base.Hash
import Test.Base.Lock
import Test.Base.Tap
import Test.Base.Question
import Test.Base.Settings

/-! The tests of `Alaya.Base`: none needs more than Lean and the filesystem. -/

namespace BaseTests

open Testing

def suites : Array Suite :=
  #[HashTests.suite, LockTests.suite, QuestionTests.suite, SettingsTests.suite, TapTests.specSuite, TapTests.fixtureSuite]

end BaseTests
