import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! Questions, and the tool that lets a model ask them. A program asks with `ask`: the question
goes into the log, the run waits in the frame that asked, and a reply is a notice to that frame,
checked against the question before it is appended. `ask_user` is a model's way to do that, for
the kinds of question its configuration names, and only MiniVero offers it. All model responses
are scripted; an executor that counts calls detects unwanted side effects. -/

namespace AskUserTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Alaya.Agents

/-- MiniVero's configuration: the agent that offers `ask_user`. -/
private abbrev Config := MiniVero.Config

/-- A response as MiniVero, and the routines of its calls, take it: the calls that ask, or the
first refusal. -/
private inductive Parsed where
  | calls (calls : Array Chat.ToolCall)
  | formatError (problem : String)

/-- What MiniVero, configured so, refuses of a call, or the `ask_user` routine refuses of the
call its tool makes. -/
private def refusal? (config : Config) (response : Chat.Response) (call : Chat.ToolCall) : Option String :=
  match Basic.problem? config.tools response call, config.tools.find? (·.name == call.name) with
  | some problem, _ => some problem
  | none, some tool =>
    if call.name != "ask_user" then none
    else match Tools.AskUser.read (tool.arguments call.arguments) with
      | .ok _ => none
      | .error problem => some problem
  | none, none => none

/-- How MiniVero, configured so, and its routines take a response. -/
private def parseActions (response : Chat.Response) (config : Config := {}) : Parsed :=
  match response.toolCalls.findSome? (refusal? config response) with
  | some problem => .formatError problem
  | none => .calls response.toolCalls
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

private def enabled : Config := { questionTypes := Question.Kind.all }

/-- Every kind of question, as a configuration names them. -/
private def everyKind : Json := .arr (Question.Kind.all.map fun kind => Json.str kind.name)

/-- MiniVero, with a configuration that offers asking every kind of question, and `extra` fields. -/
private def asking (extra : List (String × Json) := []) : String × Json :=
  ("mini-vero", .mkObj ([("question_types", everyKind)] ++ extra))

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

/-- What the model was shown as the result of the call `q`. -/
private def shownResult (request : Chat.Request) : TestM String := do
  let some shown := request.messages.findSome? fun
      | .tool "q" (.str text) => some text
      | _ => none
    | fail "the answer must be the asking call's observation"
  pure shown

/-- A result as the model is shown it: a text as it is, anything else as JSON. -/
private def asShown : Json → String
  | .str text => text
  | json => json.pretty

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
  test "MiniVero offers ask_user only for the kinds of question its configuration names, and MiniSwe never" do
    let plain ← assertOk <| Builtin.catalog.complete "mini-vero" (.mkObj [])
    assertEqual "no kinds by default" ((plain.getObjVal? "question_types").toOption.map (·.compress)) (some "[]")
    check (!(({} : Config).tools.any (·.name == "ask_user"))) "so no ask_user"
    check (enabled.tools.any (·.name == "ask_user")) "with kinds, ask_user"
    let resolved ← assertOk <| Builtin.catalog.resolve "mini-vero" #[{ path := ["question_types"], value := everyKind }]
    assertEqual "round-trips" (← assertOk <| Builtin.catalog.complete "mini-vero" resolved).compress resolved.compress
    for field in ["question_types", "tools"] do
      assertError s!"mini-swe takes no {field}" (Builtin.catalog.complete "mini-swe" (.mkObj [(field, everyKind)])) fun
        | .input message => contains message s!"unknown field '{field}'"
        | _ => false
    let opening (config : Config) : String :=
      match (MiniVero.openingMessages config "task" testUname)[1]? with
      | some (Chat.Message.user text) => text
      | _ => ""
    -- Asking adds its instruction where the tool stands among the others, and changes nothing else.
    assertStringEq "asking only adds its instruction" (opening enabled)
      ((opening {}).replace ("\n\n" ++ Tools.Subagent.instruction)
        ("\n\n" ++ Tools.AskUser.instruction Question.Kind.all ++ "\n\n" ++ Tools.Subagent.instruction)),

  test "single choice offers None of the above beside the model's options, kept verbatim" do
    let question := "  Which rule applies?\nContext: α < β.  "
    let candidates := #[" Keep α ", "Change β\nwith evidence"]
    let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.read (args question candidates))
    assertEqual "a choice of the original candidates" form.form (.singleChoice candidates)
    assertEqual "original question" form.text question
    let rendered := form.render
    check (rendered.startsWith question) "the question and context must retain their original wording"
    check (contains rendered "\n1.  Keep α \n2. Change β\nwith evidence")
      "numbered candidates must retain their wording"
    check (contains rendered "none_of_above: None of the above") "None of the above is offered"
    assertEqual "once" (rendered.splitOn "None of the above").length 2
    check (contains rendered "Select exactly one answer") "the answer is single choice"
    match parseActions (response #[askOne "q" (args question candidates)]) enabled with
    | .calls calls => assertEqual "the call" (calls.map (·.name)) #["ask_user"]
    | .formatError message => fail s!"valid choices should parse: {message}"
    for (questionType, expectedForm) in #[("yes_no", Question.Form.yesNo),
        ("open_ended", Question.Form.openEnded)] do
      let arguments := args question #[] questionType
      let form ← assertOk <| Result.fromExcept Error.protocol (Tools.AskUser.read arguments)
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
      args "q" #["a", "b"] "open_ended"]
    -- A key the routine does not know is ignored, as a routine's arguments hold the agent's
    -- settings besides the model's.
    match parseActions (response #[askOne "q" ((args).setObjVal! "unexpected" true)]) enabled with
    | .calls _ => pure ()
    | .formatError problem => fail s!"an unknown key was refused: {problem}"
    let cases := malformed.map (fun json => response #[askOne "q" json]) ++ #[
      response #[bash, askOne], response #[askOne, bash], response #[askOne, submit],
      response #[submit, askOne], response #[askOne, askOne "second"],
      response #[{ (askOne) with invalidArguments? := some "{\"question_type\":" }]]
    for bad in cases do
      match parseActions bad enabled with
      | .formatError _ => pure ()
      | .calls _ => fail s!"accepted malformed or mixed response: {bad.toolCalls.map (·.name)}"
    -- Driven, a malformed question is answered with its problem: the run never waits, nothing
    -- of the response runs, and the run goes on.
    withRun (asking) fun run => do
      for bad in cases.extract 0 4 ++ cases.extract (cases.size - 6) cases.size do
        let (executor, calls) ← countingExecutor
        let (model, _) ← scripted #[bad, response #[submit]]
        let (rt, last, stop) ← drive run executor model
        if isIdle stop then assertEqual "the run goes on" (agentStatus (← logAt rt last)) "Submitted"
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
    for (questionType, arguments, answers) in cases do
      let answers := answers.push (none, .mkObj [("status", "unavailable")])
      withRun (asking) fun run => do
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
          assertEqual s!"{questionType} answer in the model's view" (← shownResult request) (asShown shown)
        let forest ← assertOk rt.store.forest
        assertEqual "one branch per answer" (forest.childrenOf waiting).size answers.size
        assertEqual "one question and one continuation each" (← requests.get).size (1 + answers.size)
        assertEqual "answers never execute" (← calls.get) 0,

  test "a reply is refused where no question waits, in another form, or a second time" do
    withRun (asking) fun run => do
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
      (Tools.AskUser.read (args "Which?" #["first", "second"]))
    assertEqual "its form" question.form (.singleChoice #["first", "second"])
    for arguments in #[Json.null, args " \n" #["a", "b"], args "q" #["only"], args "q" #["same", " same "],
        args "q" #["valid", " \n"], args "q" #["valid", "None of the above"], args "q" #["a", "b"] "yes_no",
        (args).setObjVal! "question_type" "unknown", (args).setObjVal! "options" "not an array"] do
      check (Tools.AskUser.read arguments).toOption.isNone
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
      check (log.any fun | .failed ⟪"session", "agent"⟫ (.refused error) => contains error "blank" | _ => false)
        "a blank question is refused"
      check (!log.any (· matches .asked ..)) "and is never asked",

  test "ask_user lets a model ask only the kinds of question its configuration names" do
    let only (kinds : Array Question.Kind) : Config := { questionTypes := kinds }
    let schema (config : Config) : String :=
      ((config.tools.find? (·.name == "ask_user")).map (·.definition.toJson.compress)).getD ""
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
    -- With a choice among the kinds, the instruction says what the schema cannot.
    assertStringEq "the instruction for every kind" (Tools.AskUser.instruction Question.Kind.all)
      ("You may ask the person a question with ask_user. Give enough context to answer it. " ++
       "A single_choice question needs at least two distinct options; the person may also answer " ++
       "None of the above, so do not list it yourself.")
    -- The kinds are named, each once.
    for (kinds, problem) in (#[(Json.arr #["yes_no", "maybe"], "not maybe"),
        (.arr #["yes_no", "yes_no"], "twice"), (.str "yes_no", "must be an array")] : Array (Json × String)) do
      assertError s!"with {kinds.compress}" (Builtin.catalog.complete "mini-vero" (.mkObj [("question_types", kinds)])) fun
        | .input message => contains message problem
        | _ => false
    let one ← assertOk <| Builtin.catalog.complete "mini-vero" (.mkObj [("question_types", .arr #["open_ended"])])
    assertEqual "it records the kinds" ((one.getObjVal? "question_types").toOption.map (·.compress))
      (some "[\"open_ended\"]"),

  test "a question consumes its model turn and a reply leads to the next one" do
    withRun (asking) fun run => do
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

  test "a bad question, and a response with no call, are answered, and the run goes on" do
    let bad := response #[askOne "bad" (args "q" #["only one"])]
    let prose : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
    withRun (asking) fun run => do
      let (executor, calls) ← countingExecutor
      let (model, requests) ← scripted #[prose, bad, response #[submit]]
      let (rt, last, _) ← drive run executor model
      assertEqual "submitted in the end" (agentStatus (← logAt rt last)) "Submitted"
      let some second := (← requests.get)[1]? | fail "no second request"
      check (second.messages.any fun | .user text => text == Basic.reminder prose | _ => false)
        "a response with no call is answered with the reminder"
      let some third := (← requests.get)[2]? | fail "no third request"
      check (third.messages.any fun | .tool "bad" (.str text) => contains text "at least two" | _ => false)
        "a bad question is answered with its problem"
      assertEqual "nothing ran" (← calls.get) 0,

  test "a reply adds nothing to the run's time, however long the person took" do
    withRun (asking) fun run => do
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
