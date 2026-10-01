import Alaya.Model
import Alaya.Executor
import Alaya.Agent.Question

/-! The agent API: the log of events, the view of it the model is sent, and the operations a
trajectory drives an agent with. See `docs/agent-api.md`. -/

namespace Alaya.Agent

open Alaya (Result Error)

/-- The context a sample is conditioned on: the output of a view. -/
abbrev Dialogue := Array Chat.Message

/-- One thing that happened, recorded verbatim. -/
inductive Event where
  /-- Text placed in the context by something other than the model or a tool. -/
  | message (message : Chat.Message)
  /-- The model's turn, whether or not it parsed. -/
  | response (response : Chat.Response)
  /-- One tool call's result, in whatever shape the agent's `act` produced. -/
  | observation (callId : String) (content : Lean.Json)
  deriving Inhabited

/-- Everything that happened, in order. -/
abbrev Log := Array Event

/-- A pure, total projection of the log onto the model's context. -/
abbrev View := Log -> Dialogue

/-- Why a run stopped, and what it produced. -/
structure Outcome where
  /-- A short machine-readable status, e.g. "Submitted" or "LimitsExceeded". -/
  status : String
  /-- The agent's final output, when it submitted one. -/
  submission : String := ""
  deriving Repr, BEq, Inhabited

/-- What the loop should do next, decided from the log and the session. -/
inductive Directive where
  | sample
  /-- Run one tool call in the workspace; the workspace is snapshotted and the result recorded. -/
  | act (call : Chat.ToolCall)
  /-- Record `content` as the observation of `callId`: the result of a tool call the agent
  computed itself, without the workspace — a page of an earlier output, the time left. Nothing
  runs and the workspace is not snapshotted. -/
  | record (callId : String) (content : Lean.Json)
  /-- Stop and wait for a person; their reply is recorded as the observation of `callId`. -/
  | ask (callId : String) (question : Question)
  | done (outcome : Outcome)
  deriving Inhabited

/-- What the driver knows about this invocation that the log does not. `next` is given it;
`view` is not, since what the model was sent must be rebuilt from the log alone — whatever
`next` decides from it that the model sees becomes an event. -/
structure Session where
  /-- How long this trajectory has run: its recorded steps from the root, and the current one
  so far. -/
  elapsedMs : Nat := 0
  /-- This invocation's time budget; `none` when it was given none. -/
  budgetMs? : Option Nat := none
  deriving Inhabited, Repr

/-- Whole seconds of the budget left, never negative; `none` when there is no budget. -/
def Session.secondsLeft? (session : Session) : Option Nat :=
  session.budgetMs?.map fun budget => (budget - session.elapsedMs) / 1000

/-- The directory an agent's tools act in. -/
structure Workspace where
  dir : System.FilePath
  deriving Inhabited

/-- Where the commands of a run find the files an agent's view names (`Agent.outputs`):
read-only, and outside any workdir. -/
def outputsDir : String := "/alaya/outputs"

/-- An agent: what a run records of it, how it opens a run and runs commands, the tools it
offers, and the pure functions it decides by. -/
structure Agent where
  /-- The complete configuration, in canonical form: what a root records, and all a later
  command needs to build the same agent again. -/
  config : Lean.Json
  /-- The opening log of a run for a task, on a machine described by `uname`. -/
  initialLog : String -> Uname -> Log
  /-- How its commands run: their timeout and environment. -/
  executorConfig : Executor.Config
  tools : Array Chat.ToolDefinition
  view : View
  next : Session -> Log -> Directive
  /-- Runs one tool call in the workspace through the executor, and returns the observation to
  record. The executor is the run's, chosen after the agent is built. -/
  act : Executor -> Workspace -> Chat.ToolCall -> Result Lean.Json
  /-- The files the view names in `outputsDir`, by file name, with their contents: like the
  view, a function of the log, so each branch sees its own. Nothing records them. -/
  outputs : Log -> Array (String × String) := fun _ => #[]

namespace Log

/-- How many model turns the log holds. -/
def responses (log : Log) : Nat :=
  log.foldl (fun n event => match event with | .response _ => n + 1 | _ => n) 0

/-- The most recent model turn. -/
def lastResponse? (log : Log) : Option Chat.Response :=
  log.reverse.findSome? fun | .response r => some r | _ => none

/-- The events after the most recent model turn: what has happened in the current turn. -/
def sinceLastResponse (log : Log) : Array Event :=
  -- Walk newest-first, collecting until the response; consing restores oldest-first order.
  let rec collect (events : List Event) (acc : List Event) : List Event :=
    match events with
    | [] => acc
    | .response _ :: _ => acc
    | event :: rest => collect rest (event :: acc)
  (collect log.toList.reverse []).toArray

/-- The tool calls of the most recent turn that no observation has answered yet, in order. -/
def pending (log : Log) : Array Chat.ToolCall :=
  match log.lastResponse? with
  | none => #[]
  | some response =>
    let observed := log.sinceLastResponse.filterMap fun
      | .observation id _ => some id
      | _ => none
    response.toolCalls.filter fun call => !observed.contains call.id

/-- Every tool call made, in order — from responses, and from assistant messages placed
verbatim by a person writing the model's turn. -/
def calls (log : Log) : Array Chat.ToolCall :=
  log.foldl (init := #[]) fun acc event =>
    match event with
    | .response r => acc ++ r.toolCalls
    | .message (.assistant _ calls _) => acc ++ calls
    | _ => acc

end Log

/-- The tokens of a request with `dialogue`, estimated at four characters a token of its JSON. -/
def estimateTokens (dialogue : Dialogue) : Nat :=
  (dialogue.foldl (fun n m => n + m.toJson.compress.length) 0 + 3) / 4

/-- The tokens of the request `view` makes of `log`, known without a tokenizer: the latest
response's recorded `usage` says how many the request it answered held and how many it
returned, and what the view added since is estimated. When the view rewrote what that request
held, or no response has `usage`, the whole request is estimated. -/
def contextTokens (view : View) (log : Log) : Nat :=
  let full := view log
  let wire (dialogue : Dialogue) := dialogue.map (·.toJson.compress)
  let extends? (part : Dialogue) := part.size ≤ full.size && wire (full.extract 0 part.size) == wire part
  let measured? := (List.range log.size).reverse.findSome? fun index =>
    match (log[index]? : Option Event) with
    | some (.response r) => r.usage?.bind (·.input?) |>.map fun input => (index, input, r.usage?.bind (·.output?))
    | _ => none
  match measured? with
  | none => estimateTokens full
  | some (index, input, output?) =>
    let before := view (log.extract 0 index)
    let answered := view (log.extract 0 (index + 1))
    -- Measured only while the request that was sent, and the response, are still as shown.
    if !(extends? before && extends? answered) then estimateTokens full
    else
      let response := output?.getD (estimateTokens (answered.extract before.size answered.size))
      input + response + estimateTokens (full.extract answered.size full.size)

end Alaya.Agent
