import Test.Framework
import Test.Scripted
import Alaya

/-! What the command line prints of a log: a count of tokens, a value, an event and what a run
does next, each in a line, and the forest as a tree of stretches. And the usage a response
reports, read in either API's names and summed along a log. -/

namespace RenderTests

open Testing Alaya Scripted
open Lean (Json)

private def snapshot (c : Char) : Snapshot := ⟨String.ofList (List.replicate 64 c)⟩

private def json (text : String) : Json := (Json.parse text).toOption.getD .null

/-- A usage as it is stored, to compare two: `null` where there is none. -/
private def stored (usage? : Option Chat.TokenUsage) : String :=
  (usage?.map (·.toStored)).getD Json.null |>.compress

/-- An executor that answers every command with `ok`. -/
private def echoing : Executor :=
  { exec := fun _ _ _ _ => pure { output := "ok", exitCode? := some 0 } }

def suite : Suite := Testing.suite "render" #[
  test "tokens, seconds and values read in a line" do
    assertEqual "tokens" (Render.tokens { input? := some 48200, cached? := some 41900, output? := some 1100, reasoning? := some 800 })
      "in 48.2k, 41.9k cached; out 1.1k, 800 reasoning"
    assertEqual "what was not reported is left out" (Render.tokens { input? := some 999 }) "in 999"
    assertEqual "millions" (Render.tokens { output? := some 2500000 }) "out 2.5M"
    assertEqual "nothing reported" (Render.tokens {}) ""
    assertEqual "seconds" (Render.seconds 12345, Render.seconds 0) ("12.3 s", "0.0 s")
    for (value, line) in #[
        ("{\"status\":\"fail\",\"passed\":2,\"total\":3,\"reason\":\"failed: b\",\"checks\":[]}", "fail 2/3"),
        ("[\"a\",2,{\"n\":1}]", "a, 2, n: 1"),
        ("{\"status\":\"Submitted\",\"submission\":\"done\\nand more\"}", "Submitted: done and more"),
        ("{\"status\":\"RepeatedFormatError\",\"submission\":\"\"}", "RepeatedFormatError"),
        ("{\"status\":\"unavailable\"}", "status: unavailable"),
        ("{\"output\":\"\\nfirst line\\nsecond\",\"exit_code\":0,\"error\":null,\"file\":null}", "exit 0: first line"),
        ("{\"output\":\"\",\"exit_code\":null,\"error\":\"timed out\",\"file\":null}", "timed out: "),
        ("{\"output\":\"\",\"exit_code\":null,\"error\":null,\"file\":null}", "no status: "),
        -- A value that only resembles one of Alaya's own is shown as what it holds.
        ("{\"passed\":true,\"output\":\"12 passed\"}", "output: 12 passed, passed: true"),
        ("{\"status\":\"fail\",\"passed\":2,\"total\":3}", "passed: 2, status: fail, total: 3"),
        ("{\"status\":\"Submitted\",\"submission\":\"done\",\"patch\":\"p\"}", "patch: p, status: Submitted, submission: done"),
        ("{}", ""),
        ("\"plain\\ntext\"", "plain text"), ("7", "7"), ("{\"seconds_left\":12}", "seconds_left: 12")] do
      assertEqual value (Render.valueSummary (json value)) line
    assertEqual "a long value is cut" (Render.valueSummary (.str (String.ofList (List.replicate 200 'x')))).length 80,

  test "an event reads in a line" do
    let swe : RoutineCall := { testCall with name := "mini-swe" }
    let lines : Array (Event Agent × String) := #[
      (.arrived (.said "the task\nwith a second line"), "said \"the task with a second line\""),
      (.arrived (.changed (snapshot 'a') "  M a.txt\nfixed"), "changed → aaaaaaaaaaaa:   M a.txt fixed"),
      (.arrived (.replied #[0, 3] (.choice 2)), "replied to 0.3: 2"),
      (.arrived (.replied #[0, 3] .unavailable), "replied to 0.3: unavailable"),
      (.arrived (.replied #[0, 3] .yes), "replied to 0.3: yes"),
      (.asked #[0, 3] { text := "Keep the old API?", form := .yesNo }, "ask \"Keep the old API?\""),
      (swe.event, "call mini-swe, gpt-oss-120b"),
      ((graderCall "python3 /grader/grade.py").event, "call grader"),
      (.heard #[0] #[], "inbox: nothing"),
      (.heard #[0] #[2, 5], "inbox: takes [2, 5]"),
      (.answered #[0] (.sample testModelSpec.toJson (snapshot 'b')) (.error "too long"), "failed: too long"),
      (.answered #[0] (.sample testModelSpec.toJson (snapshot 'b')) (.ok (.response { toolCalls := #[call "c" "bash" "ls -la", submitCall "s" "done"] })),
        "sample → bash ls -la; submit done"),
      (.answered #[0] (.sample testModelSpec.toJson (snapshot 'b')) (.ok (.response { content? := some "hello\nthere" })),
        "sample → says \"hello there\""),
      (.answered #[0, 1] (.exec "ls -la" {}) (.ok (.execution { output := { output := "x", exitCode? := some 2 }, workspace := snapshot 'c' })),
        "exec ls -la → exit 2, cccccccccccc"),
      (.answered #[0, 1] (.exec "sleep 9" {}) (.ok (.execution { output := { output := "", error? := some "timed out" }, workspace := snapshot 'c' })),
        "exec sleep 9 → timed out, cccccccccccc"),
      (.answered #[0, 2] .time (.ok (.timing { spentMs := 1200, budgetMs? := some 60000 })), "time 1.2 s of 60.0 s"),
      (.answered #[0, 2] .time (.ok (.timing { spentMs := 1200 })), "time 1.2 s"),
      (.opened #[0] swe, "open mini-swe, gpt-oss-120b"),
      (.opened #[1] ⟨"grader", (graderCall "sh g.sh").toJson⟩, "open grader"),
      (.opened #[0, 1] ⟨"bash", .mkObj [("command", "ls")]⟩, "open bash \"ls\""),
      (.opened #[0, 1] ⟨"ask_user", (askCall "q" "Keep it?").arguments⟩, "open ask_user \"Keep it?\""),
      (.opened #[0, 1] ⟨"time_budget", .mkObj []⟩, "open time_budget"),
      (.returned #[0] (json "{\"status\":\"Submitted\",\"submission\":\"done\"}"), "return Submitted: done"),
      (.failed #[0, 1] "no routine named bash", "fail: no routine named bash"),
      (.stopped "to grade this point", "stopped: to grade this point"),
      (.commented "the parser goes wrong here\nsee 5.7", "# the parser goes wrong here see 5.7")]
    for (event, line) in lines do
      assertEqual line (Render.eventSummary event) line
    assertEqual "an entry, as the commands that append print it"
      (Render.entryLine (snapshot 'f') 7 (.heard #[0, 2] #[]))
      (String.ofList (List.replicate 64 'f') ++ "  7  0.2  inbox: nothing")
    assertEqual "a notice is in no frame" (Render.entryLine (snapshot 'f') 2 (.stopped "x"))
      (String.ofList (List.replicate 64 'f') ++ "  2  -  stopped: x"),

  test "what a run does next reads in a line" do
    let question : Question := { text := "Keep the old API?", form := .yesNo }
    let request : Chat.Request := { messages := #[.user "a", .user "b"] }
    let lines : Array (Option Question × Next Agent × String) := #[
      (none, .done (json "{\"status\":\"Submitted\",\"submission\":\"\"}"), "done: Submitted"),
      (none, .raised "it broke", "failed: it broke"),
      (some question, .waits #[0, 0] (some question), "waits for a reply: Keep the old API?"),
      (none, .waits #[0] none, "waits for a notice in 0"),
      (none, .waits #[] none, "waits for a call"),
      (none, .ask { frame := #[0], op := .sample testModelSpec request }, "next: sample gpt-oss-120b on a request of 2 messages"),
      (none, .ask { frame := #[0, 1], op := .exec "make" {} }, "next: run make"),
      (none, .ask { frame := #[0, 1], op := .time }, "next: time the run"),
      (none, .hears #[0] #[2], "next: a read of the inbox in 0"),
      (none, .opens #[0, 1] ⟨"bash", .null⟩, "next: open bash"),
      (none, .returns #[0, 1] .null, "next: the return of 0.1"),
      (none, .fails #[0, 1] "x", "next: the failure of 0.1"),
      (none, .mismatch 7, "broken: the event at 7 is no trace of the run"),
      (none, .unguarded #[0], "broken: a loop in 0 reads no event")]
    for (question?, next, line) in lines do
      assertEqual line (Render.nextSummary question? none next) line
    -- Where no call runs, the run stands as its last call ended: an agent with its outcome, a
    -- grader with its verdict.
    let outcome := json "{\"status\":\"Submitted\",\"submission\":\"all done\"}"
    let fail := json "{\"status\":\"fail\",\"passed\":352,\"total\":464,\"checks\":[]}"
    let standings : Array (CallEnd × String) := #[
      (.returned outcome, "done: Submitted: all done"),
      (.returned fail, "done: fail 352/464"),
      (.stopped "to grade this point", "stopped: to grade this point"),
      (.failed "it broke", "failed: it broke")]
    for (ended, line) in standings do
      assertEqual line (Render.nextSummary none (some ended) (.waits #[] none)) line
    assertEqual "a call that waits is no ending" (Render.nextSummary none (some (.returned outcome)) (.waits #[1] none))
      "waits for a notice in 1",

  test "a response's usage is read in either API's names, and summed where both report" do
    let completions := json ("{\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"total_tokens\":120," ++
      "\"prompt_tokens_details\":{\"cached_tokens\":60},\"completion_tokens_details\":{\"reasoning_tokens\":7}}}")
    assertEqual "Chat Completions" (stored (Chat.Response.usageFromJson? completions))
      (stored (some { input? := some 100, output? := some 20, total? := some 120, reasoning? := some 7, cached? := some 60 }))
    let deepseek := json "{\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"prompt_cache_hit_tokens\":40}}"
    assertEqual "DeepSeek's own name for the cache" ((Chat.Response.usageFromJson? deepseek).bind (·.cached?)) (some 40)
    let responses := json ("{\"usage\":{\"input_tokens\":9,\"output_tokens\":4," ++
      "\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens_details\":{\"reasoning_tokens\":2}}}")
    assertEqual "the Responses API" (stored (Chat.Response.usageFromJson? responses))
      (stored (some { input? := some 9, output? := some 4, reasoning? := some 2, cached? := some 3 }))
    assertEqual "no usage" (stored (Chat.Response.usageFromJson? (json "{\"choices\":[]}"))) "null"
    assertEqual "a count stays unknown only where neither reported it"
      (stored (some (addUsage { input? := some 100, output? := some 20, cached? := some 60 }
        { input? := some 9, reasoning? := some 2 })))
      (stored (some { input? := some 109, output? := some 20, reasoning? := some 2, cached? := some 60 })),

  test "the usage of a run is the sum of its responses, at every entry of its log" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let responses : Array Chat.Response := #[
        { (responseWith #[call "c1" "bash" "ls"]) with usage? := some { input? := some 100, output? := some 20, cached? := some 60 } },
        { (responseWith #[submitCall "s"]) with usage? := some { input? := some 150, output? := some 5 } }]
      let (rt, last, _) ← drive run echoing (← scriptedModel responses)
      let forest ← assertOk rt.store.forest
      let usages ← assertOk <| walk (root := run) rt.store forest (#[] : Array (Event Agent × Chat.TokenUsage)) fun seen visit =>
        pure (seen.push (visit.entry.event, visit.usage))
      assertEqual "an entry each" usages.size (forest.path last).size
      assertEqual "at the end" (stored (usages.back?.map (·.2)))
        (stored (some { input? := some 250, output? := some 25, cached? := some 60 }))
      let afterFirst := usages.findSome? fun (event, usage) =>
        if event matches .answered _ (.sample ..) _ then some usage else none
      assertEqual "after the first response" (stored afterFirst)
        (stored (some { input? := some 100, output? := some 20, cached? := some 60 }))
      assertEqual "before any" (stored (usages[0]?.map (·.2))) (stored (some {})),

  test "the tree shows each stretch of a log on a line, forks under where they fork, and how a log ends" do
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let rt ← runtime echoing (some (← cached (← scriptedModel #[
        responseWith #[call "c1" "bash" "ls"], responseWith #[submitCall "s" "the first"],
        responseWith #[submitCall "t" "the other"]])))
      let (first, _) ← assertOk <| Driver.drive rt run (← start rt run "the task")
      let log ← logAt rt first
      let samples := log.zipIdx.filterMap fun (event, i) =>
        if event matches .answered _ (.sample ..) _ then some i else none
      -- A fork from just before the second sample: the same request, drawn again.
      let forest ← assertOk rt.store.forest
      let path := forest.path first
      let at' := samples[1]! - 1
      let (second, _) ← assertOk <| Driver.drive rt run path[at']!
      let forest ← assertOk rt.store.forest
      let lines := Render.treeLines (← assertOk <| Render.rows rt.store forest run)
      let short := Render.short
      assertEqual "a root, the stretch up to the fork, and one for each branch" lines.size 4
      assertEqual "the root is named by its first call" lines[0]! s!"{short path[0]!}  root  agent, gpt-oss-120b"
      assertEqual "the shared stretch, with its last event and no status" lines[1]!
        s!"  {short path[1]!}..{short path[at']!}  1-{at'}  {Render.eventSummary log[at']!}"
      let ends := (forest.path second)
      let branch (path : Array Hash) (submission : String) : String :=
        s!"    {short path[at' + 1]!}..{short path.back!}  {at' + 1}-{path.size - 1}  " ++
          s!"return Submitted: {submission}  [done: Submitted: {submission}]"
      assertEqual "the branches, under it" ((lines.extract 2 4).qsort (· < ·))
        (#[branch path "the first", branch ends "the other"].qsort (· < ·))
      -- A comment on an entry that goes on is no branch: a line under the stretch its entry is in.
      let (note, _) ← assertOk <| Notices.comment rt.store path[2]! "look here"
      let forest ← assertOk rt.store.forest
      let noted := Render.treeLines (← assertOk <| Render.rows rt.store forest run)
      assertEqual "one line more" noted.size 5
      assertEqual "the same stretch" noted[1]! lines[1]!
      assertEqual "the annotation, under it" noted[2]! s!"    {short note}  3  # look here"
      -- At the end of a log, a comment is the end of that log, and the log stands as it stood.
      let (last, _) ← assertOk <| Notices.comment rt.store first "all done"
      let forest ← assertOk rt.store.forest
      let ended := Render.treeLines (← assertOk <| Render.rows rt.store forest run)
      check (ended.any fun line => contains line s!"..{short last}" && contains line "# all done" &&
        contains line "[done: Submitted: the first]") s!"the comment ends its log: {ended}",

  test "a log that calls a program this version does not have is still shown, its call failing" do
    let store ← assertOk <| Store.create ((← scratch) / "entries")
    let call : RoutineCall := { testCall with name := "an-agent-of-another-version" }
    let mut forest ← assertOk store.forest
    let mut parent? : Option Hash := none
    for event in #[.arrived (.changed (snapshot 'a') "the project"), .arrived (.called call), .heard #[] #[1],
        (.opened #[0] call : Event Agent)] do
      let (hash, grown) ← assertOk <| store.put forest { parent?, event }
      forest := grown
      parent? := some hash
    let rows ← assertOk <| Render.rows store forest
    assertEqual "every entry" rows.size 4
    assertEqual "the run is named by its call" (rows[0]!.title?) (some "an-agent-of-another-version, gpt-oss-120b")
    assertEqual "and its end says the call fails" (rows.back?.bind (·.status?)) (some "next: the failure of 0")
]

end RenderTests
