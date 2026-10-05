import Alaya.Driver

/-! What a person adds to a log: the run itself, from a workspace and a task, and later a
message, a change to the workspace, a reply to a question, a stop, a grader, or a comment. Each is an event the
driver did not ask for, appended after an entry, so a person acts at any point of any run, and
acting at a point that already goes on is a fork. -/

namespace Alaya.Notices

open Lean (Json)
open Alaya (Result Error)
open Alaya.Workspaces (Change ChangeKind)

/-- What the root of a run says of the workspace it starts from. -/
def rootSummary : String := "the workspace the run starts from"

/-- Creates a run: its root, the workspace `project` holds, then the opening of the agent's call
with the run's configuration, then `task`, a notice the agent waits for. Gives the three
entries. -/
def create (store : Store) (workspaces : Workspaces) (run : Run Agent)
    (project : System.FilePath) (task : String) : Result (Array (Hash × Entry)) := do
  let workspace ← workspaces.snapshot project
  let mut forest ← store.forest
  let mut parent? : Option Hash := none
  let mut made : Array (Hash × Entry) := #[]
  let root : Event Agent := .arrived (.changed workspace rootSummary)
  let opening : Event Agent ← match next run #[root] with
    | .opens frame call => pure (.opened frame call)
    | _ => throw <| .input "the run does not open its agent"
  for event in #[root, opening, .arrived (.said task)] do
    let entry : Entry := { parent?, event }
    let (hash, grown) ← store.put forest entry
    forest := grown
    parent? := some hash
    made := made.push (hash, entry)
  pure made

/-- A person's comment after `tip`: for whoever reads the log, and nothing else. Replay passes
over it, so it is appended at any entry of any log, with nothing to check. Gives the new entry. -/
def comment (store : Store) (tip : Hash) (text : String) : Result (Hash × Entry) := do
  let forest ← store.forest
  let entry : Entry := { parent? := some tip, event := .commented none text }
  let (hash, _) ← store.put forest entry
  pure (hash, entry)

/-- The changes from `before` to `after`, one line each: `M path`, `+ path`, `- path`. -/
def changedLines (workspaces : Workspaces) (before after : Snapshot) : Result (Array String) := do
  let changes ← workspaces.diff before after
  pure <| changes.map fun change =>
    match change.kind with
    | .added => s!"+ {change.path}"
    | .removed => s!"- {change.path}"
    | .modified => s!"M {change.path}"

/-- A change to the workspace after `tip`: the files of `dir`, what changed from the version the
log has reached, one line each, and then what the person says of it. A directory with no change
is refused: a message alone is `said`. -/
def changed (store : Store) (workspaces : Workspaces) (tip : Hash) (dir : System.FilePath)
    (message : String) : Result (Event Agent) := do
  let forest ← store.forest
  let log ← store.log forest tip
  let some before := workspace? log | throw <| .storage "the log names no workspace"
  let after ← workspaces.snapshot dir
  let lines ← changedLines workspaces before after
  if lines.isEmpty then
    throw <| .input s!"{dir} has no change from the workspace at {tip.hex}: to send a message alone, use `tell`"
  let summary := "\n".intercalate ((lines.map ("  " ++ ·)).toList ++ (if message.isEmpty then [] else [message]))
  pure (.arrived (.changed after summary))

/-- Deletes the entry `hash` and every entry after it, and drops every snapshot no entry left
names. Gives how many entries went. -/
def remove (store : Store) (workspaces : Workspaces) (hash : Hash) : Result Nat := do
  let forest ← store.forest
  let doomed := forest.subtree hash
  store.delete forest doomed
  let forest ← store.forest
  let mut kept : Array Snapshot := #[]
  for entry in forest.entries do
    kept := kept ++ snapshots #[(← store.get forest entry).event]
  workspaces.retainOnly kept
  pure doomed.size

end Alaya.Notices
