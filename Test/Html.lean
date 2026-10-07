import Test.Framework
import Test.Scripted
import Alaya

/-! The HTML report: a page for reading only. Its script asks nothing of a network and offers no
action, and it renders every entry of a forest, and every branch, without an error. -/

namespace HtmlTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Lean (Json)

/-- A forest of two branches: a run that asks a question, is answered, and submits, and a fork
where a person said something instead. -/
private def forest : TestM (Driver.Runtime × String) := do
  match miniRun { tools := #["bash", "submit", "ask_user"], questionTypes := Question.Kind.all } with
  | .error problem => fail problem
  | .ok run =>
    let executor : Executor := { exec := fun _ _ _ _ => pure { output := "a\nb\n", exitCode? := some 0 } }
    let rt ← runtime executor (some (← scriptedModel #[
      { toolCalls := #[call "c1" "bash" "ls"], reasoning? := some "Look first.", finishReason? := some "tool_calls"
        usage? := some { input? := some 900, output? := some 30, cached? := some 400 } },
      responseWith #[askCall "q" "Keep it?"], responseWith #[submitCall "s" "done"],
      responseWith #[submitCall "t" "other"]]))
    let (waiting, _) ← assertOk <| Driver.drive rt run (← start rt run "the task")
    let log ← logAt rt waiting
    let event ← assertOk <| Result.fromExcept Error.input (replyTo (next run log) .yes)
    let (replied, _) ← assertOk <| Driver.append rt.store run waiting event
    let _ ← assertOk <| Driver.drive rt run replied
    let _ ← assertOk <| Driver.append rt.store run waiting (.arrived (.said "never mind"))
    -- A comment on an entry that goes on, an annotation; and one that ends a log.
    let _ ← assertOk <| Notices.comment rt.store waiting "why does it ask?"
    let _ ← assertOk <| Notices.comment rt.store replied "answered by hand"
    let forest ← assertOk rt.store.forest
    pure (rt, ← assertOk <| Html.report rt.store rt.workspaces forest "a <test> report" (scope := run))

def suite : Suite := Testing.suite "html" #[
  iotest "the compiled page is the files in the source tree" do
    -- Lake does not rebuild a module when a file it takes with `include_str` changes.
    for (file, compiled) in [("page.js", Html.script), ("page.css", Html.styles)] do
      if (← IO.FS.readFile ("Alaya" / "App" / "Html" / file)) != compiled then
        throw <| IO.userError s!"{file} changed after Alaya.App.Html was built: remove .lake/build/lib/lean/Alaya/Html.* and rebuild",
  iotest "the page's script asks nothing of a network and offers no action" do
    for api in ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "<form", "import(",
        "localStorage", "eval(", "new Function", "window.open"] do
      if (Html.script.splitOn api).length > 1 || (Html.styles.splitOn api).length > 1 then
        throw <| IO.userError s!"the page uses {api}",

  test "the page carries every entry, its title escaped, and its data where a script cannot end early" do
    let (rt, page) ← forest
    check (contains page "<title>a &lt;test&gt; report</title>") "the title is escaped"
    let forest ← assertOk rt.store.forest
    let some start := (page.splitOn "<script id=\"data\" type=\"application/json\">")[1]?
      | fail "no data"
    let text := (start.splitOn "</script>")[0]!
    let data ← assertOk <| Result.fromExcept Error.storage (Json.parse text)
    let entries ← assertOk <| Result.fromExcept Error.storage (data.getObjVal? "entries" >>= Json.getArr?)
    assertEqual "every entry" entries.size forest.entries.size
    check (entries.any fun e => contains e.compress "Look first.") "the reasoning is there"
    check (entries.any fun e => (e.getObjVal? "question").toOption.any (· != Json.null)) "a waiting question"
    check (entries.all fun e => (e.getObjVal? "t" >>= Json.getNat?).toOption.isSome) "every entry's time",

  test "the page renders every entry and every branch without an error" do
    let node ← IO.Process.output { cmd := "node", args := #["--version"] } |>.toBaseIO
    match node with
    | .error _ => IO.println "  (node is not installed: the page's script is not run)"
    | .ok _ =>
      let (_, page) ← forest
      let file := (← scratch) / "report.html"
      IO.FS.writeFile file page
      let out ← IO.Process.output { cmd := "node", args := #["Test/Html/page-check.js", file.toString] }
      check (out.exitCode == 0) s!"the page failed: {out.stderr}"
      check (out.stdout.startsWith "ok ") out.stdout
]

end HtmlTests
