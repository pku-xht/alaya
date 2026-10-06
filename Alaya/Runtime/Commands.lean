import Alaya.Core.Rebase
import Alaya.Runtime.Data
import Alaya.Runtime.Notices
import Alaya.Runtime.Walk
import Alaya.Runtime.Executor.Docker

/-! What can be done with a data directory, as functions: start a run, append what a person
says, drive a run, copy a rebased run into a new directory, and read what a run did. Each takes
the run's routine, `root`, so the runtime knows no catalog of programs; a front end parses its
input, calls these, and shows what they give. -/

namespace Alaya.Runtime

open Alaya.Base Alaya.Core Alaya.LLM

open Lean (Json)

private def io (action : IO α) : Result α := Result.fromIO Error.storage action

/-- An entry written by a command, at its position in its log. -/
structure Appended where
  hash : Hash
  position : Nat
  entry : Entry

/-- Where a new run's workspace comes from: a directory, or the work directory of an image,
`""` for the one the image names. -/
inductive Source where
  | directory (path : System.FilePath)
  | image (image : String) (workdir : String)

/-- A container image pinned by its digest, and where the workspace is mounted in it: where a
call's commands run. The work directory must not be the one the driver reserves for outputs. -/
def Environment.pinned (image workdir : String) : Result Environment := do
  Executor.Docker.checkWorkdir workdir #[Driver.outputsDir]
  let settings ← (← Executor.Docker.settingsOf {} image workdir).pin
  pure { image := settings.image, workdir }

namespace Data

/-! ## Starting a run -/

/-- Creates the data directory at `path`, when there is none, and a new run in it, from
`source`. Gives the run's root. -/
def create (path : System.FilePath) (source : Source) : Result Appended := do
  -- Before the data directory is created: inside the project it would become part of it.
  if let .directory project := source then
    Workspaces.refuseOverlap "snapshot" project #[path]
  Data.with path (write := true) (create := true) fun data => do
    let project ← match source with
      | .directory project => pure project
      | .image image workdir =>
        let settings ← (← Executor.Docker.settingsOf {} image).pin
        let workdir ← if workdir.isEmpty then Executor.Docker.imageWorkdir settings else pure workdir
        let work := data.scratch / "project"
        io (IO.FS.createDirAll work)
        Executor.Docker.copyOut settings workdir work
        pure work
    let (hash, entry) ← Notices.create data.store data.workspaces project
    pure { hash, position := 0, entry }

/-! ## What a person appends -/

/-- Appends the event `event` makes of the log at the entry a reference names, and of what the
run does next there. -/
def append (data : Data) (root : Routine Agent) (reference : String)
    (event : Log Agent → Next Agent → Result (Event Agent)) : Result Appended := do
  let (_, tip, entries) ← data.entriesAt reference
  let log := entries.map (·.event)
  let event ← event log (next root log)
  let (hash, entry) ← Driver.append data.store root tip event
  pure { hash, position := entries.size, entry }

/-- A call of a program, where no call is running. -/
def call (data : Data) (root : Routine Agent) (reference : String) (call : RoutineCall) :
    Result Appended :=
  data.append root reference fun _ _ => pure call.event

/-- A message to the run. -/
def tell (data : Data) (root : Routine Agent) (reference text : String) : Result Appended :=
  data.append root reference fun _ _ => pure (.arrived (.said text))

/-- A stop of the calls running there. -/
def stop (data : Data) (root : Routine Agent) (reference reason : String) : Result Appended :=
  data.append root reference fun _ _ => pure (.stopped reason)

/-- A change to the workspace: the files of `dir`, and what the person says of it. -/
def commit (data : Data) (root : Routine Agent) (reference : String) (dir : System.FilePath)
    (message : String) : Result Appended := do
  let (_, tip) ← data.resolve reference
  let event ← Notices.changed data.store data.workspaces tip dir message
  data.append root reference fun _ _ => pure event

/-- A reply to the question the run waits on: the answer's text, or `none` when the person
cannot answer. -/
def reply (data : Data) (root : Routine Agent) (reference : String) (answer? : Option String) :
    Result Appended :=
  data.append root reference fun _ next => do
    let some (_, question) := questionOf? next
      | throw <| .input s!"no question waits for a reply at {reference}"
    let reply ← match answer? with
      | some text => Result.fromExcept Error.input (question.parseReply text)
      | none => pure .unavailable
    Result.fromExcept Error.input (replyTo next reply)

/-- A comment. Nothing reads it, so nothing is checked: the log need not even be one its run can
still be built from. -/
def comment (data : Data) (reference text : String) : Result Appended := do
  let (forest, tip) ← data.resolve reference
  let (hash, entry) ← Notices.comment data.store tip text
  pure { hash, position := (forest.path tip).size, entry }

/-- Deletes the entry a reference names and every entry after it. Gives how many went. -/
def remove (data : Data) (reference : String) : Result Nat := do
  let (_, hash) ← data.resolve reference
  Notices.remove data.store data.workspaces hash

/-! ## Driving a run -/

/-- Runs `k` with what a run is driven with: its work directory and outputs in the command's
scratch, a container of each call's image as `options` say, and the models `provider?` serves,
at `baseUrl?` when given, each built once; a sample with no provider fails with `unserved`. -/
def withRuntime (data : Data) (options : Executor.Docker.RunOptions)
    (provider? : Option Provider.Provider) (baseUrl? : Option String) (k : Driver.Runtime → Result α)
    (unserved : Error := .input "a call samples its model, and no provider is named") : Result α := do
  let outputs := data.scratch / "outputs"
  let work := data.scratch / "work"
  io do
    IO.FS.createDirAll outputs
    IO.FS.createDirAll work
  let outputsHost ← io (IO.FS.realPath outputs)
  let models ← io (IO.mkRef (#[] : Array (String × Model)))
  k { store := data.store, workspaces := data.workspaces, workDir := work, outputsDir := outputs
      executor := fun environment => do
        let settings ← Executor.Docker.settingsOf options environment.image environment.workdir
        let settings := { settings with
          mounts := #[{ host := outputsHost, container := Driver.outputsDir, readOnly := true }] }
        settings.ensurePresent
        Executor.Docker.executor settings
      model := fun spec => do
        let some provider := provider?
          | throw unserved
        let key := spec.toJson.compress
        if let some (_, model) := (← io models.get).find? (·.1 == key) then
          return model
        let model ← Driver.buildModel spec provider data.cache baseUrl?
        io (models.modify (·.push (key, model)))
        pure model }

/-- Drives the run from the entry a reference names until it stops, `onEntry` told of each
entry written. Gives the last entry, why the driver stopped, and the log there. -/
def resume (data : Data) (root : Routine Agent) (reference : String) (runtime : Driver.Runtime)
    (limits : Driver.Limits := {}) (onEntry : Appended → Result Unit := fun _ => pure ()) :
    Result (Hash × Driver.Stop × Log Agent) := do
  let (_, tip, entries) ← data.entriesAt reference
  let position ← io (IO.mkRef entries.size)
  let (last, stop) ← Driver.drive runtime root tip limits fun hash entry => do
    onEntry { hash, position := ← io (position.modifyGet fun p => (p, p + 1)), entry }
  pure (last, stop, ← data.store.log (← data.store.forest) last)

/-! ## Rebasing a run -/

/-- Writes the rebased log into `store`, an empty one, with the snapshots it names copied from
`workspaces` into a new store at `repository`, and then `note`, a comment that says where it came
from. An entry taken from the old log keeps its time, `entries` being the old log's; a comment
the routine made took none. Gives the entries written, in order. -/
def _root_.Alaya.Core.Rebased.write (rebased : Rebased Agent) (entries : Array Entry) (workspaces : Workspaces)
    (repository : System.FilePath) (store : Store) (note : String) : Result (Array (Hash × Entry)) := do
  let ids := snapshots (rebased.log.map (·.1))
  let copies ← workspaces.transfer ids repository
  let renamed : Std.HashMap Snapshot Snapshot := (ids.zip copies).foldl (init := {}) fun m (id, copy) =>
    m.insert id copy
  let rename (id : Snapshot) := renamed.getD id id
  let mut forest ← store.forest
  let mut parent? : Option Hash := none
  let mut written : Array (Hash × Entry) := #[]
  let events := rebased.log.map (fun (event, origin?) =>
    (event.renameSnapshots rename, (origin?.bind (entries[·]?)).map (·.elapsedMs) |>.getD 0))
  for (event, elapsedMs) in events.push (.commented note, 0) do
    let entry : Entry := { parent?, event, elapsedMs }
    let (hash, grown) ← store.put forest entry
    forest := grown
    parent? := some hash
    written := written.push (hash, entry)
  pure written

/-- Copies a rebased log, of the old log `entries`, into a new data directory, `target`, with
`note` after it, and the model cache shared. The new directory is written beside `target` under
another name and renamed into place once complete, so a failure leaves none. -/
def rebase (data : Data) (entries : Array Entry) (rebased : Rebased Agent) (target : System.FilePath)
    (note : String) : Result (Array Appended) := do
  if ← io target.pathExists then
    throw <| .input s!"{target} exists: rebase makes a new data directory"
  let some name := target.fileName | throw <| .input s!"not a directory to create: {target}"
  let source ← io (IO.FS.realPath data.path)
  if Workspaces.overlap (← io (Workspaces.resolved target)) source then
    throw <| .input s!"{target} overlaps the data directory {data.path}: put the new one beside it"
  let staging := target.withFileName
    s!".{name}.rebase-{← (IO.Process.getPID : BaseIO UInt32)}-{← (IO.monoNanosNow : BaseIO Nat)}"
  let written ← try
      let store ← Store.create (staging / "entries")
      let written ← rebased.write entries data.workspaces (staging / "restic") store note
      Cache.link data.cache (staging / "cache")
      io (IO.FS.rename staging target)
      pure written
    catch error =>
      Workspaces.makeWritable staging
      io do if ← staging.pathExists then IO.FS.removeDirAll staging
      throw error
  pure <| written.zipIdx.map fun ((hash, entry), position) => { hash, position, entry }

/-! ## Reading -/

/-- What a reader knows at each entry of the log at the entry a reference names. -/
def visitsAt (data : Data) (root : Routine Agent) (reference : String) : Result (Array Visit) := do
  let (_, _, entries) ← data.entriesAt reference
  pure (visits root entries)

/-- What a reader knows at the entry a reference names. -/
def visitAt (data : Data) (root : Routine Agent) (reference : String) : Result Visit := do
  let some visit := (← data.visitsAt root reference).back? | throw <| .storage "an empty log"
  pure visit

/-- Every end of a log that waits on a question: the entry, the frame that asks, the question. -/
def waiting (data : Data) (root : Routine Agent) : Result (Array (Hash × Frame × Question)) := do
  let forest ← data.store.forest
  walk data.store forest #[] (root := root) fun found visit =>
    let leaf := (forest.childrenOf visit.hash).isEmpty
    pure <| match leaf, visit.next?, visit.question? with
      | true, some (.waits frame _), some question => found.push (visit.hash, frame, question)
      | _, _, _ => found

/-- What changed from the workspace at one entry to the workspace at another. -/
def changes (data : Data) (before after : String) : Result (Array Workspaces.Change) := do
  let (_, _, before) ← data.entriesAt before
  let (_, _, after) ← data.entriesAt after
  data.workspaces.diff (← snapshotOf before) (← snapshotOf after)

end Data

end Alaya.Runtime
