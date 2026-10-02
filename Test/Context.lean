import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! Context management in MiniSwe: a run stops cleanly before its context is full, and the
view may omit old outputs in blocks, naming the files that hold them. -/

namespace ContextTests

open Testing Alaya Alaya.Agent Alaya.Trajectory Alaya.Driver
open Alaya.Agent.MiniSwe

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def response (id : String) (usage? : Option Chat.TokenUsage := none) : Chat.Response :=
  { toolCalls := #[bashCall id], finishReason? := some "tool_calls", usage? }

/-- The output of the call `id` of the response at log position `response`. -/
private def observed (output : String) (response : Nat) : Event := ran output (response := response)

/-- `turns` turns, each a call `c<i>` whose output is 500 characters, after a task message. -/
private def turns (n : Nat) : Log :=
  #[.told (.user "task")] ++ (List.range n).foldl (init := #[]) fun log i =>
    log ++ #[.sampled default .turn (response s!"c{i}"), observed (String.ofList (List.replicate 500 'x')) (log.size + 1)]

private def shownOutput (dialogue : Dialogue) (id : String) : String :=
  dialogue.findSome? (fun
    | .tool callId (.str shown) => if callId != id then none else
      (Lean.Json.parse shown).toOption >>= fun json => (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
    | _ => none) |>.getD ""

private def stored (dialogue : Dialogue) : List String :=
  dialogue.toList.map (·.toStored.compress)

private def masking : Config := { masking? := some { keepTurns := 2, block := 3 } }

private def status : Effect ⊕ Outcome → String
  | .inr outcome => outcome.status
  | .inl (.sample ..) => "sample"
  | _ => "other"

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

def suite : Suite := Testing.suite "context" #[
  iotest "the configuration records the reserve and masking, and rejects a bad block" do
    let json := masking.toJson
    if (json.getObjVal? "context_reserve").toOption != some (8000 : Nat) then throw <| IO.userError "no reserve"
    if (({} : Config).toJson.getObjVal? "mask_observations").toOption != some .null then
      throw <| IO.userError "masking should be off by default"
    match Config.fromJson json with
    | .ok again => if again.masking? != masking.masking? then throw <| IO.userError "no round trip"
    | .error e => throw <| IO.userError e
    for bad in [Lean.Json.mkObj [("keep_turns", 2), ("block", 0)], .mkObj [("block", 3)], .mkObj [("keep_turns", 2), ("block", 3), ("x", 1)]] do
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
    let log := turns 6 ++ #[.sampled default .turn (response "s"), observed "ok" (turns 6).size]
    -- Seven turns: the first three are omitted; `s` is in the last.
    let dialogue := view masking log
    let notice := shownOutput dialogue "c0"
    if notice != "[output omitted; full output: /alaya/outputs/2-c0.txt]" then
      throw <| IO.userError s!"wrong notice: {notice}"
    if shownOutput dialogue "c3" != String.ofList (List.replicate 500 'x') then
      throw <| IO.userError "a kept turn was omitted"
    let early := view masking (#[.told (.user "task"), .sampled default .turn (response "s"), observed "ok" 1] ++ (turns 6).extract 1)
    if shownOutput early "s" != "ok" then throw <| IO.userError "a short output was omitted"
    if stored (view {} log) != stored (view { masking? := none } log) then throw <| IO.userError "off changed the view",

  iotest "the context is the last measured request, its response, and what came since" do
    let usage : Chat.TokenUsage := { input? := some 1000, output? := some 50 }
    let log : Log := #[.told (.user "task"), .sampled default .turn (response "c" (some usage)),
      observed (String.ofList (List.replicate 4000 'x')) 1]
    let size (config : Config) (log : Log) : Nat := Agent.contextTokens (next config) log (view config log)
    let tokens := size {} log
    -- 4,000 characters of output, plus its JSON, at four characters a token.
    if tokens < 2050 || tokens > 2100 then throw <| IO.userError s!"wrong size: {tokens}"
    let unmeasured := size {} #[.told (.user (String.ofList (List.replicate 400 'y')))]
    if unmeasured < 100 || unmeasured > 115 then throw <| IO.userError s!"wrong estimate: {unmeasured}"
    -- Once masking rewrites what was measured, the measure no longer holds: the whole is estimated.
    let measured (t : Nat) : Log := (turns t).map fun
      | .sampled digest purpose r => .sampled digest purpose { r with usage? := some { input? := some 1, output? := some 1 } }
      | event => event
    let small := size masking (measured 4)
    if small > 200 then throw <| IO.userError s!"not measured before the boundary moves: {small}"
    let moved := size masking (measured 5)
    if moved != estimateTokens (view masking (measured 5)) then
      throw <| IO.userError s!"measured across a move of the boundary: {moved}"
    -- The limit is the model's context less the reserve, or less its output size when smaller.
    let model : Models.Spec := { name := "m", contextTokens? := some 3000, outputTokens? := some 500 }
    if contextLimit? {} model != some 2500 then throw <| IO.userError "wrong limit"
    if contextLimit? {} { name := "m" } != none then throw <| IO.userError "a limit with no context size"
    let stops := (agent {} { model with contextTokens? := some 2500 }).next log
    let goes := (agent {} { model with contextTokens? := some 3000 }).next log
    if status stops != "ContextExceeded" || status goes != "sample" then
      throw <| IO.userError s!"{status stops}, {status goes}"
    if status ((agent {}).next log) != "sample" then throw <| IO.userError "no model, no check",

  test "an agent from the catalog knows its model's context; one checked for no run does not" do
    let model : Models.Spec := { name := "m", contextTokens? := some 100 }
    let log : Log := #[.told (.user (String.ofList (List.replicate 4000 'y')))]
    for definition in Catalog.all do
      let bounded ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name)]) model
      let unbounded ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name)])
      assertEqual s!"{definition.name} bounded" (status (bounded.next log)) "ContextExceeded"
      assertEqual s!"{definition.name} unbounded" (status (unbounded.next log)) "sample"
,

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
    match ← (Provider.Responses.responseOf (Lean.Json.parse
        "{\"status\":\"failed\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too long\"},\"output\":[]}"
        |>.toOption.getD .null)).toBaseIO with
    | .error (.contextExceeded "too long") => pure ()
    | _ => throw <| IO.userError "a failed Responses overflow is not one",

  test "a refused request ends the run as ContextExceeded, recorded, and a later draw is not lost" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    let workspaces ← Testing.workspaces
    let project := (← scratch) / "proj"
    IO.FS.createDirAll project
    let work := (← scratch) / "work"
    IO.FS.createDirAll work
    let executor : Executor := { exec := fun _ _ _ _ => pure { output := "ok", exitCode? := some 0 }
                                 uname := pure default }
    let outputsDir := (← scratch) / "outputs"
    let rt (model : Model) : Runtime :=
      { store, workspaces, workDir := work, outputsDir, executor, model, agent := agent {} }
    let root ← assertOk <| createRoot store workspaces #[.told (.user "task")] project
      (← testImage) (agent := testAgent) (model := testModel)
    let first ← refusing #[response "c1"]
    let (ended, halt) ← assertOk <| resume (rt first) root
    match halt with
    | .outcome o => assertEqual "status" o.status "ContextExceeded"
    | _ => fail "the run did not end"
    let state ← assertOk <| getState store ended
    assertEqual "nothing sampled" state.appended.size 0
    let reason? := state.outcome?.bind (·.reason?)
    check (reason?.any fun reason => (reason.splitOn "maximum context length is 100 tokens").length > 1)
      s!"the provider's words are not kept: {reason?}"
    check ((← assertOk <| getState store (state.parent?.getD root)).appended.size > 0) "the turn before was not kept"
    -- The refusal took no draw: from the same parent, the next sample is its first draw again.
    let parent := state.parent?.getD root
    let again ← refusing #[response "c2"]
    let (_, halt) ← assertOk <| resume (rt again) parent { steps? := some 1 }
    check (halt != .outcome { status := "ContextExceeded" }) "the parent's first draw was spent by the refusal"
]

end ContextTests
