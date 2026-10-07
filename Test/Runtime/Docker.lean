import Test.Support.Framework
import Test.Support.DirectoryWorkspaces
import Test.Support.Container
import Test.Support.Scripted
import Alaya

/-! The container executor, and the containers of a run's calls, against a real docker daemon. -/

namespace DockerTests

open Testing
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Alaya.Runtime.Executor
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
private def withRun (agent : Agents.MiniSwe.Config := miniConfig) (k : Scope Agent → TestM Unit) : TestM Unit :=
  match Scripted.runOfConfig "mini-swe" agent.toJson with
  | .ok run => k run
  | .error problem => fail problem

/-- Creates a run and calls its agent in `settings`' image, at its workdir. -/
private def startIn (settings : Docker.Settings) (rt : Driver.Runtime) (run : Scope Agent) : TestM Hash :=
  Scripted.start rt run "t" none { image := settings.image, workdir := settings.workdir }

/-- Creates a run, calls its agent in `settings`' image, and drives it until the agent is about to
read its inbox: the agent runs, and nothing has been asked of a model. -/
private def openIn (settings : Docker.Settings) (rt : Driver.Runtime) (run : Scope Agent) : TestM Hash := do
  let (tip, _) ← assertOk <| Driver.drive rt run (← startIn settings rt run) { samples? := some 0 }
  pure tip

/-- Grades the point `tip` of a run with the grader `call`: the agent stopped there, the grader
called. Gives its verdict, and what its command left: its output and the workspace after it. -/
private def gradeAt (rt : Driver.Runtime) (run : Scope Agent) (tip : Hash) (call : RoutineCall) :
    TestM (Json × Execution) := do
  let (graded, verdict) ← Scripted.grade rt run tip call
  let log ← Scripted.logAt rt graded
  -- The grader's command, in the frame of the run's call of the grader.
  let found := log.reverse.findSome? fun
    | .answered #[_, step] _ (.ok (.execution e)) => if step.name == "grader" then some e else none
    | _ => none
  let some ran := found | fail "the grader ran no command"
  pure (verdict, ran)

private def status (verdict : Json) : String := (verdict.getObjVal? "status" >>= Json.getStr?).toOption.getD "?"

def suite : Suite := Testing.suite "runtime/docker" #[
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
          let environment ← assertOk (environmentOf log ⟪"session", "agent"⟫)
          assertEqual "the call's image, from the person's call" environment.2.image settings.image
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
      let vero : Agents.MiniVero.Config := { executor := { miniConfig.executor with env := #[] } }
      match Scripted.runOfConfig "mini-vero" vero.toJson with
      | .error problem => fail problem
      | .ok run => do
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
          let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" (scope := run)
          let rows := ((page.getObjVal? "entries" >>= Json.getArr?).toOption.getD #[]).filter fun row =>
            -- The grader's own frame: the run's call of `grader`, the first or a later one.
            (row.getObjVal? "f").toOption.any (fun f => match f with
              | .arr #[_, .str call] => call.startsWith "grader"
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
          let (stopped, _) ← assertOk <| Driver.append rt.store run paused (.broke ⟪"session", "agent"⟫ "out of time")
          let (asked, _) ← assertOk <| Driver.append rt.store run stopped
            (Scripted.graderCall "printf '1..1\\nok 1\\n'" settings.image).event
          let (held, stop) ← assertOk <| Driver.drive rt run asked spent
          check (stop matches .paused _) "the grader pauses before its command"
          let (graded, stop) ← assertOk <| Driver.drive rt run held
          check (Scripted.isIdle stop) "and runs on without the budget"
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
          check (contains ((verdict.getObjVal? "reason" >>= Json.getStr?).toOption.getD "") "timed out after 1 seconds")
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
          let (stopped, _) ← assertOk <| Driver.append rt.store run tip (.broke ⟪"session", "agent"⟫ "to grade this point")
          let (asked, _) ← assertOk <| Driver.append rt.store run stopped
            (Scripted.graderCall "true" "alaya.invalid/nope@sha256:0").event
          assertError "cannot start" (Driver.drive rt run asked) fun
            | .environment _ => true
            | _ => false
        finally pure (),

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

/-- Runs `command` with mini's default settings in a container over `work`. -/
private def runIn (work : System.FilePath) (command : String) : TestM Output := do
  let executor ← containerExecutor
  try executor.bash Agents.MiniSwe.defaultExecutor work command finally executor.close

/-- What the test image's own `/bin/sh -c command` prints on stdout and stderr, and its status. -/
private def imageShell (command : String) : TestM (String × UInt32) := do
  let out ← IO.Process.output { cmd := "docker", args := #["run", "--rm", "--network", "none",
    "--label", testLabel, "--entrypoint", "/bin/sh", ← testImage, "-c", command] }
  pure (out.stdout ++ out.stderr, out.exitCode)

def execSuite : Suite := Testing.suite "runtime/docker.exec" #[
  test "stderr is merged into stdout at the fd level" do
    let out ← runIn (← Scripted.workDir) "echo hi >&2"
    assertEqual "merged output" out.output "hi\n"
    assertEqual "exit code" out.exitCode? (some 0),

  test "shell diagnostics are the shell's own, with stderr merged" do
    -- The inner shell sees the script as `$1`, so its messages are what the image's
    -- `/bin/sh -c` prints; for commands whose output is all on one stream, concatenating the
    -- streams is exact.
    let work ← Scripted.workDir
    for command in ["fi", "echo \"unterminated", "nosuchcmd_alaya_test"] do
      let out ← runIn work command
      let (output, code) ← imageShell command
      assertEqual s!"output of {repr command}" out.output output
      assertEqual s!"exit code of {repr command}" out.exitCode? (some code),

  test "non-UTF-8 command output is replaced, not dropped" do
    let out ← runIn (← Scripted.workDir) "printf 'a\\377b'"
    assertEqual "replaced output" out.output "a�b"
    assertEqual "exit code" out.exitCode? (some 0),

  test "a container that cannot be started is the machine's failure, not a command's result" do
    -- A work directory that is not there: docker has nothing to mount.
    let missing := (← scratch) / "missing"
    let executor ← containerExecutor
    let ran ← (try some <$> executor.bash Agents.MiniSwe.defaultExecutor missing "echo hi" catch _ => pure none : IO (Option Output))
    executor.close
    check ran.isNone s!"the command was given a result: {repr ran}"
    -- A user the image does not have, as a mistyped `--container-user` names.
    let settings := { (← testSettings) with user? := some "no-such-user-of-alaya" }
    let executor ← assertOk (Executor.Docker.executor settings)
    let work ← Scripted.workDir
    let ran ← (try some <$> executor.bash Agents.MiniSwe.defaultExecutor work "echo hi" catch _ => pure none : IO (Option Output))
    executor.close
    check ran.isNone s!"a command run as no user was given a result: {repr ran}",

  test "a command reads nothing from whoever runs alaya" do
    -- Its standard input is closed: a command that reads it gets the end at once.
    let out ← runIn (← Scripted.workDir) "cat; echo read to the end"
    assertEqual "it went on past the read" out.output "read to the end\n"
    assertEqual "exit code" out.exitCode? (some 0)
]

/-- What an executor and docker's settings say before any container runs. -/
def settingsSuite : Suite := Testing.suite "runtime/executor" #[
  iotest "invalid UTF-8 bytes are replaced and valid text survives" do
    let cases : Array (List UInt8 × String) := #[
      ([0xff], "�"),
      ([0xe2, 0x82, 0xac, 0x58], "€X"),
      ([0x61, 0xc2], "a�"),
      ([0xe2, 0x82], "��"),
      ([0xf0, 0x9f, 0x98, 0x80], "😀")]
    for (bytes, expected) in cases do
      let actual := Executor.lossyDecodeUtf8 ⟨bytes.toArray⟩
      if actual != expected then
        throw <| IO.userError s!"lossy decode {bytes}: got {repr actual}, want {repr expected}",
  test "a command docker could not run tells the agent nothing of the machine" do
    let said := "Error response from daemon: container 3f9a1c is not running (/data/tmp/41-7/work)"
    let out := Executor.failed said
    assertEqual "no exit code" out.exitCode? none
    assertEqual "what the agent is told" out.error? (some Executor.couldNotRun)
    assertEqual "the detail, for a reader of the log" out.detail? (some said)
    -- What a model is shown of it holds nothing docker said.
    let shown := (Agents.Tools.Bash.observation out Agents.MiniSwe.outputLimit).compress
    for leaked in ["3f9a1c", "/data/tmp", "daemon"] do
      check (!contains shown leaked) s!"the observation holds {leaked}: {shown}"
    check (contains shown Executor.couldNotRun) "and says the command could not be run",
  test "a workdir is an absolute, clean path, and not one alaya mounts" do
    for good in ["/workspace", "/testbed", "/home/user/project"] do
      assertOk <| Docker.checkWorkdir good #["/grader", "/out"]
    for bad in ["workspace", "/", "/a/../b", "/a//b", "/a/", "/a/./b", "/grader", "/out/x"] do
      assertError bad (Docker.checkWorkdir bad #["/grader", "/out"]) fun
        | .input _ => true
        | _ => false
]

end DockerTests
