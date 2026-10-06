import Test.Support.Framework
import Alaya.Agents.Verdict

/-! The verdict on a grader's TAP: pass, fail, or error (`Alaya.Agents.Verdict`). -/

namespace GraderTests

open Testing
open Alaya.Agents.Grader

private def tap (lines : List String) : String := String.join (lines.map (· ++ "\n"))

def suite : Suite := Testing.suite "agents/grader" #[
  test "complete TAP with every check ok is a pass, with each check recorded" do
    let v := verdict (tap ["TAP version 14", "1..2", "ok 1 - first", "ok 2 - second"])
    assertEqual "status" v.status .pass
    assertEqual "checks" v.checks #[{ ok := true, name := "first" }, { ok := true, name := "second" }]
    assertEqual "reason" v.reason ""
    assertEqual "score" (Verdict.score v.checks) (2, 2),

  test "a failing check is a fail that names it" do
    let v := verdict (tap ["1..3", "ok 1 - a", "not ok 2 - b", "not ok 3"])
    assertEqual "status" v.status .fail
    assertEqual "reason" v.reason "failed: b, #3"
    assertEqual "score" (Verdict.score v.checks) (1, 3),

  test "a failing TODO or SKIP check is not a failure, and says why" do
    let v := verdict (tap ["1..2", "ok 1 - a", "not ok 2 - b # TODO later"])
    assertEqual "status" v.status .pass
    assertEqual "todo" (v.checks.map (·.directive)) #["", "todo later"]
    assertEqual "counted as ok" (Verdict.score v.checks) (2, 2),

  test "a failing subtest fails the verdict even under an ok point" do
    let v := verdict (tap ["1..1", "# Subtest: group", "    1..1", "    not ok 1", "ok 1 - group"])
    assertEqual "status" v.status .fail
    assertEqual "reason" v.reason "failed: group",

  test "a stream that is not complete TAP is an error, with the reason" do
    for (label, stdout, reason) in [
        ("no output", "", "no plan"),
        ("no plan", tap ["ok 1", "ok 2"], "no plan"),
        ("cut short", tap ["1..3", "ok 1"], "planned 3 test points, but found 1"),
        ("bail out", tap ["1..2", "ok 1", "Bail out! database gone"], "Bail out! database gone"),
        ("an ID outside the plan", tap ["1..1", "ok 2"], "test point id 2 is greater than the plan end")] do
      let v := verdict stdout
      assertEqual s!"{label}: status" v.status .error
      assertEqual s!"{label}: reason" v.reason reason,

  test "a grader that did not finish is an error, however complete its TAP" do
    let v := verdict (tap ["1..1", "ok 1"]) (stopped? := some "timed out after 5 seconds")
    assertEqual "status" v.status .error
    assertEqual "reason" v.reason "timed out after 5 seconds"
    assertEqual "checks still recorded" v.checks.size 1,

  test "a failing check in an invalid stream is an error, not a fail" do
    let v := verdict (tap ["1..3", "not ok 1"])
    assertEqual "status" v.status .error
]

end GraderTests
