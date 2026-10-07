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
    let run := Session.scope
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

  test "the command line says how to give a field the configuration leaves empty" do
    for (program, arguments, flag) in [("mini-swe", Json.mkObj [("task", "t")], "--set model=NAME"),
        ("mini-swe", Json.mkObj [("model", "gpt-oss-120b")], "--set task=TEXT or --set-file task=FILE"),
        ("grader", Json.mkObj [], "--set command=CMD")] do
      match Catalog.check { name := program, arguments } with
      | .ok () => fail s!"{program}: fits"
      | .error message => assertContains program message flag
    match Catalog.check { name := "mini-swe", arguments := Json.mkObj [("tsak", "t")] } with
    | .ok () => fail "an unknown field fits"
    | .error message => check (!contains message "--set") "a field no program takes has no flag to give",

  test "a provider serves a model under its own name, or the name its route gives" do
    let route (provider model : String) : TestM (Except String Provider.Route) := do
      let some p := Catalog.provider? provider | fail s!"no provider {provider}"
      pure (p.route model)
    let nameOf (provider model : String) : TestM (Option String) := do
      pure ((← route provider model).toOption.map (·.name))
    assertEqual "apiyi, its own name" (← nameOf "apiyi" "deepseek-v4.1-flash") (some "deepseek-v4.1-flash")
    assertEqual "xmcp's name" (← nameOf "xmcp" "deepseek-v4.1-flash") (some "ds/deepseek-v4-flash")
    assertEqual "fireworks' name" (← nameOf "fireworks" "deepseek-v4.1-flash")
      (some "accounts/fireworks/models/deepseek-v4p1-flash")
    match ← route "fireworks" "gpt-oss-120b" with
    | .error m => check ((m.splitOn "does not serve gpt-oss-120b").length > 1) m
    | .ok _ => fail "fireworks serves only its routes",
  test "a run that sends items back needs a Responses route, and apiyi serves gpt-6-luna through one" do
    let some spec := Catalog.model? "gpt-6-luna" | fail "no luna"
    assertEqual "luna sends items back" (toString spec.echoReasoning) "items"
    let some apiyi := Catalog.provider? "apiyi" | fail "no apiyi"
    let route ← assertOk <| Result.fromExcept Error.input (apiyi.route "gpt-6-luna")
    check (route.api == .responses) "apiyi's route for luna is not Responses"
    check (Provider.check apiyi spec route).toOption.isSome "apiyi refuses luna"
    let some yunwu := Catalog.provider? "yunwu" | fail "no yunwu"
    let chat ← assertOk <| Result.fromExcept Error.input (yunwu.route "gpt-6-luna")
    match Provider.check yunwu spec chat with
    | .error m => check ((m.splitOn "need the Responses API").length > 1) m
    | .ok _ => fail "luna through Chat Completions",
  test "a model's name alone is its defaults, and settings over an agent's model are checked" do
    let some defaults := Catalog.model? "gpt-oss-120b" | fail "no gpt-oss-120b"
    assertEqual "context from the list" defaults.contextTokens? (some 131072)
    let modelOf (config : Lean.Json) : TestM Models.Spec :=
      match Models.Spec.read ((config.getObjVal? "model").toOption.getD .null) with
      | .ok spec => pure spec
      | .error problem => fail problem
    let set ← modelOf (← assertOk <| Catalog.resolve "mini-swe"
      #[agentSet ["model"] "gpt-oss-120b", agentSet ["model", "params", "temperature"] (1 : Nat),
        agentSet ["model", "context_tokens"] (65536 : Nat)])
    assertEqual "params" set.params.compress "{\"temperature\":1}"
    assertEqual "context" set.contextTokens? (some 65536)
    for (label, settings, expected) in [
        ("unknown", #[agentSet ["model", "temperature"] (1 : Nat)], "unknown field 'temperature'"),
        ("protected", #[agentSet ["model", "params", "model"] "x"], "params cannot set 'model'"),
        ("name", #[agentSet ["name"] "x"], "unknown field 'name'")] do
      assertError label (Catalog.resolve "mini-swe" (#[agentSet ["model"] "gpt-oss-120b"] ++ settings)) fun
        | .input m => (m.splitOn expected).length > 1
        | _ => false
    assertInput "a model named alone that the list does not name" (Catalog.resolve "mini-swe" #[agentSet ["model"] "nope"])
      "unknown model: nope"
    -- A whole spec of a model the list does not name, as a log holds one, is kept as it is written.
    let unlisted : Models.Spec := { name := "a-model-of-another-day", contextTokens? := some 4096 }
    let kept ← assertOk <| Catalog.complete "mini-swe" (.mkObj [("model", unlisted.toJson), ("task", "t")])
    assertEqual "kept" ((kept.getObjVal? "model").toOption.map (·.compress)) (some unlisted.toJson.compress)
    let ran := Agents.MiniSwe.routine.body kept
    check (!(ran matches Computation.fail _)) "and the agent runs on it, with no list to consult"
    match Settings.parse "model.params.reasoning_effort=high" with
    | .ok s => check (s.path == ["model", "params", "reasoning_effort"] && s.value == "high") "parsed"
    | .error m => fail m
]

end CatalogTests
