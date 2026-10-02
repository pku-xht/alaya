import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! The optional typed-question tool, from configuration through recorded replies and forks.
All model responses are scripted; an executor that counts calls detects unwanted side effects. -/

namespace AskUserTests

open Testing Alaya Alaya.Agent Alaya.Trajectory Alaya.Driver
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

private def enabled : Config := { tools := ({} : Config).tools.push Tools.AskUser.tool }

/-- The `tools` a configuration of agent `name` names to offer asking, besides its defaults. -/
private def askingTools (name : String) : Lean.Json :=
  .arr ((#["bash", "submit"] ++ (if name == "mini-vero" then #["time_budget"] else #[]) ++
    #["ask_user"]).map Lean.Json.str)

private def countingExecutor : IO (Executor × IO.Ref Nat) := do
  let calls ← IO.mkRef 0
  pure ({ exec := fun _ _ _ _ => do
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

private def expectDone (next : Effect ⊕ Outcome) (status : String) : TestM Unit := do
  match next with
  | .inr outcome => assertEqual "stop status" outcome.status status
  | _ => fail s!"expected {status}"

private def expectSample (next : Effect ⊕ Outcome) : TestM Unit := do
  match next with
  | .inl (.sample ..) => pure ()
  | _ => fail "expected another model sample"

private def resumed (result : Result (Hash × Stop)) : TestM Hash := do
  let (state, halt) ← assertOk result
  check (halt != .outOfTime) "this continuation must stop at its question or outcome, not its time budget"
  pure state

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

/-- What a valid answer `text` to a question of `questionType` is recorded as, and so what the
model is shown: a candidate's number as a number, and anything else as the text. -/
private def recordedAnswer (questionType answer : String) : Lean.Json :=
  if questionType == "single_choice" && answer != "none_of_above" then (answer.trimAscii.toString.toNat! : Lean.Json)
  else .str answer

def suite : Suite := Testing.suite "ask_user" #[
  test "both agents keep their default prompts and tools when asking is disabled" do
    for definition in Catalog.all do
      let minimal ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name)])
      let timeTools := if definition.name == "mini-vero" then #["time_budget"] else #[]
      let off ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name),
        ("tools", .arr ((#["bash", "submit"] ++ timeTools).map Lean.Json.str))])
      assertEqual "default tools" (toolNames minimal (minimal.initialLog "task" testUname)) (#["bash", "submit"] ++ timeTools)
      assertEqual "explicit off config" off.config.compress minimal.config.compress
      check (!contains ((minimal.config.getObjVal? "tools").toOption.getD .null).compress "ask_user")
        "the default configuration names no ask_user"
      let request (spec : Agent) : Lean.Json := (requestOf spec (spec.initialLog "task" testUname)).toJson
      assertEqual "explicit off opening" (request off).compress (request minimal).compress
      check (!contains (request minimal).compress "ask_user") "the default opening must not offer questions"
      let bad := response #[ask]
      match (requestOf minimal #[.sampled default .turn bad]).messages[0]? with
      | some (Chat.Message.user text) => check (contains text "Unknown tool 'ask_user'") "disabled is unknown"
      | _ => fail "disabled ask should be a format error"
    match parseActions (response #[ask]) with
    | .formatError _ => pure ()
    | _ => fail "the default parser must still reject ask_user",

  test "opening and repair prompts permit a lone ask with or without output recovery" do
    let incompatible := #["AT LEAST ONE bash tool call", "needs to use the 'bash' tool at least once",
      "Every response needs at least one tool call: 'bash'",
      "exactly one bash tool call"]
    for recover in #[false, true] do
      for definition in Catalog.all do
        let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name),
          ("tools", askingTools definition.name), ("recover_output", recover)])
        let opening := (built.initialLog "task" testUname).foldl (init := "") fun text event =>
          match event with
          | .told (.user message) => text ++ message
          | _ => text
        check (contains opening "Call ask_user alone") "the opening must permit a question on its own"
        for phrase in incompatible do
          check (!contains opening phrase) s!"the opening still conflicts with a lone question: {phrase}"
      for timeBudget in #[false, true] do
        let base := ({} : Config).tools
        let config : Config := {
          recoverOutput := recover
          tools := if timeBudget then base.push Tools.TimeBudget.tool else base }
        let asking : Config := { config with tools := config.tools.push Tools.AskUser.tool }
        for reason in #["stop", "length", "tool_calls"] do
          let malformed : Chat.Response := { content? := some "unfinished", finishReason? := some reason }
          match parseActions malformed asking with
          | .formatError message =>
            check (contains message "ask_user") "every repair path must retain the offered question tool"
            for phrase in incompatible do
              check (!contains message phrase) s!"the repair still requires bash: {phrase}"
            if reason != "stop" then
              check (contains message s!"finish_reason={reason}") "the truncation reason must be preserved"
              check (contains message "exactly one tool call") "the truncation hint must allow a lone question"
          | _ => fail "an unfinished response needs a repair"
          -- Asking only adds to the repair: what the tools without it say comes first, unchanged.
          check ((formatErrorMessage "error" false (some reason) asking).startsWith
              (formatErrorMessage "error" false (some reason) config))
            "asking appends to the repair, and changes nothing before it"
        match parseActions (response #[ask]) asking with
        | .actions actions => check (actions.size == 1) "a lone ask is valid with recovery and time-budget tools"
        | _ => fail "other optional tools must not prevent a lone ask",

  test "settings enable asking in both agents, round-trip, and reject wrong types" do
    for definition in Catalog.all do
      let set (path : String) (value : Lean.Json) : Settings.Setting := { target := .agent, path := [path], value }
      let built ← assertOk <| Catalog.resolve definition.name #[set "tools" (askingTools definition.name),
        set "recover_output" true, set "step_limit" (11 : Nat), set "max_consecutive_format_errors" (2 : Nat)]
      let timeTools := if definition.name == "mini-vero" then #["time_budget"] else #[]
      assertEqual "enabled tools" (toolNames built (built.initialLog "task" testUname))
        (#["bash", "submit"] ++ timeTools ++ #["ask_user"])
      assertEqual "recorded tools" ((built.config.getObjVal? "tools").toOption.map (·.compress))
        (some (askingTools definition.name).compress)
      let restored ← assertOk <| Catalog.fromJson built.config
      assertEqual "complete config round-trip" restored.config.compress built.config.compress
      check ((built.initialLog "task" testUname).any fun
        | .told (.user text) => contains text "ask_user"
        | _ => false) "the enabled agent must tell the model it can ask"
      for bad in #[Lean.Json.null, .str "ask_user", .num 1, .arr #[], .mkObj [],
          .arr #[.str "bash", .str "submit", .str "ask_users"], .arr #[.str "bash", .str "ask_user"],
          .arr #[.str "bash", .str "submit", .str "bash"]] do
        assertError "tools" (Catalog.fromJson
          (.mkObj [("name", definition.name), ("tools", bad)])) fun
            | .input message => contains message "tool"
            | _ => false,

  test "single choice adds a platform answer while retaining model candidates verbatim" do
    let question := "  Which rule applies?\nContext: α < β.  "
    let candidates := #[" Keep α ", "Change β\nwith evidence"]
    let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question (args question candidates))
    assertEqual "a choice of the original candidates" form.form (.singleChoice candidates)
    assertEqual "original question" form.text question
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
      match actions[0]?.map (fun (action : Action) => action.next { response := 0, index := 0 } #[]) with
      | some (.inl (Effect.ask _ parsed)) =>
        assertEqual "waiting form" parsed.form form.form
        assertEqual "waiting text" parsed.text question
      | _ => fail "expected the question effect's action"
    | _ => fail "valid choices should parse"
    for (questionType, expectedForm) in #[("yes_no", Question.Form.yesNo),
        ("open_ended", Question.Form.openEnded)] do
      let arguments := args question #[] questionType
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question arguments)
      assertEqual "question form" form.form expectedForm
      assertEqual "original question" form.text question
      assertEqual "no model-defined choices" form.form.options #[]
      check (!contains form.render "OTHER") s!"{questionType} must not invent a custom-answer choice"
      check (!contains form.render "none_of_above") s!"{questionType} must not offer the reserved single-choice answer"
      match parseActions (response #[ask "q" arguments]) enabled with
      | .actions actions =>
        match actions[0]?.map (fun (action : Action) => action.next { response := 0, index := 0 } #[]) with
        | some (.inl (Effect.ask _ parsed)) =>
          assertEqual "waiting form" parsed.form expectedForm
          assertEqual "waiting text" parsed.text question
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
      -- Every choice has this answer already; the model may not offer it as a candidate.
      args "q" #["a", "None of the above"], args "q" #["a", " none_of_above "],
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
      let a := agent config
      let (_, _, halt) ← drive a executor model (initialLog config "task" testUname)
      match halt with
      | .outcome outcome => assertEqual "rejected turn outcome" outcome.status "RepeatedFormatError"
      | _ => fail "an invalid question must not wait for an answer"
      assertEqual "executor calls" (← calls.get) 0,

  test "typed questions record candidate, none-of-above, yes/no, and open replies after reconstruction" do
    let cases : Array (String × Lean.Json × Array String) := #[
      ("yes_no", args "Keep the public API?\nContext: callers depend on it." #[] "yes_no",
        #["yes", "no"]),
      ("single_choice", args "Which change should be included?\nSelect one answer."
        #["Keep α", "Check β\nwith evidence",
          "Document γ with a detailed explanation of the public API, compatibility constraints, boundary cases, and expected output."],
        #["1", "2", "3", "none_of_above"]),
      ("open_ended", args "How should we handle the boundary case?" #[] "open_ended",
        #["  Keep the public API.\nPreserve the literal \"[]\" in the response.\n理由：边界条件不同。\n",
          "[]", String.ofList [Char.ofNat 0x200B]])]
    for definition in Catalog.all do
      for (questionType, arguments, answers) in cases do
        let base := (← scratch) / s!"{definition.name}-{questionType}"
        IO.FS.createDirAll base
        let built ← assertOk <| Catalog.resolve definition.name #[{ target := .agent, path := ["tools"], value := askingTools definition.name }]
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        IO.FS.writeFile (project / "untouched.txt") "original\n"
        let (executor, calls) ← countingExecutor
        let continuations := (List.replicate answers.size (response #[submit])).toArray
        let (model, requests) ← scripted (#[response #[ask "q" arguments]] ++ continuations)
        let rt : Runtime := { store, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := built }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config) (model := testModel)
        let waitingHash ← resumed <| resume rt root
        let questionState ← assertOk <| getState store waitingHash
        assertEqual "waiting kind" questionState.kind.toString "step"
        check questionState.question?.isSome "the turn waits on its question"
        let some asked := questionState.asked? | fail "missing recorded question"
        let question := asked.question
        assertEqual "call id" ((← assertOk <| logOf store waitingHash).index.callId? asked.call) (some "q")
        let expected ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question arguments)
        assertEqual "recorded question wording" question.text expected.text
        assertEqual "recorded question form" question.form expected.form
        check (!contains question.render "OTHER") "the waiting record must not add a custom option"
        -- The log's call summary is truncated, so `show` must render the complete question
        -- separately, including long choices and the requested answer format.
        let shown ← assertOk <| showLines store waitingHash
        assertEqual "show retains complete question, long options, and answer format"
          (shown.find? (·.startsWith "question ")) (some ("question " ++ expected.render))
        assertEqual "waiting workspace" questionState.workspace (← assertOk <| getState store root).workspace
        assertEqual "unanswered question count" (← assertOk <| waiting store).size 1
        assertEqual "unanswered question has no reply children" (← assertOk <| children store waitingHash).size 0
        assertError "cannot step while waiting" (step rt waitingHash) fun
          | .input _ => true
          | _ => false
        assertEqual "only question sampled" (← requests.get).size 1
        -- Reopening the store must reconstruct the form before enforcing its answer rules.
        let reopened ← assertOk <| Store.create (base / "states")
        let some persistedQuestion := (← assertOk <| getState reopened waitingHash).question?
          | fail "the persisted question disappeared"
        assertEqual "reopened form" persistedQuestion.form expected.form
        let mut replyHashes : Array Hash := #[]
        for answer in answers do
          let answered ← assertOk <| replyText reopened waitingHash answer
          check (!replyHashes.contains answered) "different answers must create distinct reply branches"
          replyHashes := replyHashes.push answered
          let state ← assertOk <| getState store answered
          assertEqual "reply kind" state.kind.toString "reply"
          assertEqual "reply parent" state.parent? (some waitingHash)
          assertEqual "reply workspace" state.workspace questionState.workspace
          check state.question?.isNone "an answer, including none_of_above, must not still be a waiting question"
          check state.root?.isNone "the reply must inherit configuration rather than duplicate it"
          match state.appended.toList with
          | [.recorded _ content] =>
            assertEqual "recorded answer" content.compress (recordedAnswer questionType answer).compress
          | _ => fail "a reply must append exactly the answer as the asking call's result"
          check (← assertOk <| waiting store).isEmpty
            "an explicit answer, including none_of_above, must differ from not answering"
          let recorded ← assertOk <| agentOf store answered
          assertEqual "recorded root config" recorded.compress built.config.compress
          let restored ← assertOk <| Catalog.fromJson recorded
          checkQuestionResult (requestOf restored (← assertOk <| logOf store answered)).messages
            (recordedAnswer questionType answer) arguments
          let rebuilt : Runtime := { rt with agent := restored }
          let final ← resumed <| resume rebuilt answered
          let finalState ← assertOk <| getState store final
          assertEqual "resumed submission" (finalState.outcome?.map (·.status)) (some "Submitted")
          assertEqual "final workspace" finalState.workspace questionState.workspace
          let some request := (← requests.get).back? | fail "missing continuation request"
          checkQuestionResult request.messages (recordedAnswer questionType answer) arguments
        -- A choice is its number however it was typed: the same reply, and so the same state.
        if questionType == "single_choice" then
          assertEqual "a choice typed with spaces" (← assertOk <| replyText reopened waitingHash " \t\r2 \n")
            (replyHashes[1]?.getD default)
        assertEqual "distinct reply branches" (← assertOk <| children store waitingHash).size answers.size
        assertEqual "one question and one continuation per answer" (← requests.get).size (answers.size + 1)
        assertEqual "no command ran for asking or replying" (← calls.get) 0
        let report ← assertOk <| Html.dataJson store workspaces (fun _ => pure built)
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
    for definition in Catalog.all do
      for (questionType, arguments, ordinaryAnswer) in cases do
        let base := (← scratch) / s!"{definition.name}-{questionType}"
        IO.FS.createDirAll base
        let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name), ("tools", askingTools definition.name)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        let (model, requests) ← scripted #[response #[ask "q" arguments], response #[bash], response #[submit]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := built }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config) (model := testModel)
        let before ← assertOk <| allStates store
        assertError "only a question accepts an unavailable reply" (reply store root .unavailable) fun
          | .input _ => true
          | _ => false
        assertEqual "rejected reply writes no state" (← assertOk <| allStates store) before
        let question ← resumed <| resume rt root
        let questionState ← assertOk <| getState store question
        let answered ← assertOk <| reply store question .unavailable
        let reopened ← assertOk <| Store.create (base / "states")
        let state ← assertOk <| getState reopened answered
        assertEqual "reply kind" state.kind.toString "reply"
        assertEqual "reply parent" state.parent? (some question)
        assertEqual "reply workspace" state.workspace questionState.workspace
        assertEqual "reply adds no runtime" state.elapsedMs? none
        assertEqual "reply inherits accumulated time" (← assertOk <| elapsedMs reopened answered)
          (← assertOk <| elapsedMs reopened question)
        check state.question?.isNone "unavailable is an explicit response, not an unanswered question"
        match state.appended.toList with
        | [.recorded _ content] => assertEqual "structured unavailable status" content.compress unavailable.compress
        | _ => fail "unavailable must answer the original call exactly once"
        check (← assertOk <| waiting reopened).isEmpty "unavailable clears the waiting question"
        let ordinary ← assertOk <| replyText reopened question ordinaryAnswer
        check (ordinary != answered) "unavailable must differ from no, none_of_above, and literal JSON open text"
        checkQuestionResult (requestOf built (← assertOk <| logOf reopened ordinary)).messages
          (recordedAnswer questionType ordinaryAnswer) arguments
        let final ← resumed <| resume { rt with store := reopened } answered
        assertEqual "continuation submitted" ((← assertOk <| getState reopened final).outcome?.map (·.status)) (some "Submitted")
        assertEqual "continuation ran a command" (← calls.get) 1
        let allRequests ← requests.get
        assertEqual "one ask, one command, and one submit" allRequests.size 3
        let some nextRequest := allRequests[1]? | fail "missing post-reply request"
        checkQuestionResult nextRequest.messages unavailable arguments
        let lines ← assertOk <| treeLines reopened
        check (lines.any (contains · ("reply  " ++ unavailable.compress))) "tree retains the structured status"
        let report ← assertOk <| Html.dataJson reopened workspaces (fun _ => pure built)
        let states ← assertOk <| Result.fromExcept Error.storage (report.getObjVal? "states" >>= Lean.Json.getArr?)
        let some reportReply := states.find? fun json =>
            (json.getObjValAs? String "hash").toOption == some answered.hex
          | fail "the unavailable reply is missing from the HTML report"
        let events ← assertOk <| Result.fromExcept Error.storage (reportReply.getObjVal? "events" >>= Lean.Json.getArr?)
        let some event := events[0]? | fail "the report reply observation is missing"
        let content ← assertOk <| Result.fromExcept Error.storage (event.getObjVal? "content")
        assertEqual "HTML report retains structured status" content.compress unavailable.compress,

  test "unavailable answers retain exhausted time and step limits" do
    for definition in Catalog.all do
      let base := (← scratch) / definition.name
      IO.FS.createDirAll base
      let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name),
        ("tools", askingTools definition.name), ("step_limit", 1)])
      let store ← assertOk <| Store.create (base / "states")
      let workspaces ← Testing.workspaces
      let project := base / "project"
      IO.FS.createDirAll project
      let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
        project (← testImage) (some "task") (agent := built.config) (model := testModel)
      let rootState ← assertOk <| getState store root
      let workspace := rootState.workspace
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question args)
      let question ← assertOk <| putState store {
        parent? := some root, workspace
        appended := #[.sampled default .turn (response #[ask])]
        -- After the root's opening and workspace, the response is at log position 3.
        kind := .step (some 1000) (some (.inr { call := { response := 3, index := 0 }, question := form })) }
      let answered ← assertOk <| reply store question .unavailable
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[]
      let rt : Runtime := { store, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := built }
      let spent : Limits := { budgetMs? := some 1000 }
      let before ← assertOk <| allStates store
      check ((← assertOk <| step rt answered spent.budgetMs?).2 == .outOfTime) "step cannot sample after exhausted time"
      let (stopped, halt) ← assertOk <| resume rt answered spent
      check (halt == .outOfTime) "unavailable retains the exhausted budget"
      assertEqual "budget leaves reply resumable" stopped answered
      assertEqual "budget writes no new state" (← assertOk <| allStates store) before
      let final ← resumed <| resume rt answered
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
    for definition in Catalog.all do
      for (questionType, arguments, invalid, valid) in cases do
        let base := (← scratch) / s!"{definition.name}-{questionType}"
        IO.FS.createDirAll base
        let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name), ("tools", askingTools definition.name)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        let (model, requests) ← scripted #[response #[ask "q" arguments], response #[submit]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := built }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config) (model := testModel)
        let stopped ← resumed <| resume rt root
        let reopened ← assertOk <| Store.create (base / "states")
        let before ← assertOk <| allStates reopened
        let original := (← assertOk <| getState reopened stopped).toJson.compress
        for answer in invalid do
          assertError s!"invalid {questionType} answer {repr answer}" (replyText reopened stopped answer) fun
            | .input _ => true
            | _ => false
          assertEqual "no new stored state" (← assertOk <| allStates reopened) before
          assertEqual "no reply child" (← assertOk <| children reopened stopped).size 0
          assertEqual "question state is unchanged" (← assertOk <| getState reopened stopped).toJson.compress original
          let pending ← assertOk <| waiting reopened
          assertEqual "question is still waiting" pending.size 1
          assertEqual "same question is waiting" (pending[0]?.map (·.1)) (some stopped)
          assertEqual "answer validation never samples" (← requests.get).size 1
          assertEqual "answer validation never executes" (← calls.get) 0
        let answered ← assertOk <| replyText reopened stopped valid
        assertEqual "one committed reply" (← assertOk <| children reopened stopped).size 1
        match (← assertOk <| getState reopened answered).appended.toList with
        | [.recorded _ content] =>
          assertEqual "the corrected answer is recorded" content.compress (recordedAnswer questionType valid).compress
        | _ => fail "a corrected answer must be the asking call's one result"
        check (← assertOk <| waiting reopened).isEmpty "a valid submitted answer closes waiting"
        let final ← resumed <| resume { rt with store := reopened } answered
        assertEqual "continuation after correction" ((← assertOk <| getState reopened final).outcome?.map (·.status))
          (some "Submitted")
        assertEqual "one question and one continuation" (← requests.get).size 2,

  test "a stored question must be one that can be asked" do
    let seed : State := { parent? := none, workspace := ⟨String.ofList (List.replicate 64 '0')⟩, appended := #[]
                          kind := .step none (some (.inr { call := { response := 0, index := 0 }, question := { text := "Choose." } })) }
    -- The stored state with a question of `fields` as what its step waits on.
    let waitingOn (fields : List (String × Lean.Json)) : Lean.Json :=
      seed.toJson.setObjVal! "kind" (.mkObj [("type", "step"), ("elapsed_ms", .null),
        ("stop", .mkObj [("asked", .mkObj [("call", .mkObj [("response", 0), ("index", 0)]),
          ("question", .mkObj fields)])])])
    let form (type : Lean.Json) (options? : Option Lean.Json := none) : Lean.Json :=
      .mkObj (("type", type) :: (options?.map fun options => [("options", options)]).getD [])
    let asking (form : Lean.Json) : List (String × Lean.Json) := [("text", "Choose."), ("form", form)]
    assertEqual "the seed is stored so" (waitingOn (asking (form "open_ended"))).compress seed.toJson.compress
    let malformed : Array (List (String × Lean.Json)) := #[
      [("text", "Choose.")],
      [("form", form "yes_no")],
      [("text", " \n"), ("form", form "yes_no")],
      asking (form "unknown"), asking (form .null), asking (form "multiple_choice" (some (.arr #[.str "first", .str "second"]))),
      asking (form "single_choice"),
      asking (form "single_choice" (some (.arr #[]))),
      asking (form "single_choice" (some (.arr #[.str "only"]))),
      asking (form "single_choice" (some (.arr #[.str "same", .str " same "]))),
      asking (form "single_choice" (some (.arr #[.str "valid", .str " \n"]))),
      asking (form "single_choice" (some (.arr #[.str "valid", .num 2]))),
      asking (form "single_choice" (some (.str "not an array"))),
      -- Every choice has this answer already; a candidate may not be it.
      asking (form "single_choice" (some (.arr #[.str "valid", .str "None of the above"]))),
      asking (form "single_choice" (some (.arr #[.str "valid", .str " none_of_above "])))]
    for fields in malformed do
      match State.fromJson (waitingOn fields) with
      | .error _ => pure ()
      | .ok _ => fail s!"a malformed stored question was accepted: {(Lean.Json.mkObj fields).compress}"
    let parsed ← assertOk <| Result.fromExcept Error.storage
      (State.fromJson (waitingOn (asking (form "single_choice" (some (.arr #[.str "first", .str "second"]))))))
    assertEqual "a complete question reads back" (parsed.question?.map (·.form)) (some (.singleChoice #["first", "second"])),

  test "a question consumes its model turn and a reply does not reset the step limit" do
    let config : Config := { enabled with stepLimit := 1 }
    let (executor, calls) ← countingExecutor
    let (model, requests) ← scripted #[response #[ask]]
    let a := agent config
    let (rt, asked, halt) ← drive a executor model (initialLog config "task" testUname)
    match halt with
    | .question q =>
      assertEqual "the asking call" ((← assertOk <| logOf rt.store asked).index.callId? q.call) (some "q")
    | _ => fail "the last allowed model turn may still ask its question"
    let replied ← assertOk <| replyText rt.store asked "2"
    let answered ← assertOk <| logOf rt.store replied
    let (_, halt) ← assertOk <| resume rt replied
    match halt with
    | .outcome outcome => assertEqual "limit after reply" outcome.status "LimitsExceeded"
    | _ => fail "reply must not grant another model turn"
    assertEqual "sample count" (← requests.get).size 1
    assertEqual "executor count" (← calls.get) 0
    expectSample (next { enabled with stepLimit := 0 } answered),

  test "step and resume enforce the recorded limit before sampling after a reply" do
    for definition in Catalog.all do
      for useResume in #[false, true] do
        let base := (← scratch) / s!"{definition.name}-{useResume}"
        IO.FS.createDirAll base
        let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name),
          ("tools", askingTools definition.name), ("step_limit", 1)])
        let store ← assertOk <| Store.create (base / "states")
        let workspaces ← Testing.workspaces
        let project := base / "project"
        IO.FS.createDirAll project
        let (executor, calls) ← countingExecutor
        -- Exhausted after the question: any accidental second model call is a test failure.
        let (model, requests) ← scripted #[response #[ask]]
        let rt : Runtime := { store, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := built }
        let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
          project (← testImage) (some "task") (agent := built.config) (model := testModel)
        let stopped ← resumed <| resume rt root
        check (← assertOk <| getState store stopped).question?.isSome "the allowed model turn asks"
        let answered ← assertOk <| replyText store stopped "2"
        let recorded ← assertOk <| agentOf store answered
        let restored ← assertOk <| Catalog.fromJson recorded
        let rebuilt := { rt with agent := restored }
        let final ← if useResume then
            resumed <| resume rebuilt answered
          else stepped <| step rebuilt answered
        let terminal ← assertOk <| getState store final
        assertEqual "limit outcome" (terminal.outcome?.map (·.status)) (some "LimitsExceeded")
        assertEqual "terminal parent" terminal.parent? (some answered)
        check terminal.appended.isEmpty "the terminal child must not invent a response or observation"
        assertEqual "terminal workspace" terminal.workspace (← assertOk <| getState store answered).workspace
        assertEqual "one request in all" (← requests.get).size 1
        assertEqual "no execution" (← calls.get) 0
        assertError "terminal state cannot resume" (resume rebuilt final) fun
          | .input _ => true
          | _ => false
        assertEqual "refusing terminal resume does not sample" (← requests.get).size 1,

  test "reply preserves recorded running time and an exhausted budget never samples" do
    for definition in Catalog.all do
      let base := (← scratch) / definition.name
      IO.FS.createDirAll base
      let built ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name), ("tools", askingTools definition.name)])
      let store ← assertOk <| Store.create (base / "states")
      let workspaces ← Testing.workspaces
      let project := base / "project"
      IO.FS.createDirAll project
      let root ← assertOk <| createRoot store workspaces (built.initialLog "task" testUname)
        project (← testImage) (some "task") (agent := built.config) (model := testModel)
      let rootState ← assertOk <| getState store root
      let workspace := rootState.workspace
      -- Reconstruct an already-recorded run with two timed model steps. Fixed durations
      -- exercise persistence and accumulation without sleeps or timing-sensitive assertions.
      let previous : Chat.ToolCall := { id := "previous", name := "bash", arguments := .mkObj [("command", "true")] }
      let first ← assertOk <| putState store {
        parent? := some root, workspace, kind := .step (some 700)
        appended := #[.sampled default .turn (response #[previous]),
          ran "" (response := 3) (workspace := workspace)] }
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question args)
      let question ← assertOk <| putState store {
        parent? := some first, workspace
        appended := #[.sampled default .turn (response #[ask])]
        kind := .step (some 300) (some (.inr { call := { response := 5, index := 0 }, question := form })) }
      let reopened ← assertOk <| Store.create (base / "states")
      assertEqual "recorded steps add up" (← assertOk <| elapsedMs reopened question) 1000
      let answered ← assertOk <| replyText reopened question "2"
      let alternate ← assertOk <| replyText reopened question "none_of_above"
      for answer in #[answered, alternate] do
        assertEqual "answer inherits all recorded running time" (← assertOk <| elapsedMs reopened answer) 1000
        assertEqual "the human reply adds no running time"
          (← assertOk <| getState reopened answer).elapsedMs? none
      let recorded ← assertOk <| agentOf reopened answered
      let restored ← assertOk <| Catalog.fromJson recorded
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[response #[submit]]
      let rt : Runtime := { store := reopened, workspaces, workDir := base / "work", outputsDir := base / "outputs", executor, model, agent := restored }
      let spent : Limits := { budgetMs? := some 1000 }
      let before ← assertOk <| allStates reopened
      let (stopped, halt) ← assertOk <| resume rt answered spent
      check (halt == .outOfTime) "the inherited time exhausts this invocation's budget"
      assertEqual "resume leaves the reply available for later continuation" stopped answered
      check ((← assertOk <| step rt answered spent.budgetMs?).2 == .outOfTime) "step also refuses another sample"
      assertEqual "the budget writes no terminal or model state" (← assertOk <| allStates reopened) before
      assertEqual "no model request after the exhausted budget" (← requests.get).size 0
      assertEqual "no command after the exhausted budget" (← calls.get) 0
      let final ← resumed <| resume rt answered
      assertEqual "the same reply remains resumable with more budget"
        ((← assertOk <| getState reopened final).outcome?.map (·.status)) (some "Submitted")
      assertEqual "only the later allowed continuation samples" (← requests.get).size 1
      check ((← assertOk <| elapsedMs reopened final) >= 1000) "continuing must retain all earlier running time",

  test "invalid asks count as consecutive format errors and a valid ask resets the streak" do
    let config := { enabled with maxConsecutiveFormatErrors := 2 }
    let bad := Event.sampled default .turn (response #[ask "bad" (args "q" #["only one"])])
    let prose := Event.sampled default .turn { content? := some "no tool", finishReason? := some "stop" }
    expectSample (next config #[bad])
    expectDone (next config #[prose, .told (.user "try again"), bad]) "RepeatedFormatError"
    let answered : Log := #[prose, .sampled default .turn (response #[ask]),
      .recorded { response := 1, index := 0 } (.str "none_of_above")]
    expectSample (next config (answered.push bad))
    expectDone (next config (answered ++ #[bad, bad])) "RepeatedFormatError"
    expectSample (next { config with maxConsecutiveFormatErrors := 0 } #[bad, bad, bad]),

  test "asking and output recovery compose" do
    let config : Config := { enabled with recoverOutput := true }
    let arguments := args "Which part of the output should be inspected next?" #[] "open_ended"
    let output := "\n".intercalate ((List.range 3000).map fun i => s!"line {i + 1} xxxx") ++ "\n"
    let history : Log := #[.sampled default .turn (response #[bash]),
      ran output (response := 3)]
    let (executor, calls) ← countingExecutor
    let (model, _) ← scripted #[response #[ask "q" arguments], response #[submit]]
    let a := agent config
    let (rt, asked, halt) ← drive a executor model (initialLog config "task" testUname) history
    match halt with
    | .question q =>
      assertEqual "the asking call" ((← assertOk <| logOf rt.store asked).index.callId? q.call) (some "q")
    | _ => fail "the recovery-enabled agent should ask normally"
    let replied ← assertOk <| replyText rt.store asked "Inspect the middle lines.\nKeep the output unchanged."
    let (final, halt) ← assertOk <| resume rt replied
    match halt with
    | .outcome outcome => assertEqual "submitted after the reply" outcome.status "Submitted"
    | _ => fail "expected submission after the reply"
    let finalLog ← assertOk <| logOf rt.store final
    let dialogue := view config finalLog
    checkQuestionResult dialogue (.str "Inspect the middle lines.\nKeep the output unchanged.") arguments
    check (dialogue.any fun
      | .tool "b" (.str shown) => contains shown "[output truncated; full output: /alaya/outputs/4-b.txt]"
      | _ => false) "output truncation must retain its recovery hint"
    assertEqual "no executor calls" (← calls.get) 0
]

end AskUserTests
