import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! The container executor and the grader's container, against a real docker daemon. -/

namespace DockerTests

open Testing
open Alaya
open Alaya.Executor
open Alaya.Trajectory

/-- Mini's command settings, with a short timeout. -/
private def miniConfig : Agent.MiniSwe.Config :=
  { executor := { Agent.MiniSwe.defaultExecutor with timeoutSeconds := 5 } }

private def config : Executor.Config := miniConfig.executor

/-- Runs `body` with the pinned settings for the test image. -/
private def withDocker (body : Docker.Settings -> TestM Unit) : TestM Unit := do
  body (← testSettings)

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
private def runtime (settings : Docker.Settings) (work : System.FilePath) (store : Trajectory.Store)
    (model : Model) (agentConfig : Agent.MiniSwe.Config := miniConfig)
    (outputsDir : System.FilePath := work.withFileName "outputs") : TestM Runtime := do
  let mounts := #[{ host := outputsDir, container := Agent.outputsDir, readOnly := true }]
  let executor ← assertOk (Docker.executor { settings with mounts } config)
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir, executor, model
         agent := Agent.MiniSwe.agent agentConfig }

def suite : Suite := Testing.suite "docker" #[
  test "pins the image to exact bits and reads uname from it, not the host" <| withDocker
    fun settings => do
      check (settings.image != testImageReference)
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

  test "merges stderr into stdout at the fd level" <| withDocker
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

  test "a timeout of 0 lets a command run as long as it takes" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings { config with timeoutSeconds := 0 })
      try
        -- Past the 5-second kill grace, which once was all a 0 allowed.
        let out ← executor.exec work #["sleep 6; echo done"] "sleep 6; echo done"
        assertEqual "no error" out.error? none
        assertEqual "finished" out.output "done\n"
      finally
        executor.close,

  test "close leaves no container behind" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      let _ ← executor.exec work #["true"] "true"
      -- Other tests' containers may still be running, so count the difference.
      let running : IO Nat := do
        let out ← IO.Process.output {
          cmd := "docker", args := #["ps", "--quiet", "--filter", s!"label={testLabel}"] }
        pure ((out.stdout.splitOn "\n").filter (!·.isEmpty)).length
      let open_ ← running
      check (open_ > 0) "expected a running container while the executor is open"
      executor.close
      assertEqual "one fewer" (← running) (open_ - 1),

  test "a step runs its command in the container and snapshots what it wrote" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll project)
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let model ← scripted #[toolResponse "echo made-in-container > made.txt"]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (← workspaces) (Agent.MiniSwe.initialLog miniConfig "t" uname) project
          settings.image (some "t") (agent := testAgent) (model := testModel)
        let child ← stepped <| step rt root
        let state ← assertOk (getState store child)
        assertEqual "image inherited" state.image settings.image
        -- The container wrote it, the host snapshotted it.
        assertEqual "snapshot"
          ((← assertOk ((← workspaces).readFile? state.workspace "made.txt")).map (String.fromUTF8? ·))
          (some (some "made-in-container\n"))
      finally
        rt.executor.close,

  test "seeds a workspace from a path inside the image" <| withDocker
    fun settings => do
      let work ← workspace
      -- Never started, so nothing in the image runs: this only reads the image's filesystem.
      assertOk <| Docker.copyOut settings "/etc/apk" work
      let contents ← IO.FS.readFile (work / "repositories")
      check (!contents.isEmpty) "expected alpine's /etc/apk/repositories to be copied out"
      -- Copied files belong to the host user, or a snapshot could neither read nor wipe them.
      IO.FS.removeFile (work / "repositories")
      let snapshot ← assertOk <| (← workspaces).snapshot work
      check (← assertOk ((← workspaces).readFile? snapshot "world")).isSome
        "expected /etc/apk/world in the snapshot",

  test "a path that is not in the image is an input error" <| withDocker
    fun settings => do
      let work ← workspace
      assertError "copyOut" (Docker.copyOut settings "/no/such/path" work) fun
        | .input m => (m.splitOn "/no/such/path").length > 1
        | _ => false,

  test "a grader runs in the trajectory's image and sees what a turn wrote" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll project)
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let model ← scripted #[toolResponse "echo made-in-container > made.txt"]
      let rt ← runtime settings work store model
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <| createRoot store (← workspaces) (Agent.MiniSwe.initialLog miniConfig "t" uname) project
          settings.image (some "t") (agent := testAgent) (model := testModel)
        let child ← stepped <| step rt root
        -- The image's own file shows the grader is in the container, not on the host.
        let node ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") child
          "test -f /etc/alpine-release && echo 1..1 && echo \"ok 1 - $(cat made.txt)\"" settings.user?
        let state ← assertOk (getState store node)
        let some e := state.evaluation? | fail "expected an evaluation"
        assertEqual "status" e.status .pass
        assertEqual "checks" e.checks #[{ ok := true, name := "made-in-container" }]
        assertEqual "image inherited" state.image settings.image
      finally
        rt.executor.close,

  test "a cut output is readable, read-only, in a recreated container, and stays out of the workspace" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      IO.FS.createDirAll project
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let recover := { miniConfig with recoverOutput := true }
      let model ← scripted #[toolResponse "awk 'BEGIN {for(i=0;i<6000;i++) printf \"a\"; printf \"MIDDLE\"; for(i=0;i<6000;i++) printf \"z\"}'"]
      let first ← runtime settings work store model recover ((← scratch) / "outputs-1")
      let saved ← try
        let root ← assertOk <| createRoot store (← workspaces) #[] project settings.image (agent := testAgent) (model := testModel)
        stepped <| step first root
      finally first.executor.close
      -- A later command: a new container, a wiped workdir, and outputs written afresh from the log.
      IO.FS.removeDirAll work
      IO.FS.createDirAll work
      let reading ← scripted #[toolResponse
        "grep -c MIDDLE /alaya/outputs/1-c1.txt; touch /alaya/outputs/x 2>/dev/null || echo read-only; ls -A"]
      let second ← runtime settings work store reading recover ((← scratch) / "outputs-2")
      try
        let child ← stepped <| step second saved
        let shown? := (← assertOk <| logOf store child).reverse.findSome? fun
          | .observation _ content => (Output.fromJson? content).map (·.output)
          | _ => none
        -- The view elided the middle; the file has it, the mount refuses writes, and the
        -- workdir holds nothing of it.
        assertEqual "read back" shown? (some "1\nread-only\n")
        let workspace := (← assertOk <| getState store child).workspace
        let checkout := (← scratch) / "checkout"
        IO.FS.createDirAll checkout
        assertOk <| (← workspaces).materialize workspace checkout
        assertEqual "snapshot" ((← checkout.readDir).map (·.fileName)) #[]
      finally second.executor.close,

  test "a grader has no network, reads its input at /grader and cannot write it, and keeps stderr apart" <| withDocker
    fun settings => do
      let project := (← scratch) / "proj"
      IO.FS.createDirAll project
      let input := (← scratch) / "input"
      writeSpec input #[("data.txt", "trusted")]
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let root ← assertOk <| createRoot store (← workspaces) #[] project settings.image (agent := testAgent) (model := testModel)
      -- Without network the routing table has its header line and nothing else.
      let grader := "echo noise >&2; test \"$(wc -l < /proc/net/route)\" = 1 && " ++
        "test \"$(pwd)\" = /workspace && test \"$(cat /grader/data.txt)\" = trusted && " ++
        "! touch /grader/written 2>/dev/null && echo checked > graded.txt && " ++
        "printf '1..1\\nok 1 - isolated\\n'"
      let node ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") root grader
        settings.user? (input? := some input)
      let state ← assertOk (getState store node)
      let some e := state.evaluation? | fail "expected an evaluation"
      assertEqual "status" (e.status, e.reason) (.pass, "")
      assertEqual "stdout is the TAP" e.stdout "1..1\nok 1 - isolated\n"
      assertEqual "stderr apart" e.stderr "noise\n"
      check (!(← (input / "written").pathExists)) "the input stays as it was"
      check (← assertOk ((← workspaces).readFile? state.workspace "graded.txt")).isSome
        "the checkout as the grader left it",

  test "a grader past its timeout is an error, and its container is removed" <| withDocker
    fun settings => do
      let project := (← scratch) / "proj"
      IO.FS.createDirAll project
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let root ← assertOk <| createRoot store (← workspaces) #[] project settings.image (agent := testAgent) (model := testModel)
      -- Complete TAP before the timeout does not make it a pass.
      let node ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") root
        "printf '1..1\\nok 1\\n'; sleep 30" settings.user? (timeoutSeconds := 1)
      let some e := (← assertOk (getState store node)).evaluation? | fail "expected an evaluation"
      assertEqual "status" e.status .error
      assertEqual "no exit status" e.returncode? none
      assertEqual "reason" e.reason "timed out after 1 seconds"
      assertEqual "what it printed before is kept" e.stdout "1..1\nok 1\n"
      let left ← IO.Process.output {
        cmd := "docker", args := #["ps", "--all", "--quiet", "--filter", "name=alaya-once-"] }
      assertEqual "no grader container left" left.stdout.trimAscii.toString "",

  test "--grader-image runs the grader in another image, pinned and recorded" <| withDocker
    fun settings => do
      let project := (← scratch) / "proj"
      IO.FS.createDirAll project
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      -- The trajectory's own image does not exist, so only the grader image can run it.
      let root ← assertOk <| createRoot store (← workspaces) #[] project recordedImage (agent := testAgent) (model := testModel)
      let node ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") root
        "test -f /etc/alpine-release && printf '1..1\\nok 1\\n'" settings.user?
        (graderImage? := some testImageReference)
      let some e := (← assertOk (getState store node)).evaluation? | fail "expected an evaluation"
      assertEqual "status" e.status .pass
      assertEqual "pinned" e.graderImage settings.image
      -- A grader image that cannot be had is no verdict at all.
      assertError "missing" (evaluate store (← workspaces) ((← scratch) / "eval") root "true"
          settings.user? (graderImage? := some "alaya.invalid/nope:1")) fun
        | .environment m => (m.splitOn "alaya.invalid/nope").length > 1
        | _ => false
      -- Without one, the trajectory's missing image is an error verdict with docker's message.
      let broken ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") root "true" settings.user?
      let some b := (← assertOk (getState store broken)).evaluation? | fail "expected an evaluation"
      assertEqual "cannot start" b.status .error
      check (!b.stderr.isEmpty) "docker's message is kept",

  test "a trajectory at another workdir runs its commands there, and its grader finds the checkout there" <| withDocker
    fun settings => do
      let settings := { settings with workdir := "/testbed" }
      let work ← workspace
      let project := (← scratch) / "proj"
      IO.FS.createDirAll project
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
      let model ← scripted #[toolResponse "pwd > where.txt"]
      let rt ← runtime settings work store model
      try
        let root ← assertOk <| createRoot store (← workspaces) #[] project settings.image (agent := testAgent) (model := testModel)
          (workdir := "/testbed")
        let child ← stepped <| step rt root
        let state ← assertOk (getState store child)
        assertEqual "workdir inherited" state.workdir "/testbed"
        assertEqual "the command ran there"
          ((← assertOk ((← workspaces).readFile? state.workspace "where.txt")).map (String.fromUTF8? ·))
          (some (some "/testbed\n"))
        let node ← assertOk <| evaluate store (← workspaces) ((← scratch) / "eval") child
          "test \"$(pwd)\" = /testbed && test \"$(cat where.txt)\" = /testbed && printf '1..1\\nok\\n'"
          settings.user?
        let evaluation ← assertOk (getState store node)
        assertEqual "graded there" (evaluation.evaluation?.map (·.status)) (some .pass)
        assertEqual "evaluation workdir" evaluation.workdir "/testbed"
      finally
        rt.executor.close,

  test "a workdir is an absolute, clean path, and not one the grader mounts" <| withDocker
    fun _ => do
      for good in ["/workspace", "/testbed", "/home/user/project"] do
        assertOk <| Docker.checkWorkdir good #["/grader", "/out"]
      for bad in ["workspace", "/", "/a/../b", "/a//b", "/a/", "/a/./b", "/grader", "/out/x"] do
        assertError bad (Docker.checkWorkdir bad #["/grader", "/out"]) fun
          | .input _ => true
          | _ => false,

  test "a missing recorded image is pulled by its digest, and a local build's ID cannot be" <| withDocker
    fun _ => do
      let missing : Docker.Settings := { image := "alaya.invalid/nope@sha256:0" }
      assertError "digest" missing.ensurePresent fun
        | .environment m => (m.splitOn "docker pull alaya.invalid/nope@sha256:0").length > 1
        | _ => false
      let local_ : Docker.Settings := { image := "sha256:" ++ "0".pushn '0' 63 }
      assertError "local" local_.ensurePresent fun
        | .environment m => (m.splitOn "cannot be pulled").length > 1
        | _ => false
]

end DockerTests
