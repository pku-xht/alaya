import Test.Framework
import Test.DirectoryWorkspaces
import Test.Scripted
import Test.Container
import Alaya

/-! Tests of what follows from an agent being a pure function of its log: calls answered by
reference, and each effect paired with the event that answers it. -/

namespace EffectsTests

open Testing
open Scripted
open Alaya
open Alaya.Agent (Event Log Dialogue Effect Outcome)
open Alaya.Agent.MiniSwe
open Alaya.Trajectory
open Alaya.Driver

/-- A mini agent's runtime over a scripted model behind the persistent cache, as runs have it. -/
private def runtime (responses : Array Chat.Response) (config : Config := {})
    (executor? : Option Executor := none) : TestM Runtime := do
  let model ← scriptedModel responses
  let cached ← assertOk <| Cache.persistent model { directory := (← scratch) / "cache" }
  let store ← assertOk <| Trajectory.Store.create ((← scratch) / "states")
  let work ← workDir
  let executor ← match executor? with
    | some executor => pure executor
    | none => containerExecutor
  pure { store, workspaces := ← workspaces, workDir := work, outputsDir := work.withFileName "outputs"
         executor, model := cached, agent := agent config }

private def mkRoot (rt : Runtime) (config : Config := {}) : TestM Hash := do
  let project := (← scratch) / "proj"
  IO.FS.createDirAll project
  assertOk <| createRoot rt.store rt.workspaces (initialLog config "t" testUname) project (← testImage)
    (some "t") (agent := config.toJson) (model := testModel)

private def outputs (log : Log) : Array String :=
  log.filterMap fun | .executed _ _ _ output _ => some output.output | _ => none

/-- What an agent asks for next, in a few words. -/
private def said : Effect ⊕ Outcome -> String :=
  Sum.elim Effect.describe (s!"stop: {·.status}")

def suite : Suite := Testing.suite "effects" #[
  test "a sample between a call and its answer does not hide the turn's calls" do
    let turn := responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"]
    let log : Log := #[.placed default, .sampled default .turn turn, ran "x" (response := 1),
      .sampled default (.other "summary") { content? := some "so far: listed the files" }]
    match (agent {}).next log with
    | .inl (.exec { response := 1, index := 1 } "pwd" _) => pure ()
    | other => fail s!"expected b to run next, got: {said other}"
    let index := log.index
    assertEqual "one turn" index.turns.size 1
    assertEqual "two model calls" index.responses 2
    assertEqual "a's answer joined to it" ((index.call? { response := 1, index := 0 }).bind (·.answer?)) (some 2)
    assertEqual "b pending" (index.pending.map (·.call.id)) #["b"]
    assertEqual "a call's id is read off the log" (index.callId? { response := 1, index := 0 }) (some "a"),

  test "a call id the provider reuses names a new call, answered on its own" do
    let log : Log := #[.placed default, .sampled default .turn (responseWith #[call "c1" "bash" "ls"]),
      ran "x" (response := 1), .sampled default .turn (responseWith #[call "c1" "bash" "pwd"])]
    match (agent {}).next log with
    | .inl (.exec { response := 3, index := 0 } "pwd" _) => pure ()
    | other => fail s!"expected the second c1 to run, got: {said other}"
    let index := log.index
    assertEqual "the turn each event is part of" index.turnOf #[0, 1, 1, 2]
    assertEqual "the latest workspace" index.workspace? (some default),

  test "a command sees the branch's outputs only when it asks to, as plain mini does not" do
    for (config, expected) in #[(({} : Config), "0"), ({ recoverOutput := true }, "1")] do
      let outputsDir := (← workDir).withFileName s!"outputs-{expected}"
      -- Each command answers how many output files it could see.
      let executor : Executor := {
        exec := fun _ _ _ _ => do
          let seen ← if ← outputsDir.pathExists then pure (← outputsDir.readDir).size else pure 0
          pure { output := toString seen, exitCode? := some 0 }
        uname := pure default }
      let rt ← runtime #[responseWith #[call "a" "bash" "true"], responseWith #[call "b" "bash" "true"]]
        config (executor? := some executor)
      let store ← assertOk <| Trajectory.Store.create ((← scratch) / s!"states-{expected}")
      let rt := { rt with outputsDir, store, agent := agent config }
      let root ← mkRoot rt config
      let first ← stepped <| step rt root
      let second ← stepped <| step rt first
      assertEqual s!"b's view of a's output, recover_output {config.recoverOutput}"
        (outputs (← assertOk <| logOf rt.store second)).back? (some expected),

  test "an event answers the effect it was recorded for, and no other" do
    let ref : Agent.CallRef := { response := 1, index := 0 }
    let other : Agent.CallRef := { ref with index := 1 }
    let w0 : Hash := ⟨"w0"⟩
    let w1 : Hash := ⟨"w1"⟩
    let request : Chat.Request := { messages := #[.user "hi"] }
    let response : Chat.Response := { content? := some "hello" }
    let sample := Effect.sample .turn request
    match sample.answer? (sample.event response) with
    | some answer => assertEqual "the response" answer.content? (some "hello")
    | none => fail "a response answers its sample"
    check ((Effect.sample (.other "summary") request).answer? (sample.event response)).isNone "another purpose"
    check ((Effect.sample .turn { messages := #[.user "bye"] }).answer? (sample.event response)).isNone
      "another request"
    let exec := Effect.exec ref "ls" {}
    let executed := exec.event ({ output := "a\n", exitCode? := some 0 }, w1)
    match exec.answer? executed with
    | some (output, result) =>
      assertEqual "the output" output.output "a\n"
      check (result == w1) "the snapshot after"
    | none => fail "a run answers its exec"
    check ((Effect.exec ref "ls" { timeoutSeconds := 5 }).answer? executed).isNone "run another way"
    check ((Effect.exec ref "pwd" {}).answer? executed).isNone "another command"
    check ((Effect.exec other "ls" {}).answer? executed).isNone "another call"
    let record := Effect.record ref (.str "v")
    check (record.answer? (record.event ())).isSome "a recorded result answers its record"
    check ((Effect.record ref (.str "w")).answer? (record.event ())).isNone "another value"
    check ((Effect.record other (.str "v")).answer? (record.event ())).isNone "another call"
    let ask := Effect.ask ref { text := "which?" }
    let reply : Option Agent.Reply := ask.answer? (ask.event (.text "this"))
    check (reply == some (.text "this")) "a reply answers its question"
    let read (question : Agent.Question) (content : Lean.Json) : Option Agent.Reply :=
      (Effect.ask ref question).answer? (.recorded ref content)
    let yesNo : Agent.Question := { text := "keep it?", form := .yesNo }
    check (read { text := "which?" } (.str "yes") == some (.text "yes")) "read as the form says: here, the person's words"
    check (read yesNo (.str "yes") == some .yes) "and here, a yes"
    check (read yesNo (.str "maybe")).isNone "a value the form does not accept answers nothing"
    check (read yesNo Agent.Reply.unavailable.toJson == some .unavailable) "that the person cannot answer fits any form"
    let reading : Option (Nat × Option Nat) := Effect.time.answer? (Effect.time.event (5, some 9))
    check (reading == some (5, some 9)) "a reading"
    check (Effect.time.answer? executed).isNone "a run is no reading"
    check (executed.isAnswer && !(Event.placed w0).isAnswer && !(Event.told (.user "m")).isAnswer)
      "answers, and what the world places"
]

end EffectsTests
