import Test.Support.Scripted

/-! The data directory and what can be done with it, as the runtime gives it: opening it, one
writer at a time, a new run, what a person appends, driving a run, copying a rebased run into a
new directory, and the queries. Its workspaces are the test's directory copies, so nothing here
needs restic or docker; `app/commands` runs the same through the binary. -/

namespace DataTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

/-- Directory copies under the data directory, in place of restic. -/
private def copies : Opener := fun path _ _ => pure (directoryWorkspaces (path / "snapshots"))

private def withData (path : System.FilePath) (f : Data → Result α) (write := true) : TestM α :=
  assertOk <| Data.with path f (write := write) (workspaces := copies)

/-- A data directory with a run of `project`, the session waiting; and the entries `create` made. -/
private def created : TestM (System.FilePath × Array Appended) := do
  let data := (← scratch) / "data"
  let project := (← scratch) / "project"
  writeSpec project #[("a.txt", "one\n")]
  let made ← assertOk <| Data.create data (.directory project) Session.scope Session.call (workspaces := copies)
  pure (data, made)

/-- A runtime over the data directory: the test's model, and commands that keep files. -/
private def runtimeOf (data : Data) (model : Model) : Result Driver.Runtime := do
  let work := data.scratch / "work"
  Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure { store := data.store, workspaces := data.workspaces, workDir := work, outputsDir := data.scratch / "outputs"
         executor := fun _ => pure (answeringUname (filing (data.scratch / "outputs")))
         model := fun _ => pure model }

private def agentCall (task : String := "t") : RoutineCall :=
  { name := "mini-swe", arguments := .mkObj [("model", testModelSpec.toJson), ("task", task)]
    environment? := some testEnvironment.toJson }

def suite : Suite := Testing.suite "runtime/data" #[
  test "a directory that holds no entries is refused, and nothing is made in it" do
    let path := (← scratch) / "nowhere"
    assertInput "no data directory" (Data.with path (fun _ => pure ()) (workspaces := copies)) "no data directory"
    check (!(← path.pathExists)) "nothing was created",

  test "a command's scratch is removed however it ends, read-only files and all" do
    let (data, _) ← created
    let scratch ← IO.mkRef (none : Option System.FilePath)
    assertError "a failing command" (Data.with (α := Unit) data (workspaces := copies) fun open' => do
      Result.fromIO Error.storage do
        scratch.set (some open'.scratch)
        IO.FS.createDirAll (open'.scratch / "deep")
        IO.FS.writeFile (open'.scratch / "deep" / "f") "x"
        let _ ← IO.Process.output { cmd := "chmod", args := #["-R", "a-w", (open'.scratch / "deep").toString] }
      throw (.input "it failed")) fun | .input _ => true | _ => false
    let some left := ← scratch.get | fail "no scratch"
    check (!(← left.pathExists)) s!"the scratch is gone: {left}",

  test "one writer at a time, refused at once, while a reader needs no lock" do
    let (data, _) ← created
    -- A writer holds the lock, as one command does while another starts.
    let lock ← assertOk <| Lock.acquire data
    assertError "a second writer" (Data.with data (fun _ => pure ()) (write := true) (workspaces := copies)) fun
      | .busy _ => true
      | _ => false
    withData data (write := false) fun _ => pure ()
    assertOk lock.release
    -- Once the first ends, the lock is free again.
    withData data fun _ => pure (),

  test "a new run is its workspace and the session's call, read and opened, waiting for a call" do
    let (data, made) ← created
    assertEqual "positions from 0" (made.map (·.position)) #[0, 1, 2, 3]
    assertEqual "each after the one before" (made.map (·.entry.parent?)) (#[none] ++ (made.pop.map (some ·.hash)))
    check (made[3]!.entry.event matches .opened ⟪"session"⟫ _) "the session is open"
    withData data fun data => do
      let visit ← data.visitAt Session.scope made.back!.hash.hex
      if !(visit.next?.any Session.idle) then throw (.input "the session does not wait")
    -- A project that holds the data directory would snapshot it.
    let project := (← scratch) / "outer"
    IO.FS.createDirAll project
    assertInput "a data directory inside the project"
      (Data.create (project / "data") (.directory project) Session.scope Session.call (workspaces := copies)) "",

  test "what a person appends is checked by the session, and what the log can take by the runtime" do
    let (data, made) ← created
    let tip := made.back!.hash.hex
    withData data fun data => do
      -- The session admits a call where it waits; then a message, but no second call.
      let called ← data.call Session.scope tip (agentCall) (admit := Session.admitsCall)
      let _ ← data.tell Session.scope tip "too early" |>.toBaseIO   -- the runtime takes it: a notice
      let refusals : Array (String × Result Appended × String) := #[
        ("a message where no call runs", data.tell Session.scope tip "hi" (admit := Session.admitsNotice), "no call is running"),
        ("a second call before the first is made", data.call Session.scope called.hash.hex (agentCall) (admit := Session.admitsCall), "a call to make here already"),
        ("a reply where no question waits", data.reply Session.scope called.hash.hex (some "yes"), "no question waits"),
        ("a stop where no call is open in its frame", data.stop Session.scope tip ⟪"session", "mini-swe"⟫ "x", "no call is open")]
      for (label, appended, needle) in refusals do
        match ← appended.toBaseIO with
        | .ok _ => throw (.input s!"{label}: taken")
        | .error (.input message) => if !contains message needle then throw (.input s!"{label}: {message}")
        | .error error => throw error
    pure (),

  test "resume drives the run on, telling of each entry at its position, to where the session waits" do
    let (data, made) ← created
    withData data fun data => do
      let called ← data.call Session.scope made.back!.hash.hex (agentCall) (admit := Session.admitsCall)
      let model ← Result.fromIO Error.storage (scriptedModel #[responseWith #[call "c" "bash" "write b.txt two"],
        responseWith #[sentinelCall "s"]])
      let rt ← runtimeOf data model
      let told ← Result.fromIO Error.storage (IO.mkRef (#[] : Array Nat))
      let (last, stop, log) ← data.resume Session.scope called.hash.hex rt {} fun appended =>
        Result.fromIO Error.storage (told.modify (·.push appended.position))
      let positions ← Result.fromIO Error.storage told.get
      if positions != (Array.range positions.size).map (· + called.position + 1) then
        throw (.input s!"positions told: {positions}")
      if !(stop matches .waits ⟪"session"⟫ none) then throw (.input "the session should wait")
      if log.size != called.position + 1 + positions.size then throw (.input "the log is the entries told")
      -- The queries read the same: the workspace changed, and nothing waits for a reply.
      let changes ← data.changes made.back!.hash.hex last.hex
      if changes.map (·.line) != #["+ b.txt"] then throw (.input s!"changes: {changes.map (·.line)}")
      if !(← data.waiting Session.scope).isEmpty then throw (.input "nothing waits for a reply")
      let visits ← data.visitsAt Session.scope last.hex
      if visits.map (·.position) != Array.range log.size then throw (.input "a visit for each entry, in order")
    pure (),

  test "a rebased run is written into a new directory, which a failure leaves as if never begun" do
    let (data, made) ← created
    let target := (← scratch) / "rebased"
    withData data (write := false) fun data => do
      let (_, _, entries) ← data.entriesAt made.back!.hash.hex
      let rebased := rebase Session.scope (entries.map (·.event))
      for (label, to, needle) in [("a directory that exists", data.path, "exists"),
          ("one inside the data directory", data.path / "inner", "overlaps")] do
        match ← (data.rebase entries rebased to "note").toBaseIO with
        | .error (.input message) => if !contains message needle then throw (.input s!"{label}: {message}")
        | _ => throw (.input s!"{label}: taken")
      -- A log that names a snapshot the workspaces do not have: the copy fails, and leaves nothing.
      let broken := { rebased with log := rebased.log.push (.arrived (.changed ⟨String.ofList (List.replicate 64 'f')⟩ "gone"), none) }
      match ← (data.rebase entries broken target "note").toBaseIO with
      | .ok _ => throw (.input "a missing snapshot copied")
      | .error _ => pure ()
      let siblings ← Result.fromIO Error.storage (target.parent.getD ".").readDir
      if siblings.any (·.fileName.startsWith ".rebased.rebase-") || (← Result.fromIO Error.storage target.pathExists) then
        throw (.input "a failed rebase left a directory")
      let written ← data.rebase entries rebased target "note"
      if !(written.back?.any (·.entry.event matches .commented "note")) then throw (.input "the note ends it")
    check (← (target / "entries").isDir) "the new directory holds the run"
    check (← (target / "cache").isDir) "and the model cache",

  test "the marks a run makes with no world are appended where it would make them, and nowhere else" do
    let (data, made) ← created
    withData data fun data => do
      if !(← Driver.settle data.store Session.scope made.back!.hash).isEmpty then
        throw (.input "the session already waits: nothing to settle")
      let called ← data.call Session.scope made.back!.hash.hex (agentCall)
      let settled ← Driver.settle data.store Session.scope called.hash
      if !(settled.map (·.2.event) |>.all fun | .heard .. | .opened .. => true | _ => false) || settled.size != 2 then
        throw (.input "the session's read of the call and the agent's opening")
      if !(← Driver.settle data.store Session.scope settled.back!.1).isEmpty then
        throw (.input "the agent asks the world next: nothing more")
    pure (),

  test "a limit lets the session take a call, and holds a read that may take a message" do
    let (data, made) ← created
    withData data fun data => do
      let called ← data.call Session.scope made.back!.hash.hex (agentCall)
      let model ← Result.fromIO Error.storage (scriptedModel #[responseWith #[sentinelCall "s"]])
      let rt ← runtimeOf data model
      let (_, stop, log) ← data.resume Session.scope called.hash.hex rt { samples? := some 0 }
      if !(stop matches .paused _) then throw (.input "paused")
      -- The session read the call and opened the agent; the agent ran uname, and stopped before its read.
      if !(log.any (· matches .opened ⟪"session", "mini-swe"⟫ _)) then throw (.input "the call was opened")
      if log.back? matches some (.heard ..) then throw (.input "the agent's read was held")
    pure ()
]

end DataTests
