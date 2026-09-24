import Alaya.Trajectory

/-! Read-only evidence for a person joining a run at a question. History follows only parent
edges, and files always come from that question's immutable workspace snapshot. -/

namespace Alaya.Trajectory.QuestionContext

open Lean (Json)

private def questionState (store : Store) (hash : Hash) : Result State := do
  let state ← getState store hash
  if state.kind != .question || state.question?.isNone then
    throw <| .configuration "context is only available for a question state"
  pure state

private partial def ancestry (store : Store) (hash : Hash)
    (seen : Array Hash := #[]) : Result (Array (Hash × State)) := do
  if seen.contains hash then throw <| .storage "cycle in question ancestry"
  let state ← getState store hash
  if state.kind == .evaluation then
    throw <| .storage "question ancestry contains an evaluation state"
  let before ← match state.parent? with
    | some parent => ancestry store parent (seen.push hash)
    | none => pure #[]
  pure (before.push (hash, state))

/-- Original root task and every recorded event on exactly the root-to-question branch.
`task = null` means the root recorded no user task; no later message is substituted for it. -/
def context (store : Store) (hash : Hash) : Result Json := do
  let state ← questionState store hash
  let branch ← ancestry store hash
  let task? := branch[0]?.bind fun (_, root) =>
    if root.kind != .root then none else root.appended.findSome? fun
      | .message (.user text) => some text
      | _ => none
  pure <| .mkObj [
    ("state", hash.hex), ("workspace", state.workspace.hex),
    ("task", task?.map Json.str |>.getD .null),
    ("history", .arr (branch.map fun (id, item) => .mkObj [
      ("state", id.hex), ("kind", item.kind.toString),
      ("events", .arr (item.appended.map eventToJson))]))]

private def validatePath (path : String) : Result Unit := do
  if !Workspaces.safeSnapshotPath path then
    throw <| .configuration "snapshot path must be a clean relative path"

/-- Walk only metadata, checking each ancestor before requesting its children. In particular,
a symlink to a directory is never traversed, even when its target is inside the snapshot. -/
private def entryAt (workspaces : Workspaces) (workspace : Hash) (path : String) :
    Result Workspaces.Entry := do
  validatePath path
  if path.isEmpty then return { name := "", path := "", kind := .directory }
  let mut directory := ""
  let parts := (path.splitOn "/").toArray
  let mut found : Workspaces.Entry := default
  for index in [:parts.size] do
    let name := parts[index]!
    let expected := if directory.isEmpty then name else directory ++ "/" ++ name
    let entries ← workspaces.listEntries workspace directory
    let some entry := entries.find? fun entry => entry.name == name && entry.path == expected
      | throw <| .configuration s!"no such snapshot path: {path}"
    if index + 1 < parts.size && entry.kind != .directory then
      throw <| .configuration s!"snapshot path crosses a non-directory: {expected}"
    found := entry
    directory := expected
  pure found

private def sizeJson (size : Option Nat) : Json := size.map (fun n => (n : Json)) |>.getD .null

/-- Immediate entries at the question's snapshot. The empty path is the project root. -/
def directory (store : Store) (workspaces : Workspaces) (hash : Hash)
    (path : String := "") : Result Json := do
  let state ← questionState store hash
  let entry ← entryAt workspaces state.workspace path
  if entry.kind != .directory then
    throw <| .configuration s!"not a snapshot directory: {path}"
  let entries ← workspaces.listEntries state.workspace path
  pure <| .mkObj [
    ("state", hash.hex), ("workspace", state.workspace.hex), ("path", path),
    ("entries", .arr (entries.map fun e => .mkObj [
      ("name", e.name), ("path", e.path), ("kind", e.kind.toString), ("size", sizeJson e.size)]))]

/-- Maximum size of a file preview, measured in bytes before decoding. -/
def maxFileBytes : Nat := 1024 * 1024

/-- UTF-8 regular files up to 1 MiB are shown verbatim. Links, special files, binary data, and
larger files remain visible as explicit metadata-only results. No working tree is consulted. -/
def file (store : Store) (workspaces : Workspaces) (hash : Hash) (path : String) : Result Json := do
  let state ← questionState store hash
  let entry ← entryAt workspaces state.workspace path
  let response (kind : String) (content : Json := .null) (size := entry.size) := Json.mkObj [
    ("state", hash.hex), ("workspace", state.workspace.hex), ("path", path),
    ("kind", kind), ("content", content), ("size", sizeJson size)]
  if entry.kind == .symlink then return response "symlink"
  if entry.kind != .file then return response "other"
  let some size := entry.size
    | throw <| .storage s!"snapshot file has no size metadata: {path}"
  if size > maxFileBytes then return response "too_large"
  let some bytes ← workspaces.readFile? state.workspace path
    | throw <| .storage s!"snapshot file could not be read: {path}"
  if bytes.size > maxFileBytes then return response "too_large" (size := some bytes.size)
  if bytes.data.contains 0 then return response "binary" (size := some bytes.size)
  match String.fromUTF8? bytes with
  | none => pure (response "binary" (size := some bytes.size))
  | some text => pure (response "text" (.str text) (some bytes.size))

end Alaya.Trajectory.QuestionContext
