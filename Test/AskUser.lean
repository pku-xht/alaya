import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! The optional typed-question tool, from configuration through recorded replies and forks.
All model responses are scripted; an executor that counts calls detects unwanted side effects. -/

namespace AskUserTests

open Testing Alaya Alaya.Agent Alaya.Trajectory
open Alaya.Agent.MiniSwe

private def contains (text part : String) : Bool := (text.splitOn part).length > 1

private def testUname : Uname :=
  { system := "Linux", release := "test", version := "test", machine := "test" }

private def args (question : String := "Which interpretation?\nThe examples disagree.")
    (options : Array String := #["Use the written specification", "Use the examples"])
    (questionType : String := "single_choice") : Lean.Json :=
  .mkObj [("question_type", questionType), ("question", question),
    ("options", .arr (options.map Lean.Json.str))]

private def ask (id : String := "q") (arguments : Lean.Json := args) : Chat.ToolCall :=
  { id, name := "ask_user", arguments }

private def bash : Chat.ToolCall :=
  { id := "b", name := "bash", arguments := .mkObj [("command", "touch must-not-run")] }

private def submit : Chat.ToolCall :=
  { id := "s", name := "submit", arguments := .mkObj [("message", "done")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def enabled : Config := { askUser := true }

private def countingExecutor : IO (Executor × IO.Ref Nat) := do
  let calls ← IO.mkRef 0
  pure ({ exec := fun _ _ _ => do
            calls.modify (· + 1)
            pure { output := "unexpected execution", exitCode? := some 0 }
          uname := pure testUname }, calls)

private def scripted (responses : Array Chat.Response) : IO (Model × IO.Ref (Array Chat.Request)) := do
  let index ← IO.mkRef 0
  let requests ← IO.mkRef #[]
  pure ({
    identity := .mkObj [("model", "scripted-ask-user")]
    sample := fun request => do
      Result.fromIO Error.cache <| requests.modify (·.push request)
      pure { next := do
        let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
        match responses[i]? with
        | some r => pure r
        | none => throw <| Error.protocol "scripted model exhausted" } }, requests)

private def sampleWith (model : Model) (a : Agent) (dialogue : Dialogue) : Result Chat.Response := do
  (← model.sample { messages := dialogue, tools := a.tools }).next

private def expectDone (directive : Directive) (status : String) : TestM Unit := do
  match directive with
  | .done outcome => assertEqual "stop status" outcome.status status
  | _ => fail s!"expected {status}"

private def expectSample (directive : Directive) : TestM Unit := do
  match directive with
  | .sample => pure ()
  | _ => fail "expected another model sample"

private def resumed (result : Result Stopped) : TestM Hash := do
  let stopped ← assertOk result
  check (!stopped.outOfTime) "this continuation must stop at its question or outcome, not its time budget"
  pure stopped.state

private def checkQuestionResult (dialogue : Dialogue) (answer : Lean.Json)
    (expectedArguments : Lean.Json := args) : TestM Unit := do
  let question := dialogue.findSome? fun
    | .assistant _ calls _ => calls.find? (·.id == "q")
    | _ => none
  let some question := question | fail "the question must remain an assistant tool call"
  assertEqual "original question arguments" question.arguments.compress expectedArguments.compress
  check (!(dialogue.any fun
    | .user text => contains text "Tool call error:"
    | _ => false)) "a valid question must not become a format error"
  let shown := dialogue.findSome? fun
    | .tool "q" (.str text) => some text
    | _ => none
  let some shown := shown | fail "the answer must remain the matching tool observation"
  -- Mini's view renders observations as JSON; decoding it must recover the exact answer.
  let decoded ← assertOk <| Result.fromExcept Error.protocol (Lean.Json.parse shown)
  assertEqual "answer in the model view" decoded.compress answer.compress

private def checkQuestionView (dialogue : Dialogue) (answer : String)
    (expectedArguments : Lean.Json := args) : TestM Unit :=
  checkQuestionResult dialogue (.str answer) expectedArguments

def suite : Suite := Testing.suite "ask_user" #[
  test "both families keep their default prompts and tools when asking is disabled" do
    for family in Families.all do
      let minimal ← assertOk <| Families.instanceOf (.mkObj [("family", family.name)])
      let off ← assertOk <| Families.instanceOf
        (.mkObj [("family", family.name), ("ask_user", false)])
      let timeTools := if family.name == "mini-vero" then #["time_budget"] else #[]
      assertEqual "default tools" (minimal.tools.map (·.name)) (#["bash", "submit"] ++ timeTools)
      assertEqual "explicit off config" off.config.compress minimal.config.compress
      assertEqual "default serializes ask_user false"
        (minimal.config.getObjValAs? Bool "ask_user").toOption (some false)
      let defaultPath : System.FilePath := "agents" / s!"{family.name}-default.json"
      let defaultText ← IO.FS.readFile defaultPath
      let defaultJson ← assertOk <| Result.fromExcept Error.configuration (Lean.Json.parse defaultText)
      assertEqual "default JSON explicitly contains ask_user false"
        (defaultJson.getObjValAs? Bool "ask_user").toOption (some false)
      let request (spec : Families.Instance) : Lean.Json :=
        ({ messages := spec.view (spec.initialLog "task" testUname), tools := spec.tools } : Chat.Request).toJson
      assertEqual "explicit off opening" (request off).compress (request minimal).compress
      check (!contains (request minimal).compress "ask_user") "the default opening must not offer questions"
      let bad := response #[ask]
      match (minimal.view #[.response bad])[0]? with
      | some (Chat.Message.user text) => check (contains text "Unknown tool 'ask_user'") "disabled is unknown"
      | _ => fail "disabled ask should be a format error"
    match parseActions (response #[ask]) with
    | .formatError _ => pure ()
    | _ => fail "the default parser must still reject ask_user",

  test "opening and repair prompts permit a lone ask with or without output recovery" do
    let incompatible := #["AT LEAST ONE bash tool call", "needs to use the 'bash' tool at least once",
      "AT LEAST ONE tool call: bash, or read_output", "Every response needs at least one tool call: 'bash'",
      "exactly one bash tool call"]
    for recover in #[false, true] do
      for family in Families.all do
        let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name),
          ("ask_user", true), ("recover_output", recover)])
        let opening := (built.initialLog "task" testUname).foldl (init := "") fun text event =>
          match event with
          | .message (.user message) => text ++ message
          | _ => text
        check (contains opening "Call ask_user alone") "the opening must permit a question on its own"
        for phrase in incompatible do
          check (!contains opening phrase) s!"the opening still conflicts with a lone question: {phrase}"
      for timeBudget in #[false, true] do
        let config : Config := { recoverOutput := recover, timeBudget }
        for reason in #["stop", "length", "tool_calls"] do
          let malformed : Chat.Response := { content? := some "unfinished", finishReason? := some reason }
          match parseActions malformed { config with askUser := true } with
          | .formatError message =>
            check (contains message "ask_user") "every repair path must retain the offered question tool"
            for phrase in incompatible do
              check (!contains message phrase) s!"the repair still requires bash: {phrase}"
            if reason != "stop" then
              check (contains message s!"finish_reason={reason}") "the truncation reason must be preserved"
              check (contains message "exactly one tool call") "the truncation hint must allow a lone question"
          | _ => fail "an unfinished response needs a repair"
          let old := if reason == "stop" then
              withExtraTools config (sentinelToSubmit (formatErrorTemplate.replace "{{error}}" "error"))
            else withExtraTools config (formatErrorCut.replace "{{ finish_reason }}" reason)
          assertEqual "asking off retains the original repair"
            (formatErrorMessage "error" false (some reason) config) old
        match parseActions (response #[ask]) { config with askUser := true } with
        | .actions actions => check (actions.size == 1) "a lone ask is valid with recovery and time-budget tools"
        | _ => fail "other optional tools must not prevent a lone ask",

  test "JSON files enable asking in both families, round-trip, and reject wrong types" do
    for family in Families.all do
      let path := (← scratch) / s!"{family.name}.json"
      let json := Lean.Json.mkObj [("family", family.name), ("ask_user", true),
        ("recover_output", true), ("step_limit", 11), ("max_consecutive_format_errors", 2)]
      IO.FS.writeFile path json.pretty
      let built ← assertOk <| Families.fromFile path
      let timeTools := if family.name == "mini-vero" then #["time_budget"] else #[]
      assertEqual "enabled tools" (built.tools.map (·.name))
        (#["bash", "submit", "read_output"] ++ timeTools ++ #["ask_user"])
      assertEqual "recordable flag" (built.config.getObjValAs? Bool "ask_user").toOption (some true)
      let restored ← assertOk <| Families.instanceOf built.config
      assertEqual "complete config round-trip" restored.config.compress built.config.compress
      let (executor, _) ← countingExecutor
      assertEqual "agent identity" (restored.build executor).identity.compress built.config.compress
      check ((built.initialLog "task" testUname).any fun
        | .message (.user text) => contains text "ask_user"
        | _ => false) "the enabled agent must tell the model it can ask"
      for bad in #[Lean.Json.null, .str "true", .num 1, .arr #[], .mkObj []] do
        assertError "ask_user type" (Families.instanceOf
          (.mkObj [("family", family.name), ("ask_user", bad)])) fun
            | .configuration message => contains message "ask_user" && contains message "true or false"
            | _ => false,

  test "single choice adds a platform answer while retaining model candidates verbatim" do
    let question := "  Which rule applies?\nContext: α < β.  "
    let candidates := #[" Keep α ", "Change β\nwith evidence"]
    let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question (args question candidates))
    assertEqual "single-choice type" form.questionType QuestionType.singleChoice
    assertEqual "original question" form.text question
    assertEqual "original choices" form.options candidates
    let rendered := form.render
    check (rendered.startsWith question) "the question and context must retain their original wording"
    check (contains rendered "\n1.  Keep α \n2. Change β\nwith evidence")
      "numbered candidates must retain their wording"
    check (contains rendered "none_of_above. None of the above") "the platform adds its reserved answer"
    assertEqual "one platform label" (rendered.splitOn "None of the above").length 2
    check (contains rendered "Select exactly one answer") "the answer is single choice"
    check (contains rendered "plain text none_of_above") "the reserved answer has an explicit encoding"
    check (!contains rendered "OTHER") "single choice must not append a custom-answer input"
    match parseActions (response #[ask "q" (args question candidates)]) enabled with
    | .actions actions =>
      match actions[0]? with
      | some (MiniSwe.Action.ask "q" parsed) =>
        assertEqual "waiting type" parsed.questionType form.questionType
        assertEqual "waiting choices" parsed.options candidates
        assertEqual "waiting text" parsed.text question
      | _ => fail "expected the question directive's action"
    | _ => fail "valid choices should parse"
    for (questionType, expectedType) in #[("yes_no", QuestionType.yesNo),
        ("open_ended", QuestionType.openEnded)] do
      let arguments := args question #[] questionType
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question arguments)
      assertEqual "question type" form.questionType expectedType
      assertEqual "original question" form.text question
      assertEqual "no model-defined choices" form.options #[]
      check (!contains form.render "OTHER") s!"{questionType} must not invent a custom-answer choice"
      check (!contains form.render "none_of_above") s!"{questionType} must not offer the reserved single-choice answer"
      match parseActions (response #[ask "q" arguments]) enabled with
      | .actions actions =>
        match actions[0]? with
        | some (MiniSwe.Action.ask "q" parsed) =>
          assertEqual "waiting type" parsed.questionType expectedType
          assertEqual "waiting text" parsed.text question
          assertEqual "waiting options" parsed.options #[]
        | _ => fail s!"expected the {questionType} question action"
      | _ => fail s!"valid {questionType} question should parse",

  test "invalid question types, arguments, and mixed calls cannot run a command" do
    let malformed : Array Lean.Json := #[
      .null,
      .mkObj [("question", "q"), ("options", .arr #[.str "a", .str "b"])],
      .mkObj [("question_type", "single_choice"), ("options", .arr #[.str "a", .str "b"])],
      .mkObj [("question_type", "single_choice"), ("question", "q")],
      (args).setObjVal! "question_type" "unknown",
      (args).setObjVal! "question_type" "multiple_choice",
      (args).setObjVal! "question_type" "",
      (args).setObjVal! "question_type" Lean.Json.null,
      (args).setObjVal! "question_type" 7,
      (args).setObjVal! "question" 7,
      args " \n\t" #["a", "b"],
      args " \n\t" #[] "yes_no", args " \n\t" #[] "open_ended",
      (args).setObjVal! "options" "a,b",
      (args).setObjVal! "options" (.arr #[.str "a", .num 2]),
      args "q" #[], args "q" #["a"], args "q" #["a", " \t"],
      args "q" #["a", "a"], args "q" #["a", " a "],
      args "q" #["yes", "no"] "yes_no",
      args "q" #["one"] "yes_no",
      args "q" #["a", "b"] "open_ended",
      args "q" #["one"] "open_ended",
      (args).setObjVal! "unexpected" true]
    let cases := malformed.map (fun json => response #[ask "q" json]) ++ #[
      response #[bash, ask], response #[ask, bash], response #[ask, submit],
      response #[submit, ask],
      response #[ask, ask "second"],
      response #[{ (ask) with invalidArguments? := some "{\"question_type\":" }]]
    for bad in cases do
      match parseActions bad enabled with
      | .formatError _ => pure ()
      | _ => fail s!"accepted malformed or mixed response: {bad.toolCalls.map (·.name)}"
      let (executor, calls) ← countingExecutor
      let (model, _) ← scripted #[bad]
      let config := { enabled with maxConsecutiveFormatErrors := 1 }
      let a := agent executor config
      let (_, stop) ← assertOk <| Agent.run a { dir := ← scratch } (sampleWith model a)
        (initialLog config "task" testUname)
      match stop with
      | .outcome outcome => assertEqual "rejected turn outcome" outcome.status "RepeatedFormatError"
      | .question _ _ => fail "an invalid question must not wait for an answer"
      assertEqual "executor calls" (← calls.get) 0,

  test "typed questions record candidate, none-of-above, yes/no, and open replies after reconstruction" do
    let cases : Array (String × Lean.Json × Array String) := #[
      ("yes_no", args "Keep the public API?\nContext: callers depend on it." #[] "yes_no",
        #["yes", "no"]),
      ("single_choice", args "Which change should be included?\nSelect one answer."
        #["Keep α", "Check β\nwith evidence",
          "Document γ with a detailed explanation of the public API, compatibility constraints, boundary cases, and expected output."],
        #["1", "2", "3", "none_of_above", " \t\r2 \n"]),
      ("open_ended", args "How should we handle the boundary case?" #[] "open_ended",
        #["  Keep the public API.\nPreserve the literal \"[]\" in the response.\n理由：边界条件不同。\n",
          "[]", String.ofList [Char.ofNat 0x200B]])]
    for family in Families.all do
      for (questionType, arguments, answers) in cases do
        let base := (← scratch) / s!"{family.name}-{questionType}"
        IO.FS.createDirAll base
        let configPath := base / "agent.json"
        IO.FS.writeFile configPath (Lean.Json.mkObj [("family", family.name), ("ask_user", true)]).pretty
        let built ← assertOk <| Families.fromFile configPath
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        IO.FS.writeFile (project / "untouched.txt") "original\n"
        let (executor, calls) ← countingExecutor
        let continuations := (List.replicate answers.size (response #[submit])).toArray
        let (model, requests) ← scripted (#[response #[ask "q" arguments]] ++ continuations)
        let rt : Runtime := { store, workspaces, workDir := base / "work", executor, model, agent := built.build executor }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config)
        let waitingHash ← resumed <| resume rt "scripted" root (fun _ => pure ())
        let questionState ← assertOk <| getState store waitingHash
        assertEqual "waiting kind" questionState.kind Kind.question
        let some question := questionState.question? | fail "missing recorded question"
        assertEqual "call id" question.callId "q"
        let expected ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question arguments)
        assertEqual "recorded question wording" question.text expected.text
        assertEqual "recorded question type" question.questionType expected.questionType
        assertEqual "recorded question options" question.options expected.options
        check (!contains question.toQuestion.render "OTHER") "the waiting record must not add a custom option"
        -- The log's call summary is truncated, so `show` must render the complete question
        -- separately, including long choices and the requested answer format.
        let shown ← assertOk <| showLines store waitingHash
        assertEqual "show retains complete question, long options, and answer format"
          (shown.find? (·.startsWith "question ")) (some ("question " ++ expected.render))
        assertEqual "waiting workspace" questionState.workspace (← assertOk <| getState store root).workspace
        assertEqual "unanswered question count" (← assertOk <| waiting store).size 1
        assertEqual "unanswered question has no reply children" (← assertOk <| children store waitingHash).size 0
        assertError "cannot step while waiting" (stepOnce rt "scripted" waitingHash) fun
          | .configuration _ => true
          | _ => false
        assertEqual "only question sampled" (← requests.get).size 1
        -- Changing the source file cannot disable the capability on a recorded run.
        IO.FS.writeFile configPath (Lean.Json.mkObj [("family", family.name), ("ask_user", false)]).pretty
        -- Reopening the store must reconstruct the form before enforcing its answer rules.
        let reopened ← assertOk <| Store.create (base / "states")
        let some persistedQuestion := (← assertOk <| getState reopened waitingHash).question?
          | fail "the persisted question disappeared"
        assertEqual "reopened type" persistedQuestion.questionType expected.questionType
        assertEqual "reopened choices" persistedQuestion.options expected.options
        let mut replyHashes : Array Hash := #[]
        for answer in answers do
          let answered ← assertOk <| reply reopened waitingHash answer
          check (!replyHashes.contains answered) "different answers must create distinct reply branches"
          replyHashes := replyHashes.push answered
          let state ← assertOk <| getState store answered
          assertEqual "reply kind" state.kind Kind.reply
          assertEqual "reply parent" state.parent? (some waitingHash)
          assertEqual "reply workspace" state.workspace questionState.workspace
          check state.question?.isNone "an answer, including none_of_above, must not still be a waiting question"
          check state.agent?.isNone "the reply must inherit configuration rather than duplicate it"
          match state.appended.toList with
          | [.observation "q" (.str raw)] => assertEqual "raw answer" raw answer
          | _ => fail "a reply must append exactly the original answer as the asking call's observation"
          check (← assertOk <| waiting store).isEmpty
            "an explicit answer, including none_of_above, must differ from not answering"
          let some recorded ← assertOk <| agentOf store answered | fail "missing root configuration"
          assertEqual "recorded root config" recorded.compress built.config.compress
          let restored ← assertOk <| Families.instanceOf recorded
          checkQuestionView (restored.view (← assertOk <| logOf store answered)) answer arguments
          let rebuilt : Runtime := { rt with agent := restored.build executor }
          let final ← resumed <| resume rebuilt "scripted" answered (fun _ => pure ())
          let finalState ← assertOk <| getState store final
          assertEqual "resumed submission" (finalState.outcome?.map (·.status)) (some "Submitted")
          assertEqual "final workspace" finalState.workspace questionState.workspace
          let some request := (← requests.get).back? | fail "missing continuation request"
          checkQuestionView request.messages answer arguments
        assertEqual "distinct reply branches" (← assertOk <| children store waitingHash).size answers.size
        assertEqual "one question and one continuation per answer" (← requests.get).size (answers.size + 1)
        assertEqual "no command ran for asking or replying" (← calls.get) 0
        let report ← assertOk <| Html.dataJson store workspaces built.view built.tools
        let states ← assertOk <| Result.fromExcept Error.storage (report.getObjVal? "states" >>= Lean.Json.getArr?)
        let some reportQuestion := states.find? fun json =>
            (json.getObjValAs? String "hash").toOption == some waitingHash.hex
          | fail "the waiting question is missing from the HTML report data"
        let displayed ← assertOk <| Result.fromExcept Error.storage
          (reportQuestion.getObjVal? "question" >>= (·.getObjValAs? String "text"))
        assertEqual "report question" displayed question.text,

  test "unavailable answers preserve explicit status and resume all question types" do
    let unavailable := Lean.Json.mkObj [("status", "unavailable")]
    let cases : Array (String × Lean.Json × String) := #[
      ("yes_no", args "Keep the public API?" #[] "yes_no", "no"),
      ("single_choice", args, "none_of_above"),
      ("open_ended", args "What should change?" #[] "open_ended", unavailable.compress)]
    for family in Families.all do
      for (questionType, arguments, ordinaryAnswer) in cases do
        let base := (← scratch) / s!"{family.name}-{questionType}"
        IO.FS.createDirAll base
        let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name), ("ask_user", true)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        let (model, requests) ← scripted #[response #[ask "q" arguments], response #[bash], response #[submit]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", executor, model, agent := built.build executor }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config)
        let before ← assertOk <| allStates store
        assertError "only a question accepts an unavailable reply" (replyUnavailable store root) fun
          | .configuration _ => true
          | _ => false
        assertEqual "rejected reply writes no state" (← assertOk <| allStates store) before
        let question ← resumed <| resume rt "scripted" root (fun _ => pure ())
        let questionState ← assertOk <| getState store question
        let answered ← assertOk <| replyUnavailable store question
        let reopened ← assertOk <| Store.create (base / "states")
        let state ← assertOk <| getState reopened answered
        assertEqual "reply kind" state.kind Kind.reply
        assertEqual "reply parent" state.parent? (some question)
        assertEqual "reply workspace" state.workspace questionState.workspace
        assertEqual "reply image" state.image questionState.image
        assertEqual "reply adds no runtime" state.elapsedMs? none
        assertEqual "reply inherits accumulated time" (← assertOk <| elapsedMs reopened answered)
          (← assertOk <| elapsedMs reopened question)
        check state.question?.isNone "unavailable is an explicit response, not an unanswered question"
        match state.appended.toList with
        | [.observation "q" content] => assertEqual "structured unavailable status" content.compress unavailable.compress
        | _ => fail "unavailable must answer the original call exactly once"
        check (← assertOk <| waiting reopened).isEmpty "unavailable clears the waiting question"
        let ordinary ← assertOk <| reply reopened question ordinaryAnswer
        check (ordinary != answered) "unavailable must differ from no, none_of_above, and literal JSON open text"
        checkQuestionView (built.view (← assertOk <| logOf reopened ordinary)) ordinaryAnswer arguments
        let final ← resumed <| resume { rt with store := reopened } "scripted" answered (fun _ => pure ())
        assertEqual "continuation submitted" ((← assertOk <| getState reopened final).outcome?.map (·.status)) (some "Submitted")
        assertEqual "continuation ran a command" (← calls.get) 1
        let allRequests ← requests.get
        assertEqual "one ask, one command, and one submit" allRequests.size 3
        let some nextRequest := allRequests[1]? | fail "missing post-reply request"
        checkQuestionResult nextRequest.messages unavailable arguments
        let lines ← assertOk <| treeLines reopened
        check (lines.any (contains · ("reply  " ++ unavailable.compress))) "tree retains the structured status"
        let report ← assertOk <| Html.dataJson reopened workspaces built.view built.tools
        let states ← assertOk <| Result.fromExcept Error.storage (report.getObjVal? "states" >>= Lean.Json.getArr?)
        let some reportReply := states.find? fun json =>
            (json.getObjValAs? String "hash").toOption == some answered.hex
          | fail "the unavailable reply is missing from the HTML report"
        let events ← assertOk <| Result.fromExcept Error.storage (reportReply.getObjVal? "events" >>= Lean.Json.getArr?)
        let some event := events[0]? | fail "the report reply observation is missing"
        let content ← assertOk <| Result.fromExcept Error.storage (event.getObjVal? "content")
        assertEqual "HTML report retains structured status" content.compress unavailable.compress,

  test "unavailable answers retain exhausted time and step limits" do
    for family in Families.all do
      let base := (← scratch) / family.name
      IO.FS.createDirAll base
      let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name),
        ("ask_user", true), ("step_limit", 1)])
      let store ← assertOk <| Store.create (base / "states")
      let workspaces ← Testing.workspaces
      let project := base / "project"
      IO.FS.createDirAll project
      let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
        project (← testImage) (some "task") (agent := built.config)
      let workspace := (← assertOk <| getState store root).workspace
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question args)
      let question ← assertOk <| putState store {
        image := recordedImage
        parent? := some root, workspace, kind := .question, elapsedMs? := some 1000
        appended := #[.response (response #[ask])]
        question? := some { callId := "q", toQuestion := form } }
      let answered ← assertOk <| replyUnavailable store question
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[]
      let rt : Runtime := { store, workspaces, workDir := base / "work", executor, model, agent := built.build executor, budgetMs? := some 1000 }
      let before ← assertOk <| allStates store
      assertEqual "step cannot sample after exhausted time" (← assertOk <| stepOnce rt "scripted" answered) none
      let stopped ← assertOk <| resume rt "scripted" answered (fun _ => pure ())
      check stopped.outOfTime "unavailable retains the exhausted budget"
      assertEqual "budget leaves reply resumable" stopped.state answered
      assertEqual "budget writes no new state" (← assertOk <| allStates store) before
      let final ← resumed <| resume { rt with budgetMs? := none } "scripted" answered (fun _ => pure ())
      let terminal ← assertOk <| getState store final
      assertEqual "unavailable does not reset step limit" (terminal.outcome?.map (·.status)) (some "LimitsExceeded")
      assertEqual "terminal belongs to reply" terminal.parent? (some answered)
      assertEqual "unavailable inherits running time" (← assertOk <| elapsedMs store answered) 1000
      assertEqual "limits prevent all samples" (← requests.get).size 0
      assertEqual "limits prevent commands" (← calls.get) 0,

  test "reply rejects invalid or blank answers without writing a state or clearing waiting" do
    let blankCodepoints : Array Nat := #[0x0009, 0x000A, 0x000B, 0x000C, 0x000D,
      0x0020, 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
      0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    let blanks := #["", " \n\t\r", String.ofList (blankCodepoints.toList.map Char.ofNat)] ++
      blankCodepoints.map (fun n => String.ofList [Char.ofNat n])
    let cases : Array (String × Lean.Json × Array String × String) := #[
      ("yes_no", args "Keep the public API?" #[] "yes_no",
        #["", "maybe", "yes/no", "YES", " yes ", "no\n", "yes\nwith another instruction", "no, because it is inconvenient",
          "true", "false", "1", "0", "\"yes\"", "[]", "[1]", "{}", "null", "none_of_above"], "yes"),
      ("single_choice", args "Which changes apply?" #["first", "second", "third"],
        #["", " ", "true", "null", "{}", "\"1\"", "[]", "[1]", "[1, 2]", "[1, 1]",
          "1.5", "1.0", "1e0", "1E+0", "+1", "-1", "0", "4", "999999999999999999999999999", "1 trailing", "01",
          String.ofList [Char.ofNat 0x000B] ++ "1", "1" ++ String.ofList [Char.ofNat 0x00A0],
          "\"none_of_above\"", "None of the above", "NONE_OF_ABOVE", " none_of_above ",
          "{\"status\":\"unavailable\"}"], "none_of_above"),
      ("open_ended", args "What should change?" #[] "open_ended", blanks,
        String.ofList [Char.ofNat 0x00A0] ++ " Keep the API. \n" ++ String.ofList [Char.ofNat 0x3000])]
    for family in Families.all do
      for (questionType, arguments, invalid, valid) in cases do
        let base := (← scratch) / s!"{family.name}-{questionType}"
        IO.FS.createDirAll base
        let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name), ("ask_user", true)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        let (model, requests) ← scripted #[response #[ask "q" arguments], response #[submit]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", executor, model, agent := built.build executor }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config)
        let stopped ← resumed <| resume rt "scripted" root (fun _ => pure ())
        let reopened ← assertOk <| Store.create (base / "states")
        let before ← assertOk <| allStates reopened
        let original := (← assertOk <| getState reopened stopped).toJson.compress
        for answer in invalid do
          assertError s!"invalid {questionType} answer {repr answer}" (reply reopened stopped answer) fun
            | .configuration _ => true
            | _ => false
          assertEqual "no new stored state" (← assertOk <| allStates reopened) before
          assertEqual "no reply child" (← assertOk <| children reopened stopped).size 0
          assertEqual "question state is unchanged" (← assertOk <| getState reopened stopped).toJson.compress original
          let pending ← assertOk <| waiting reopened
          assertEqual "question is still waiting" pending.size 1
          assertEqual "same question is waiting" (pending[0]?.map (·.1)) (some stopped)
          assertEqual "answer validation never samples" (← requests.get).size 1
          assertEqual "answer validation never executes" (← calls.get) 0
        let answered ← assertOk <| reply reopened stopped valid
        assertEqual "one committed reply" (← assertOk <| children reopened stopped).size 1
        match (← assertOk <| getState reopened answered).appended.toList with
        | [.observation "q" (.str raw)] => assertEqual "corrected answer remains verbatim" raw valid
        | _ => fail "a corrected answer must retain its question call id"
        check (← assertOk <| waiting reopened).isEmpty "a valid submitted answer closes waiting"
        let final ← resumed <| resume { rt with store := reopened } "scripted" answered (fun _ => pure ())
        assertEqual "continuation after correction" ((← assertOk <| getState reopened final).outcome?.map (·.status))
          (some "Submitted")
        assertEqual "one question and one continuation" (← requests.get).size 2,

  test "stored question forms reject malformed metadata and retain legacy open text" do
    let seed : State := { image := recordedImage, parent? := none, workspace := ⟨String.ofList (List.replicate 64 '0')⟩, kind := .question, appended := #[], question? := some { callId := "legacy", text := "Explain the change." } }
    let legacyJson := seed.toJson.setObjVal! "question"
      (.mkObj [("call_id", "legacy"), ("text", "Explain the change.")])
    let legacy ← assertOk <| Result.fromExcept Error.storage (State.fromJson legacyJson)
    let some legacyQuestion := legacy.question? | fail "legacy question missing"
    assertEqual "legacy defaults to open text" legacyQuestion.questionType QuestionType.openEnded
    assertEqual "legacy has no options" legacyQuestion.options #[]
    let questionJson (kind : Lean.Json) (options : Lean.Json) : Lean.Json :=
      .mkObj [("call_id", "q"), ("text", "Choose."), ("question_type", kind), ("options", options)]
    let malformed : Array Lean.Json := #[
      .mkObj [("call_id", "q"), ("text", "Choose."), ("question_type", "yes_no")],
      .mkObj [("call_id", "q"), ("text", "Choose."), ("options", .arr #[])],
      questionJson "unknown" (.arr #[]), questionJson .null (.arr #[]),
      questionJson "multiple_choice" (.arr #[.str "first", .str "second"]),
      questionJson "yes_no" (.arr #[.str "yes", .str "no"]),
      questionJson "open_ended" (.arr #[.str "candidate"]),
      questionJson "single_choice" (.arr #[]),
      questionJson "single_choice" (.arr #[.str "only"]),
      questionJson "single_choice" (.arr #[.str "same", .str " same "]),
      questionJson "single_choice" (.arr #[.str "valid", .str " \n"]),
      questionJson "single_choice" (.arr #[.str "valid", .num 2]),
      questionJson "single_choice" (.str "not an array"),
      questionJson "yes_no" .null]
    for question in malformed do
      match State.fromJson (seed.toJson.setObjVal! "question" question) with
      | .error _ => pure ()
      | .ok _ => fail s!"malformed stored form was accepted: {question.compress}"
    let store ← assertOk <| Store.create ((← scratch) / "legacy-states")
    let waitingHash ← assertOk <| putState store legacy
    let text := "  Neither answer is suitable.\nKeep this legacy text unchanged.\n"
    let answered ← assertOk <| reply store waitingHash text
    match (← assertOk <| getState store answered).appended.toList with
    | [.observation "legacy" (.str raw)] => assertEqual "legacy reply stays verbatim" raw text
    | _ => fail "legacy open question lost its raw reply",

  test "a question consumes its model turn and a reply does not reset the step limit" do
    let config : Config := { askUser := true, stepLimit := 1 }
    let (executor, calls) ← countingExecutor
    let (model, requests) ← scripted #[response #[ask]]
    let a := agent executor config
    let (log, stop) ← assertOk <| Agent.run a { dir := ← scratch } (sampleWith model a)
      (initialLog config "task" testUname)
    match stop with
    | .question "q" _ => pure ()
    | _ => fail "the last allowed model turn may still ask its question"
    let answered := log.push (.observation "q" (.str "2"))
    let (_, stop) ← assertOk <| Agent.run a { dir := ← scratch } (sampleWith model a) answered
    match stop with
    | .outcome outcome => assertEqual "limit after reply" outcome.status "LimitsExceeded"
    | _ => fail "reply must not grant another model turn"
    assertEqual "sample count" (← requests.get).size 1
    assertEqual "executor count" (← calls.get) 0
    expectSample (next { enabled with stepLimit := 0 } {} answered),

  test "step and resume enforce the recorded limit before sampling after a reply" do
    for family in Families.all do
      for useResume in #[false, true] do
        let base := (← scratch) / s!"{family.name}-{useResume}"
        IO.FS.createDirAll base
        let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name),
          ("ask_user", true), ("step_limit", 1)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        -- Exhausted after the question: any accidental second model call is a test failure.
        let (model, requests) ← scripted #[response #[ask]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", executor, model, agent := built.build executor }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config)
        let stopped ← resumed <| resume rt "scripted" root (fun _ => pure ())
        check (← assertOk <| getState store stopped).question?.isSome "the allowed model turn asks"
        let answered ← assertOk <| reply store stopped "2"
        let some recorded ← assertOk <| agentOf store answered | fail "missing recorded configuration"
        let restored ← assertOk <| Families.instanceOf recorded
        let rebuilt := { rt with agent := restored.build executor }
        let final ← if useResume then
            resumed <| resume rebuilt "scripted" answered (fun _ => pure ())
          else stepped <| stepOnce rebuilt "scripted" answered
        let terminal ← assertOk <| getState store final
        assertEqual "limit outcome" (terminal.outcome?.map (·.status)) (some "LimitsExceeded")
        assertEqual "terminal parent" terminal.parent? (some answered)
        check terminal.appended.isEmpty "the terminal child must not invent a response or observation"
        assertEqual "terminal workspace" terminal.workspace (← assertOk <| getState store answered).workspace
        assertEqual "one request in all" (← requests.get).size 1
        assertEqual "no execution" (← calls.get) 0
        assertError "terminal state cannot resume" (resume rebuilt "scripted" final (fun _ => pure ())) fun
          | .configuration _ => true
          | _ => false
        assertEqual "refusing terminal resume does not sample" (← requests.get).size 1,

  test "reply preserves recorded running time and an exhausted budget never samples" do
    for family in Families.all do
      let base := (← scratch) / family.name
      IO.FS.createDirAll base
      let built ← assertOk <| Families.instanceOf (.mkObj [("family", family.name), ("ask_user", true)])
      let store ← assertOk <| Store.create (base / "states")
      let workspaces ← Testing.workspaces
      let project := base / "project"
      IO.FS.createDirAll project
      let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
        project (← testImage) (some "task") (agent := built.config)
      let workspace := (← assertOk <| getState store root).workspace
      -- Reconstruct an already-recorded run with two timed model steps. Fixed durations
      -- exercise persistence and accumulation without sleeps or timing-sensitive assertions.
      let previous : Chat.ToolCall := { id := "previous", name := "bash", arguments := .mkObj [("command", "true")] }
      let first ← assertOk <| putState store {
        image := recordedImage
        parent? := some root, workspace, kind := .turn, elapsedMs? := some 700
        appended := #[.response (response #[previous]),
          .observation "previous" (Output.toJson { output := "", exitCode? := some 0 })] }
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question args)
      let question ← assertOk <| putState store {
        image := recordedImage
        parent? := some first, workspace, kind := .question, elapsedMs? := some 300
        appended := #[.response (response #[ask])]
        question? := some { callId := "q", toQuestion := form } }
      let reopened ← assertOk <| Store.create (base / "states")
      assertEqual "recorded steps add up" (← assertOk <| elapsedMs reopened question) 1000
      let answered ← assertOk <| reply reopened question "2"
      let alternate ← assertOk <| reply reopened question "none_of_above"
      for answer in #[answered, alternate] do
        assertEqual "answer inherits all recorded running time" (← assertOk <| elapsedMs reopened answer) 1000
        assertEqual "the human reply adds no running time"
          (← assertOk <| getState reopened answer).elapsedMs? none
      let some recorded ← assertOk <| agentOf reopened answered | fail "missing recorded agent"
      let restored ← assertOk <| Families.instanceOf recorded
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[response #[submit]]
      let rt : Runtime := { store := reopened, workspaces, workDir := base / "work", executor, model, agent := restored.build executor, budgetMs? := some 1000 }
      let before ← assertOk <| allStates reopened
      let stopped ← assertOk <| resume rt "scripted" answered (fun _ => pure ())
      check stopped.outOfTime "the inherited time exhausts this invocation's budget"
      assertEqual "resume leaves the reply available for later continuation" stopped.state answered
      assertEqual "step also refuses another sample" (← assertOk <| stepOnce rt "scripted" answered) none
      assertEqual "the budget writes no terminal or model state" (← assertOk <| allStates reopened) before
      assertEqual "no model request after the exhausted budget" (← requests.get).size 0
      assertEqual "no command after the exhausted budget" (← calls.get) 0
      let final ← resumed <| resume { rt with budgetMs? := none } "scripted" answered (fun _ => pure ())
      assertEqual "the same reply remains resumable with more budget"
        ((← assertOk <| getState reopened final).outcome?.map (·.status)) (some "Submitted")
      assertEqual "only the later allowed continuation samples" (← requests.get).size 1
      check ((← assertOk <| elapsedMs reopened final) >= 1000) "continuing must retain all earlier running time",

  test "invalid asks count as consecutive format errors and a valid ask resets the streak" do
    let config := { enabled with maxConsecutiveFormatErrors := 2 }
    let bad := Event.response (response #[ask "bad" (args "q" #["only one"])])
    let prose := Event.response { content? := some "no tool", finishReason? := some "stop" }
    expectSample (next config {} #[bad])
    expectDone (next config {} #[prose, .message (.user "try again"), bad]) "RepeatedFormatError"
    let answered : Log := #[prose, .response (response #[ask]), .observation "q" (.str "none_of_above")]
    expectSample (next config {} (answered.push bad))
    expectDone (next config {} (answered ++ #[bad, bad])) "RepeatedFormatError"
    expectSample (next { config with maxConsecutiveFormatErrors := 0 } {} #[bad, bad, bad]),

  test "asking and output recovery compose without running a command" do
    let config : Config := { askUser := true, recoverOutput := true }
    let arguments := args "Which part of the output should be inspected next?" #[] "open_ended"
    let output := "\n".intercalate ((List.range 3000).map fun i => s!"line {i + 1} xxxx") ++ "\n"
    let history : Log := #[.response (response #[bash]),
      .observation "b" (Output.toJson { output, exitCode? := some 0 })]
    let readCall : Chat.ToolCall := { id := "r", name := "read_output", arguments := .mkObj [("call_id", "b"), ("offset", 1500), ("limit", 2)] }
    let (executor, calls) ← countingExecutor
    let (model, _) ← scripted #[response #[ask "q" arguments], response #[readCall], response #[submit]]
    let a := agent executor config
    let (log, firstStop) ← assertOk <| Agent.run a { dir := ← scratch } (sampleWith model a)
      (initialLog config "task" testUname ++ history)
    match firstStop with
    | .question "q" _ => pure ()
    | _ => fail "the recovery-enabled agent should ask normally"
    let (finalLog, finalStop) ← assertOk <| Agent.run a { dir := ← scratch } (sampleWith model a)
      (log.push (.observation "q" (.str "Inspect the middle lines.\nKeep the output unchanged.")))
    match finalStop with
    | .outcome outcome => assertEqual "submitted after reading" outcome.status "Submitted"
    | _ => fail "expected submission after output recovery"
    let page := finalLog.findSome? fun
      | .observation "r" json => (json.getObjValAs? String "text").toOption
      | _ => none
    assertEqual "recovered lines" page (some "line 1500 xxxx\nline 1501 xxxx")
    let dialogue := view config finalLog
    checkQuestionView dialogue "Inspect the middle lines.\nKeep the output unchanged." arguments
    check (dialogue.any fun
      | .tool "b" (.str shown) => contains shown "read_output" && contains shown "id is b"
      | _ => false) "output truncation must retain its recovery hint"
    assertEqual "no executor calls" (← calls.get) 0
]

end AskUserTests
