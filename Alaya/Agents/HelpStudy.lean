import Alaya.Agents.MiniVero

/-! Study-only MiniVero variant: initial-system guidance and no model subagent.
The stock MiniVero, task rules, output recovery, and context accounting are unchanged. -/
namespace Alaya.Agents.HelpStudy

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

structure Config where
  base : MiniVero.Config := {}
  guidance : String := ""
  deriving Inhabited

def fields : Fields Config :=
  MiniVero.fields.lift (·.base) (fun b c => { c with base := b }) ++ #[
    .of "guidance" .string (·.guidance) fun v c => { c with guidance := v }]

def Config.toJson (config : Config) : Lean.Json := fields.toJson config
def Config.fromJson (json : Lean.Json) : Except String Config := fields.read json {}

def Config.tools (config : Config) : Array Tool :=
  Basic.tools config.base.toConfig ++ #[Tools.TimeBudget.tool]

def openingMessages (config : Config) (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system (MiniVero.systemMessage ++ "\n\n" ++ config.guidance),
    .user (Basic.withInstructions config.tools (MiniVero.taskMessage task config.base.mode uname))]

def round (config : Config) (model : Models.Spec) (history : MiniVero.History) :
    Computation Agent (MiniVero.History ⊕ Lean.Json) := do
  let history := { history with items := history.items ++ (← Basic.heard).map .told }
  let request : Chat.Request := { messages := MiniVero.view history, tools := config.tools.map (·.definition) }
  if let some limit := MiniVero.contextLimit? config.base model then
    if MiniVero.contextTokens history request.messages >= limit then
      return .inr (Basic.outcome "ContextExceeded")
  let response ← try sample model request catch
    | .refused refusal => return .inr (Basic.refused refusal)
    | failure => throw failure
  let measured? := match response.usage?.bind (·.input?) with
    | some input => some (request.messages, input, response.usage?.bind (·.output?))
    | none => history.measured?
  return match ← Basic.respond config.tools history.items response with
    | .inl items => .inl { items, measured? }
    | .inr ended => .inr ended

def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Lean.Json := do
  let uname ← Tools.Uname.read
  iter (round config model) { items := (openingMessages config task uname).map .told }

def routine : Routine Agent :=
  Basic.agent "help-study" fields {} (·.base.toCommon) computation (Scope.of Tools.routines)

/-- Engineering fixture only; never counted as a model question or participant response. -/
def probe : Routine Agent := {
  name := "help-probe"
  body := fun _ => do
    let answer ← call "ask_user" (.mkObj [
      ("question", "Engineering fixture: reply with probe-ok."),
      ("question_type", "open_ended"), ("question_types", .arr #["open_ended"])])
    if answer != Lean.Json.str "probe-ok" then throw (.refused "probe reply mismatch")
    let ran ← exec "printf 'probe-ok\\n' > probe-reply.txt"
    if ran.output.exitCode? != some 0 then throw (.refused "probe continuation failed")
    return .mkObj [("status", "ProbeComplete"), ("reply", answer)]
  scope := Scope.of Tools.routines }

end Alaya.Agents.HelpStudy
