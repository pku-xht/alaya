import Test.Framework
import Alaya

/-! The container executor, against a real docker daemon. Every case skips when the machine has
no usable docker or cannot get the test image, so the suite is safe to run anywhere. -/

namespace DockerTests

open Testing
open Alaya
open Alaya.Executor
open Alaya.Trajectory

/-- The image the tests run in. Small, and `busybox` gives it a `timeout(1)`. -/
private def imageReference : String := "alpine:3"

/-- Mini's command settings, with a short timeout. -/
private def miniConfig : Agent.MiniSwe.Config :=
  { task := "t", executor := { Agent.MiniSwe.defaultExecutor with timeoutSeconds := 5 } }

private def config : Executor.Config := miniConfig.executor

/-- Pinned settings for the test image, or `none` when this machine cannot run the suite. -/
private def settings? : TestM (Option Docker.Settings) := do
  let daemonUp ←
    try pure ((← IO.Process.output { cmd := "docker", args := #["info"] }).exitCode == 0)
    catch _ => pure false
  if !daemonUp then return none
  let args := Cli.parse ["--image", imageReference]
  match ← (do (← Docker.settingsFor args imageReference).pin).toBaseIO with
  | .ok settings => pure (some settings)
  | .error _ => pure none

private def skipping (reason : String) : TestM Unit := do
  IO.println s!"SKIP {(← read).name}: {reason}"

/-- Runs `body` with pinned settings, or skips. -/
private def withDocker (body : Docker.Settings -> TestM Unit) : TestM Unit := do
  match ← settings? with
  | some settings => body settings
  | none => skipping s!"no docker daemon, or {imageReference} unavailable"

/-- This integration needs Git inside the container. Use an explicitly supplied local image;
the test never pulls or builds an image just to install Git. -/
private def withGitDocker (body : Docker.Settings -> TestM Unit) : TestM Unit := do
  let some image ← IO.getEnv "ALAYA_TEST_GIT_IMAGE"
    | return ← skipping "set ALAYA_TEST_GIT_IMAGE to a local image containing Git"
  let available ←
    try pure ((← IO.Process.output {
      cmd := "docker", args := #["image", "inspect", image] }).exitCode == 0)
    catch _ => pure false
  if !available then return ← skipping s!"local Git test image {image} is unavailable"
  let probe ← IO.Process.output {
    cmd := "docker", args := #["run", "--pull=never", "--rm", "--network=none",
      "--entrypoint", "/bin/sh", image, "-c", "command -v git"] }
  if probe.exitCode != 0 then return ← skipping s!"{image} does not provide Git"
  let args := Cli.parse ["--image", image]
  let settings ← assertOk <| (do (← Docker.settingsFor args image).pin)
  body settings

/-- A model that answers with `responses` in order, for driving one real turn. -/
private def scripted (responses : Array Chat.Response) : TestM Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

private def toolResponse (command : String) : Chat.Response :=
  { toolCalls := #[{ id := "c1", name := "bash"
                     arguments := .mkObj [("command", (command : Lean.Json))] }]
    finishReason? := some "tool_calls" }

private def workspace : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

/-- A runtime driving the mini agent in the container. -/
private def runtime (settings : Docker.Settings) (work : System.FilePath) (store : Cas.Store)
    (model : Model) : TestM Runtime := do
  let executor ← assertOk (Docker.executor settings config)
  pure { store, workDir := work, executor, model, agent := Agent.MiniSwe.agent executor miniConfig }

private def observedOutput (store : Cas.Store) (hash : Cas.Hash) : TestM Output := do
  for event in (← assertOk (getState store hash)).appended do
    if let .observation _ content := event then
      if let some output := Output.fromJson? content then return output
  fail "expected a recorded command observation"

def suite : Suite := Testing.suite "docker" #[
  test "pins the image to exact bits and reads uname from it, not the host" <| withDocker
    fun settings => do
      check (settings.image != imageReference)
        s!"expected a pinned reference, got {settings.image}"
      check ((settings.image.splitOn "sha256:").length > 1)
        s!"expected a digest, got {settings.image}"
      let uname ← assertOk (Docker.uname settings)
      assertEqual "system" uname.system "Linux"
      check (!uname.machine.isEmpty) "machine should not be empty",

  test "runs commands in the container against the bind-mounted workspace" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let wrote ← executor.exec work #["echo hi > a.txt; cat a.txt"] "cat"
        assertEqual "exit code" wrote.exitCode? (some 0)
        assertEqual "output" wrote.output "hi\n"
        -- The file the container wrote is in the host directory the store snapshots.
        assertEqual "host sees it" (← IO.FS.readFile (work / "a.txt")) "hi\n"
        -- And the host still owns it: a checkout has to be able to wipe this directory.
        IO.FS.removeFile (work / "a.txt")
        let sees ← executor.exec work #["ls /workspace | wc -l"] "ls"
        assertEqual "container sees the removal" sees.output.trimAscii.toString "0"
      finally
        executor.close,

  test "merges stderr into stdout at the fd level, as the host executor does" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let merged ← executor.exec work #["echo out; echo err >&2"] "echo"
        assertEqual "merged" merged.output "out\nerr\n"
        let failing ← executor.exec work #["exit 3"] "exit 3"
        assertEqual "exit code passes through" failing.exitCode? (some 3)
      finally
        executor.close,

  test "environment overrides reach the command, not the docker client" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let out ← executor.exec work #["echo $PAGER $TQDM_DISABLE"] "echo"
        assertEqual "mini's overrides" out.output "cat 1\n"
      finally
        executor.close,

  test "a command past the timeout is a timeout observation" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings { config with timeoutSeconds := 1 })
      try
        let out ← executor.exec work #["sleep 30"] "sleep 30"
        assertEqual "no exit code" out.exitCode? none
        assertEqual "error" out.error? (some "'sleep 30' timed out after 1 seconds")
        -- The run survives it: the next command still works.
        let after ← executor.exec work #["echo alive"] "echo alive"
        assertEqual "still usable" after.output "alive\n"
      finally
        executor.close,

  test "close leaves no container behind" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      let _ ← executor.exec work #["true"] "true"
      let running : IO String := do
        pure (← IO.Process.output {
          cmd := "docker"
          args := #["ps", "--quiet", "--filter", s!"ancestor={settings.image}"] }).stdout
      check (!(← running).trimAscii.isEmpty)
        "expected a running container while the executor is open"
      executor.close
      assertEqual "none left" (← running).trimAscii.toString "",

  test "a step runs its command in the container and snapshots what it wrote" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll project)
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let model ← scripted #[toolResponse "echo made-in-container > made.txt"]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (Agent.MiniSwe.initialLog miniConfig uname) project
          (some "t") (some settings.image)
        let child ← assertOk <| stepOnce rt "test:model" root
        let state ← assertOk (getState store child)
        assertEqual "image inherited" state.image? (some settings.image)
        -- The container wrote it, the host snapshotted it, the store has it.
        assertEqual "snapshot"
          ((← assertOk (store.readPath state.workspace "made.txt")).map (String.fromUTF8? ·))
          (some (some "made-in-container\n"))
      finally
        rt.executor.close,

  test "reusing one runtime remounts the workspace for stepOnce and resume" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      writeSpec project #[("seed.txt", "seed-value\n")]
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let read := toolResponse "cat seed.txt"
      let submit : Chat.ToolCall := { id := "submit", name := "submit", arguments := .mkObj [] }
      let model ← scripted #[read, read, { read with toolCalls := read.toolCalls.push submit }]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (Agent.MiniSwe.initialLog miniConfig uname) project
          (some "t") (some settings.image)
        let first ← assertOk <| stepOnce rt "test:model" root
        let second ← assertOk <| stepOnce rt "test:model" first
        let final ← assertOk <| resume rt "test:model" second (fun _ => pure ())
        for child in [first, second, final] do
          let output ← observedOutput store child
          assertEqual "command exit" output.exitCode? (some 0)
          assertEqual "command read" output.output "seed-value\n"
        assertEqual "submitted" ((← assertOk (getState store final)).outcome?.map (·.status))
          (some "Submitted")
      finally
        rt.executor.close,

  test "reusing one runtime restores an independent fork before its next command" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      writeSpec project #[("seed.txt", "seed-value\n")]
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let model ← scripted #[toolResponse "echo first > first.txt",
        toolResponse "test ! -e first.txt && cat seed.txt && echo second > second.txt"]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (Agent.MiniSwe.initialLog miniConfig uname) project
          (some "t") (some settings.image)
        let first ← assertOk <| stepOnce rt "test:model" root
        let fork ← assertOk <| tell store root "Start an independent branch."
        let second ← assertOk <| stepOnce rt "test:model" fork
        let output ← observedOutput store second
        assertEqual "fork command exit" output.exitCode? (some 0)
        assertEqual "fork reads the root" output.output "seed-value\n"
        let firstTree := (← assertOk (getState store first)).workspace
        let secondTree := (← assertOk (getState store second)).workspace
        assertEqual "first branch remains intact" (← assertOk (store.readPath firstTree "first.txt"))
          (some "first\n".toUTF8)
        assertEqual "first branch did not gain the sibling's file"
          (← assertOk (store.readPath firstTree "second.txt")) none
        assertEqual "sibling did not inherit first branch's file"
          (← assertOk (store.readPath secondTree "first.txt")) none
        assertEqual "sibling write was captured" (← assertOk (store.readPath secondTree "second.txt"))
          (some "second\n".toUTF8)
      finally
        rt.executor.close,

  test "native Git in the container retains commits when restoring a fork" <| withGitDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      writeSpec project #[("seed.txt", "seed-value\n")]
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let commit := "git status --porcelain && git log -1 --format=%H && " ++
        "printf 'container-change\\n' > seed.txt && git add seed.txt && " ++
        "git -c user.name=Container -c user.email=container@localhost commit -qm container-commit && " ++
        "git update-ref refs/test/container-commit HEAD && git rev-parse HEAD"
      let inspect := "test -d .git && git status --porcelain && git log -1 --format=%H && " ++
        "git cat-file -t refs/test/container-commit && cat seed.txt"
      let model ← scripted #[toolResponse commit, toolResponse inspect]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (Agent.MiniSwe.initialLog miniConfig uname) project
          (some "t") (some settings.image)
        let rootCommit := (← assertOk (getState store root)).workspace
        let first ← assertOk <| stepOnce rt "test:model" root
        let firstOutput ← observedOutput store first
        assertEqual "container commit exit" firstOutput.exitCode? (some 0)
        let containerCommit := (← assertOk (getState store first)).workspace
        check (containerCommit != rootCommit) "the container should have created a new commit"
        assertEqual "Git runs inside the initial container" firstOutput.output
          s!"{rootCommit.hex}\n{containerCommit.hex}\n"
        let fork ← assertOk <| tell store root "Restore the original tracked files."
        let second ← assertOk <| stepOnce rt "test:model" fork
        let secondOutput ← observedOutput store second
        assertEqual "container Git after restore" secondOutput.exitCode? (some 0)
        assertEqual "old tree restored and later commit still readable" secondOutput.output
          s!"{rootCommit.hex}\ncommit\nseed-value\n"
        assertEqual "container commit remains in the store"
          (← assertOk (store.readPath containerCommit "seed.txt"))
          (some "container-change\n".toUTF8)
        assertEqual "restored branch has the original tracked file"
          (← assertOk (store.readPath (← assertOk (getState store second)).workspace "seed.txt"))
          (some "seed-value\n".toUTF8)
      finally
        rt.executor.close,

  test "seeds a workspace from a path inside the image" <| withDocker
    fun settings => do
      let work ← workspace
      -- Never started, so nothing in the image runs: this only reads the image's filesystem.
      assertOk <| Docker.copyOut settings "/etc/apk" work
      let contents ← IO.FS.readFile (work / "repositories")
      check (!contents.isEmpty) "expected alpine's /etc/apk/repositories to be copied out"
      -- Copied files belong to the host user, or the store could neither read nor wipe them.
      IO.FS.removeFile (work / "repositories")
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let snapshot ← assertOk <| store.snapshot work
      check (← assertOk (store.entryAt? snapshot "world")).isSome
        "expected /etc/apk/world in the snapshot",

  test "a path that is not in the image is a configuration error" <| withDocker
    fun settings => do
      let work ← workspace
      assertError "copyOut" (Docker.copyOut settings "/no/such/path" work) fun
        | .configuration m => (m.splitOn "/no/such/path").length > 1
        | _ => false,

  test "a grader on the host sees what a container turn wrote" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll project)
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let model ← scripted #[toolResponse "echo made-in-container > made.txt"]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (Agent.MiniSwe.initialLog miniConfig uname) project
          (some "t") (some settings.image)
        let child ← assertOk <| stepOnce rt "test:model" root
        -- The grader is a host program over a checkout; the container is not involved.
        let node ← assertOk <| evaluate store ((← scratch) / "eval") child
          "test -f {checkout}/made.txt && cat {checkout}/made.txt"
        let state ← assertOk (getState store node)
        assertEqual "passed" (state.evaluation?.map (·.passed)) (some true)
        assertEqual "output" (state.evaluation?.map (·.output)) (some "made-in-container\n")
        assertEqual "image inherited" state.image? (some settings.image)
      finally
        rt.executor.close,

  test "a missing image is a configuration error naming it" <| withDocker
    fun _ => do
      let missing : Docker.Settings := { image := "alaya.invalid/nope@sha256:0" }
      assertError "verifyPresent" missing.verifyPresent fun
        | .configuration m => (m.splitOn "alaya.invalid/nope").length > 1
        | _ => false
]

end DockerTests
