import Alaya.Executor
import Alaya.Cli

/-! The container executor: every command of a run in one container, with the working directory
bind-mounted at the trajectory's workdir, `/workspace` unless the root chose another, so the
store still snapshots a host directory. The command runs
through a `/bin/sh` trampoline that merges stderr into stdout, with the environment overrides
applied to the command rather than to the docker client. `runOnce` runs a single command in a
fresh container, which is how a grader runs. -/

namespace Alaya.Executor.Docker

open Alaya (Result Error Output Uname Executor)

/-- Where the working directory is mounted inside the container, unless a root chooses another. -/
def defaultWorkdir : String := "/workspace"

/-- A workdir is an absolute, clean path other than the root, and neither in nor around one of
`reserved`, which are mounted beside it. -/
def checkWorkdir (workdir : String) (reserved : Array String := #[]) : Result Unit := do
  let parts := (workdir.drop 1).toString.splitOn "/"
  if !workdir.startsWith "/" || workdir == "/" ||
      parts.any (fun part => part.isEmpty || part == "." || part == "..") then
    throw <| .input s!"--workdir must be an absolute, clean path other than /: {workdir}"
  if let some taken := reserved.find? fun r =>
      workdir == r || workdir.startsWith (r ++ "/") || r.startsWith (workdir ++ "/") then
    throw <| .input s!"--workdir cannot be {workdir}: {taken} is reserved"

/-- A host directory bind-mounted into a container. -/
structure Mount where
  host : System.FilePath
  container : String
  readOnly : Bool := false
  deriving Repr

/-- `--volume` arguments for `mounts`. -/
private def volumes (mounts : Array Mount) : IO (Array String) :=
  mounts.foldlM (init := #[]) fun args m => do
    let host ← IO.FS.realPath m.host
    pure (args ++ #["--volume", s!"{host}:{m.container}{if m.readOnly then ":ro" else ""}"])

/-- How the container is created. `image` is a runnable reference; once `pin`ned it is one that
names exact bits, which is what a trajectory records. -/
structure Settings where
  image : String
  /-- `uid:gid` to run as. Files the agent creates land in the bind-mounted workspace, so on
  Linux this must be the host user or the host can neither snapshot nor wipe them. Docker
  Desktop virtualizes ownership, so macOS leaves it unset. -/
  user? : Option String := none
  /-- `docker run --network`; off by default, see `docs/cli.md` §5. -/
  network? : Option String := some "none"
  /-- Where the working directory is mounted, and where commands run. -/
  workdir : String := defaultWorkdir
  /-- Extra `docker run` arguments, verbatim. -/
  extraRunArgs : Array String := #[]
  /-- Directories mounted into the execution container besides the workdir. -/
  mounts : Array Mount := #[]
  deriving Repr, Inhabited

/-! ## Talking to the docker client -/

private structure Client where
  exitCode : UInt32
  stdout : String
  stderr : String

private def client (args : Array String) : IO Client := do
  let out ← IO.Process.output { cmd := "docker", args }
  pure { exitCode := out.exitCode
         stdout := out.stdout.trimAscii.toString, stderr := out.stderr.trimAscii.toString }

/-- Runs a docker command, failing with its stderr. Every failure here is a setup problem —
docker missing, daemon down, image absent — so they are environment errors. -/
private def docker (args : Array String) (what : String) : Result String := do
  let result ← Result.fromIO (fun e => .environment s!"cannot run docker: {e}") (client args)
  if result.exitCode == 0 then pure result.stdout
  else throw <| .environment <|
    s!"{what} failed" ++ (if result.stderr.isEmpty then "" else s!": {result.stderr}")

private def inspect? (reference format : String) : IO (Option String) := do
  let result ← client #["image", "inspect", "--format", format, reference]
  pure (if result.exitCode == 0 && !result.stdout.isEmpty then some result.stdout else none)

/-! ## Pinning the image -/

/-- Replaces the image reference with one that names exact bits: its repo digest, or its image
id when it was built locally and has none. Both are runnable, so a trajectory can record one and
a later `resume` can start from it without consulting a tag that may have moved. Pulls once if
the image is not present locally. -/
def Settings.pin (settings : Settings) : Result Settings := do
  let reference := settings.image
  let resolve : Result (Option String) := Result.fromIO Error.environment do
    match ← inspect? reference "{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}" with
    | some digest => pure (some digest)
    | none => inspect? reference "{{.Id}}"
  match ← resolve with
  | some pinned => pure { settings with image := pinned }
  | none =>
    let _ ← docker #["pull", reference] s!"docker pull {reference}"
    match ← resolve with
    | some pinned => pure { settings with image := pinned }
    | none => throw <| .environment s!"image {reference} is not available after pulling it"

/-- Makes sure a recorded image is available locally, so a resumed trajectory fails with a clear
message rather than a container that cannot start. A registry digest names bits anyone can
fetch, so a missing one is pulled; a bare image ID is a local build's, which nothing can pull. -/
def Settings.ensurePresent (settings : Settings) : Result Unit := do
  let present : Result Bool := do
    pure (← Result.fromIO Error.environment (inspect? settings.image "{{.Id}}")).isSome
  if ← present then return
  if (settings.image.splitOn "@sha256:").length != 2 then
    throw <| .environment <|
      s!"image {settings.image} is recorded in this trajectory but is not available locally, " ++
      "and it is a local build's ID, which cannot be pulled: rebuild the image, or `docker load` it"
  let _ ← docker #["pull", settings.image] s!"docker pull {settings.image}"
  if !(← present) then
    throw <| .environment s!"image {settings.image} is not available after pulling it"

/-- The host user, as Linux containers must run as it to leave a workspace the host still owns.
Docker Desktop maps ownership itself, so macOS keeps the image's own user. -/
def defaultUser? : IO (Option String) := do
  if System.Platform.isOSX then pure none
  else
    let uid ← IO.Process.output { cmd := "id", args := #["-u"] }
    let gid ← IO.Process.output { cmd := "id", args := #["-g"] }
    if uid.exitCode != 0 || gid.exitCode != 0 then pure none
    else pure (some s!"{uid.stdout.trimAscii}:{gid.stdout.trimAscii}")

/-! ## The container -/

private def runArgs (settings : Settings) : Array String :=
  (match settings.user? with | some user => #["--user", user] | none => #[])
    ++ (match settings.network? with | some network => #["--network", network] | none => #[])
    -- The uid usually has no passwd entry, and tools that want $HOME would write to /.
    ++ #["--env", "HOME=/tmp"]

/-- `uname` inside the image, for a prompt that describes the machine. Read with a throwaway
container, since it is needed at `root` time, before any run has started. -/
def uname (settings : Settings) : Result Uname := do
  let script := "uname -s; uname -r; uname -v; uname -m"
  let out ← docker (#["run", "--rm", "--entrypoint", "/bin/sh"] ++ runArgs settings ++
    #[settings.image, "-c", script]) s!"reading uname from {settings.image}"
  match out.splitOn "\n" with
  | [system, release, version, machine] =>
    pure { system := system.trimAscii.toString, release := release.trimAscii.toString
           version := version.trimAscii.toString, machine := machine.trimAscii.toString }
  | _ => throw <| .environment s!"unexpected uname output from {settings.image}: {out}"

/-- A running container, plus whether its image has `timeout(1)`, which kills the command's
whole process group inside. Minimal images may not, and then the host-side deadline below is the
only backstop. -/
private structure Container where
  id : String
  hasTimeout : Bool

/-- Starts the run's container with the working directory bind-mounted.

The mount is bound to that directory's inode, and a full (non-incremental) materialize replaces
it — `Store.materialize` removes the destination and recreates it. A trajectory closes the
executor before every checkout, so the next command starts a container on the new directory. -/
private def start (settings : Settings) (workDir : System.FilePath) : IO Container := do
  let host ← IO.FS.realPath workDir
  let args := #["run", "--detach", "--rm", "--init", "--entrypoint", "/bin/sh"]
    ++ runArgs settings
    ++ #["--volume", s!"{host}:{settings.workdir}", "--workdir", settings.workdir]
    ++ (← volumes settings.mounts)
    ++ settings.extraRunArgs
    ++ #[settings.image, "-c", "while :; do sleep 86400; done"]
  let started ← client args
  if started.exitCode != 0 then
    throw <| IO.userError s!"cannot start a container from {settings.image}: {started.stderr}"
  let id := started.stdout
  let probe ← client #["exec", id, "/bin/sh", "-c", "command -v timeout > /dev/null 2>&1"]
  pure { id, hasTimeout := probe.exitCode == 0 }

private def remove (id : String) : IO Unit := do
  let _ ← client #["rm", "--force", id]

/-- Copies the contents of `path` in the image into `destination`, which must already exist.
The container is created but never started, so nothing in the image runs — this seeds a
trajectory from an image that already carries the project, the way task images usually do. -/
def copyOut (settings : Settings) (path : String) (destination : System.FilePath) : Result Unit := do
  let host ← Result.fromIO Error.storage (IO.FS.realPath destination)
  let id ← docker #["create", "--entrypoint", "/bin/sh", settings.image, "-c", "true"]
    s!"creating a container from {settings.image}"
  try
    -- The image was there a moment ago, so a copy that fails names a path the image lacks.
    let copy := docker #["cp", s!"{id}:{path}/.", host.toString] s!"copying {path} out of {settings.image}"
    let _ ← tryCatch copy fun
      | .environment message => throw <| .input message
      | error => throw error
  finally
    Result.fromIO Error.storage (remove id)

/-! ## Running one command -/

/-- The trampoline, with the in-container timeout when the image has one. The inner
`/bin/sh -c "$@"` still receives exactly the caller's argv, so its error messages are unchanged. -/
private def script (config : Config) (hasTimeout : Bool) : String :=
  if hasTimeout && config.timeoutSeconds > 0 then
    s!"exec timeout -k 2 {config.timeoutSeconds} /bin/sh -c \"$@\" 2>&1"
  else "exec /bin/sh -c \"$@\" 2>&1"

private partial def poll (child : IO.Process.Child cfg) (readAll : IO String)
    (deadlineMs? : Option Nat) : IO (Option UInt32 × String) := do
  match ← child.tryWait with
  | some code => pure (some code, ← readAll)
  | none =>
    if deadlineMs?.any ((← IO.monoMsNow) ≥ ·) then
      child.kill
      let _ ← child.wait
      pure (none, ← readAll)
    else
      IO.sleep 20
      poll child readAll deadlineMs?

/-- Docker's own failures (125, and 126/127 when it could not exec at all) come back on the
client's stderr, while the command's own output arrives on stdout with its stderr already
merged. A command may legitimately exit 126/127, so both signals are required. -/
private def clientFailure? (code : UInt32) (stderr : String) : Option String :=
  if (code == 125 || code == 126 || code == 127) && !stderr.isEmpty then some stderr else none

private def envArgs (config : Config) : Array String :=
  config.env.foldl (fun args (key, value) => args ++ #["--env", s!"{key}={value}"]) #[]

/-- Runs one command in the run's container, starting it on first use and after a timeout had to
take it down. Every failure is an observation, as an execution problem must never end a run. -/
private def execIn (ref : IO.Ref (Option Container)) (settings : Settings) (config : Config)
    (workDir : System.FilePath) (argv : Array String) (display : String) : IO Output := do
  try
    let container ← match ← ref.get with
      | some container => pure container
      | none =>
        let container ← start settings workDir
        ref.set (some container)
        pure container
    let child ← IO.Process.spawn {
      cmd := "docker"
      args := #["exec", "--interactive", "--workdir", settings.workdir] ++ envArgs config
        ++ #[container.id, "/bin/sh", "-c", script config container.hasTimeout, "sh"] ++ argv
      stdin := .inherit, stdout := .piped, stderr := .piped }
    let outReader ← IO.asTask (prio := .dedicated) child.stdout.readBinToEnd
    let errReader ← IO.asTask (prio := .dedicated) child.stderr.readBinToEnd
    let readAll : IO String := do
      pure (lossyDecodeUtf8 ((← IO.wait outReader).toOption.getD ByteArray.empty))
    let start ← IO.monoMsNow
    -- With an in-container `timeout` the host deadline is only a backstop, so it allows for the
    -- kill grace; without one it is the whole mechanism.
    let graceMs := if container.hasTimeout then 5000 else 0
    let deadline? := if config.timeoutSeconds == 0 then none
      else some (start + config.timeoutSeconds * 1000 + graceMs)
    let (code?, output) ← poll child readAll deadline?
    let elapsedMs := (← IO.monoMsNow) - start
    match code? with
    | none =>
      -- The client is gone but the command is still running inside; the container has to go.
      let _ ← client #["kill", container.id]
      remove container.id
      ref.set none
      pure (timedOut output display config.timeoutSeconds)
    | some code =>
      let stderr := lossyDecodeUtf8 ((← IO.wait errReader).toOption.getD ByteArray.empty)
      match clientFailure? code stderr.trimAscii.toString with
      | some message =>
        -- A container that died under us should not poison every later command.
        if (message.splitOn "is not running").length > 1 then ref.set none
        pure (failed message)
      | none =>
        -- How a killed command reports depends on the `timeout` in the image: GNU exits 124,
        -- busybox passes the signal status through (143 for TERM, 137 once `-k` sends KILL). A
        -- command can return any of those on its own, so a run that did not reach the limit is
        -- taken at its word.
        if (code == 124 || code == 137 || code == 143) && config.timeoutSeconds > 0 &&
            elapsedMs >= config.timeoutSeconds * 1000 then
          pure (timedOut output display config.timeoutSeconds)
        else pure { output, exitCode? := some code }
  catch e =>
    pure (failed (toString e))

/-- An executor that runs every command of a run in one container, with the working directory
bind-mounted, each as its own configuration says. `settings.image` should already be pinned,
since it is what the trajectory records. -/
def executor (settings : Settings) : Result Executor := do
  let ref ← Result.fromIO Error.storage (IO.mkRef (none : Option Container))
  pure {
    exec := execIn ref settings
    uname := (uname settings).toUserIO
    close := do
      match ← ref.get with
      | some container => remove container.id; ref.set none
      | none => pure ()
  }

/-! ## One command in a fresh container -/

/-- Waits for `child`; at `deadline` runs `stop` and returns `none`. -/
private partial def waitUntil (child : IO.Process.Child cfg) (deadline : Option Nat)
    (stop : IO Unit) : IO (Option UInt32) := do
  match ← child.tryWait with
  | some code => pure (some code)
  | none =>
    if let some limit := deadline then
      if (← IO.monoMsNow) >= limit then
        stop
        let _ ← child.wait
        return none
    IO.sleep 20
    waitUntil child deadline stop

/-- What a `runOnce` command printed, how it ended, and, when it did not end on its own, why. -/
structure Captured where
  stdout : String := ""
  stderr : String := ""
  exitCode? : Option UInt32 := none
  /-- Set when the command did not finish: it timed out, or could not be started. -/
  stopped? : Option String := none
  deriving Inhabited

/-- Runs `command` once with `/bin/sh -c` in a fresh container from `settings.image`, with
`mounts`, in `workdir`, and removes the container afterwards. Stdout and stderr are kept apart.
At `timeoutSeconds` (0 for none) the container is removed and the result says it timed out. -/
def runOnce (settings : Settings) (mounts : Array Mount) (workdir command : String)
    (timeoutSeconds : Nat) : IO Captured := do
  let name := s!"alaya-once-{← IO.monoNanosNow}"
  try
    let volumes ← volumes mounts
    let child ← IO.Process.spawn {
      cmd := "docker"
      args := #["run", "--rm", "--init", "--name", name, "--entrypoint", "/bin/sh"]
        ++ runArgs settings ++ volumes ++ #["--workdir", workdir] ++ settings.extraRunArgs
        ++ #[settings.image, "-c", command]
      stdin := .null, stdout := .piped, stderr := .piped }
    let outReader ← IO.asTask (prio := .dedicated) child.stdout.readBinToEnd
    let errReader ← IO.asTask (prio := .dedicated) child.stderr.readBinToEnd
    let read (reader : Task (Except IO.Error ByteArray)) : IO String := do
      pure (lossyDecodeUtf8 ((← IO.wait reader).toOption.getD ByteArray.empty))
    let now ← IO.monoMsNow
    let deadline := if timeoutSeconds == 0 then none else some (now + timeoutSeconds * 1000)
    -- Killing the client would leave the command running; the container has to go.
    let code? ← waitUntil child deadline (remove name)
    pure { stdout := ← read outReader, stderr := ← read errReader, exitCode? := code?
           stopped? := if code?.isNone then some s!"timed out after {timeoutSeconds} seconds" else none }
  catch e =>
    remove name
    pure { stopped? := some s!"could not be started: {e}" }

/-! ## Command line -/

/-- How this invocation's containers run: as whom, and on which network. Neither is recorded. -/
structure RunOptions where
  /-- `none` is `defaultUser?`. -/
  user? : Option String := none
  network : String := "none"
  deriving Repr, Inhabited

def RunOptions.cli : Cli.Spec RunOptions :=
  (fun user? network => { user?, network })
    <$> Cli.flag? "container-user" (.string "UID:GID")
      "the user commands run as; by default the host user on Linux, the image's own on macOS"
    <*> Cli.flagD "network" (.string "NAME") "none" "the docker network, e.g. bridge; none is no network"

/-- Settings for a trajectory's image and workdir, run as `options` say. -/
def settingsOf (options : RunOptions) (image : String) (workdir : String := defaultWorkdir) :
    Result Settings := do
  let user? ← match options.user? with
    | some user => pure (some user)
    | none => Result.fromIO Error.environment defaultUser?
  pure { image, user?, network? := some options.network, workdir }

end Alaya.Executor.Docker
