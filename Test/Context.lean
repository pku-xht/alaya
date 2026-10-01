import Test.Framework
import Alaya

/-! Context management in MiniSwe: a run stops cleanly before its context is full, and the
view may omit old outputs in blocks, naming the files that hold them. -/

namespace ContextTests

open Testing Alaya Alaya.Agent
open Alaya.Agent.MiniSwe

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def response (id : String) (usage? : Option Chat.TokenUsage := none) : Chat.Response :=
  { toolCalls := #[bashCall id], finishReason? := some "tool_calls", usage? }

private def observed (id output : String) : Event :=
  .observation id (Output.toJson { output, exitCode? := some 0 })

/-- `turns` turns, each a call `c<i>` whose output is 500 characters, after a task message. -/
private def turns (n : Nat) : Log :=
  #[.message (.user "task")] ++ (List.range n).foldl (init := #[]) fun log i =>
    log ++ #[.response (response s!"c{i}"), observed s!"c{i}" (String.ofList (List.replicate 500 'x'))]

private def shownOutput (dialogue : Dialogue) (id : String) : String :=
  dialogue.findSome? (fun
    | .tool callId (.str shown) => if callId != id then none else
      (Lean.Json.parse shown).toOption >>= fun json => (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
    | _ => none) |>.getD ""

private def stored (dialogue : Dialogue) : List String :=
  dialogue.toList.map (·.toStored.compress)

private def masking : Config := { masking? := some { keepTurns := 2, block := 3 } }

private def status : Directive → String
  | .done outcome => outcome.status
  | .sample => "sample"
  | _ => "other"

def suite : Suite := Testing.suite "context" #[
  iotest "the configuration records the reserve and masking, and rejects a bad block" do
    let json := masking.toJson
    if (json.getObjVal? "context_reserve").toOption != some (32000 : Nat) then throw <| IO.userError "no reserve"
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
    let log := turns 6 ++ #[.response (response "s"), observed "s" "ok"]
    -- Seven turns: the first three are omitted; `s` is in the last.
    let dialogue := view masking log
    let notice := shownOutput dialogue "c0"
    if notice != "[output omitted; full output: /alaya/outputs/2-c0.txt]" then
      throw <| IO.userError s!"wrong notice: {notice}"
    if shownOutput dialogue "c3" != String.ofList (List.replicate 500 'x') then
      throw <| IO.userError "a kept turn was omitted"
    let early := view masking (#[.message (.user "task"), .response (response "s"), observed "s" "ok"] ++ (turns 6).extract 1)
    if shownOutput early "s" != "ok" then throw <| IO.userError "a short output was omitted"
    let files := (outputs masking log).map (·.1)
    if files != #["2-c0.txt", "4-c1.txt", "6-c2.txt"] then throw <| IO.userError s!"wrong files: {files}"
    if stored (view {} log) != stored (view { masking? := none } log) then throw <| IO.userError "off changed the view"
    if !(outputs {} log).isEmpty then throw <| IO.userError "files with masking off",

  iotest "the context is the last measured request, its response, and what came since" do
    let usage : Chat.TokenUsage := { input? := some 1000, output? := some 50 }
    let log : Log := #[.message (.user "task"), .response (response "c" (some usage)),
      observed "c" (String.ofList (List.replicate 4000 'x'))]
    let tokens := contextTokens {} log
    -- 4,000 characters of output, plus its JSON, at four characters a token.
    if tokens < 2050 || tokens > 2100 then throw <| IO.userError s!"wrong size: {tokens}"
    let unmeasured := contextTokens {} #[.message (.user (String.ofList (List.replicate 400 'y')))]
    if unmeasured != 100 then throw <| IO.userError s!"wrong estimate: {unmeasured}"
    -- The limit is the model's context less the reserve, or less its output size when smaller.
    let model : Models.Spec := { name := "m", contextTokens? := some 3000, outputTokens? := some 500 }
    if contextLimit? {} model != some 2500 then throw <| IO.userError "wrong limit"
    if contextLimit? {} { name := "m" } != none then throw <| IO.userError "a limit with no context size"
    let stops := (agent {} { model with contextTokens? := some 2500 }).next {} log
    let goes := (agent {} { model with contextTokens? := some 3000 }).next {} log
    if status stops != "ContextExceeded" || status goes != "sample" then
      throw <| IO.userError s!"{status stops}, {status goes}"
    if status ((agent {}).next {} log) != "sample" then throw <| IO.userError "no model, no check",

  test "an agent from the catalog knows its model's context; one checked for no run does not" do
    let model : Models.Spec := { name := "m", contextTokens? := some 100 }
    let log : Log := #[.message (.user (String.ofList (List.replicate 4000 'y')))]
    for definition in Catalog.all do
      let bounded ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name)]) model
      let unbounded ← assertOk <| Catalog.fromJson (.mkObj [("name", definition.name)])
      assertEqual s!"{definition.name} bounded" (status (bounded.next {} log)) "ContextExceeded"
      assertEqual s!"{definition.name} unbounded" (status (unbounded.next {} log)) "sample"
]

end ContextTests
