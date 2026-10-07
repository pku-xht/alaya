import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! The HTML report: a page for reading only. Its script asks nothing of a network and offers no
action, and it renders every entry of a forest, and every branch, without an error. -/

namespace HtmlTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Lean (Json)

/-- A forest of two branches: a run that asks a question, is answered, and submits, and a fork
where a person said something instead. -/
private def forest : TestM (Driver.Runtime × String) := do
  match veroRun { questionTypes := Question.Kind.all } with
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

def suite : Suite := Testing.suite "app/html" #[
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

  test "the report shows how each command changed the workspace, with the text when it is cheap" do
    withVero {} fun run => do
      let commands := #["write a.txt one", "write .venv/x 1", "write a.txt two", "rm a.txt", "write .venv/x 2"]
      let rt ← filingRuntime (← scriptedModel (commands.mapIdx (fun i command =>
        responseWith #[call s!"c{i}" "bash" command]) ++ #[responseWith #[submitCall "s"]]))
      let _ ← assertOk <| Driver.drive rt run (← start rt run)
      let forest ← assertOk rt.store.forest
      -- The directory to fold is given as a person types it, with its slash.
      let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" #[".venv/"] run
      let entries ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "entries" >>= Json.getArr?)
      let changesOf (command : String) : TestM Json := do
        let some row := entries.find? fun row =>
            (row.getObjVal? "e" >>= (·.getObjVal? "command") >>= Json.getStr?).toOption == some command
          | fail s!"no entry for {command}"
        pure ((row.getObjVal? "changes").toOption.getD .null)
      let listed (changes : Json) : String := ((changes.getObjVal? "changes").toOption.getD .null).compress
      let folded (changes : Json) : String := ((changes.getObjVal? "folded").toOption.getD .null).compress
      assertStringEq "a file added" (listed (← changesOf commands[0]!))
        "[{\"kind\":\"added\",\"new\":\"one\\n\",\"old\":null,\"path\":\"a.txt\"}]"
      assertStringEq "a file modified" (listed (← changesOf commands[2]!))
        "[{\"kind\":\"modified\",\"new\":\"two\\n\",\"old\":\"one\\n\",\"path\":\"a.txt\"}]"
      assertStringEq "a file removed" (listed (← changesOf commands[3]!))
        "[{\"kind\":\"removed\",\"new\":null,\"old\":\"two\\n\",\"path\":\"a.txt\"}]"
      -- What changes under a folded directory is counted, not listed.
      let made ← changesOf commands[1]!
      assertStringEq "nothing listed" (listed made) "[]"
      assertStringEq "a folded directory made" (folded made)
        "[{\"added\":1,\"modified\":0,\"prefix\":\".venv\",\"removed\":0}]"
      assertEqual "but counted" ((made.getObjVal? "count" >>= Json.getNat?).toOption) (some 1)
      assertStringEq "a file modified under it" (folded (← changesOf commands[4]!))
        "[{\"added\":0,\"modified\":1,\"prefix\":\".venv\",\"removed\":0}]"
      -- An entry that leaves the workspace as it was carries no change.
      check (entries.all fun row => (row.getObjVal? "e" >>= (·.getObjVal? "k") >>= Json.getStr?).toOption == some "exec"
          || (row.getObjVal? "changes").toOption == some Json.null) "a change on an entry that is no command",
  test "the report carries every sample's request, exactly, and every entry once" do
    withVero {} fun run => do
      let responses := #[responseWith #[call "a" "bash" "echo one", call "b" "bash" "echo two"],
        responseWith #[],   -- a format error: the view substitutes a user turn
        responseWith #[submitCall "s"], responseWith #[submitCall "t"]]
      -- Behind the cache, as a run's model is: the fork's draw asks for one response more.
      let rt ← runtime (echoing) (some (← cached (← scriptedModel responses)))
      let tip ← start rt run
      let (first, _) ← assertOk <| Driver.drive rt run tip
      -- A fork from just before the last sample, so the forest has two branches.
      let log ← logAt rt first
      let forest ← assertOk rt.store.forest
      let some lastSample := (log.zipIdx.filter fun (e, _) => e matches .answered _ (.sample ..) _).back?
        | fail "no sample"
      let _ ← assertOk <| Driver.drive rt run (forest.path first)[lastSample.2 - 1]!
      let forest ← assertOk rt.store.forest
      let page ← assertOk <| Html.dataJson rt.store rt.workspaces forest "t" (scope := run)
      let entries ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "entries" >>= Json.getArr?)
      assertEqual "every entry once" entries.size forest.entries.size
      let envelopes ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "envelopes" >>= Json.getArr?)
      -- Assemble each request as the page does, from what each adds to the one before it.
      let rec messages (fuel i : Nat) : Array Json :=
        match fuel with
        | 0 => #[]
        | fuel + 1 =>
          let request := (entries[i]!.getObjVal? "request").toOption.getD .null
          let added := ((request.getObjVal? "added" >>= Json.getArr?).toOption).getD #[]
          match (request.getObjVal? "base" >>= Json.getNat?).toOption with
          | some base => messages fuel base ++ added
          | none => added
      let byHash := entries.zipIdx.map fun (e, i) => ((e.getObjVal? "h" >>= Json.getStr?).toOption.getD "", i)
      for (request, _) in samplesOf run log do
        let digest := Model.requestDigest request
        -- The entry that answered this request, in the first branch.
        let found := log.findIdx? (fun | .answered _ (.sample _ d) _ => d == digest | _ => false)
        let some position := found | fail "no answer for a request"
        let some (_, i) := byHash.find? (·.1 == ((forest.path first)[position]!).hex) | fail "entry missing"
        let row := entries[i]!.getObjVal? "request" |>.toOption.getD .null
        let envelope := envelopes[(row.getObjVal? "envelope" >>= Json.getNat?).toOption.getD 0]!
        let assembled := envelope.setObjVal! "messages" (.arr (messages entries.size i))
        assertStringEq "request" assembled.compress request.toJson.compress
]

/-- The page's own script, run in a fake DOM by node. -/
def pageSuite : Suite := Testing.suite "app/html.page" #[
  test "the page renders every entry and every branch without an error" do
    let (_, page) ← forest
    let file := (← scratch) / "report.html"
    IO.FS.writeFile file page
    let out ← IO.Process.output { cmd := "node", args := #["Test/App/Html/page-check.js", file.toString] }
    check (out.exitCode == 0) s!"the page failed: {out.stderr}"
    check (out.stdout.startsWith "ok ") out.stdout
]

end HtmlTests
