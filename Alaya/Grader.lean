import Lean.Data.Json
import Alaya.Tap
import Alaya.Hash

/-!
A grader, and its verdict, from the TAP it printed on stdout (`Alaya.Tap`, `docs/log-schema.md`
§4). A grader is an external program: a command in a container of its own image on a checkout of
the workspace, with trusted files mounted at `/grader`. The grader's exit status is recorded but decides nothing: "the checks ran and some failed"
and "the grader crashed" can share a status, and only an incomplete TAP stream tells them apart.

- **error**: the grader did not finish (it timed out, or could not be started), or its TAP is
  invalid as a whole (no plan, a count or ID that disagrees with it, …), or it bailed out;
- **fail**: otherwise, a test point failed, or a subtest did;
- **pass**: otherwise.
-/

namespace Alaya

open Lean (Json)

/-- A grader: a name for a reader, the command, the pinned image it runs in, the snapshot of its
trusted input, and how long it may take; 0 is no limit. -/
structure Grader where
  name : String := "grader"
  command : String
  image : String
  input? : Option Snapshot := none
  timeoutSeconds : Nat := 900
  deriving Inhabited

def Grader.toJson (grader : Grader) : Json :=
  .mkObj [("name", grader.name), ("command", grader.command), ("image", grader.image),
    ("input", grader.input?.map (Json.str ·.hex) |>.getD .null),
    ("timeout_seconds", grader.timeoutSeconds)]

def Grader.fromJson (json : Json) : Except String Grader := do
  let input? ← match json.getObjVal? "input" with
    | .ok (.str hex) => if Hash.valid hex then pure (some ⟨hex⟩) else throw s!"not a snapshot: {hex}"
    | .ok .null | .error _ => pure none
    | .ok other => throw s!"a grader's input is a snapshot, not {other.compress}"
  pure {
    name := (json.getObjVal? "name" >>= Json.getStr?).toOption.getD "grader"
    command := ← json.getObjVal? "command" >>= Json.getStr?
    image := ← json.getObjVal? "image" >>= Json.getStr?
    input?
    timeoutSeconds := (json.getObjVal? "timeout_seconds" >>= Json.getNat?).toOption.getD 900 }

end Alaya

namespace Alaya.Grader

inductive Status where
  | pass | fail | error
  deriving BEq, Repr, Inhabited

def Status.toString : Status -> String
  | .pass => "pass" | .fail => "fail" | .error => "error"

def Status.ofString? : String -> Option Status
  | "pass" => some .pass | "fail" => some .fail | "error" => some .error | _ => none

/-- One top-level test point. `ok` is whether it counts as passed: a failing `TODO` or `SKIP`
point does not count as failed, and says so in `directive`. -/
structure Check where
  ok : Bool
  name : String
  /-- `todo` or `skip`, with its reason after a space, when the point has one. -/
  directive : String := ""
  deriving BEq, Repr, Inhabited

structure Verdict where
  status : Status
  checks : Array Check := #[]
  /-- Why the status is `error`, or which checks made it `fail`; empty for `pass`. -/
  reason : String := ""
  deriving Repr, Inhabited

private def checkOf (point : Tap.Point) : Check :=
  let directive := match point.directive with
    | .none => ""
    | .todo reason => ("todo " ++ reason).trimAscii.toString
    | .skip reason => ("skip " ++ reason).trimAscii.toString
  { ok := !point.failed, name := point.description, directive }

/-- The verdict on a grader's stdout. `stopped?` says why the grader did not finish, when it did
not: a timeout, or a failure to start it. -/
def verdict (stdout : String) (stopped? : Option String := none) : Verdict :=
  let document := Tap.parse stdout
  let checks := document.points.map checkOf
  let problems := stopped?.toArray ++
    (document.bailout?.map fun reason => s!"Bail out! {reason}".trimAscii.toString).toArray ++
    document.errors
  if !problems.isEmpty then
    { status := .error, checks, reason := "; ".intercalate problems.toList }
  else if document.ok then
    { status := .pass, checks }
  else
    let failed := document.points.filter (·.failed)
    let subtests := document.points.filter fun p => p.subtest?.any (!·.ok)
    let names := (failed ++ subtests).map fun p =>
      if p.description.isEmpty then s!"#{p.id}" else p.description
    { status := .fail, checks, reason := s!"failed: {", ".intercalate names.toList}" }

/-- How many checks passed, out of how many. -/
def Verdict.score (checks : Array Check) : Nat × Nat :=
  ((checks.filter (·.ok)).size, checks.size)

end Alaya.Grader
