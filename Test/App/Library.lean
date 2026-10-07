import Test.Support.Framework
import Alaya

/-! Alaya as a library: an application of its own, Alaya's commands over a catalog that adds a
program, a model and a provider to Alaya's, and a command of its own. -/

namespace LibraryTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App
open Lean (Json)

/-- A program of the application's own: it returns its configuration's `text`. -/
private def echo : Program where
  routine := { name := "echo", body := fun arguments => pure ((arguments.getObjVal? "text").toOption.getD "")
               scope := .empty }
  complete json := match json with
    | .obj _ => if (json.getObjVal? "text").isOk then .ok json else .ok (json.setObjVal! "text" "")
    | other => .error s!"expected an object, got {other.compress}"

/-- The application's catalog: Alaya's, with a program, a model in place of one of Alaya's, and
a provider. -/
private def catalog : Catalog := Builtin.catalog ++ {
  programs := #[echo]
  models := #[{ name := "gpt-oss-120b", contextTokens? := some 4096 }, { name := "my-model" }]
  providers := #[{ name := "local", baseUrl := "http://localhost:8000/v1", keyVar := "LOCAL_API_KEY" }] }

/-- A command of the application's own: it exits 7. -/
private def hello : Cli.Command where
  name := "hello"
  summary := "Exit 7."
  spec := pure fun _ => pure 7

private def app : Cli.App := Commands.app "myalaya" catalog (extra := #[hello])

def suite : Suite := Testing.suite "app/library" #[
  test "a catalog adds to Alaya's, an entry in place of one of the same name" do
    assertEqual "the programs" (catalog.programs.map (·.name))
      #["basic", "mini-swe", "mini-vero", "grader", "echo"]
    assertEqual "a model in place of Alaya's" ((catalog.model? "gpt-oss-120b").bind (·.contextTokens?)) (some 4096)
    assertEqual "a model of its own" ((catalog.model? "my-model").map (·.name)) (some "my-model")
    assertEqual "a provider of its own" ((catalog.provider? "local").map (·.baseUrl)) (some "http://localhost:8000/v1")
    check ((catalog.provider? "dgx").isSome) "Alaya's providers stay"
    let config ← assertOk <| catalog.resolve "echo" #[{ path := ["text"], value := "hi" }]
    assertEqual "its program's configuration" config.compress "{\"text\":\"hi\"}"
    check (((Session.scope catalog).find "echo").isSome) "a run's call may name it"
    check (((Session.scope Builtin.catalog).find "echo").isNone) "Alaya's may not",

  iotest "an application runs Alaya's commands over its catalog, and its own" do
    if (← app.run ["hello"]) != 7 then throw <| IO.userError "its own command"
    if (← app.run ["config", "--program", "echo", "--json"]) != 0 then throw <| IO.userError "config of its program"
    if (← app.run ["config", "--program", "nothing", "--json"]) == 0 then throw <| IO.userError "an unknown program"
    if !app.commands.any (·.name == "resume") then throw <| IO.userError "Alaya's commands"
]

end LibraryTests
