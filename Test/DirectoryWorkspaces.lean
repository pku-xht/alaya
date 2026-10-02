import Test.Framework
import Alaya

/-! A `Workspaces` for tests of everything above it: a snapshot is a copy of the directory. It
keeps the contract `Test/Workspaces.lean` checks, costs no `restic` process — each of which
spends most of a second deriving the repository key — and so keeps trajectory tests about
the trajectory. -/

namespace Testing

open Alaya
open Alaya.Workspaces (Change)

private def storageIO (action : IO α) : Result α := Result.fromIO Error.storage action

private def copy (source destination : System.FilePath) : IO Unit := do
  IO.FS.createDirAll destination
  let out ← IO.Process.output { cmd := "cp", args := #["-Rp", s!"{source}/.", destination.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"cp failed: {out.stderr}"

/-- What is at each path under `base`: `none` for a directory, otherwise what identifies the
content — a link's target, a file's bytes. -/
private partial def listing (base : System.FilePath) (relative : String := "")
    (found : Array (String × Option String) := #[]) : IO (Array (String × Option String)) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  let mut found := found
  for child in ← directory.readDir do
    let path := if relative.isEmpty then child.fileName else s!"{relative}/{child.fileName}"
    match (← child.path.symlinkMetadata).type with
    | .dir =>
      found := found.push (path, none)
      found ← listing base path found
    | .symlink =>
      let out ← IO.Process.output { cmd := "readlink", args := #[child.path.toString] }
      found := found.push (path, some s!"link {out.stdout}")
    | _ => found := found.push (path, some s!"file {Sha256.sumHex (← IO.FS.readBinFile child.path)}")
  pure found

private def under (roots : Array String) (path : String) : Bool :=
  roots.any fun root => path.startsWith (root ++ "/")

def directoryWorkspaces (root : System.FilePath) : Workspaces where
  snapshot directory := storageIO do
    let id : Hash := ⟨Sha256.sumHex s!"{directory} {← IO.monoNanosNow}".toUTF8⟩
    copy directory (root / id.hex)
    pure id
  materialize id directory := do
    Workspaces.makeWritable directory
    storageIO do
      if !(← (root / id.hex).isDir) then throw <| IO.userError s!"no snapshot {id.hex}"
      if ← directory.pathExists then IO.FS.removeDirAll directory
      copy (root / id.hex) directory
  diff before after := storageIO do
    let old := Std.HashMap.ofList (← listing (root / before.hex)).toList
    let new := Std.HashMap.ofList (← listing (root / after.hex)).toList
    -- A path that was a directory and is not, or the reverse, is a removal and an addition.
    let retyped (path : String) : Bool :=
      match old.get? path, new.get? path with
      | some was, some now => was.isNone != now.isNone
      | _, _ => false
    let removed := old.toArray.filter fun (path, _) => !new.contains path || retyped path
    let added := new.toArray.filter fun (path, _) => !old.contains path || retyped path
    let fold (kind : Workspaces.ChangeKind) (entries : Array (String × Option String)) :=
      let roots := entries.filterMap fun (path, content) => if content.isNone then some path else none
      entries.filterMap fun (path, content) =>
        if under roots path then none
        else some ({ kind, path, directory := content.isNone } : Change)
    let modified := new.toArray.filterMap fun (path, content) =>
      match old.get? path with
      | some was => if was != content && was.isSome && content.isSome
          then some ({ kind := .modified, path } : Change) else none
      | none => none
    let rank : Workspaces.ChangeKind -> Nat | .removed => 0 | .added => 1 | .modified => 2
    pure <| (fold .removed removed ++ fold .added added ++ modified).qsort fun a b =>
      a.path < b.path || (a.path == b.path && rank a.kind < rank b.kind)
  readFiles id paths := paths.mapM fun path => storageIO do
    if !Workspaces.safeRelativePath path then return none
    let file := root / id.hex / (path : System.FilePath)
    if !(← file.pathExists) then return none
    match (← file.symlinkMetadata).type with
    | .file => pure (some (← IO.FS.readBinFile file))
    | _ => pure none
  listEntries id path := storageIO do
    if !Workspaces.safeSnapshotPath path then
      throw <| IO.userError s!"not a clean relative path: {path}"
    let directory := if path.isEmpty then root / id.hex else root / id.hex / (path : System.FilePath)
    let mut entries := #[]
    for child in ← directory.readDir do
      let metadata ← child.path.symlinkMetadata
      let kind : Workspaces.EntryKind := match metadata.type with
        | .dir => .directory | .file => .file | .symlink => .symlink | _ => .other
      entries := entries.push {
        name := child.fileName
        path := if path.isEmpty then child.fileName else s!"{path}/{child.fileName}"
        kind, size := if kind == .file then some metadata.byteSize.toNat else none }
    pure entries
  retainOnly keep := storageIO do
    if !(← root.isDir) then return
    for entry in ← root.readDir do
      if !keep.any (·.hex == entry.fileName) then
        let _ ← IO.Process.output { cmd := "chmod", args := #["-R", "u+w", entry.path.toString] }
        IO.FS.removeDirAll entry.path

/-- The kind of a root a test builds by hand: nothing runs in it, so it names no real image. -/
def testRoot : Trajectory.Kind :=
  .root { agent := testAgent, model := testModel, image := recordedImage, workdir := recordedWorkdir }

/-- A model turn as a hand-built log records it; the request it answered goes unchecked. -/
def responded (response : Chat.Response) : Agent.Event := .sampled default Agent.Purpose.turn response

/-- A command's output as a hand-built log records it: the answer to call `index` of the response
at log position `response`, run in `workspace` and leaving it as it was — a placeholder unless a
later command will run where it left the log. -/
def ran (output : String) (exitCode? : Option UInt32 := some 0) (response : Nat := 0) (index : Nat := 0)
    (workspace : Hash := default) : Agent.Event :=
  .executed { response, index } "" {} { output, exitCode? } workspace

/-- The request `agent` samples from `log`, or an empty one when it would not sample. -/
def requestOf (agent : Agent.Agent) (log : Agent.Log) : Chat.Request :=
  (agent.request? log).getD { messages := #[] }

/-- The names of the tools `agent` offers at `log`. -/
def toolNames (agent : Agent.Agent) (log : Agent.Log) : Array String :=
  (requestOf agent log).tools.map (·.name)

/-- One step from `hash`: a continuation allowed one step, as `alaya resume --steps 1` is. -/
def step (rt : Driver.Runtime) (hash : Hash) (budgetMs? : Option Nat := none) :
    Result (Hash × Driver.Stop) :=
  Driver.resume rt hash { steps? := some 1, budgetMs? }

/-- The state a step reached, when no time budget stopped it: the tests that step give none. -/
def stepped (result : Result (Hash × Driver.Stop)) : TestM Hash := do
  let (state, stop) ← assertOk result
  if stop == .outOfTime then fail "the step was stopped by a time budget"
  pure state

/-- The test's own snapshot store, the same one however often it is asked for. -/
def workspaces : TestM Workspaces := do
  pure (directoryWorkspaces ((← scratch) / "snapshots"))

/-- A step under `parent` holding `appended`, recorded by hand: history a test starts from. It
keeps the parent's workspace: a command `ran` records on the placeholder workspace ran where the
parent is, and left it as it was. -/
def putStep (store : Trajectory.Store) (parent : Hash) (appended : Agent.Log) : TestM Hash := do
  let above ← assertOk <| Trajectory.getState store parent
  let here (workspace : Hash) := if workspace == default then above.workspace else workspace
  let appended : Agent.Log := appended.map fun
    | .executed call command config output snapshot =>
      .executed call command config output (here snapshot)
    | event => event
  assertOk <| Trajectory.putState store {
    parent? := some parent, workspace := appended.workspace?.getD above.workspace, kind := .step
    appended }

/-- Drives `agent` as production runs do — a root of `log` over an empty project, and `history`
after it as a step, on the test's
directory workspaces and in its working directory, grown by `resume` — until the run ends,
asks, or reaches a limit. Each call has a store of its own. Returns the runtime, the state it stopped at, and why. -/
def drive (agent : Agent.Agent) (executor : Executor) (model : Model) (log : Agent.Log)
    (history : Agent.Log := #[]) : TestM (Driver.Runtime × Hash × Driver.Stop) := do
  let base := (← scratch) / s!"drive-{← IO.monoNanosNow}"
  IO.FS.createDirAll (base / "project")
  -- The test's own working directory, which the tests that check files read.
  let work := (← scratch) / "work"
  IO.FS.createDirAll work
  let store ← assertOk <| Trajectory.Store.create (base / "states")
  let workspaces ← workspaces
  let root ← assertOk <| Trajectory.createRoot store workspaces log (base / "project") recordedImage
    (agent := testAgent) (model := testModel)
  -- History the test starts from is a step of its own, as a run would have recorded it.
  let start ← if history.isEmpty then pure root else putStep store root history
  let rt : Driver.Runtime := { store, workspaces, workDir := work, outputsDir := work.withFileName "outputs", executor, model, agent }
  let (state, halt) ← assertOk <| Driver.resume rt start
  pure (rt, state, halt)

end Testing
