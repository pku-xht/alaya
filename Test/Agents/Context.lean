import Test.Support.Framework
import Test.Support.Scripted
import Alaya

/-! Context management in MiniSwe: a run stops cleanly before its context is full, and the same
way when the provider refuses a request as too long, which is the answer the log keeps; and the
view may omit old outputs in blocks, naming the files that hold them. -/

namespace ContextTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
open Alaya.Agents.MiniSwe
open Lean (Json)

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def response (id : String) (usage? : Option Chat.TokenUsage := none) : Chat.Response :=
  { toolCalls := #[bashCall id], finishReason? := some "tool_calls", usage? }

/-- A turn: the call `id`, whose command printed `output`, kept whole in its file. -/
private def turn (id : String) (output : String) (usage? : Option Chat.TokenUsage := none) : Item :=
  .turn (response id usage?) #[(bashCall id, Agents.Tools.Bash.result
    { output := { output, exitCode? := some 0 }, workspace := default
      file? := some s!"/alaya/outputs/{id}.txt" })]

/-- `n` turns, each a call `c<i>` whose output is 500 characters, after a task message. -/
private def turns (n : Nat) : History :=
  { items := #[.told (.user "task")] ++ (List.range n).toArray.map fun i =>
      turn s!"c{i}" (String.ofList (List.replicate 500 'x')) }

private def shownOutput (dialogue : Dialogue) (id : String) : String :=
  dialogue.findSome? (fun
    | .tool callId (.str shown) => if callId != id then none else
      (Json.parse shown).toOption >>= fun json => (json.getObjVal? "output" >>= Json.getStr?).toOption
    | _ => none) |>.getD ""

private def stored (dialogue : Dialogue) : List String :=
  dialogue.toList.map (·.toStored.compress)

private def masking : Config := { masking? := some { keepTurns := 2, block := 3 } }

/-- How apiyi refused a request too long for the model, through each API. -/
private def deepseekRefusal : String :=
  "{\"error\":{\"message\":\"This model's maximum context length is 1048576 tokens. However, you requested 2600030 tokens (2600030 in the messages, 0 in the completion). Please reduce the length of the messages or completion.\",\"type\":\"invalid_request_error\",\"code\":\"invalid_request_error\"}}"

private def lunaRefusal : String :=
  "{\"error\":{\"message\":\"Your input exceeds the context window of this model. Please adjust your input and try again.\",\"type\":\"invalid_request_error\",\"param\":\"input\",\"code\":\"context_length_exceeded\"}}"

/-- A model that answers `answers` first, then refuses every request as too long. -/
private def refusing (answers : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "refusing")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match answers[i]? with
      | some response => pure response
      | none => throw <| .contextExceeded "This model's maximum context length is 100 tokens." } }

/-- What MiniSwe does after its task, `task`, for a model of `context` tokens: sample, or end
before it. -/
private def afterTask (context? : Option Nat) (task : String) (config : Config := {}) : String :=
  match runOfConfig "mini-swe" config.toJson { testModelSpec with contextTokens? := context? } with
  | .error problem => problem
  | .ok run =>
    let log := settle run (opening task)
    match next run log with
    | .ask { op := .sample .., .. } => "sample"
    | _ => agentStatus log

def suite : Suite := Testing.suite "agents/context" #[
  iotest "the configuration records the reserve and masking, and rejects a bad block" do
    let json := masking.toJson
    if (json.getObjVal? "context_reserve").toOption != some (8000 : Nat) then throw <| IO.userError "no reserve"
    if (({} : Config).toJson.getObjVal? "mask_observations").toOption != some .null then
      throw <| IO.userError "masking should be off by default"
    match Config.fromJson json with
    | .ok again => if again.masking? != masking.masking? then throw <| IO.userError "no round trip"
    | .error e => throw <| IO.userError e
    for bad in [Json.mkObj [("keep_turns", 2), ("block", 0)], .mkObj [("block", 3)], .mkObj [("keep_turns", 2), ("block", 3), ("x", 1)]] do
      if (Config.fromJson (.mkObj [("name", "mini-swe"), ("mask_observations", bad)])).toOption.isSome then
        throw <| IO.userError s!"accepted {bad.compress}",

  iotest "the boundary moves in blocks, and between its moves the view only grows" do
    let m : Masking := { keepTurns := 2, block := 3 }
    let boundaries := (List.range 12).map m.omittedTurns
    if boundaries != [0, 0, 0, 0, 0, 3, 3, 3, 6, 6, 6, 9] then
      throw <| IO.userError s!"wrong boundaries: {boundaries}"
    for t in List.range 11 do
      let before := view masking (turns t)
      let after := view masking (turns (t + 1))
      let grows := (stored after).take before.size == stored before
      if grows != (m.omittedTurns (t + 1) == m.omittedTurns t) then
        throw <| IO.userError s!"turn {t + 1}: grows {grows}",

  iotest "an omitted output names its file, which holds it; short ones and recent ones stay" do
    let history := { turns 6 with items := (turns 6).items.push (turn "s" "ok") }
    -- Seven turns: the first three are omitted; `s` is in the last.
    let dialogue := view masking history
    let notice := shownOutput dialogue "c0"
    if notice != "[output omitted; full output: /alaya/outputs/c0.txt]" then
      throw <| IO.userError s!"wrong notice: {notice}"
    if shownOutput dialogue "c3" != String.ofList (List.replicate 500 'x') then
      throw <| IO.userError "a kept turn was omitted"
    let early : History := { items := #[.told (.user "task"), turn "s" "ok"] ++ (turns 6).items.extract 1 }
    if shownOutput (view masking early) "s" != "ok" then throw <| IO.userError "a short output was omitted"
    if stored (view {} history) != stored (view { masking? := none } history) then
      throw <| IO.userError "off changed the view",

  iotest "the context is the last measured request, its response, and what came since" do
    let task : Dialogue := #[.user "task"]
    let history : History := {
      items := #[.told (.user "task"), turn "c" (String.ofList (List.replicate 4000 'x'))]
      measured? := some (task, 1000, some 50) }
    let tokens := contextTokens history (view {} history)
    -- 4,000 characters of output, plus its JSON, at four characters a token.
    if tokens < 2050 || tokens > 2100 then throw <| IO.userError s!"wrong size: {tokens}"
    let unmeasured := contextTokens {} #[.user (String.ofList (List.replicate 400 'y'))]
    if unmeasured < 100 || unmeasured > 115 then throw <| IO.userError s!"wrong estimate: {unmeasured}"
    -- Once masking rewrites what was measured, the measure no longer holds: the whole is estimated.
    let measured (t : Nat) : History :=
      let before := view masking (turns (t - 1))
      { turns t with measured? := some (before, 1, some 1) }
    let small := contextTokens (measured 4) (view masking (measured 4))
    if small > 200 then throw <| IO.userError s!"not measured before the boundary moves: {small}"
    let moved := contextTokens (measured 5) (view masking (measured 5))
    if moved != Chat.estimateTokens (view masking (measured 5)) then
      throw <| IO.userError s!"measured across a move of the boundary: {moved}"
    -- The limit is the model's context less the reserve, or less its output size when smaller.
    let model : Models.Spec := { name := "m", contextTokens? := some 3000, outputTokens? := some 500 }
    if contextLimit? {} model != some 2500 then throw <| IO.userError "wrong limit"
    if contextLimit? {} { name := "m" } != none then throw <| IO.userError "a limit with no context size",

  test "the agent stops before a request its model's context cannot hold, and only then" do
    let long := String.ofList (List.replicate 40000 'y')
    assertEqual "bounded" (afterTask (some 9000) long) "ContextExceeded"
    assertEqual "roomy" (afterTask (some 100000) long) "sample"
    assertEqual "unknown context" (afterTask none long) "sample"
    assertEqual "MiniVero too" (match runOfConfig "mini-vero" (.mkObj [])
        { testModelSpec with contextTokens? := some 9000 } with
      | .ok run => agentStatus (settle run (opening long))
      | .error problem => problem) "ContextExceeded",

  iotest "a provider's refusal of a too-long request is recognised, in either API's words" do
    for (label, status, body) in [("deepseek", 400, deepseekRefusal), ("luna", 400, lunaRefusal),
        ("too large", 413, "{\"error\":{\"message\":\"prompt is too long: 210000 tokens > 200000 maximum\"}}")] do
      if (Provider.Http.contextExceeded? status body).isNone then throw <| IO.userError s!"{label} not recognised"
    if Provider.Http.contextExceeded? 400 deepseekRefusal != some
        "This model's maximum context length is 1048576 tokens. However, you requested 2600030 tokens (2600030 in the messages, 0 in the completion). Please reduce the length of the messages or completion." then
      throw <| IO.userError "the provider's message is not kept"
    for (label, status, body) in [("another refusal", 400, "{\"error\":{\"message\":\"temperature must be finite\"}}"),
        ("a server failure", 500, deepseekRefusal), ("rate limit", 429, lunaRefusal)] do
      if (Provider.Http.contextExceeded? status body).isSome then throw <| IO.userError s!"{label} taken for an overflow"
    match ← (Provider.Responses.responseOf (Json.parse
        "{\"status\":\"failed\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"},\"output\":[]}"
        |>.toOption.getD .null)).toBaseIO with
    | .error (.contextExceeded "too long") => pure ()
    | _ => throw <| IO.userError "a failed Responses overflow is not one",

  test "a refused request ends the agent with ContextExceeded, and the draw it took is not lost" do
    let executor : Executor := { exec := fun _ _ _ _ => pure { output := "ok", exitCode? := some 0 } }
    match miniRun with
    | .error problem => fail problem
    | .ok run =>
      let rt ← runtime executor (some (← refusing #[response "c1"]))
      let tip ← start rt run
      let (ended, stop) ← assertOk <| Driver.drive rt run tip
      check (isIdle stop) "the agent is over"
      let log ← logAt rt ended
      match agentResult log with
      | some (.ok value) =>
        assertEqual "the agent's outcome" value.compress
          (outcome "ContextExceeded" (reason? := some
            "the provider refused the request: This model's maximum context length is 100 tokens.")).compress
      | _ => fail "the agent ends with an outcome, as it does before a request it knows is too long"
      assertEqual "the agent's status" (agentStatus log) "ContextExceeded"
      let refused? := log.findIdx? fun
        | .answered _ (.sample ..) (.error "This model's maximum context length is 100 tokens.") => true
        | _ => false
      let some refused := refused? | fail "the refusal is not logged as the answer, in the provider's words"
      -- The refusal took no draw: from the entry before it, the next sample is its first draw.
      let forest ← assertOk rt.store.forest
      let before := (forest.path ended)[refused - 1]!
      let again ← runtime executor (some (← refusing #[response "c2", { content? := some "x" }]))
      let again := { again with store := rt.store, workspaces := rt.workspaces }
      let (_, _) ← assertOk <| Driver.drive again run before { samples? := some 1 }
      let forest ← assertOk rt.store.forest
      let mut answered := 0
      for child in forest.childrenOf before do
        if let .answered _ _ (.ok _) := (← assertOk (rt.store.get forest child)).event then answered := answered + 1
      assertEqual "a response beside the refusal" answered 1
]

end ContextTests
