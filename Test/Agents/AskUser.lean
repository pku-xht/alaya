import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! Questions, and the tool that lets a model ask them. A program asks with `ask`: the question
goes into the log, the run waits in the frame that asked, and a reply is a notice to that frame,
checked against the question before it is appended. `ask_user` is a model's way to do that, for
the kinds of question its configuration names. All model responses are scripted; an executor
that counts calls detects unwanted side effects. -/

namespace AskUserTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Alaya.Agents
open Alaya.Agents.MiniSwe (Config parseActions)
open Lean (Json)

private def args (question : String := "Which interpretation?\nThe examples disagree.")
    (options : Array String := #["Use the written specification", "Use the examples"])
    (questionType : String := "single_choice") : Json :=
  .mkObj [("question_type", questionType), ("question", question),
    ("options", .arr (options.map Json.str))]

private def askOne (id : String := "q") (arguments : Json := args) : Chat.ToolCall :=
  { id, name := "ask_user", arguments }

private def bash : Chat.ToolCall :=
  { id := "b", name := "bash", arguments := .mkObj [("command", "touch must-not-run")] }

private def submit : Chat.ToolCall :=
  { id := "s", name := "submit", arguments := .mkObj [("message", "done")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def enabled : Config :=
  { tools := #["bash", "submit", "ask_user"], questionTypes := Question.Kind.all }

/-- Every kind of question, as a configuration names them. -/
private def everyKind : Json := .arr (Question.Kind.all.map fun kind => Json.str kind.name)

/-- The `tools` a configuration of agent `name` names to offer asking, besides its defaults. -/
private def askingTools (name : String) : Json :=
  .arr ((#["bash", "submit"] ++ (if name == "mini-vero" then #["time_budget"] else #[]) ++
    #["ask_user"]).map Json.str)

/-- The agent `name`, with a configuration that offers asking, with `extra` fields. -/
private def asking (name : String) (extra : List (String × Json) := []) : String × Json :=
  (name, .mkObj ([("tools", askingTools name), ("question_types", everyKind)] ++ extra))

private def countingExecutor : IO (Executor × IO.Ref Nat) := do
  let calls ← IO.mkRef 0
  pure ({ exec := fun _ _ _ _ => do
            calls.modify (· + 1)
            pure { output := "unexpected execution", exitCode? := some 0 } }, calls)

/-- A model that answers `responses` in order, keeping every request it is sent. -/
private def scripted (responses : Array Chat.Response) : IO (Model × IO.Ref (Array Chat.Request)) := do
  let index ← IO.mkRef 0
  let requests ← IO.mkRef #[]
  pure ({
    identity := .mkObj [("model", "scripted-askOne-user")]
    sample := fun request => do
      Result.fromIO Error.cache <| requests.modify (·.push request)
      pure { next := do
        let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
        match responses[i]? with
        | some r => pure r
        | none => throw <| Error.protocol "scripted model exhausted" } }, requests)

/-- Runs `k` with the run of `agent`. -/
private def withRun (agent : String × Json) (k : Scope Agent → TestM Unit) : TestM Unit :=
  match runOfConfig agent.1 agent.2 with
  | .ok run => k run
  | .error problem => fail problem

/-- What the model was shown as the result of the call `q`: the observation, read back. -/
private def shownResult (request : Chat.Request) : TestM Json := do
  let some shown := request.messages.findSome? fun
      | .tool "q" (.str text) => some text
      | _ => none
    | fail "the answer must be the asking call's observation"
  assertOk <| Result.fromExcept Error.protocol (Json.parse shown)

/-- Appends a reply to the question the log at `tip` waits on, read from `text` against the
question's form, or that the person cannot answer. -/
private def replyAt (rt : Driver.Runtime) (run : Scope Agent) (tip : Hash) (text? : Option String) :
    Result Hash := do
  let forest ← rt.store.forest
  let log ← rt.store.log forest tip
  let next := next run log
  let some (_, question) := questionOf? next | throw <| .input "no question waits for a reply"
  let reply ← match text? with
    | some text => Result.fromExcept Error.input (question.parseReply text)
    | none => pure .unavailable
  let event ← Result.fromExcept Error.input (replyTo next reply)
  pure (← Driver.append rt.store run tip event).1

def suite : Suite := Testing.suite "agents/ask-user" #[
  test "both agents keep their default prompts and tools when asking is disabled" do
    for definition in Catalog.all.filter (·.name != Catalog.grader.name) do
      let plain ← assertOk <| Catalog.complete definition.name (.mkObj [])
      let names := ((plain.getObjVal? "tools" >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
      check (!names.contains "ask_user") s!"{definition.name} offers asking by default"
      let enabled ← assertOk <| Catalog.complete definition.name (asking definition.name).2
      let names := ((enabled.getObjVal? "tools" >>= Json.getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
      check (names.contains "ask_user") s!"{definition.name} does not offer asking when asked to"
    let opening (config : Config) : String :=
      match (MiniSwe.openingMessages config "task" testUname)[1]? with
      | some (Chat.Message.user text) => text
      | _ => ""
    assertStringEq "asking only appends its instruction" (opening enabled)
      (opening {} ++ "\n\n" ++ Tools.AskUser.instruction Question.Kind.all),

  test "settings enable asking in both agents, round-trip, and reject wrong types" do
    for definition in Catalog.all.filter (·.name != Catalog.grader.name) do
      let config ← assertOk <| Catalog.resolve definition.name
        #[{ path := ["tools"], value := askingTools definition.name },
          { path := ["question_types"], value := everyKind }]
      assertEqual s!"{definition.name} round-trips" (← assertOk <| Catalog.complete definition.name config).compress config.compress
      assertError "a string is no list of tools" (Catalog.resolve definition.name
        #[{ path := ["tools"], value := "ask_user" }]) fun
        | .input _ => true
        | _ => false
      assertError "an unknown tool" (Catalog.resolve definition.name
        #[{ path := ["tools"], value := .arr #["bash", "submit", "ask_everyone"] }]) fun
        | .input _ => true
        | _ => false,

  test "single choice adds a platform answer while retaining model candidates verbatim" do
    let question := "  Which rule applies?\nContext: α < β.  "
    let candidates := #[" Keep α ", "Change β\nwith evidence"]
    let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question Question.Kind.all (args question candidates))
    assertEqual "a choice of the original candidates" form.form (.singleChoice candidates)
    assertEqual "original question" form.text question
    let rendered := form.render
    check (rendered.startsWith question) "the question and context must retain their original wording"
    check (contains rendered "\n1.  Keep α \n2. Change β\nwith evidence")
      "numbered candidates must retain their wording"
    check (contains rendered "none_of_above. None of the above") "the platform adds its reserved answer"
    assertEqual "one platform label" (rendered.splitOn "None of the above").length 2
    check (contains rendered "Select exactly one answer") "the answer is single choice"
    match parseActions (response #[askOne "q" (args question candidates)]) enabled with
    | .calls calls => assertEqual "the call" (calls.map (·.name)) #["ask_user"]
    | .formatError message => fail s!"valid choices should parse: {message}"
    for (questionType, expectedForm) in #[("yes_no", Question.Form.yesNo),
        ("open_ended", Question.Form.openEnded)] do
      let arguments := args question #[] questionType
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.question Question.Kind.all arguments)
      assertEqual "question form" form.form expectedForm
      assertEqual "original question" form.text question
      check (!contains form.render "none_of_above") s!"{questionType} must not offer the reserved single-choice answer",

  test "invalid question types, arguments, and mixed calls cannot run a command" do
    let malformed : Array Json := #[
      .null,
      .mkObj [("question", "q"), ("options", .arr #[.str "a", .str "b"])],
      .mkObj [("question_type", "single_choice"), ("options", .arr #[.str "a", .str "b"])],
      .mkObj [("question_type", "single_choice"), ("question", "q")],
      (args).setObjVal! "question_type" "unknown",
      (args).setObjVal! "question_type" "multiple_choice",
      (args).setObjVal! "question_type" Json.null,
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
      args "q" #["a", "b"] "open_ended",
      (args).setObjVal! "unexpected" true]
    let cases := malformed.map (fun json => response #[askOne "q" json]) ++ #[
      response #[bash, askOne], response #[askOne, bash], response #[askOne, submit],
      response #[submit, askOne], response #[askOne, askOne "second"],
      response #[{ (askOne) with invalidArguments? := some "{\"question_type\":" }]]
    for bad in cases do
      match parseActions bad enabled with
      | .formatError _ => pure ()
      | .calls _ => fail s!"accepted malformed or mixed response: {bad.toolCalls.map (·.name)}"
    -- Driven, a malformed question is a format error: the run never waits, and nothing runs.
    withRun (asking "mini-swe" [("max_consecutive_format_errors", 1)]) fun run => do
      for bad in cases.extract 0 4 ++ cases.extract (cases.size - 6) cases.size do
        let (executor, calls) ← countingExecutor
        let (model, _) ← scripted #[bad]
        let (rt, last, stop) ← drive run executor model
        if isIdle stop then assertEqual "rejected turn outcome" (agentStatus (← logAt rt last)) "RepeatedFormatError"
        else fail "an invalid question must not wait for an answer"
        assertEqual "executor calls" (← calls.get) 0,

  test "typed questions record candidate, none-of-above, yes/no, open and unavailable replies" do
    let cases : Array (String × Json × Array (Option String × Json)) := #[
      ("yes_no", args "Keep the public API?\nContext: callers depend on it." #[] "yes_no",
        #[(some "yes", "yes"), (some "no", "no")]),
      ("single_choice", args "Which change should be included?" #["Keep α", "Check β\nwith evidence", "Document γ"],
        #[(some "1", (1 : Json)), (some "3", (3 : Json)), (some "none_of_above", "none_of_above")]),
      ("open_ended", args "How should we handle the boundary case?" #[] "open_ended",
        #[(some "  Keep the public API.\nPreserve the literal \"[]\".\n理由：边界条件不同。\n",
            "  Keep the public API.\nPreserve the literal \"[]\".\n理由：边界条件不同。\n"),
          (some "[]", "[]"), (some (String.ofList [Char.ofNat 0x200B]), .str (String.ofList [Char.ofNat 0x200B]))])]
    for definition in Catalog.all.filter (·.name != Catalog.grader.name) do
      for (questionType, arguments, answers) in cases do
        let answers := answers.push (none, .mkObj [("status", "unavailable")])
        withRun (asking definition.name) fun run => do
          let (executor, calls) ← countingExecutor
          let continuations := (List.replicate answers.size (response #[submit])).toArray
          let (model, requests) ← scripted (#[response #[askOne "q" arguments]] ++ continuations)
          let rt ← runtime executor (some model)
          let tip ← start rt run
          let (waiting, stop) ← assertOk <| Driver.drive rt run tip
          match stop with
          | .waits frame (some question) =>
            assertEqual "the asking call's frame" frame ⟪"session", "agent", "ask_user"⟫
            assertEqual "the form" question.form.name questionType
          | _ => fail "the run must wait for the answer"
          -- Every answer forks the waiting log: each is a branch of its own.
          for (text?, shown) in answers do
            let replied ← assertOk <| replyAt rt run waiting text?
            let (final, stop) ← assertOk <| Driver.drive rt run replied
            if isIdle stop then assertEqual "submitted after the reply" (agentStatus (← logAt rt final)) "Submitted"
            else fail "the run must go on after the reply"
            let some request := (← requests.get).back? | fail "no request after the reply"
            assertEqual s!"{questionType} answer in the model's view" (← shownResult request).compress shown.compress
          let forest ← assertOk rt.store.forest
          assertEqual "one branch per answer" (forest.childrenOf waiting).size answers.size
          assertEqual "one question and one continuation each" (← requests.get).size (1 + answers.size)
          assertEqual "answers never execute" (← calls.get) 0,

  test "a reply is refused where no question waits, in another form, or a second time" do
    withRun (asking "mini-swe") fun run => do
      let (executor, _) ← countingExecutor
      let (model, _) ← scripted #[response #[askOne "q" (args "Keep it?" #[] "yes_no")], response #[submit]]
      let rt ← runtime executor (some model)
      let tip ← start rt run
      assertError "no question yet" (replyAt rt run tip (some "yes")) fun | .input _ => true | _ => false
      let (waiting, _) ← assertOk <| Driver.drive rt run tip
      let log ← logAt rt waiting
      match replyTo (next run log) (.choice 1) with
      | .error message => check (contains message "yes_no") s!"says the form: {message}"
      | .ok _ => fail "a choice answers no yes/no question"
      for text in ["maybe", "YES", " yes ", "no\n", "true", "1", "\"yes\"", "none_of_above", ""] do
        assertError s!"{repr text} is no yes/no answer" (replyAt rt run waiting (some text)) fun
          | .input _ => true
          | _ => false
      let forest ← assertOk rt.store.forest
      assertEqual "nothing was appended" (forest.childrenOf waiting).size 0
      let replied ← assertOk <| replyAt rt run waiting (some "yes")
      assertError "a second reply" (replyAt rt run replied (some "no")) fun | .input _ => true | _ => false,

  test "a call's arguments read as a question only when it can be asked" do
    let question ← assertOk <| Result.fromExcept Error.protocol
      (Tools.AskUser.question Question.Kind.all (args "Which?" #["first", "second"]))
    assertEqual "its form" question.form (.singleChoice #["first", "second"])
    for arguments in #[Json.null, args " \n" #["a", "b"], args "q" #["only"], args "q" #["same", " same "],
        args "q" #["valid", " \n"], args "q" #["valid", "None of the above"], args "q" #["a", "b"] "yes_no",
        (args).setObjVal! "question_type" "unknown", (args).setObjVal! "options" "not an array"] do
      check (Tools.AskUser.question Question.Kind.all arguments).toOption.isNone
        s!"a question was read from {arguments.compress}",

  test "a program asks without any tool: the question is in the log, and a reply to its frame answers it" do
    let deploy : Question := { text := "Deploy?", form := .yesNo }
    let program : Computation Agent Json := do
      let first ← Alaya.Core.ask deploy
      let second ← Alaya.Core.ask { text := "Which region?", form := .singleChoice #["east", "west"] }
      return .str s!"{first.line}, {second.line}"
    do
      let run := runOf fun _ => program
      let log := settle run opening
      check (log.back? matches some (.asked ⟪"session", "agent"⟫ _)) "the question is the last event: a mark of the program"
      check (log.any fun | .asked ⟪"session", "agent"⟫ question => question == deploy | _ => false) "the question, whole"
      match next run log with
      | .waits ⟪"session", "agent"⟫ (some question) => assertEqual "the question the run waits on" question deploy
      | _ => fail "the run waits on the question, in the frame that asked"
      -- A reply that does not fit is refused; one that fits is taken, and the next question asked.
      check (replyTo (next run log) (.choice 1)).toOption.isNone "a choice answers no yes/no question"
      let reply ← assertOk <| Result.fromExcept Error.input (replyTo (next run log) .yes)
      check (reply matches .arrived (.replied ⟪"session", "agent"⟫ .yes)) "the reply is addressed to the frame that asked"
      let log := settle run (log.push reply)
      match next run log with
      | .waits ⟪"session", "agent"⟫ (some question) => assertEqual "the second question" question.text "Which region?"
      | _ => fail "the run waits on the second question, asked from the same frame"
      -- The first reply is read already: it does not answer the second question.
      check (replyTo (next run log) .yes).toOption.isNone "yes answers no choice"
      let reply ← assertOk <| Result.fromExcept Error.input (replyTo (next run log) (.choice 2))
      let log := settle run (log.push reply)
      check (log.any fun | .returned ⟪"session", "agent"⟫ (.str "yes, 2") => true | _ => false) "the program went on with both replies"
      assertEqual "two questions asked" (log.filter (· matches .asked ..)).size 2
      check (replyTo (next run log) .yes).toOption.isNone "no question waits once the agent is over"
    -- A question that cannot be asked is a failure where it is asked, and nothing waits.
    do
      let run := runOf fun _ => Json.str <$> (·.line) <$> Alaya.Core.ask { text := " \n" }
      let log := settle run opening
      check (log.any fun | .failed ⟪"session", "agent"⟫ error => contains error "blank" | _ => false) "a blank question fails"
      check (!log.any (· matches .asked ..)) "and is never asked",

  test "ask_user lets a model ask only the kinds of question its configuration names" do
    let only (kinds : Array Question.Kind) : Config :=
      { tools := #["bash", "submit", "ask_user"], questionTypes := kinds }
    let schema (config : Config) : String :=
      (((MiniSwe.tools config).find? (·.name == "ask_user")).map (·.toJson.compress)).getD ""
    -- Yes/no alone: no other kind is named anywhere a model sees, and there are no options.
    let yesNo := only #[.yesNo]
    check (contains (schema yesNo) "yes_no") "the schema names yes_no"
    for absent in ["single_choice", "open_ended", "options"] do
      check (!contains (schema yesNo) absent) s!"the schema of a yes/no tool names {absent}"
      check (!contains (Tools.AskUser.instruction #[.yesNo]) absent) s!"its instruction names {absent}"
    match parseActions (response #[askOne "q" (.mkObj [("question_type", "yes_no"), ("question", "Keep it?")])]) yesNo with
    | .calls _ => pure ()
    | .formatError message => fail s!"a yes/no question is allowed: {message}"
    for refused in #[args "Which?" #["a", "b"], args "What?" #[] "open_ended"] do
      match parseActions (response #[askOne "q" refused]) yesNo with
      | .formatError _ => pure ()
      | .calls _ => fail s!"a kind that is not allowed was accepted: {refused.compress}"
    -- With every kind, the words are the ones the tool always had.
    check (contains (Tools.AskUser.instruction Question.Kind.all)
      "choose question_type: yes_no for a yes/no answer, single_choice to select exactly one of at least two distinct candidates, or open_ended for a nonblank free-text answer.")
      "the instruction for every kind"
    -- The kinds are chosen with the tool: none by default, and none without it.
    for definition in Catalog.all.filter (·.name != Catalog.grader.name) do
      let config (fields : List (String × Json)) : Json := .mkObj fields
      for (fields, problem) in #[
          ([("tools", askingTools definition.name)], "must say which kinds"),
          ([("tools", askingTools definition.name), ("question_types", .arr #[])], "must say which kinds"),
          ([("question_types", everyKind)], "which 'tools' does not offer"),
          ([("tools", askingTools definition.name), ("question_types", .arr #["yes_no", "maybe"])], "unknown kind"),
          ([("tools", askingTools definition.name), ("question_types", .arr #["yes_no", "yes_no"])], "twice"),
          ([("tools", askingTools definition.name), ("question_types", "yes_no")], "must be an array")] do
        assertError s!"{definition.name} with {(config fields).compress}" (Catalog.complete definition.name (config fields)) fun
          | .input message => contains message problem
          | _ => false
      let one ← assertOk <| Catalog.complete definition.name (config [("tools", askingTools definition.name),
        ("question_types", .arr #["open_ended"])])
      assertEqual s!"{definition.name} records the kinds" ((one.getObjVal? "question_types").toOption.map (·.compress))
        (some "[\"open_ended\"]"),

  test "an agent's tools must include bash and submit, each tool once" do
    for definition in Catalog.all.filter (·.name != Catalog.grader.name) do
      for (tools, problem) in #[(#["submit"], "must include bash"), (#["bash"], "must include submit"),
          (#["bash", "submit", "bash"], "names bash twice"),
          (#["bash", "submit", "ask_user", "ask_user"], "names ask_user twice")] do
        assertError s!"{definition.name} with {tools}"
          (Catalog.complete definition.name (.mkObj [("tools", .arr (tools.map Json.str)),
            ("question_types", if tools.contains "ask_user" then everyKind else .arr #[])])) fun
          | .input message => contains message problem
          | _ => false,

  test "asking only appends its instruction: to MiniVero's opening, and to a format error after other tools'" do
    let veroOpening (tools : Array String) : String :=
      let config : MiniVero.Config := { base := { ({} : MiniVero.Config).base with
        tools, questionTypes := if tools.contains "ask_user" then Question.Kind.all else #[] } }
      match (MiniVero.openingMessages config "task" testUname)[1]? with
      | some (Chat.Message.user text) => text
      | _ => ""
    assertStringEq "MiniVero's opening" (veroOpening #["bash", "submit", "time_budget", "ask_user"])
      (veroOpening #["bash", "submit", "time_budget"] ++ "\n\n" ++ Tools.AskUser.instruction Question.Kind.all)
    for recoverOutput in [false, true] do
      let plain : Config := { recoverOutput }
      let both : Config := { plain with tools := #["bash", "submit", "time_budget", "ask_user"]
                                        questionTypes := Question.Kind.all }
      assertStringEq s!"the format error, recover_output {recoverOutput}"
        (MiniSwe.formatErrorMessage "x" true none both)
        (MiniSwe.formatErrorMessage "x" true none plain ++ "\n\n" ++ Tools.TimeBudget.instruction ++
          "\n\n" ++ Tools.AskUser.instruction Question.Kind.all),

  test "a question consumes its model turn and a reply leads to the next one" do
    withRun (asking "mini-swe") fun run => do
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[response #[askOne]]
      let rt ← runtime executor (some model)
      let (waiting, stop) ← assertOk <| Driver.drive rt run (← start rt run) { samples? := some 1 }
      match stop with
      | .waits _ (some _) => pure ()
      | _ => fail "the last allowed model turn may still askOne its question"
      let replied ← assertOk <| replyAt rt run waiting (some "2")
      let (_, stop) ← assertOk <| Driver.drive rt run replied { samples? := some 0 }
      check (stop matches .paused _) "after the reply, the agent goes on to sample"
      assertEqual "sample count" (← requests.get).size 1
      assertEqual "executor count" (← calls.get) 0,

  test "invalid asks count as consecutive format errors and a valid askOne resets the streak" do
    let bad := response #[askOne "bad" (args "q" #["only one"])]
    let prose : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    withRun (asking "mini-swe" [("max_consecutive_format_errors", 2)]) fun run => do
      let (executor, _) ← countingExecutor
      let (model, requests) ← scripted #[prose, response #[askOne], bad, bad]
      let rt ← runtime executor (some model)
      let (waiting, _) ← assertOk <| Driver.drive rt run (← start rt run)
      let replied ← assertOk <| replyAt rt run waiting (some "none_of_above")
      let (final, _) ← assertOk <| Driver.drive rt run replied
      assertEqual "two in a row after the askOne" (agentStatus (← logAt rt final)) "RepeatedFormatError"
      assertEqual "the askOne reset the streak" (← requests.get).size 4,

  test "the format-error limit can be turned off, and a person's message does not reset the streak" do
    let prose : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    withRun (asking "mini-swe" [("max_consecutive_format_errors", 0)]) fun run => do
      let (executor, _) ← countingExecutor
      let (model, requests) ← scripted #[prose, prose, prose, prose, response #[submit]]
      let (rt, last, _) ← drive run executor model
      assertEqual "no limit" (agentStatus (← logAt rt last)) "Submitted"
      assertEqual "every response was sampled" (← requests.get).size 5
    withRun (asking "mini-swe" [("max_consecutive_format_errors", 2)]) fun run => do
      let (executor, _) ← countingExecutor
      let (model, requests) ← scripted #[prose, prose]
      let rt ← runtime executor (some model)
      let (paused, stop) ← assertOk <| Driver.drive rt run (← start rt run) { samples? := some 1 }
      check (stop matches .paused _) "paused after the first malformed response"
      let (told, _) ← assertOk <| Driver.append rt.store run paused (.arrived (.said "call a tool"))
      let (final, _) ← assertOk <| Driver.drive rt run told
      assertEqual "two in a row, a person's message between them" (agentStatus (← logAt rt final)) "RepeatedFormatError"
      let some request := (← requests.get)[1]? | fail "no second request"
      check (request.messages.any fun | .user text => contains text "call a tool" | _ => false)
        "the message reached the model",

  test "a reply adds nothing to the run's time, however long the person took" do
    withRun (asking "mini-vero") fun run => do
      let (executor, _) ← countingExecutor
      let timeCall : Chat.ToolCall := { id := "t", name := "time_budget", arguments := .mkObj [] }
      let (model, _) ← scripted #[response #[askOne "q" (args "Keep it?" #[] "yes_no")], response #[timeCall],
        response #[submit]]
      let rt ← runtime executor (some model)
      let limits : Driver.Limits := { budgetMs? := some 3600000 }
      let spent (tip : Hash) : TestM Nat := do
        let forest ← assertOk rt.store.forest
        pure ((← assertOk <| rt.store.entries forest tip).foldl (fun ms entry => ms + entry.elapsedMs) 0)
      let (waiting, _) ← assertOk <| Driver.drive rt run (← start rt run) limits
      let before ← spent waiting
      IO.sleep 500
      let replied ← assertOk <| replyAt rt run waiting (some "yes")
      assertEqual "the reply took no run time" (← spent replied) before
      let (final, _) ← assertOk <| Driver.drive rt run replied limits
      let log ← logAt rt final
      let some timing := log.findSome? fun | .answered _ .time (.ok (.timing t)) => some t | _ => none
        | fail "the clock was read"
      check (timing.spentMs < before + 500) s!"the wait was counted: {timing.spentMs} ms after {before} ms"
      assertEqual "the budget is the invocation's" timing.budgetMs? (some 3600000)
      assertEqual "submitted" (agentStatus log) "Submitted"
]

end AskUserTests
