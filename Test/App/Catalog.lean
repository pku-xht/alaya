import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! The catalog of programs and the session over it: what a program's configuration is, which
call fits its program, what a run of the session looks like, and what a person may append to it
where. -/

namespace CatalogTests

open Testing Scripted
open Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

private def agentSet (path : List String) (value : Lean.Json) : Settings.Setting :=
  { path, value }

private def compressed (json : Lean.Json) : String := json.compress

def suite : Suite := Testing.suite "app/catalog" #[
  test "a program's name alone is its complete defaults, and they read back as themselves" do
    for definition in Catalog.all do
      let defaults ← assertOk <| Catalog.resolve definition.name #[]
      check (defaults.getObjVal? "name").toOption.isNone s!"{definition.name}: the name is the call's, not the configuration's"
      let again ← assertOk <| Catalog.complete definition.name defaults
      assertEqual s!"{definition.name} round-trips" (compressed again) (compressed defaults),

  test "a configuration may leave fields out, but not misname or mistype one" do
    let refused (label : String) (name : String) (json : Lean.Json) (expected : String) : TestM Unit :=
      assertError label (Catalog.complete name json) fun
        | .input m => (m.splitOn expected).length > 1
        | _ => false
    refused "unknown program" "mini-swf" (.mkObj []) "unknown program"
    refused "a name in the configuration" "mini-swe" (.mkObj [("name", "mini-swe")]) "unknown field 'name'"
    refused "typo" "mini-swe" (.mkObj [("step_limt", 1)]) "unknown field 'step_limt'"
    refused "type" "mini-swe" (.mkObj [("recover_output", "yes")]) "must be true or false"
    refused "mode" "mini-vero" (.mkObj [("mode", "both")]) "unknown mode"
    refused "nested" "mini-swe" (.mkObj [("executor", .mkObj [("timeout", 1)])]) "unknown field 'timeout'"
    refused "own field, misnamed" "mini-vero" (.mkObj [("stepp", 1)]) "mask_observations, mode"
    let built ← assertOk <| Catalog.resolve "mini-vero" #[agentSet ["mode"] "codeproof", agentSet ["recover_output"] true]
    assertEqual "tools follow the settings" ((built.getObjVal? "tools").toOption.map (·.compress))
      (some "[\"bash\",\"submit\",\"time_budget\"]")
    -- How commands run is in each command the agent asks for.
    let nested ← assertOk <| Catalog.resolve "mini-swe" #[agentSet ["executor", "timeout_seconds"] (5 : Nat)]
    let timeout? : Option Nat := match Scripted.runOfConfig "mini-swe" nested with
      | .ok run =>
        let asked := Scripted.respond run (Scripted.settle run Scripted.opening)
          { toolCalls := #[{ id := "c", name := "bash", arguments := .mkObj [("command", "ls")] }] }
        match next run asked with
        | .ask { op := .exec _ config, .. } => some config.timeoutSeconds
        | _ => none
      | .error _ => none
    assertEqual "a nested setting" timeout? (some 5)
    assertError "the name is not a setting" (Catalog.resolve "mini-swe" #[agentSet ["name"] "mini-vero"]) fun
      | .input m => (m.splitOn "unknown field 'name'").length > 1
      | _ => false,

  test "a run's configuration is the opening of its agent's call, and the tree names it" do
    let agent ← assertOk <| Catalog.complete "mini-swe" (.mkObj [("model", "gpt-oss-120b"), ("context_reserve", 7)])
    let run := Catalog.run
    let rt ← Scripted.runtime noCommands none
    let project := (← scratch) / "project"
    IO.FS.createDirAll project
    let root ← Scripted.begin rt.store rt.workspaces run project
    let call : RoutineCall := { name := "mini-swe", arguments := agent, environment? := some Scripted.testEnvironment.toJson }
    let (called, _) ← assertOk <| Driver.append rt.store run root call.event
    -- The run reads the call and opens it; the agent's first read of its inbox takes nothing.
    let log := Scripted.settle run (← Scripted.logAt rt called)
    do
      assertEqual "the configuration" ((argumentsAt? log { name := "mini-swe" }).map compressed) (some (compressed agent))
      let mut tip := called
      for event in log.extract 5 log.size do
        tip := (← assertOk <| rt.store.put (← assertOk rt.store.forest) { parent? := some tip, event }).1
      let forest ← assertOk rt.store.forest
      let tree := Render.treeLines (← assertOk <| Render.rows rt.store forest run)
      check (tree.any fun l => (l.splitOn "root  mini-swe, gpt-oss-120b").length > 1) s!"tree names the agent: {tree}",

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
  test "a program brings its scope: an agent's tools and itself, fixed where it is defined" do
    match Catalog.scope.find "mini-swe" with
    | none => fail "mini-swe is a program"
    | some swe =>
      assertEqual "what a call inside MiniSwe can name"
        (#["bash", "submit", "ask_user", "time_budget", "mini-swe", "mini-vero", "grader"].filter
          fun name => (swe.scope.find name).isSome) #["bash", "ask_user", "time_budget", "mini-swe"]
      -- The scope holds MiniSwe itself, with the same scope: what lets it call itself.
      check ((swe.scope.find "mini-swe").any fun inner => (inner.scope.find "bash").isSome)
        "MiniSwe in its own scope has the same scope"
    check (Catalog.scope.find "nothing").isNone "no program of that name",

  test "a call fits its program only with every field its program takes, and none it does not" do
    check (match Catalog.check { testCall with name := "nothing" } with
      | .error message => contains message "unknown program: nothing"
      | .ok () => false) "a call of no program"
    -- Whether a call's arguments fit its program is the CLI's to check before it appends it.
    check (match Catalog.check (graderCall "") with
      | .error message => contains message "needs its command"
      | .ok () => false) "a grader with no command"
    -- Every program is called the same way: a task is a field of an agent's configuration.
    let agentWith (fields : List (String × Json)) : RoutineCall :=
      { name := "mini-swe", arguments := .mkObj ((("model", "gpt-oss-120b") : String × Json) :: fields) }
    check (match Catalog.check (agentWith []) with
      | .error message => contains message "works on a task"
      | .ok () => false) "an agent with no task"
    check (Catalog.check (agentWith [("task", "fix it")]) matches .ok ()) "an agent with its task"
    let tasked : RoutineCall := { name := "grader", arguments := .mkObj [("command", "true"), ("task", "t")] }
    check (match Catalog.check tasked with
      | .error message => contains message "task"
      | .ok () => false) "a grader takes no task: it has no such field",

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
      | none => assertOk <| Catalog.admitsCall next
      | some refusal => assertInput s!"{label}: a call" (Catalog.admitsCall next) refusal
      if notice then assertOk <| Catalog.admitsNotice next
      else assertInput s!"{label}: a notice" (Catalog.admitsNotice next) "no call is running",

  test "a stop ends the session's call, however deep the calls open inside it" do
    let open' (frames : Array Frame) : Array OpenCall :=
      frames.zipIdx.map fun (frame, position) => { frame, call := { name := "x", arguments := .null }, position }
    assertEqual "the session's call" (← assertOk <| Catalog.callToStop (open' #[⟪"session"⟫, ⟪"session", "mini-swe"⟫,
      ⟪"session", "mini-swe", "mini-swe"⟫, ⟪"session", "mini-swe", "mini-swe", "bash"⟫])) ⟪"session", "mini-swe"⟫
    assertInput "the session alone" (Catalog.callToStop (open' #[⟪"session"⟫])) "nothing to stop"
    assertInput "nothing open" (Catalog.callToStop #[]) "nothing to stop",

  test "a run of the session starts waiting, takes one call at a time, and goes on after a call is stopped" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      check (Catalog.idle (next run (settle run (opening "t").pop.pop.pop))) "the session waits for a call"
      let running := settle run (opening "t")
      check (Catalog.running (next run running)) "the agent runs"
      let frame ← assertOk <| Catalog.callToStop (openCalls running)
      assertEqual "a stop ends the agent" frame ⟪"session", "agent"⟫
      let stopped := settle run (running.push (.broke frame "enough"))
      check (Catalog.idle (next run stopped)) "and the session waits for the next"
      assertEqual "the agent's call ended, stopped" ((lastCall? stopped).bind (·.2) |>.map Render.endingSummary) (some "stopped: enough")
]

end CatalogTests
