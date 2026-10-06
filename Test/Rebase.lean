import Test.Framework
import Test.Scripted
import Test.DirectoryWorkspaces
import Alaya

/-! Rebase: a log made again by another version of its agent. The prefix the new agent still
makes is kept, its comments are its own, a read of the inbox takes the notices at their new
positions, and the run goes on with the new agent in a store of its own, to the log that agent
makes from the start. A response is not taken for another model, and a configuration given over
the recorded one is the new log's. -/

namespace RebaseTests

open Testing Alaya Scripted
open Lean (Json)

/-- An executor that answers every command with `ok`, and runs nothing. -/
private def echoing : Executor :=
  { exec := fun _ _ _ _ => pure { output := "ok", exitCode? := some 0 } }

/-- An agent that waits for its task and runs `commands`, one after another, reading its inbox
after each; when `comments`, it says which command it runs before each. -/
private def agent (commands : Array String) (comments : Bool := false) : Routine Agent :=
  runOf fun _ => do
    for command in commands do
      if comments then comment s!"running {command}"
      let _ ← exec command
      let _ ← inbox
    return "done"

private def first : Array String := #["echo one", "echo two", "echo three"]

/-- The events of a log as JSON, to compare two logs whole. -/
private def json (log : Log Agent) : Array String := log.map (eventToJson · |>.compress)

/-- A log as lines, the names of snapshots left out: two stores name them differently. -/
private def describe (log : Log Agent) : Array String :=
  log.map fun event => Render.eventSummary (event.renameSnapshots fun _ => default)

private def comments (log : Log Agent) : Array String :=
  log.filterMap fun | .commented text => some text | _ => none

/-- Drives `run` from a new log until it is over. -/
private def driven (run : Routine Agent) : TestM (Driver.Runtime × Hash × Log Agent) := do
  let (rt, last, _) ← drive run echoing (← scriptedModel #[])
  pure (rt, last, ← logAt rt last)

/-- The position of the command `command`'s answer in a log. -/
private def answerOf (log : Log Agent) (command : String) : TestM Nat := do
  let some position := log.findIdx? fun
      | .answered _ (.exec ran _) _ => ran == command
      | _ => false
    | fail s!"no answer to {command}"
  pure position

/-- A run of MiniSwe, as Alaya runs it, rebased with another model, and with a field of the
agent changed. -/
private def reconfigured : TestM Unit := do
  let run := session
  let rt ← runtime echoing (some (← scriptedModel #[
    responseWith #[call "c1" "bash" "echo one"], responseWith #[submitCall "s" "done"]]))
  let project := (← scratch) / "project"
  IO.FS.createDirAll project
  let (root, _) ← assertOk <| Notices.create rt.store rt.workspaces project
  let config ← assertOk <| Agents.Catalog.resolve "mini-swe"
    #[{ path := ["model"], value := "gpt-oss-120b" }, { path := ["task"], value := "t" }]
  let swe : RoutineCall := { name := "mini-swe", arguments := config, environment? := some testEnvironment.toJson }
  let (called, _) ← assertOk <| Driver.append rt.store run root swe.event
  let (last, _) ← assertOk <| Driver.drive rt run called
  let log ← logAt rt last
  let setting (text : String) : TestM Settings.Setting := match Settings.parse text with
    | .ok setting => pure setting
    | .error problem => fail problem
  let rebaseWith (settings : Array Settings.Setting) : TestM (Rebased Agent) := do
    pure (rebase run (← assertOk <| Rebase.reconfigure log settings))
  -- A field of the agent that changes no request: the whole log holds, under the new opening.
  let tuned ← rebaseWith #[← setting "context_reserve=7"]
  check tuned.divergence?.isNone "the whole log holds"
  let some opening := tuned.log.findSome? fun | (.opened ⟪"mini-swe"⟫ opened, _) => some opened | _ => none
    | fail "the opening of the agent"
  let reserve := (opening.arguments.getObjVal? "context_reserve").toOption
  assertEqual "the new configuration" (reserve.map (·.compress)) (some "7")
  -- Another model's parameters: a sample names its model, so the first is another operation.
  let other ← rebaseWith #[← setting "model.params.reasoning_effort=high"]
  let some divergence := other.divergence? | fail "the log diverges"
  check (divergence.found matches .answered _ (.sample ..) _) "at the first response"
  check (divergence.expected matches .ask { op := .sample { params := .obj _, .. } _, .. }) "where the agent samples the other"
  -- A field no call takes is the caller's to fix.
  assertError "an unknown field" (Rebase.reconfigure log #[← setting "no_such_field=1"]) fun
    | .input message => contains message "fits no call"
    | _ => false

def suite : Suite := Testing.suite "rebase" #[
  test "a log rebased onto the agent that wrote it is that log" do
    let run := agent first
    let (_, _, log) ← driven run
    let rebased := rebase run log
    check rebased.divergence?.isNone "the whole log holds"
    assertEqual "event for event" (json (rebased.log.map (·.1))) (json log)
    assertEqual "each from its own position" (rebased.log.map (·.2)) ((Array.range log.size).map some),

  test "comments are the revised agent's, before the events they precede, and a read takes the notices at their new positions" do
    -- The original agent's log, with a message after the first command.
    let original := agent first
    let (rt, last, _) ← driven original
    let forest ← assertOk rt.store.forest
    let point := (forest.path last)[← answerOf (← logAt rt last) "echo one"]!
    let (told, _) ← assertOk <| Driver.append rt.store original point (.arrived (.said "a hint"))
    let (end', _) ← assertOk <| Driver.drive rt original told
    let log ← logAt rt end'
    let revised := agent first (comments := true)
    let rebased := rebase revised log
    check rebased.divergence?.isNone "a change of comments only: the whole log holds"
    let new := rebased.log.map (·.1)
    assertEqual "the revised agent's comments" (comments new) (first.map (s!"running {·}"))
    check (first.all fun command => new.zipIdx.any fun (event, i) =>
      event matches .commented _ && (new[i + 1]?.any fun | .answered _ (.exec ran _) _ => ran == command | _ => false))
      "each just before its command"
    -- The comment before the first command moves the message on by one, and its read with it.
    let some hint := new.findIdx? (· matches .arrived (.said "a hint")) | fail "the message"
    assertEqual "the message, one further on" hint ((log.findIdx? (· matches .arrived (.said "a hint"))).map (· + 1) |>.getD 0)
    check (new.any fun | .heard _ notices => notices == #[hint] | _ => false) "the read takes it there"
    assertEqual "a trace of the revised agent, to the same end" (Render.nextSummary none ((lastCall? new).bind (·.2)) (next revised new))
      (Render.nextSummary none ((lastCall? log).bind (·.2)) (next original log))
    -- The way back: every comment of the log is left out, whoever wrote it.
    let (rt, last, commented) ← driven revised
    let (noted, _) ← assertOk <| Notices.comment rt.store last "by hand"
    let back := rebase original (← logAt rt noted)
    check back.divergence?.isNone "the whole log holds"
    assertEqual "no comment" (comments (back.log.map (·.1))) #[]
    assertEqual "the rest kept" back.log.size (commented.size - first.size),

  test "a change after a point keeps the log before it, and the run goes on in a store of its own" do
    let (rt, last, log) ← driven (agent first)
    let changed := agent #["echo one", "echo TWO", "echo three"]
    let rebased := rebase changed log
    let some divergence := rebased.divergence? | fail "the log diverges"
    assertEqual "at the second command" divergence.position (← answerOf log "echo two")
    check (divergence.expected matches .ask { op := .exec "echo TWO" _, .. }) "where the agent runs another"
    assertEqual "the log before it" (json (rebased.log.map (·.1))) (json (log.extract 0 divergence.position))
    -- Written into a new store, with its snapshots copied into new workspaces.
    let entries ← assertOk <| rt.store.entries (← assertOk rt.store.forest) last
    let base := (← scratch) / "rebased"
    let store ← assertOk <| Store.create (base / "entries")
    let written ← assertOk <| Rebase.write rebased entries rt.workspaces (base / "snapshots") store "rebased"
    let some (tip, _) := written.back? | fail "nothing written"
    let copied := (written.extract 0 (written.size - 1)).map (·.2)
    assertEqual "each entry keeps its time" (copied.map (·.elapsedMs)) ((entries.extract 0 copied.size).map (·.elapsedMs))
    let workspaces := directoryWorkspaces (base / "snapshots")
    let old := snapshots log
    for id in snapshots (copied.map (·.event)) do
      check (!old.contains id) s!"a snapshot under a name of the new store: {id.hex}"
      assertOk <| workspaces.materialize id ((← scratch) / "check")
    let rt' := { rt with store, workspaces }
    let (end', stop) ← assertOk <| Driver.drive rt' changed tip
    check (stop matches .idle) "the new agent is over"
    let goneOn ← logAt rt' end'
    let (_, _, fresh) ← driven changed
    assertEqual "the log the new agent makes from the start, and the note"
      (describe (goneOn.filter fun | .commented _ => false | _ => true)) (describe fresh)
    check (goneOn[divergence.position]! matches .commented "rebased") "the note, where the copy ends",

  test "what came from outside after the divergence is left out, and said so" do
    let (rt, last, log) ← driven (agent first)
    let two ← answerOf log "echo two"
    let forest ← assertOk rt.store.forest
    let point := (forest.path last)[two]!
    let (late, _) ← assertOk <| Driver.append rt.store (agent first) point (.arrived (.said "late"))
    let (stopped, _) ← assertOk <| Driver.append rt.store (agent first) late (.stopped "enough")
    let rebased := rebase (agent #["echo one", "echo TWO"]) (← logAt rt stopped)
    assertEqual "the message and the stop" (rebased.dropped.map (·.1)) #[two + 1, two + 2]
    check (Rebase.droppedLines rebased |>.all (contains · "left out")) "each in a line"
    check (rebased.log.any fun | (Event.arrived (.called ..), _) => true | _ => false) "the call, before it, is kept",

  test "a response is not taken for another model, and a setting over the configuration is the new log's" do
    reconfigured,

  test "the cache is shared as links, and a write in either directory leaves the other as it was" do
    let source := (← scratch) / "cache"
    IO.FS.createDirAll source
    IO.FS.writeFile (source / "a.json") "first"
    IO.FS.writeFile (source / "a.json.1-2.tmp") "half-written"
    let target := (← scratch) / "linked"
    assertOk <| Cache.link source target
    assertEqual "the entries, not a save in progress" ((← target.readDir).map (·.fileName)) #["a.json"]
    assertEqual "the same content" (← IO.FS.readFile (target / "a.json")) "first"
    -- As `save` writes: a new file renamed over the name.
    IO.FS.writeFile (target / "a.json.tmp") "second"
    IO.FS.rename (target / "a.json.tmp") (target / "a.json")
    assertEqual "the source unchanged" (← IO.FS.readFile (source / "a.json")) "first"
    assertEqual "the target changed" (← IO.FS.readFile (target / "a.json")) "second"]

end RebaseTests
