import Alaya.Runtime.Driver

/-! What a person adds to a log: the run itself, from a workspace, and later a call of a program,
a message, a change to the workspace, a reply to a question, a stop, or a comment. Each is an
event the driver did not ask for, appended after an entry, so a person acts at any point of any
run, and acting at a point that already goes on is a fork. -/

namespace Alaya.Runtime.Notices

open Alaya.Base Alaya.Core Alaya.LLM

open Lean (Json)
open Alaya.Runtime.Workspaces (Change ChangeKind)

/-- What the root of a run says of the workspace it starts from. -/
def rootSummary : String := "the workspace the run starts from"

/-- Creates a run: its root, the workspace `project` holds, where the run waits for a program to be
called. Gives the root's entry. -/
def create (store : Store) (workspaces : Workspaces) (project : System.FilePath) : Result (Hash × Entry) := do
  let workspace ← workspaces.snapshot project
  let entry : Entry := { parent? := none, event := .arrived (.changed workspace rootSummary) }
  let (hash, _) ← store.put (← store.forest) entry
  pure (hash, entry)

/-- A person's comment after `tip`: for whoever reads the log, and nothing else. Replay passes
over it, so it is appended at any entry of any log, with nothing to check. Gives the new entry. -/
def comment (store : Store) (tip : Hash) (text : String) : Result (Hash × Entry) := do
  let forest ← store.forest
  let entry : Entry := { parent? := some tip, event := .commented text }
  let (hash, _) ← store.put forest entry
  pure (hash, entry)

/-- A change to the workspace after `tip`: the files of `dir`, and what changed from the version
the log has reached, one line each. A directory with no change is refused. -/
def changed (store : Store) (workspaces : Workspaces) (tip : Hash) (dir : System.FilePath) :
    Result (Event Agent) := do
  let forest ← store.forest
  let log ← store.log forest tip
  let some before := workspace? log | throw <| .storage "the log names no workspace"
  let after ← workspaces.snapshot dir
  let lines := (← workspaces.diff before after).map (·.line)
  if lines.isEmpty then
    throw <| .input s!"{dir} has no change from the workspace at {tip.hex}"
  pure (.arrived (.changed after ("\n".intercalate lines.toList)))

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

end Alaya.Runtime.Notices
