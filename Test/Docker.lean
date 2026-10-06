import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Test.Scripted
import Alaya

/-! The container executor, and the containers of a run's calls, against a real docker daemon. -/

namespace DockerTests

open Testing
open Alaya
open Alaya.Executor
open Lean (Json)

/-- Mini's command settings, with a short timeout. -/
private def miniConfig : Agents.MiniSwe.Config :=
  { executor := { Agents.MiniSwe.defaultExecutor with timeoutSeconds := 5 } }

private def config : Executor.Config := miniConfig.executor

/-- Runs `body` with the pinned settings for the test image. -/
private def withDocker (body : Docker.Settings -> TestM Unit) : TestM Unit := do
  body (← testSettings)

private def toolResponse (command : String) : Chat.Response :=
  { toolCalls := #[{ id := "c1", name := "bash"
                     arguments := .mkObj [("command", (command : Json))] }]
    finishReason? := some "tool_calls" }

private def workspace : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

/-- A runtime whose calls run their commands in a container of their own image and workdir, run
as `settings` say, with the outputs directory mounted where a command finds it, over the test's
store and directory workspaces. An agent's `uname` is the test's machine, so an agent whose
image does not exist starts no container. -/
private def runtime (settings : Docker.Settings) (model? : Option Model)
    (outputsDir? : Option System.FilePath := none) : TestM Driver.Runtime := do
  let work ← workspace
  let outputsDir := outputsDir?.getD ((← scratch) / s!"outputs-{← IO.monoNanosNow}")
  IO.FS.createDirAll outputsDir
  let mounts := #[{ host := ← IO.FS.realPath outputsDir, container := Driver.outputsDir, readOnly := true }]
  let store ← assertOk <| Store.create ((← scratch) / "entries")
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir
         executor := fun environment => Scripted.answeringUname <$>
           Docker.executor { settings with image := environment.image, workdir := environment.workdir, mounts }
         model := fun _ => match model? with
           | some model => pure model
           | none => throw <| .input "a call samples its model: name a --provider" }

/-- Runs `k` with MiniSwe's run, configured by `agent`. -/
private def withRun (agent : Agents.MiniSwe.Config := miniConfig) (k : Routine Agent → TestM Unit) : TestM Unit :=
  match Scripted.runOfConfig "mini-swe" agent.toJson with
  | .ok run => k run
  | .error problem => fail problem

/-- Creates a run and calls its agent in `settings`' image, at its workdir. -/
private def startIn (settings : Docker.Settings) (rt : Driver.Runtime) (run : Routine Agent) : TestM Hash :=
  Scripted.start rt run "t" none { image := settings.image, workdir := settings.workdir }

/-- Creates a run, calls its agent in `settings`' image, and drives it until the agent is about to
read its inbox: the agent runs, and nothing has been asked of a model. -/
private def openIn (settings : Docker.Settings) (rt : Driver.Runtime) (run : Routine Agent) : TestM Hash := do
  let (tip, _) ← assertOk <| Driver.drive rt run (← startIn settings rt run) { samples? := some 0 }
  pure tip

/-- Grades the point `tip` of a run with the grader `call`: the agent stopped there, the grader
called. Gives its verdict, and what its command left: its output and the workspace after it. -/
private def gradeAt (rt : Driver.Runtime) (run : Routine Agent) (tip : Hash) (call : RoutineCall) :
    TestM (Json × Execution) := do
  let (graded, verdict) ← Scripted.grade rt run tip call
  let log ← Scripted.logAt rt graded
  -- The grader's command, in the frame of the run's call of the grader.
  let found := log.reverse.findSome? fun
    | .answered #[step] _ (.ok (.execution e)) => if step.name == "grader" then some e else none
    | _ => none
  let some ran := found | fail "the grader ran no command"
  pure (verdict, ran)

private def status (verdict : Json) : String := (verdict.getObjVal? "status" >>= Json.getStr?).toOption.getD "?"

def suite : Suite := Testing.suite "docker" #[
  test "pins the image to exact bits and reads uname from it, not the host" <| withDocker
    fun settings => do
      check (settings.image != testImageReference)
        s!"expected a pinned reference, got {settings.image}"
      check ((settings.image.splitOn "sha256:").length > 1)
        s!"expected a digest, got {settings.image}"
      -- The agent's `uname` routine reads the machine in the container its commands run in.
      let executor ← assertOk (Docker.executor settings)
      try
        let ran ← executor.exec config (← workspace) #[Agents.Tools.Uname.command] "uname"
        let uname ← match Agents.Tools.Uname.parse ran.output with
          | .ok uname => pure uname
          | .error problem => fail problem
        assertEqual "system" uname.system "Linux"
        check (!uname.machine.isEmpty) "machine should not be empty"
      finally
        executor.close,

  test "runs commands in the container against the bind-mounted workspace" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      try
        let wrote ← executor.exec config work #["echo hi > a.txt; cat a.txt"] "cat"
        assertEqual "exit code" wrote.exitCode? (some 0)
        assertEqual "output" wrote.output "hi\n"
        -- The file the container wrote is in the host directory the store snapshots.
        assertEqual "host sees it" (← IO.FS.readFile (work / "a.txt")) "hi\n"
        -- And the host still owns it: a checkout has to be able to wipe this directory.
        IO.FS.removeFile (work / "a.txt")
        let sees ← executor.exec config work #["ls /workspace | wc -l"] "ls"
        assertEqual "container sees the removal" sees.output.trimAscii.toString "0"
      finally
        executor.close,

  test "merges stderr into stdout at the fd level" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      try
        let merged ← executor.exec config work #["echo out; echo err >&2"] "echo"
        assertEqual "merged" merged.output "out\nerr\n"
        let failing ← executor.exec config work #["exit 3"] "exit 3"
        assertEqual "exit code passes through" failing.exitCode? (some 3)
      finally
        executor.close,

  test "environment overrides reach the command, not the docker client" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      try
        let out ← executor.exec config work #["echo $PAGER $TQDM_DISABLE"] "echo"
        assertEqual "mini's overrides" out.output "cat 1\n"
      finally
        executor.close,

  test "a command past the timeout is a timeout observation" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      try
        let out ← executor.exec { config with timeoutSeconds := 1 } work #["sleep 30"] "sleep 30"
        assertEqual "no exit code" out.exitCode? none
        assertEqual "error" out.error? (some "'sleep 30' timed out after 1 seconds")
        -- The run survives it: the next command still works.
        let after ← executor.exec { config with timeoutSeconds := 1 } work #["echo alive"] "echo alive"
        assertEqual "still usable" after.output "alive\n"
      finally
        executor.close,

  test "a timeout of 0 lets a command run as long as it takes" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      try
        -- Past the 5-second kill grace, which once was all a 0 allowed.
        let out ← executor.exec { config with timeoutSeconds := 0 } work #["sleep 6; echo done"] "sleep 6; echo done"
        assertEqual "no error" out.error? none
        assertEqual "finished" out.output "done\n"
      finally
        executor.close,

  test "close leaves no container behind" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings)
      let _ ← executor.exec config work #["true"] "true"
      -- Other tests' containers may still be running, so count the difference.
      let running : IO Nat := do
        let out ← IO.Process.output {
          cmd := "docker", args := #["ps", "--quiet", "--filter", s!"label={testLabel}"] }
        pure ((out.stdout.splitOn "\n").filter (!·.isEmpty)).length
      let open_ ← running
      check (open_ > 0) "expected a running container while the executor is open"
      executor.close
      assertEqual "one fewer" (← running) (open_ - 1),

  test "a command runs in the container and the driver snapshots what it wrote" <| withDocker
    fun settings => do
      withRun miniConfig fun run => do
        let rt ← runtime settings (some (← Scripted.scriptedModel #[toolResponse "echo made-in-container > made.txt"]))
        try
          let (paused, _) ← assertOk <| Driver.drive rt run (← startIn settings rt run) { samples? := some 1 }
          let log ← Scripted.logAt rt paused
          assertEqual "the call's image, from its configuration" ((callAt? log { name := "agent" }).bind (·.environment?.map (·.image))) (some settings.image)
          -- The container wrote it, the host snapshotted it.
          assertEqual "snapshot"
            ((← assertOk ((← workspaces).readFile? ((workspace? log).getD default) "made.txt")).map (String.fromUTF8? ·))
            (some (some "made-in-container\n"))
        finally pure (),

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

  test "a grader runs in its image on a checkout, and sees what a command wrote" <| withDocker
    fun settings => do
      -- The image's own file shows the grader is in the container, not on the host.
      let check := "test -f /etc/alpine-release && echo 1..1 && echo \"ok 1 - $(cat made.txt)\""
      withRun miniConfig fun run => do
        let rt ← runtime settings (some (← Scripted.scriptedModel #[toolResponse "echo made-in-container > made.txt"]))
        try
          let (paused, _) ← assertOk <| Driver.drive rt run (← startIn settings rt run) { samples? := some 1 }
          let (verdict, _) ← gradeAt rt run paused (Scripted.graderCall check settings.image)
          assertEqual "status" (status verdict) "pass"
          assertEqual "checks" ((verdict.getObjVal? "checks").toOption.map (·.compress))
            (some "[{\"directive\":\"\",\"name\":\"made-in-container\",\"ok\":true}]")
        finally pure (),

  test "a cut output is readable, read-only, in a recreated container, and stays out of the workspace" <| withDocker
    fun settings => do
      let recover := { miniConfig with recoverOutput := true }
      withRun recover fun run => do
        let model ← Scripted.scriptedModel #[
          toolResponse "awk 'BEGIN {for(i=0;i<6000;i++) printf \"a\"; printf \"MIDDLE\"; for(i=0;i<6000;i++) printf \"z\"}'",
          toolResponse "grep -c MIDDLE /alaya/outputs/*.txt; touch /alaya/outputs/x 2>/dev/null || echo read-only; ls -A"]
        let first ← runtime settings (some model)
        let (saved, _) ← assertOk <| Driver.drive first run (← startIn settings first run) { samples? := some 1 }
        -- A later command: a new container, a wiped workdir, and outputs written afresh from the log.
        IO.FS.removeDirAll (← workspace)
        let second ← runtime settings (some model)
        let second := { second with store := first.store }
        try
          let (child, _) ← assertOk <| Driver.drive second run saved { samples? := some 1 }
          let log ← Scripted.logAt second child
          let shown? := log.reverse.findSome? fun
            | .answered _ (.exec ..) (.ok (.execution e)) => some e.output.output
            | _ => none
          -- The view elided the middle; the file has it, the mount refuses writes, and the
          -- workdir holds nothing of it.
          assertEqual "read back" shown? (some "1\nread-only\n")
          let checkout := (← scratch) / "checkout"
          IO.FS.createDirAll checkout
          assertOk <| (← workspaces).materialize ((workspace? log).getD default) checkout
          assertEqual "snapshot" ((← checkout.readDir).map (·.fileName)) #[]
        finally pure (),

  test "a grader runs in a container of its own, with no network, keeps stderr apart, and writes in the workspace" <| withDocker
    fun settings => do
      -- Without network the routing table has its header line and nothing else.
      let command := "echo noise >&2; test \"$(wc -l < /proc/net/route)\" = 1 && " ++
        "test \"$(pwd)\" = /workspace && test ! -e left-by-agent.txt && echo checked > graded.txt && " ++
        "printf '1..1\\nok 1 - isolated\\n'"
      withRun miniConfig fun run => do
        let rt ← runtime settings (some (← Scripted.scriptedModel #[toolResponse "touch /tmp/left-by-agent.txt"]))
        try
          let (paused, _) ← assertOk <| Driver.drive rt run (← startIn settings rt run) { samples? := some 1 }
          let (verdict, ran) ← gradeAt rt run paused (Scripted.graderCall command settings.image)
          assertEqual "status" (status verdict, (verdict.getObjVal? "reason" >>= Json.getStr?).toOption) ("pass", some "")
          assertEqual "stdout is the TAP" ran.output.output "1..1\nok 1 - isolated\n"
          assertEqual "stderr apart" ran.output.stderr? (some "noise\n")
          check (← assertOk ((← workspaces).readFile? ran.workspace "graded.txt")).isSome
            "the workspace as the grader left it"
        finally pure (),

  test "a failing check is a fail with its score, whatever the exit status" <| withDocker
    fun settings => do
      let failing := "echo junk > graded.txt; printf '1..3\\nok 1 - builds\\nnot ok 2 - parses\\nok 3 - reports\\n'"
      let passing := "printf '1..1\\nok 1 - alone\\n'; exit 7"
      withRun miniConfig fun run => do
        let rt ← runtime settings none
        try
          let tip ← openIn settings rt run
          -- The same point, graded by two graders: each on a fork of its own.
          let (graded, failed) ← Scripted.grade rt run tip (Scripted.graderCall failing settings.image)
          let (other, passed) ← Scripted.grade rt run tip (Scripted.graderCall passing settings.image)
          check (graded != other) "a point graded again is another log"
          let field (verdict : Json) (name : String) : String :=
            ((verdict.getObjVal? name).toOption.getD .null).compress
          let read (verdict : Json) := #["status", "passed", "total", "exit_code", "reason"].map (field verdict)
          assertEqual "a failing check" (read failed) #["\"fail\"", "2", "3", "0", "\"failed: parses\""]
          assertEqual "the exit status decides nothing" (read passed) #["\"pass\"", "1", "1", "7", "\"\""]
          -- The report shows what a grader's command changed, as any command's.
          let forest ← assertOk rt.store.forest
          let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" (root := run)
          let rows := ((page.getObjVal? "entries" >>= Json.getArr?).toOption.getD #[]).filter fun row =>
            -- The grader's own frame: the run's call of `grader`, the first or a later one.
            (row.getObjVal? "f").toOption.any (fun f => match f with
              | .arr #[.str call] => call.startsWith "grader"
              | _ => false) &&
            (row.getObjVal? "e" >>= (·.getObjVal? "k") >>= Json.getStr?).toOption == some "exec"
          assertEqual "the graders' commands" rows.size 2
          let changed (row : Json) : Array String :=
            ((row.getObjVal? "changes" >>= (·.getObjVal? "changes") >>= Json.getArr?).toOption.getD #[]).map fun change =>
              (change.getObjVal? "path" >>= Json.getStr?).toOption.getD "?"
          let wrote (row : Json) : Bool :=
            ((row.getObjVal? "e" >>= (·.getObjVal? "command") >>= Json.getStr?).toOption.getD "").startsWith "echo junk"
          assertEqual "what the first wrote" ((rows.filter wrote).map changed) #[#["graded.txt"]]
          assertEqual "the second wrote nothing" ((rows.filter (!wrote ·)).map changed) #[#[]]
        finally pure (),

  test "a limit pauses a grader as it does an agent, and the next resume goes on" <| withDocker
    fun settings => do
      withRun miniConfig fun run => do
        let rt ← runtime settings none
        try
          let tip ← openIn settings rt run
          -- The budget is spent before the agent's first read: the run pauses there.
          let spent : Driver.Limits := { budgetMs? := some 0 }
          let (paused, stop) ← assertOk <| Driver.drive rt run tip spent
          check (stop matches .paused _) "paused before the agent's first read"
          let (stopped, _) ← assertOk <| Driver.append rt.store run paused (.stopped "out of time")
          let (asked, _) ← assertOk <| Driver.append rt.store run stopped
            (Scripted.graderCall "printf '1..1\\nok 1\\n'" settings.image).event
          let (held, stop) ← assertOk <| Driver.drive rt run asked spent
          check (stop matches .paused _) "the grader pauses before its command"
          let (graded, stop) ← assertOk <| Driver.drive rt run held
          check (stop matches .idle) "and runs on without the budget"
          let some (_, some (.returned verdict)) := lastCall? (← Scripted.logAt rt graded) | fail "the grader's verdict"
          assertEqual "status" (status verdict) "pass"
        finally pure (),

  test "a grader past its timeout is an error, with what it printed before" <| withDocker
    fun settings => do
      -- Complete TAP before the timeout does not make it a pass.
      withRun miniConfig fun run => do
        let rt ← runtime settings none
        try
          let (verdict, ran) ← gradeAt rt run (← openIn settings rt run)
            (Scripted.graderCall "printf '1..1\\nok 1\\n'; sleep 30" settings.image 1)
          assertEqual "status" (status verdict) "error"
          assertEqual "no exit status" ran.output.exitCode? none
          check (Scripted.contains ((verdict.getObjVal? "reason" >>= Json.getStr?).toOption.getD "") "timed out after 1 seconds")
            "the reason says it timed out"
          assertEqual "what it printed before is kept" ran.output.output "1..1\nok 1\n"
        finally pure (),

  test "a grader in another image than the agent's, at another workdir; one whose image cannot start stops resume" <| withDocker
    fun settings => do
      withRun miniConfig fun run => do
        let rt ← runtime settings none
        try
          -- The agent's own image does not exist: only the grader's runs anything.
          let (tip, _) ← assertOk <| Driver.drive rt run (← Scripted.start rt run) { samples? := some 0 }
          let (_, own) ← Scripted.grade rt run tip
            (Scripted.graderCall "test -f /etc/alpine-release && test \"$(pwd)\" = /testbed && printf '1..1\\nok 1\\n'"
              settings.image (workdir := "/testbed"))
          assertEqual "in its own image, at its workdir" (status own) "pass"
          -- A grader whose image cannot start is no verdict: nothing is logged for its command.
          let (stopped, _) ← assertOk <| Driver.append rt.store run tip (.stopped "to grade this point")
          let (asked, _) ← assertOk <| Driver.append rt.store run stopped
            (Scripted.graderCall "true" "alaya.invalid/nope@sha256:0").event
          assertError "cannot start" (Driver.drive rt run asked) fun
            | .environment _ => true
            | _ => false
        finally pure (),

  test "a workdir is an absolute, clean path, and not one alaya mounts" <| withDocker
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
