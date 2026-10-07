import Alaya.Runtime.Agent
import Alaya.Base.Fields
import Alaya.Base.Tap

/-! The grader: a routine that runs one command, in its call's container, and returns the verdict
read off the TAP the command prints on stdout (`Alaya.Base.Tap`). Its trusted input — the tests,
a reference — is in its image, so a call needs nothing besides the image and the command. What
the command writes lands in the workspace, after the agent's last version: the agent is over by
then, and nothing reads it but a person. See `docs/agents.md` §3.

The grader's exit status is recorded but decides nothing: "the checks ran and some failed" and
"the grader crashed" can share a status, and only an incomplete TAP stream tells them apart.

- **error**: the grader did not finish (it timed out, or could not be started), or its TAP is
  invalid as a whole (no plan, a count or ID that disagrees with it, …), or it bailed out;
- **fail**: otherwise, a test point failed, or a subtest did;
- **pass**: otherwise. -/

namespace Alaya.Agents.Grader

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

/-! ## The verdict -/

inductive Status where
  | pass | fail | error
  deriving BEq, Repr, Inhabited

def Status.toString : Status -> String
  | .pass => "pass" | .fail => "fail" | .error => "error"

def Status.ofString? : String -> Option Status
  | "pass" => some .pass | "fail" => some .fail | "error" => some .error | _ => none

/-- One top-level test point. `ok` is whether it counts as passed: a failing `TODO` or `SKIP`
point does not count as failed, and says so in `directive`; a point whose subtest failed does,
whatever the point itself says. -/
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

/-- Whether a point failed: itself, or a subtest under it. -/
private def failedPoint (point : Tap.Point) : Bool :=
  point.failed || point.subtest?.any (!·.ok)

private def checkOf (point : Tap.Point) : Check :=
  let directive := match point.directive with
    | .none => ""
    | .todo reason => ("todo " ++ reason).trimAscii.toString
    | .skip reason => ("skip " ++ reason).trimAscii.toString
  { ok := !failedPoint point, name := point.description, directive }

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
    let names := (document.points.filter failedPoint).map fun p =>
      if p.description.isEmpty then s!"#{p.id}" else p.description
    { status := .fail, checks, reason := s!"failed: {", ".intercalate names.toList}" }

/-- How many checks passed, out of how many. -/
def Verdict.score (checks : Array Check) : Nat × Nat :=
  ((checks.filter (·.ok)).size, checks.size)

/-! ## The routine -/

structure Config where
  /-- The command, which prints TAP on stdout; what it prints on stderr is kept apart. -/
  command : String := ""
  /-- How long it may take, in seconds; 0 is no limit. -/
  timeoutSeconds : Nat := 900
  deriving Inhabited

def fields : Fields Config := #[
  .of "command" .string (·.command) fun v c => { c with command := v },
  .of "timeout_seconds" .nat (·.timeoutSeconds) fun v c => { c with timeoutSeconds := v }]

def Config.toJson (config : Config) : Json := fields.toJson config

/-- Reads a configuration; a field left out is the default, and an unknown one is an error. -/
def Config.fromJson (json : Json) : Except String Config := fields.read json {}

/-- The verdict as the grader returns it: the status, the score, why, every check, and how the
command ended. -/
def verdictJson (verdict : Grader.Verdict) (output : Output) : Json :=
  let (passed, total) := Grader.Verdict.score verdict.checks
  .mkObj [("status", verdict.status.toString), ("passed", passed), ("total", total),
    ("reason", verdict.reason),
    ("checks", .arr (verdict.checks.map fun check =>
      .mkObj [("ok", check.ok), ("name", check.name), ("directive", check.directive)])),
    ("exit_code", output.exitCode?.map (fun c => (c.toNat : Json)) |>.getD .null)]

/-- The status of a verdict: `pass`, `fail` or `error`. -/
def verdictStatus (verdict : Json) : String :=
  (verdict.getObjVal? "status" >>= Json.getStr?).toOption.getD "error"

/-- The grader: its command, and the verdict on what it printed. -/
def computation (config : Config) : Computation Agent Json := do
  let ran ← exec config.command { timeoutSeconds := config.timeoutSeconds, merge := false }
  return verdictJson (Grader.verdict ran.output.output ran.output.failure?) ran.output

/-- The grader as a routine. A call's arguments are its configuration; one with no command fails
in the call's frame. -/
def routine : Routine Agent where
  name := "grader"
  body arguments := match Config.fromJson arguments with
    | .error problem => .fail s!"grader: {problem}"
    | .ok config =>
      if config.command.trimAscii.isEmpty then
        .fail "grader: it needs its command, which prints TAP, and its configuration names none"
      else computation config
  scope := .empty

end Alaya.Agents.Grader
