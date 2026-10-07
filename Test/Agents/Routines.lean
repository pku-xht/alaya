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
    assertEqual "inside the basic agent" (reach Basic.routine) #["bash", "ask_user"]
    assertEqual "inside MiniSwe" (reach MiniSwe.routine) #["bash"]
    assertEqual "inside MiniVero" (reach MiniVero.routine) #["bash", "ask_user", "time_budget", "subagent", "mini-vero"]
    assertEqual "inside the grader" (reach Grader.routine) #[]
    -- MiniVero in its own scope has that same scope, and so has the subagent routine there:
    -- what lets a sub-agent find MiniVero, and call it in turn.
    check ((MiniVero.routine.scope.find "mini-vero").any fun inner => (inner.scope.find "bash").isSome)
      "MiniVero in its own scope has the same scope"
    check ((MiniVero.routine.scope.find "subagent").any fun sub => (sub.scope.find "mini-vero").isSome)
      "the subagent routine finds MiniVero in its scope",

  test "a call an agent cannot run on fails in its frame, in the configuration's terms" do
    let failure (routine : Routine Agent) (arguments : Json) : Option String :=
      match routine.body arguments with
      | .fail problem => some problem.reason
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
    check (log.any fun | .failed ⟪"mini-swe"⟫ (.refused problem) => contains problem "works on a task" | _ => false)
      "the call fails in its frame",

  test "a call of a tool has its settings over the model's arguments, and its routine reads them" do
    let ask (kinds : Array Question.Kind) (arguments : Json) : Except String Question :=
      Tools.AskUser.read ((Tools.AskUser.tool kinds).arguments arguments)
    let yesNo := Json.mkObj [("question_type", "yes_no"), ("question", "Keep it?")]
    assertEqual "a yes/no question with no options" ((ask #[.yesNo] yesNo).toOption.map (·.form))
      (some Question.Form.yesNo)
    check (match ask #[.openEnded] yesNo with
      | .error problem => contains problem "question_type: open_ended"
      | .ok _ => false) "a kind the agent did not allow, refused by the routine"
    check ((ask #[.yesNo] (yesNo.setObjVal! "question_types" (.arr #["single_choice"]))).toOption.isSome)
      "the model cannot widen the kinds: the settings win"
    let bash := Tools.Bash.tool { timeoutSeconds := 7 }
    let made := bash.arguments (.mkObj [("command", "ls"), ("executor", .mkObj [("timeout_seconds", 1)])])
    assertEqual "a command, as its routine reads it" (Tools.Bash.command made).toOption (some "ls")
    assertEqual "the agent's executor, not the model's"
      ((made.getObjVal? "executor" >>= (·.getObjVal? "timeout_seconds") >>= Json.getNat?).toOption) (some 7)
    let sub := Tools.Subagent.tool "mini-vero" (.mkObj [("task", "the parent's"), ("mode", "proof")])
    assertEqual "a sub-agent: the agent, its configuration but its task, and the model's task"
      (sub.arguments (.mkObj [("task", "write b.txt")])).compress
      "{\"agent\":\"mini-vero\",\"configuration\":{\"mode\":\"proof\"},\"task\":\"write b.txt\"}"
]

end AgentRoutinesTests
