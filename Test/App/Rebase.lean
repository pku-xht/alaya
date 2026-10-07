import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! The rebase command's part: a log reconfigured as the current version of its programs reads
it, with settings over the configuration each call fits, and what a rebase says of itself. -/

namespace AppRebaseTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

private def setting (text : String) : TestM Settings.Setting := match Settings.parse text with
  | .ok setting => pure setting
  | .error problem => fail problem

/-- A run of MiniSwe, as Alaya runs it: the session, the agent's call, and its two rounds. -/
private def reconfiguredRun : TestM (Log Agent) := do
  let run := Session.scope
  let rt ← runtime echoingCommands (some (← scriptedModel #[
    responseWith #[call "c1" "bash" "echo one"], responseWith #[sentinelCall "s"]]))
  let project := (← scratch) / "project"
  IO.FS.createDirAll project
  let root ← begin rt.store rt.workspaces run project
  let config ← assertOk <| Catalog.resolve "mini-swe"
    #[{ path := ["model"], value := "gpt-oss-120b" }, { path := ["task"], value := "t" }]
  let swe : RoutineCall := { name := "mini-swe", arguments := config, environment? := some testEnvironment.toJson }
  let (called, _) ← assertOk <| Driver.append rt.store run root swe.event
  let (last, _) ← assertOk <| Driver.drive rt run called
  let log ← logAt rt last
  pure log

def suite : Suite := Testing.suite "app/rebase" #[
  test "a field that changes no request keeps the whole log, under the new opening" do
    let run := Session.scope
    let log ← reconfiguredRun
    let tuned := rebase run (← assertOk <| Rebase.reconfigure log #[← setting "max_consecutive_format_errors=7"])
    check tuned.divergence?.isNone "the whole log holds"
    let some opening := tuned.log.findSome? fun | (.opened ⟪"session", "mini-swe"⟫ opened, _) => some opened | _ => none
      | fail "the opening of the agent"
    assertEqual "the new configuration" ((opening.arguments.getObjVal? "max_consecutive_format_errors").toOption.map (·.compress)) (some "7"),

  test "another model's parameters are another operation, from the first sample on" do
    let log ← reconfiguredRun
    let other := rebase Session.scope (← assertOk <| Rebase.reconfigure log #[← setting "model.params.reasoning_effort=high"])
    let some divergence := other.divergence? | fail "the log diverges"
    check (divergence.found matches .answered _ (.sample ..) _) "at the first response"
    check (divergence.expected matches .ask { op := .sample { params := .obj _, .. } _, .. }) "where the agent samples the other",

  test "the session's call is no program's, and is left as it is; a field no call takes is refused" do
    let log ← reconfiguredRun
    let reconfigured ← assertOk <| Rebase.reconfigure log #[← setting "max_consecutive_format_errors=7"]
    assertEqual "the session, untouched" (reconfigured.filter (· matches .opened ⟪"session"⟫ _)).size 1
    check (reconfigured.any fun | .opened ⟪"session"⟫ opened => opened == Session.call | _ => false) "as it was called"
    assertInput "an unknown field" (Rebase.reconfigure log #[← setting "no_such_field=1"]) "fits no call",

  test "what a rebase says of itself: how much held, and each event from outside left out" do
    let log ← reconfiguredRun
    let held := rebase Session.scope log
    assertEqual "all of it" (Rebase.summary held log.size) s!"all {log.size} events hold"
    let late := log.push (.arrived (.said "late"))
    let shortened := rebase Session.scope ((late.extract 0 7).push (.answered ⟪"session", "mini-swe"⟫ .time (.ok (.timing { spentMs := 1 }))) ++ late.extract 7 late.size)
    check (shortened.divergence?.isSome) "a log with an answer the agent never asked for diverges"
    assertContains "the summary says where" (Rebase.summary shortened late.size) "where the revised agent goes on with"
    check (Rebase.droppedLines shortened |>.any (contains · "left out")) "and the message after it is left out"
]

end AppRebaseTests
