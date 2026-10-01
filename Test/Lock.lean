import Test.Framework
import Alaya.Lock

/-! One writer at a time in a data directory (`Alaya.Lock`). -/

namespace LockTests

open Testing Alaya

def suite : Suite := Testing.suite "lock" #[
  test "a second writer is refused at once, naming the holder, until the first releases" do
    let dir := (← scratch) / "data"
    IO.FS.createDirAll dir
    let first ← assertOk <| Lock.acquire dir
    let pid := toString (← (IO.Process.getPID : BaseIO UInt32))
    assertError "second" (Lock.acquire dir) fun
      | .busy m => (m.splitOn s!"pid {pid}").length > 1 && (m.splitOn "try again").length > 1
      | _ => false
    check ((Error.busy "x").class == .transient) "busy is a reason to try again later"
    assertOk first.release
    let again ← assertOk <| Lock.acquire dir
    assertOk again.release
]

end LockTests
