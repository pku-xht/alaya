import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! The session that `alaya new` starts a run with: it waits for a call, makes it in a frame of
its own, and waits again; and what a person may append to it where. -/

namespace SessionTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

def suite : Suite := Testing.suite "app/session" #[
  test "a grader is a call like any: the run waits for it, opens it in a frame of its own, and it gives the verdict" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      -- The agent ends, and the run waits for the next call.
      let log := respond run (settle run opening) (responseWith #[submitCall "s" "done"])
      check ((next run log) matches .waits ⟪"session"⟫ none) "the run waits for a call"
      check (((lastCall? log).bind (·.2)) matches some (.returned _)) "the agent returned"
      -- The grader: the run takes the call, opens it in `grader`, and its command is asked for there,
      -- with its stderr apart.
      let called := log.size
      let log := settle run (log.push (graderCall "sh g.sh").event)
      check (log.any fun | .heard ⟪"session"⟫ notices => notices == #[called] | _ => false) "the session takes the call"
      check (log.any fun | .opened ⟪"session", "grader"⟫ { name := "grader", .. } => true | _ => false) "the grader opens in a frame of its own"
      let .ask first := next run log | fail "the grader's command is asked for"
      assertEqual "in its frame" first.frame ⟪"session", "grader"⟫
      check (first.op matches .exec "sh g.sh" { merge := false, .. }) "the command, its stderr apart"
      -- Its verdict is the value of its call, and the run waits again.
      let graded := answer run log (.execution { output := { output := "1..1\nok 1\n", stderr? := some "", exitCode? := some 0 }, workspace := default })
      check ((next run graded) matches .waits ⟪"session"⟫ none) "the run waits for the next call"
      match lastCall? graded with
      | some (opened, some (.returned verdict)) =>
        assertEqual "the grader's verdict" (opened.name, Agents.Grader.verdictStatus verdict) ("grader", "pass")
      | _ => fail "the grader returned its verdict",
  test "the session admits a call only where it waits for one, and a notice only while a call runs" do
    let sample : OpRequest Agent := { frame := ⟪"session", "mini-swe"⟫, op := .time }
    let question : Question := { text := "Go on?", form := .yesNo }
    let opened (frame : Frame) : Next Agent := .mark (.opened frame { name := "x", arguments := .null })
    -- What the run does next, whether a call may be appended there, and whether a notice may.
    let table : Array (String × Next Agent × Option String × Bool) := #[
      ("the session waits", .waits ⟪"session"⟫ none, none, false),
      ("a call runs", .ask sample, some "a call is running", true),
      ("a call waits for a message", .waits ⟪"session", "mini-swe"⟫ none, some "a call is running", true),
      ("a question waits", .waits ⟪"session", "mini-swe", "ask_user"⟫ (some question), some "a call is running", true),
      ("a call read, not yet opened", opened ⟪"session", "mini-swe"⟫, some "a call to make here already", false),
      ("a tool opens in a call", opened ⟪"session", "mini-swe", "bash"⟫, some "a call is running", true),
      ("a call returns", .mark (.returned ⟪"session", "mini-swe"⟫ .null), some "a call is running", true),
      ("the outside waits for the run's call", .waits ⟪⟫ none, some "a call to make here already", false),
      ("the run is over", .ended (.ok .null), some "the run is over", false)]
    for (label, next, refusal?, notice) in table do
      match refusal? with
      | none => assertOk <| Session.admitsCall next
      | some refusal => assertInput s!"{label}: a call" (Session.admitsCall next) refusal
      if notice then assertOk <| Session.admitsNotice next
      else assertInput s!"{label}: a notice" (Session.admitsNotice next) "no call is running",
  test "a stop ends the session's call, however deep the calls open inside it" do
    let open' (frames : Array Frame) : Array OpenCall :=
      frames.zipIdx.map fun (frame, position) => { frame, call := { name := "x", arguments := .null }, position }
    assertEqual "the session's call" (← assertOk <| Session.callToStop (open' #[⟪"session"⟫, ⟪"session", "mini-swe"⟫,
      ⟪"session", "mini-swe", "mini-swe"⟫, ⟪"session", "mini-swe", "mini-swe", "bash"⟫])) ⟪"session", "mini-swe"⟫
    assertInput "the session alone" (Session.callToStop (open' #[⟪"session"⟫])) "nothing to stop"
    assertInput "nothing open" (Session.callToStop #[]) "nothing to stop",
  test "a run of the session starts waiting, takes one call at a time, and goes on after a call is stopped" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      check (Session.idle (next run (settle run (opening "t").pop.pop.pop))) "the session waits for a call"
      let running := settle run (opening "t")
      check (Session.running (next run running)) "the agent runs"
      let frame ← assertOk <| Session.callToStop (openCalls running)
      assertEqual "a stop ends the agent" frame ⟪"session", "agent"⟫
      let stopped := settle run (running.push (.broke frame "enough"))
      check (Session.idle (next run stopped)) "and the session waits for the next"
      assertEqual "the agent's call ended, stopped" ((lastCall? stopped).bind (·.2) |>.map Render.endingSummary) (some "stopped: enough")
]

end SessionTests
