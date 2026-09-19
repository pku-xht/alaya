import Alaya.Agent.MiniSwe

/-! MiniSwe with a standalone question tool. Answers use the trajectory's existing
question/reply mechanism; no answer provider or evaluation data enters this agent. -/
namespace Alaya.Agent.MiniAsk

open Alaya (Executor Uname)

def askTool : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask one concrete question and wait for an answer. Call this alone."
  parameters := .object #[("question", .string (description? := some "The question and relevant context"))]
}

def tools : Array Chat.ToolDefinition := MiniSwe.tools.push askTool

def instruction : String :=
  "You may also call ask_user with {\"question\": \"a concrete question\"} " ++
  "as your sole tool call to pause for an answer. This is an exception to the bash requirement. " ++
  "Do not combine ask_user with bash or submit. The answer is advice, not a change to the task's rules."

def initialLog (config : MiniSwe.Config) (uname : Uname) : Log :=
  (MiniSwe.initialLog config uname).push (.message (.user instruction))

inductive Parsed where
  | ask (id question : String)
  | ordinary (actions : Array MiniSwe.Action)
  | formatError (message : String)

def parse (r : Chat.Response) : Parsed := Id.run do
  if r.toolCalls.any (·.name == "ask_user") then
    if r.toolCalls.size == 1 then
      let c := r.toolCalls[0]!
      if c.invalidArguments?.isNone then
        if let .ok (.str question) := c.arguments.getObjVal? "question" then
          if !question.trimAscii.toString.isEmpty then
            return .ask c.id question
    return .formatError "Tool call error: ask_user must be the sole tool call and have valid JSON with a nonempty string 'question'. No tool in this response was executed."
  match MiniSwe.parseActions r with
  | .actions actions => return .ordinary actions
  | .formatError message => return .formatError message

def view (log : Log) : Dialogue :=
  log.flatMap fun event =>
    match event with
    | .response r =>
      match parse r with
      | .formatError message => #[.user message]
      | _ => #[.assistant r.content? r.toolCalls r.reasoning?]
    | _ => MiniSwe.view #[event]

private def trailingErrors (log : Log) : Nat := Id.run do
  let mut count := 0
  for event in log.reverse do
    match event with
    | .response r =>
      match parse r with
      | .formatError _ => count := count + 1
      | _ => return count
    | .observation _ _ => return count
    | .message _ => pure ()
  return count

def next (config : MiniSwe.Config) (log : Log) : Directive :=
  let sampleOrStop : Directive :=
    if config.stepLimit > 0 && log.responses >= config.stepLimit
    then .done { status := "LimitsExceeded" } else .sample
  match log.lastResponse? with
  | none => sampleOrStop
  | some response =>
    match parse response with
    | .ask id question =>
      if log.pending.any (·.id == id) then .ask id question else sampleOrStop
    | .ordinary _ => MiniSwe.next config log
    | .formatError _ =>
      if config.maxConsecutiveFormatErrors > 0 &&
          trailingErrors log >= config.maxConsecutiveFormatErrors
      then .done { status := "RepeatedFormatError" } else sampleOrStop

def agent (executor : Executor) (config : MiniSwe.Config) : Agent := {
  (MiniSwe.agent executor config) with
  identity := .mkObj [("agent", "mini-ask"), ("base", (MiniSwe.agent executor config).identity)]
  tools
  view
  next := next config
}

end Alaya.Agent.MiniAsk
