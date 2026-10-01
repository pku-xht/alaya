import Test.Framework
import Alaya

/-! The container that every test running a command runs it in. Nothing a test asks an agent or
a grader to do runs on the host, so the tests need a docker daemon; `lake exe tests` checks for
one before it starts, and removes the containers its tests left running when it ends. -/

namespace Testing

open Alaya

/-- The test image. Small, and `busybox` gives it a `timeout(1)`. -/
def testImageReference : String := "alpine:3"

/-- The label on every container the tests start. -/
def testLabel : String := "alaya-test"

/-- Settings for the pinned test image, running as the host user on Linux, without network. -/
def testSettings : IO Executor.Docker.Settings := do
  let settings ← (Executor.Docker.settingsOf {} testImageReference).toUserIO
  let settings ← settings.pin.toUserIO
  pure { settings with extraRunArgs := #["--label", testLabel] }

/-- The pinned test image, as a trajectory records it. -/
def testImage : IO String := do
  pure (← testSettings).image

/-- The user the test containers run as: the host user on Linux, so the host can remove what
they write. -/
def testUser? : IO (Option String) := do
  pure (← testSettings).user?

/-- A container executor for the test image. Its container starts at the first command. -/
def containerExecutor (config : Executor.Config) : TestM Executor := do
  assertOk (Executor.Docker.executor (← testSettings) config)

/-- An executor for tests that build an agent but must not run a command. -/
def noCommands : Executor := {
  exec := fun _ _ _ => throw (IO.userError "this test runs no commands")
  uname := pure default }

/-- Why the tests cannot run here, or `none` when docker and the test image are available. -/
def dockerProblem? : IO (Option String) := do
  let info ← try some <$> IO.Process.output { cmd := "docker", args := #["info"] } catch _ => pure none
  match info with
  | none => return some "docker is not installed"
  | some out =>
    if out.exitCode != 0 then return some "the docker daemon is not running"
  match ← (testSettings.toBaseIO) with
  | .ok _ => pure none
  | .error e => pure (some s!"the test image {testImageReference} is not available: {e}")

/-- Removes every container the tests started and left running. -/
def removeTestContainers : IO Unit := do
  let listed ← IO.Process.output {
    cmd := "docker", args := #["ps", "--all", "--quiet", "--filter", s!"label={testLabel}"] }
  let ids := (listed.stdout.splitOn "\n").filter (!·.isEmpty)
  if !ids.isEmpty then
    let _ ← IO.Process.output { cmd := "docker", args := #["rm", "--force"] ++ ids.toArray }

end Testing
