import Alaya.Model
import Alaya.Hash
import Alaya.Executor
import Alaya.Agent.Question

/-! The agent API: the log of events, the effects an agent asks for and what answers each, and
the agent itself, a function from the log to what it asks for next. See `docs/agent-api.md`. -/

namespace Alaya.Agent

open Alaya (Result Error)

/-- The context a sample is conditioned on: the output of a view. -/
abbrev Dialogue := Array Chat.Message

/-- A tool call, by where it was made: the log position of the response that made it, which
never changes on a branch, and which of its calls it is. An answer names the call it answers by
this, not by recency, so a sample taken between a call and its answer cannot hide the call, and
not by the call's id, so a provider that reuses an id cannot confuse two. The id, like the call
itself, is read off the log (`Index.call?`). -/
structure CallRef where
  response : Nat
  index : Nat
  deriving BEq, Repr, Inhabited

/-- A reference as a reader is shown it where the log is not at hand: `3.0`, the first call of
the response at position 3. -/
instance : ToString CallRef := ⟨fun ref => s!"{ref.response}.{ref.index}"⟩

/-- What a sample is for: a model turn of the agent's, whose tool calls it runs, or any other
sample — a summary, a check of a draft — by the name the agent gives it. -/
inductive Purpose where
  | turn
  /-- A sample that is not a model turn, by a name other than `turn`'s. -/
  | other (name : String)
  deriving BEq, Repr, Inhabited

namespace Purpose

/-- The purpose as a state records it: `turn`, or the other sample's name. -/
def toString : Purpose -> String
  | .turn => "turn"
  | .other name => name

def ofString : String -> Purpose
  | "turn" => .turn
  | name => .other name

instance : ToString Purpose := ⟨Purpose.toString⟩

end Purpose

/-- One thing that happened, recorded verbatim, and named for what happened. A log holds two
sorts: what the world did unasked — told the agent something, placed a workspace — and the
world's answer to each of the agent's effects, recorded with what identifies the effect, so the
log says what the agent asked for as well as what came back, and with the call it answers,
where it answers one. -/
inductive Event where
  /-- The agent was told something: text placed in the context by something other than the model
  or a tool — the prompts that open a run, a person's notice. -/
  | told (message : Chat.Message)
  /-- A workspace placed by the world, the project of a root or a person's edit: the workspace
  is then at `snapshot`. -/
  | placed (snapshot : Snapshot)
  /-- The answer to `sample`: the model's response, whether or not it parsed, with the digest of
  the request (`Model.requestDigest`) and what the sample was for. -/
  | sampled (request : Hash) (purpose : Purpose) (response : Chat.Response)
  /-- The answer to `exec`: the call the run answers, the command, how it ran, its output, and
  the snapshot of the workspace it left: as with `placed`, the workspace is then at `snapshot`.
  The command ran where the workspace was, on the latest snapshot the log names before it. -/
  | executed (call : CallRef) (command : String) (config : Executor.Config)
      (output : Output) (snapshot : Snapshot)
  /-- One tool call's result, without the workspace: computed by the agent (`record`), or a
  person's answer to `ask`. -/
  | recorded (call : CallRef) (content : Lean.Json)
  /-- The answer to `time`: how long the run has taken so far — its recorded steps, and the
  current one — and the time budget of the invocation that timed it, when it has one. -/
  | timed (runTimeMs : Nat) (budgetMs? : Option Nat)
  deriving Inhabited

/-- Whether the event answers an effect, rather than being placed by the world unasked. -/
def Event.isAnswer : Event -> Bool
  | .sampled .. | .executed .. | .recorded .. | .timed .. => true
  | .told _ | .placed _ => false

/-- Everything that happened, in order. -/
abbrev Log := Array Event

/-- Why a run stopped, and what it produced. -/
structure Outcome where
  /-- A short machine-readable status, e.g. "Submitted" or "LimitsExceeded". -/
  status : String
  /-- The agent's final output, when it submitted one. -/
  submission : String := ""
  /-- Why, in words, when the status does not say it all: a provider's refusal of a request. -/
  reason? : Option String := none
  deriving Repr, BEq, Inhabited

/-! ## Effects: what an agent asks for, and what answers it -/

/-- What an agent asks the world to do: a description of an effect, never the effect itself. The
driver carries it out and records its answer as one event. -/
inductive Effect where
  /-- Draw a response to `request`, for `purpose`. -/
  | sample (purpose : Purpose) (request : Chat.Request)
  /-- Run `command` for `call` in the workspace, where the log is (`Log.workspace?`), with
  `config`'s timeout and environment; answered by `Event.executed`, with the snapshot after it.
  A run has one workspace, which only moves forward: a command cannot name another snapshot, so
  what the model is shown of its files never contradicts what it did to them. -/
  | exec (call : CallRef) (command : String) (config : Executor.Config)
  /-- Record `content` as the result of `call`: one the agent computed itself, without the
  workspace — a page of an earlier output, the time left. Answered by `Event.recorded`. -/
  | record (call : CallRef) (content : Lean.Json)
  /-- Time the run: how long it has taken so far, and the time budget it has. -/
  | time
  /-- Stop and wait for a person; their reply is recorded as the result of `call`
  (`Event.recorded`). -/
  | ask (call : CallRef) (question : Question)
  deriving Inhabited

namespace Effect

/-- What the world answers an effect with. -/
def Answer : Effect -> Type
  | .sample .. => Chat.Response
  /- The output, and the snapshot of the workspace after the command. -/
  | .exec .. => Output × Snapshot
  | .record .. => Unit
  /- The run's time in milliseconds, and its budget. -/
  | .time => Nat × Option Nat
  | .ask .. => Reply

/-- How an answer is recorded: the event it becomes, with what identifies the effect. -/
def event : (effect : Effect) -> effect.Answer -> Event
  | .sample purpose request, response => .sampled (Model.requestDigest request) purpose response
  | .exec call command config, (output, snapshot) => .executed call command config output snapshot
  | .record call content, () => .recorded call content
  | .time, (runTimeMs, budgetMs?) => .timed runTimeMs budgetMs?
  | .ask call _, reply => .recorded call reply.toJson

/-- The answer `event` gives `effect`, if it answers it: a response for the same purpose whose
digest is the request's, a run of the same command, the same way, for the same call, a result
recorded for the same call — for `record`, with the same content; for `ask`, a reply the
question's form accepts — a timing of the run. -/
def answer? : (effect : Effect) -> Event -> Option effect.Answer
  | .sample purpose request, .sampled digest purpose' response =>
    if purpose == purpose' && digest == Model.requestDigest request then some response else none
  | .exec call command config, .executed call' command' config' output snapshot =>
    if call == call' && command == command' && config == config' then some (output, snapshot) else none
  | .record call content, .recorded call' content' =>
    if call == call' && content == content' then some () else none
  | .time, .timed runTimeMs budgetMs? => some (runTimeMs, budgetMs?)
  | .ask call question, .recorded call' content =>
    if call == call' then question.readReply? content else none
  | _, _ => none

/-- The effect in a few words, for messages. -/
def describe : Effect -> String
  | .sample purpose request => s!"sample a {purpose} request of {request.messages.size} messages"
  | .exec call command _ => s!"run for call {call}: {command}"
  | .record call _ => s!"record a result for call {call}"
  | .time => "time the run"
  | .ask call question => s!"ask for call {call}: {question.text}"

end Effect

/-- Where a run's commands find the whole output of every command of their branch, read-only
and outside any workdir: the output recorded at log position `index` by call `id` is the file
`outputFile index id`. The trajectory writes them, from the log, for any agent; a view that cuts
or omits an output can name its file. -/
def outputsDir : String := "/alaya/outputs"

/-- The file holding the output recorded at `index` by the call `id` (`Index.callId?`): named by
its position, which never changes on a branch, with the id, made safe for a file name, for
reading. -/
def outputFile (index : Nat) (id : String) : String :=
  let safe := id.map fun c => if c.isAlphanum || c == '-' || c == '_' || c == '.' then c else '_'
  s!"{index}-{safe}.txt"

/-- Where a command finds `outputFile index id`. -/
def outputPath (index : Nat) (id : String) : String := s!"{outputsDir}/{outputFile index id}"

/-- An agent: the configuration a run records of it, the log it opens a run with, and the one
function it decides by, from the log alone: the effect it asks for next, or the run's outcome.
Everything it does — what the model is sent, what runs and how — is in the effects `next`
gives. -/
structure Agent where
  /-- The complete configuration, in canonical form: what a root records, and all a later
  command needs to build the same agent again. -/
  config : Lean.Json
  /-- The opening log of a run for a task, on a machine described by `uname`. -/
  initialLog : String -> Uname -> Log
  next : Log -> Effect ⊕ Outcome

/-- The request the agent would sample from `log`, if it would sample. -/
def Agent.request? (agent : Agent) (log : Log) : Option Chat.Request :=
  match agent.next log with
  | .inl (.sample _ request) => some request
  | _ => none

/-! ## The index: what a log says, read off it once

The log is the record, flat and append-only; its structure — turns, calls and what answered
them, where the workspace is — is read off it by `Log.index`, in one pass, so no agent and no
reader rescans the log its own way, and nothing is stored twice. -/

/-- A tool call of a turn, with the position of the event that answered it, if one has. -/
structure Call where
  ref : CallRef
  call : Chat.ToolCall
  answer? : Option Nat := none

/-- A model turn: a response for `Purpose.turn`, where it is, and its calls. -/
structure Turn where
  position : Nat
  response : Chat.Response
  calls : Array Call

/-- What a log says. -/
structure Index where
  /-- The model turns, oldest first. -/
  turns : Array Turn := #[]
  /-- How many responses of any purpose: the model calls made. -/
  responses : Nat := 0
  /-- For each event, how many turns have begun by it, its own included: the turn it is part of,
  from 1, or 0 before the first. -/
  turnOf : Array Nat := #[]
  /-- The workspace the log is at: the last one placed in it or left by a command. -/
  workspace? : Option Snapshot := none
  /-- Every workspace the log names, in order. -/
  workspaces : Array Snapshot := #[]
  /-- Every tool call made, in order — of turns, and of assistant messages a person wrote. -/
  calls : Array Chat.ToolCall := #[]

namespace Index

def lastTurn? (index : Index) : Option Turn := index.turns.back?

/-- The calls of the latest turn that nothing has answered yet, in order. -/
def pending (index : Index) : Array Call :=
  match index.lastTurn? with
  | some turn => turn.calls.filter (·.answer?.isNone)
  | none => #[]

/-- The turn a call was made in, and the call. -/
def call? (index : Index) (ref : CallRef) : Option Call := do
  let turn ← index.turns.find? (·.position == ref.response)
  turn.calls[ref.index]?

/-- The id of the call `ref` names, as the model gave it. -/
def callId? (index : Index) (ref : CallRef) : Option String := (index.call? ref).map (·.call.id)

/-- `index` with `event`, at `position`, read into it. -/
private def add (index : Index) (position : Nat) (event : Event) : Index :=
  let answer (index : Index) (ref : CallRef) : Index :=
    match index.turns.findIdx? (·.position == ref.response) with
    | none => index
    | some t => { index with turns := index.turns.modify t fun turn =>
        { turn with calls := turn.calls.modify ref.index ({ · with answer? := some position }) } }
  let index := match event with
    | .told (.assistant _ calls _) => { index with calls := index.calls ++ calls }
    | .told _ => index
    | .placed snapshot =>
      { index with workspace? := some snapshot, workspaces := index.workspaces.push snapshot }
    | .sampled _ purpose response =>
      let index := { index with responses := index.responses + 1 }
      if purpose != Purpose.turn then index else
      let calls := response.toolCalls.mapIdx fun i (call : Chat.ToolCall) =>
        ({ ref := { response := position, index := i }, call } : Call)
      { index with turns := index.turns.push { position, response, calls }
                   calls := index.calls ++ response.toolCalls }
    | .executed ref _ _ _ snapshot =>
      answer { index with workspace? := some snapshot
                          workspaces := index.workspaces.push snapshot } ref
    | .recorded ref _ => answer index ref
    | .timed .. => index
  { index with turnOf := index.turnOf.push index.turns.size }

end Index

/-- What `log` says, read in one pass. -/
def Log.index (log : Log) : Index :=
  (log.foldl (init := (({} : Index), 0)) fun (index, position) event =>
    (index.add position event, position + 1)).1

/-- What is wrong with the answers `log` holds from position `start` on, if anything: each
`executed` and each `recorded` answers a call made before it that nothing has answered yet. -/
def Log.checkAnswers (log : Log) (start : Nat := 0) : Except String Unit := do
  let mut index : Index := {}
  for (event, position) in log.zipIdx do
    let ref? := if position < start then none else match event with
      | .executed ref .. | .recorded ref _ => some ref
      | _ => none
    if let some ref := ref? then
      let named := s!"the answer at position {position} names call {ref.index} of the response at {ref.response}"
      match index.call? ref with
      | none => throw s!"{named}, which is no call made before it"
      | some call =>
        if call.answer?.isSome then throw s!"{named}, which is already answered"
    index := index.add position event

namespace Log

/-- How many responses the log holds, of any purpose: the model calls made. -/
def responses (log : Log) : Nat := log.index.responses

def workspace? (log : Log) : Option Snapshot := log.index.workspace?

def workspaces (log : Log) : Array Snapshot := log.index.workspaces

def pending (log : Log) : Array Call := log.index.pending

def calls (log : Log) : Array Chat.ToolCall := log.index.calls

end Log

/-- The tokens of a request with `dialogue`, estimated at four characters a token of its JSON. -/
def estimateTokens (dialogue : Dialogue) : Nat :=
  (dialogue.foldl (fun n m => n + m.toJson.compress.length) 0 + 3) / 4

/-- The tokens `full`, a request's messages from `log`, holds, known without a tokenizer. The
latest model turn's recorded `usage` says how many the request it answered held — the request of
`next` just before it — and how many it returned; what `full` holds after that request and the
message that shows the turn is estimated. When `full` no longer begins with that request, as
when old outputs have since been elided, or no turn has `usage`, the whole is estimated. -/
def contextTokens (next : Log -> Effect ⊕ Outcome) (log : Log) (full : Dialogue) : Nat :=
  let wire (dialogue : Dialogue) := dialogue.map (·.toJson.compress)
  let measured? := log.index.turns.reverse.findSome? fun turn =>
    turn.response.usage?.bind (·.input?) |>.map fun input =>
      (turn.position, input, turn.response.usage?.bind (·.output?))
  match measured? with
  | none => estimateTokens full
  | some (position, input, output?) =>
    match next (log.extract 0 position) with
    | .inl (.sample _ sent) =>
      let before := sent.messages
      if before.size < full.size && wire (full.extract 0 before.size) == wire before then
        let response := output?.getD (estimateTokens (full.extract before.size (before.size + 1)))
        input + response + estimateTokens (full.extract (before.size + 1) full.size)
      else estimateTokens full
    | _ => estimateTokens full

/-- The request the response at `position` of `log` was sampled from: the request of `next` of
the log before it, which is what the response records the digest of. `none` when there is no
response there, or the agent no longer makes a request there, as when it has since changed. -/
def Agent.requestAt? (agent : Agent) (log : Log) (position : Nat) : Option Chat.Request := do
  let .sampled digest _ _ ← log[position]? | none
  let request ← agent.request? (log.extract 0 position)
  if Model.requestDigest request == digest then some request else none

/-! ## Combinators: an agent from an agent

Each rewrites what `next` gives and nothing else, so they compose in any order; the outermost is
applied last. -/

namespace Agent

/-- `agent`, with `rewrite` applied to what it asks for next, given the log it decided from. -/
def interpose (agent : Agent) (rewrite : Log -> Effect ⊕ Outcome -> Effect ⊕ Outcome) : Agent :=
  { agent with next := fun log => rewrite log (agent.next log) }

/-- Stops with `LimitsExceeded` instead of a sample once the log holds `limit` responses, of any
purpose; 0 is no limit. -/
def limitResponses (agent : Agent) (limit : Nat) : Agent :=
  if limit == 0 then agent else
  agent.interpose fun log next =>
    match next with
    | .inl (.sample ..) => if log.responses >= limit then .inr { status := "LimitsExceeded" } else next
    | _ => next

/-- Stops with `ContextExceeded` instead of a sample whose request holds `limit?` tokens
(`contextTokens`); `none` is no limit. -/
def limitContext (agent : Agent) (limit? : Option Nat) : Agent :=
  match limit? with
  | none => agent
  | some limit =>
    agent.interpose fun log next =>
      match next with
      | .inl (.sample _ request) =>
        if contextTokens agent.next log request.messages >= limit then .inr { status := "ContextExceeded" }
        else next
      | _ => next

/-- Runs every command with `config`'s timeout and environment, whatever the tool that asked for
it said: how commands run is the agent's policy, not a tool's. -/
def runCommandsWith (agent : Agent) (config : Executor.Config) : Agent :=
  agent.interpose fun _ next =>
    match next with
    | .inl (.exec call command _) => .inl (.exec call command config)
    | _ => next

end Agent

end Alaya.Agent
