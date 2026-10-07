import Test.Support.Scripted

/-! The agents as routines, as their modules define them: each brings its scope, its tools and
itself, and a call whose configuration it cannot run on fails in the call's frame, saying why
in the configuration's terms. -/

namespace AgentRoutinesTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.Agents
open Lean (Json)

def suite : Suite := Testing.suite "agents/routines" #[
  test "an agent brings its scope: its tools and itself, fixed where it is defined" do
    let names := #["bash", "submit", "ask_user", "time_budget", "subagent", "mini-swe", "mini-vero", "grader"]
    let reach (routine : Routine Agent) := names.filter fun name => (routine.scope.find name).isSome
    assertEqual "inside MiniSwe" (reach MiniSwe.routine) #["bash"]
    assertEqual "inside MiniVero" (reach MiniVero.routine) #["bash", "ask_user", "time_budget", "mini-vero"]
    assertEqual "inside the grader" (reach Grader.routine) #[]
    -- MiniVero in its own scope has that same scope: what lets a sub-agent call it in turn.
    check ((MiniVero.routine.scope.find "mini-vero").any fun inner => (inner.scope.find "bash").isSome)
      "MiniVero in its own scope has the same scope",

  test "a call an agent cannot run on fails in its frame, in the configuration's terms" do
    let failure (routine : Routine Agent) (arguments : Json) : Option String :=
      match routine.body arguments with
      | .fail problem => some problem
      | _ => none
    let model := Json.mkObj [("model", testModelSpec.toJson)]
    for (label, routine, arguments, said) in [
        ("no task", MiniSwe.routine, model, "mini-swe: it works on a task, and its configuration names none"),
        ("no model", MiniSwe.routine, Json.mkObj [("task", "t")], "mini-swe: it samples a model, and its configuration names none"),
        ("an unknown field", MiniSwe.routine, Json.mkObj [("tsak", "t")], "mini-swe: unknown field 'tsak'"),
        ("no command", Grader.routine, Json.mkObj [], "grader: it needs its command")] do
      match failure routine arguments with
      | none => fail s!"{label}: the agent runs"
      | some problem =>
        assertContains label problem said
        check (!contains problem "--set") s!"{label}: no flag, which is the command line's"
    check (failure MiniSwe.routine (model.setObjVal! "task" "t")).isNone "with both, it runs"
    -- Called so, the call fails in its frame, with the same words.
    let scope := Scope.of #[MiniSwe.routine]
    let log := settle scope #[.arrived (.changed default "w"), .arrived (.called { name := "mini-swe", arguments := model })]
    check (log.any fun | .failed ⟪"mini-swe"⟫ problem => contains problem "works on a task" | _ => false)
      "the call fails in its frame"
]

end AgentRoutinesTests
