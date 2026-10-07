import Test.Support.Scripted

/-! The agents as routines, as their modules define them: each brings its scope, its tools and
itself, and a call whose configuration it cannot run on fails in the call's frame, saying why
in the configuration's terms. -/

namespace AgentRoutinesTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.Agents
open Lean (Json)

/-- That `value`, written, reads back as itself, written again. -/
private def roundTrip (label : String) (codec : Codec β) (value : β) : TestM Unit :=
  let again := match codec.read (codec.write value) with
    | .ok read => (codec.write read).compress
    | .error problem => s!"unread: {problem}"
  assertEqual label again (codec.write value).compress

def suite : Suite := Testing.suite "agents/routines" #[
  test "an agent brings its scope: its tools and itself, fixed where it is defined" do
    let names := #["bash", "submit", "ask_user", "time_budget", "subagent", "mini-swe", "mini-vero", "grader"]
    let reach (routine : Routine Agent) := names.filter fun name => (routine.scope.find name).isSome
    assertEqual "inside the basic agent" (reach Basic.routine) #["bash", "ask_user"]
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
      "the call fails in its frame",

  test "a tool's result reads back as it was written, and its routine reads the arguments its tool makes" do
    roundTrip "a command" Tools.Bash.result { output := { output := "hi\n", exitCode? := some 0 }, file? := some "/alaya/outputs/a.txt" }
    roundTrip "a timeout" Tools.Bash.result { output := { output := "", error? := some "'sleep 9' timed out after 5 seconds" } }
    roundTrip "seconds left" Tools.TimeBudget.result (some 42)
    roundTrip "no budget" Tools.TimeBudget.result none
    for reply in [Reply.yes, .no, .choice 2, .noneOfAbove, .text "Keep it.\nAnd say why.", .unavailable] do
      roundTrip s!"the reply {reply.line}" Tools.AskUser.result reply
    roundTrip "an outcome" Outcome.codec { status := "Submitted", submission := "done" }
    roundTrip "an outcome with a reason" Outcome.codec { status := "ContextExceeded", reason? := some "refused" }
    -- What a tool's call makes, its routine reads with the tool's own `read`.
    let made := (Tools.AskUser.tool #[.yesNo]).call (.mkObj [("question_type", "yes_no"), ("question", "Keep it?")])
    let some made := made.toOption | fail "a yes/no question with no options is a call"
    assertEqual "the routine reads it" ((Tools.AskUser.spec Question.Kind.all).read made.arguments |>.toOption |>.map (·.form))
      (some .yesNo)
    let ran := (Tools.Bash.tool {}).call (.mkObj [("command", "ls")])
    assertEqual "a command, as its routine reads it" (ran.toOption.bind fun made => ((Tools.Bash.spec).read made.arguments).toOption) (some "ls")
]

end AgentRoutinesTests
