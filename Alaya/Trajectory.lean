import Alaya.Agent
import Alaya.Trajectory.Store
import Alaya.Workspaces
import Alaya.Cache
import Alaya.Provider
import Alaya.Executor
import Alaya.Executor.Docker
import Alaya.Grader

/-! A content-addressed trajectory tree over any `Alaya.Agent.Agent`, and the operations the
command line drives it with. See `docs/trajectory-schema.md`. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive View Session)

/-! ## Event serialization -/

private def toolCallToJson (call : Chat.ToolCall) : Lean.Json :=
  .mkObj [
    ("id", call.id), ("name", call.name), ("arguments", call.arguments),
    ("invalid_arguments", call.invalidArguments?.map Lean.Json.str |>.getD .null)]

private def toolCallFromJson (json : Lean.Json) : Except String Chat.ToolCall := do
  let id ← json.getObjVal? "id" >>= Lean.Json.getStr?
  let name ← json.getObjVal? "name" >>= Lean.Json.getStr?
  let arguments ← json.getObjVal? "arguments"
  let invalidArguments? := (json.getObjVal? "invalid_arguments" >>= Lean.Json.getStr?).toOption
  pure { id, name, arguments, invalidArguments? }

private def toolCallsFromJson (json : Lean.Json) : Except String (Array Chat.ToolCall) :=
  match json.getObjVal? "tool_calls" with
  | .ok (.arr calls) => calls.mapM toolCallFromJson
  | _ => pure #[]

def messageToJson : Chat.Message -> Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? toolCalls reasoning? => .mkObj [
      ("role", "assistant"),
      ("content", content?.map Lean.Json.str |>.getD .null),
      ("reasoning", reasoning?.map Lean.Json.str |>.getD .null),
      ("tool_calls", .arr (toolCalls.map toolCallToJson))]
  | .tool callId content => .mkObj [
      ("role", "tool"), ("tool_call_id", callId), ("content", content)]

def messageFromJson (json : Lean.Json) : Except String Chat.Message := do
  match ← json.getObjVal? "role" >>= Lean.Json.getStr? with
  | "system" => .system <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "user" => .user <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "assistant" =>
    let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
    let calls ← toolCallsFromJson json
    let reasoning? := (json.getObjVal? "reasoning" >>= Lean.Json.getStr?).toOption
    pure (.assistant content? calls reasoning?)
  | "tool" =>
    let callId ← json.getObjVal? "tool_call_id" >>= Lean.Json.getStr?
    let content ← json.getObjVal? "content"
    pure (.tool callId content)
  | other => throw s!"unknown message role: {other}"

private def usageToJson (u : Chat.TokenUsage) : Lean.Json :=
  .mkObj [
    ("input", u.input?.map (Lean.Json.num ·) |>.getD .null),
    ("output", u.output?.map (Lean.Json.num ·) |>.getD .null),
    ("total", u.total?.map (Lean.Json.num ·) |>.getD .null)]

private def usageFromJson? (json : Lean.Json) : Option Chat.TokenUsage :=
  match json.getObjVal? "usage" with
  | .ok (.obj _) =>
    let usage := (json.getObjVal? "usage").toOption.get!
    some {
      input? := (usage.getObjVal? "input" >>= Lean.Json.getNat?).toOption
      output? := (usage.getObjVal? "output" >>= Lean.Json.getNat?).toOption
      total? := (usage.getObjVal? "total" >>= Lean.Json.getNat?).toOption }
  | _ => none

/-- A response, as recorded. -/
def responseToJson (r : Chat.Response) : Lean.Json :=
  .mkObj [
    ("content", r.content?.map Lean.Json.str |>.getD .null),
    ("tool_calls", .arr (r.toolCalls.map toolCallToJson)),
    ("reasoning", r.reasoning?.map Lean.Json.str |>.getD .null),
    ("finish_reason", r.finishReason?.map Lean.Json.str |>.getD .null),
    ("usage", r.usage?.map usageToJson |>.getD .null)]

def responseFromJson (json : Lean.Json) : Except String Chat.Response := do
  let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
  let toolCalls ← toolCallsFromJson json
  let reasoning? := (json.getObjVal? "reasoning" >>= Lean.Json.getStr?).toOption
  let finishReason? := (json.getObjVal? "finish_reason" >>= Lean.Json.getStr?).toOption
  pure { content?, toolCalls, reasoning?, finishReason?, usage? := usageFromJson? json }

def eventToJson : Event -> Lean.Json
  | .message m => .mkObj [("type", "message"), ("message", messageToJson m)]
  | .response r => .mkObj [("type", "response"), ("response", responseToJson r)]
  | .observation callId content =>
    .mkObj [("type", "observation"), ("call_id", callId), ("content", content)]

def eventFromJson (json : Lean.Json) : Except String Event := do
  match ← json.getObjVal? "type" >>= Lean.Json.getStr? with
  | "message" => .message <$> (json.getObjVal? "message" >>= messageFromJson)
  | "response" => .response <$> (json.getObjVal? "response" >>= responseFromJson)
  | "observation" =>
    let callId ← json.getObjVal? "call_id" >>= Lean.Json.getStr?
    let content ← json.getObjVal? "content"
    pure (.observation callId content)
  | other => throw s!"unknown event type: {other}"

/-! ## State objects -/

/-- What produced a state, for display and provenance. -/
inductive Kind where
  | root
  /-- One model turn, or a stop recorded after a reply without another model sample. -/
  | turn
  /-- A person's workspace change, with a notice to the agent listing what changed. -/
  | intervention
  /-- A grader's verdict on a state, with the checkout as the grader left it; always a leaf. -/
  | evaluation
  /-- A person's message to the agent with no workspace change: see `tell`. -/
  | message
  /-- A turn that ended with the agent asking a person something. The run waits here, and only
  `reply` grows it. -/
  | question
  /-- A person's answer to a `question`, recorded as the tool result of the asking call. -/
  | reply
  deriving BEq, Repr, Inhabited

def Kind.toString : Kind -> String
  | .root => "root"
  | .turn => "turn"
  | .intervention => "intervention"
  | .evaluation => "evaluation"
  | .message => "message"
  | .question => "question"
  | .reply => "reply"

def Kind.ofString? : String -> Option Kind
  | "root" => some .root
  | "turn" => some .turn
  | "intervention" => some .intervention
  | "evaluation" => some .evaluation
  | "message" => some .message
  | "question" => some .question
  | "reply" => some .reply
  | _ => none

/-- What a person told the agent between turns, or what they changed. -/
structure Intervention where
  /-- The person's message, verbatim; empty for a workspace change, which says nothing more. -/
  message : String
  /-- The workspace changes, one `M path` / `+ path` / `- path` line each; empty for a
  message. -/
  changed : Array String := #[]
  deriving Inhabited

/-- The user turn an intervention becomes in the log. -/
def interventionNotice (i : Intervention) : String :=
  let header :=
    if i.changed.isEmpty then "A person sent you a message while you were paused."
    else "A person changed the workspace while you were paused:"
  let changes := String.join (i.changed.toList.map fun line => "\n  " ++ line)
  let message := if i.message.isEmpty then "" else s!"\n{i.message}"
  s!"<intervention>\n{header}{changes}{message}\n</intervention>"

/-- A question the agent asked a person and is waiting on. `callId` is the asking tool call,
so the eventual answer can be recorded as its result. -/
structure Question extends Agent.Question where
  callId : String
  deriving Inhabited, BEq, Repr

def Question.toJson (question : Question) : Lean.Json :=
  question.toQuestion.toJson.setObjVal! "call_id" question.callId

def Question.fromJson (json : Lean.Json) : Except String Question := do
  let callId ← json.getObjVal? "call_id" >>= Lean.Json.getStr?
  let toQuestion ← Agent.Question.fromJson json
  pure { callId, toQuestion }

/-- A grader's verdict on a state (`Alaya.Grader`). A separate axis from `Outcome`, which says how
a *run* ended: a submitted run can fail its grader and a run that hit the step limit can pass it. -/
structure Evaluation where
  /-- The grader command, run with `/bin/sh -c` in the grader's container. -/
  command : String
  /-- The pinned image the grader ran in. -/
  graderImage : String
  /-- A snapshot of the trusted input, mounted read-only at `/grader`, when there was one. -/
  input? : Option Hash := none
  status : Grader.Status
  /-- One per top-level TAP test point. -/
  checks : Array Grader.Check := #[]
  /-- Why the status is `error`, or which checks made it `fail`. -/
  reason : String := ""
  /-- The grader's exit status, `none` when it did not finish; recorded, not a verdict. -/
  returncode? : Option Int := none
  elapsedMs : Nat
  /-- The grader's stdout, its TAP, and its stderr, each truncated. -/
  stdout : String
  stderr : String
  deriving Inhabited

/-- How many checks passed, out of how many. -/
def Evaluation.score (e : Evaluation) : Nat × Nat := Grader.Verdict.score e.checks

/-- The status, with the score when there are checks: `pass 3/3`, `fail 2/3`, `error`. -/
def Evaluation.verdict (e : Evaluation) : String :=
  let (passed, total) := e.score
  if total == 0 then e.status.toString else s!"{e.status.toString} {passed}/{total}"

/-- A node of the trajectory tree, content-addressed in the store. -/
structure State where
  parent? : Option Hash
  workspace : Hash
  kind : Kind
  /-- Events appended on the edge from the parent to this state. -/
  appended : Log
  /-- The run outcome, when this state ended the run. -/
  outcome? : Option Outcome := none
  /-- Provenance: the model spec that produced this turn, an intervention note, the root task. -/
  note? : Option String := none
  /-- The verdict, on an `evaluation` state. -/
  evaluation? : Option Evaluation := none
  /-- The pinned container image every command of the trajectory runs in, inherited from the
  root. -/
  image : String
  /-- Where the workspace is mounted in the image, and where commands run, inherited from the
  root. -/
  workdir : String
  /-- On a root: the agent that runs this trajectory, as its complete configuration — `family`
  and the family's fields — so that every later command builds the same agent. -/
  agent? : Option Lean.Json := none
  /-- On a model step (`turn`, `question`): its wall-clock time, from before the model call to
  after its last act and snapshot. A run's time is the sum along its path from the root. -/
  elapsedMs? : Option Nat := none
  /-- What a person said, on a `message`, or changed, on an `intervention`. The notice in
  `appended` is `interventionNotice` of it. -/
  intervention? : Option Intervention := none
  /-- The open question, on a `question` state. Nothing but `reply` continues from it. -/
  question? : Option Question := none
  deriving Inhabited

namespace State

/-- The tool calls this state's turn made. -/
def calls (state : State) : Array Chat.ToolCall := Agent.Log.calls state.appended

/-- A state a run can be continued from: not ended, not an evaluation, not waiting. -/
def continuable (state : State) : Except String Unit := do
  if state.outcome?.isSome then throw "cannot continue: this state already ended the run"
  if state.kind == .evaluation then
    throw "cannot continue from an evaluation: it is a verdict on its parent, not a point in the run"
  if let some q := state.question? then
    throw s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

/-- A field `toJson` always writes, `null` for none. A missing field, or one of another type, is
an error: nothing is read with a default. -/
private def nullable (json : Lean.Json) (name : String) (read : Lean.Json → Except String α) :
    Except String (Option α) := do
  match ← json.getObjVal? name with
  | .null => pure none
  | value => some <$> read value

def checkToJson (c : Grader.Check) : Lean.Json :=
  .mkObj [("ok", c.ok), ("name", c.name), ("directive", c.directive)]

def evaluationToJson (e : Evaluation) : Lean.Json :=
  .mkObj [
    ("command", e.command), ("graderImage", e.graderImage),
    ("input", e.input?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("status", e.status.toString), ("checks", .arr (e.checks.map checkToJson)),
    ("reason", e.reason),
    ("returncode", e.returncode?.map (fun c => (c : Lean.Json)) |>.getD .null),
    ("elapsedMs", (e.elapsedMs : Lean.Json)),
    ("output", .mkObj [("stdout", e.stdout), ("stderr", e.stderr)])]

private def evaluationFromJson (json : Lean.Json) : Except String Evaluation := do
  let command ← json.getObjVal? "command" >>= Lean.Json.getStr?
  let graderImage ← json.getObjVal? "graderImage" >>= Lean.Json.getStr?
  let input? ← nullable json "input" fun j => (⟨·⟩) <$> j.getStr?
  let some status := Grader.Status.ofString? (← json.getObjVal? "status" >>= Lean.Json.getStr?)
    | throw "unknown evaluation status"
  let checks ← (← json.getObjVal? "checks" >>= Lean.Json.getArr?).mapM fun c => do
    pure ({ ok := ← c.getObjVal? "ok" >>= Lean.Json.getBool?
            name := ← c.getObjVal? "name" >>= Lean.Json.getStr?
            directive := ← c.getObjVal? "directive" >>= Lean.Json.getStr? } : Grader.Check)
  let reason ← json.getObjVal? "reason" >>= Lean.Json.getStr?
  let returncode? ← nullable json "returncode" Lean.Json.getInt?
  let elapsedMs ← json.getObjVal? "elapsedMs" >>= Lean.Json.getNat?
  let output ← json.getObjVal? "output"
  let stdout ← output.getObjVal? "stdout" >>= Lean.Json.getStr?
  let stderr ← output.getObjVal? "stderr" >>= Lean.Json.getStr?
  pure { command, graderImage, input?, status, checks, reason, returncode?, elapsedMs, stdout, stderr }

private def outcomeToJson (o : Outcome) : Lean.Json :=
  .mkObj [("status", o.status), ("submission", o.submission)]

private def outcomeFromJson (json : Lean.Json) : Except String Outcome := do
  let status ← json.getObjVal? "status" >>= Lean.Json.getStr?
  let submission ← json.getObjVal? "submission" >>= Lean.Json.getStr?
  pure { status, submission }

/-- The schema version written in every state object, so a reader can refuse what it does not
understand. -/
def schemaVersion : Nat := 1

def toJson (state : State) : Lean.Json :=
  .mkObj [
    ("v", (schemaVersion : Lean.Json)),
    ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("workspace", state.workspace.hex),
    ("kind", state.kind.toString),
    ("appended", .arr (state.appended.map eventToJson)),
    ("outcome", state.outcome?.map outcomeToJson |>.getD .null),
    ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("image", state.image),
    ("workdir", state.workdir),
    ("agent", state.agent?.getD .null),
    ("elapsed_ms", state.elapsedMs?.map (fun ms => (ms : Lean.Json)) |>.getD .null),
    ("evaluation", state.evaluation?.map evaluationToJson |>.getD .null),
    ("intervention", state.intervention?.map (fun i => .mkObj [
      ("message", i.message), ("changed", .arr (i.changed.map Lean.Json.str))]) |>.getD .null),
    ("question", state.question?.map Question.toJson |>.getD .null)]

def fromJson (json : Lean.Json) : Except String State := do
  let version ← json.getObjVal? "v" >>= Lean.Json.getNat?
  if version != schemaVersion then
    throw s!"state object has schema version {version}; this build reads version {schemaVersion}"
  let parent? ← nullable json "parent" fun j => (⟨·⟩) <$> j.getStr?
  let workspace : Hash := ⟨← json.getObjVal? "workspace" >>= Lean.Json.getStr?⟩
  let kind ← match Kind.ofString? (← json.getObjVal? "kind" >>= Lean.Json.getStr?) with
    | some kind => pure kind
    | none => throw "unknown state kind"
  let appended ← (← json.getObjVal? "appended" >>= Lean.Json.getArr?).mapM eventFromJson
  let outcome? ← nullable json "outcome" outcomeFromJson
  let note? ← nullable json "note" Lean.Json.getStr?
  let image ← json.getObjVal? "image" >>= Lean.Json.getStr?
  let workdir ← json.getObjVal? "workdir" >>= Lean.Json.getStr?
  let agent? ← nullable json "agent" fun
    | j@(.obj _) => pure j
    | _ => throw "the agent configuration is not an object"
  if parent?.isNone && agent?.isNone then throw "a root records its agent configuration"
  let elapsedMs? ← nullable json "elapsed_ms" Lean.Json.getNat?
  let evaluation? ← nullable json "evaluation" evaluationFromJson
  let intervention? ← nullable json "intervention" fun i => do
    let message ← i.getObjVal? "message" >>= Lean.Json.getStr?
    let changed ← (← i.getObjVal? "changed" >>= Lean.Json.getArr?).mapM Lean.Json.getStr?
    pure ({ message, changed } : Intervention)
  let question? ← nullable json "question" Question.fromJson
  pure { parent?, workspace, kind, appended, outcome?, note?, image, workdir, agent?, elapsedMs?
         evaluation?, intervention?, question? }

end State

/-! ## The store as a trajectory tree -/

/-- The snapshots a state keeps alive: its workspace, and an evaluation's trusted input. -/
private def snapshotsOf (state : State) : Array Hash :=
  #[state.workspace] ++ (state.evaluation?.bind (·.input?)).toArray

/-- Persists a state, returning its content hash. Its snapshots are kept by `Workspaces` from
the moment they were taken. -/
def putState (store : Store) (state : State) : Result Hash :=
  store.put state.toJson.compress.toUTF8

/-- Loads the state at `hash`. -/
def getState (store : Store) (hash : Hash) : Result State := do
  match ← store.get? hash with
  | none => throw <| .storage s!"no such state: {hash.hex}"
  | some bytes =>
    let text ← match String.fromUTF8? bytes with
      | some text => pure text
      | none => throw <| .storage s!"corrupt state: {hash.hex}"
    let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
    Result.fromExcept Error.storage (State.fromJson json)

/-- Every state hash in the store. -/
def allStates (store : Store) : Result (Array Hash) := store.list

/-- The children of `hash`, in hash order. -/
def children (store : Store) (hash : Hash) : Result (Array Hash) := do
  let states ← allStates store
  states.filterMapM fun candidate => do
    let state ← getState store candidate
    pure <| if state.parent? == some hash then some candidate else none

/-- Resolves a (possibly abbreviated) hex prefix to the unique state it names. -/
def resolve (store : Store) (pfx : String) : Result Hash := do
  let states ← allStates store
  let hits := states.filter (·.hex.startsWith pfx)
  match hits.toList with
  | [hash] => pure hash
  | [] => throw <| .input s!"no state matches {pfx}"
  | _ => throw <| .input s!"ambiguous state prefix {pfx} ({hits.size} matches)"

/-- Reconstructs the full log at `hash` by concatenating appended events root→node. -/
partial def logOf (store : Store) (hash : Hash) : Result Log := do
  let state ← getState store hash
  let ancestors ← match state.parent? with
    | some parent => logOf store parent
    | none => pure #[]
  pure (ancestors ++ state.appended)

/-- The states from the root to `hash`, in order. -/
partial def branchOf (store : Store) (hash : Hash) : Result (Array (Hash × State)) := do
  let state ← getState store hash
  let before ← match state.parent? with
    | some parent => branchOf store parent
    | none => pure #[]
  pure (before.push (hash, state))

/-- How long the run up to `hash` has taken: its model steps' times, from the root. -/
partial def elapsedMs (store : Store) (hash : Hash) : Result Nat := do
  let state ← getState store hash
  let before ← match state.parent? with
    | some parent => elapsedMs store parent
    | none => pure 0
  pure (before + state.elapsedMs?.getD 0)

/-- The transitive subtree rooted at `hash` (inclusive). -/
partial def subtree (store : Store) (hash : Hash) : Result (Array Hash) := do
  let kids ← children store hash
  let mut acc := #[hash]
  for kid in kids do
    acc := acc ++ (← subtree store kid)
  pure acc

/-- Deletes a state and its whole subtree, then drops the snapshots no surviving state names,
which includes those a turn took between its acts. -/
def removeSubtree (store : Store) (workspaces : Workspaces) (hash : Hash) : Result Nat := do
  let doomed ← subtree store hash
  for h in doomed do
    store.delete h
  let mut kept : Array Hash := #[]
  for survivor in ← allStates store do
    kept := kept ++ snapshotsOf (← getState store survivor)
  workspaces.retainOnly kept
  pure doomed.size

/-! ## Model construction -/

/-- The model stack behind a `provider:name` spec: provider, retry, batch, persistent cache. -/
def buildModel (spec : String) (temperature : Float) (cacheDir : System.FilePath)
    (options : Provider.Options := {}) : Result Model := do
  let base ← Provider.fromSpec spec temperature options
  -- Transport failures are retried: a duplicate request costs less than an aborted run, whose
  -- container — and everything the agent kept outside the workspace — is lost on resume.
  let model ← base.retry { retryUnknownDelivery := true }
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## Driving the agent, recording each turn as a state -/

/-- Where a trajectory's files live and its commands run; the part of a `Runtime` that does not
sample. -/
structure Sandbox where
  store : Store
  workspaces : Workspaces
  /-- Wiped and re-materialized from a snapshot at every checkout; holds nothing durable. -/
  workDir : System.FilePath
  executor : Executor

/-- The live run: a sandbox, the model, the agent being driven, and this invocation's time
budget, which is not recorded. -/
structure Runtime extends Sandbox where
  model : Model
  agent : Agent
  budgetMs? : Option Nat := none

private def nowMs : Result Nat := Result.fromIO Error.storage IO.monoMsNow

/-- The session `next` is given during a step that started at `started`, with `before` of the
run already spent. -/
private def sessionAt (rt : Runtime) (before started : Nat) : Result Session := do
  pure { elapsedMs := before + ((← nowMs) - started), budgetMs? := rt.budgetMs? }

/-- Why a turn handed control back, or a continuation stopped. A turn ends with one of the first
three; the limits are the driver's, checked between turns and never inside one, since a turn
stopped between its tool calls would leave calls unanswered. A limit is not recorded: a later
`resume` continues from the state it stopped at. -/
inductive Halt where
  /-- The turn went normally; the run goes on. -/
  | continue
  /-- The turn ended the run. -/
  | outcome (outcome : Outcome)
  /-- The turn asked a person something; the run waits for `reply`. -/
  | question (question : Question)
  /-- The continuation's time budget was spent. -/
  | outOfTime
  /-- The continuation took the turns it was allowed. -/
  | outOfTurns
  deriving Inhabited, BEq

/-- Follows the agent's directives after a sample until it wants to sample again or stops,
recording each observation and snapshotting the workspace after each act. Returns the events
appended, the final workspace, and why it stopped. -/
private partial def follow (rt : Runtime) (before started : Nat) (log : Log) (appended : Log)
    (workspace : Hash) : Result (Log × Hash × Option Question × Halt) := do
  match rt.agent.next (← sessionAt rt before started) log with
  | .sample => pure (appended, workspace, none, .continue)
  | .done outcome => pure (appended, workspace, none, .outcome outcome)
  | .ask callId toQuestion =>
    Result.fromExcept Error.input toQuestion.validate
    let question : Question := { callId, toQuestion }
    pure (appended, workspace, some question, .question question)
  | .act call =>
    let content ← rt.agent.act { dir := rt.workDir } call
    let workspace ← rt.workspaces.snapshot rt.workDir
    let event := Event.observation call.id content
    follow rt before started (log.push event) (appended.push event) workspace
  | .record callId content =>
    -- Nothing ran: the workspace is as it was, and the state keeps its identifier.
    let event := Event.observation callId content
    follow rt before started (log.push event) (appended.push event) workspace

/-- Runs one model turn from `parent` (whose log is `log` and workspace is `workspace`, already
materialized into `rt.workDir`, and `before` of whose run has been spent), records it as a new
child state with its time, and returns the child, its log, its workspace, the run's time so
far, and why the turn stopped, if it did. A reply may instead stop before sampling. -/
def advance (rt : Runtime) (note : String) (parent : Hash) (log : Log) (workspace : Hash)
    (before : Nat) : Result (Hash × Log × Hash × Nat × Halt) := do
  let parentState ← getState rt.store parent
  -- `follow` stopped at the question before it could check what happens after the answer.
  -- In particular, answering a question on the last allowed turn must not buy another draw.
  if parentState.kind == .reply then
    if let .done outcome := rt.agent.next { elapsedMs := before, budgetMs? := rt.budgetMs? } log then
      let child ← putState rt.store {
        parent? := some parent, workspace, appended := #[], outcome? := some outcome
        kind := .turn, note? := some note, image := parentState.image
        workdir := parentState.workdir }
      return (child, log, workspace, before, .outcome outcome)
  -- Draw index = the number of children that came from sampling.
  let mut childCount := 0
  for child in ← children rt.store parent do
    if (← getState rt.store child).appended.responses > 0 then childCount := childCount + 1
  -- Children run in whatever the parent ran in; the image is a property of the trajectory.
  let image := parentState.image
  let workdir := parentState.workdir
  let started ← nowMs
  let stream ← rt.model.sample { messages := rt.agent.view log, tools := rt.agent.tools }
  let responses ← stream.nextN (childCount + 1)
  let response ← match responses[childCount]? with
    | some response => pure response
    | none => throw <| .protocol "model returned too few responses"
  let event := Event.response response
  let (appended, workspace, question?, halt) ← follow rt before started (log.push event) #[event] workspace
  let outcome? := match halt with | .outcome o => some o | _ => none
  let elapsed := (← nowMs) - started
  let child ← putState rt.store {
    parent? := some parent, workspace, appended, outcome?, question?
    kind := if question?.isSome then .question else .turn
    note? := some note, image, workdir, elapsedMs? := some elapsed }
  pure (child, log ++ appended, workspace, before + elapsed, halt)

/-- Materializes `workspace` into `rt.workDir`, replacing whatever is there. A container bind
mount follows the directory it was started on, which a checkout replaces, so the executor is
closed first: its next command starts a container on the new directory. -/
private def checkoutInto (sandbox : Sandbox) (workspace : Hash) : Result Unit := do
  Result.fromIO Error.storage sandbox.executor.close
  sandbox.workspaces.materialize workspace sandbox.workDir

/-- Whether a run that has taken `elapsed` may take another step under the budget. The budget is
checked before a step and never cuts one short, so a run can overrun it by one step. -/
private def withinBudget (rt : Runtime) (elapsed : Nat) : Bool :=
  match rt.budgetMs? with
  | some budget => elapsed < budget
  | none => true

/-- Grows a continuation from `hash` until the run ends, stops at a question, spends the time
budget, or has taken `turns?` turns, and returns the state it reached and why it stopped there.
Stopping for a limit writes nothing more: that state is where a later `resume` continues. One
turn is `turns? := some 1`. -/
partial def resume (rt : Runtime) (note : String) (hash : Hash)
    (onStep : Hash -> Result Unit) (turns? : Option Nat := none) : Result (Hash × Halt) := do
  let start ← getState rt.store hash
  Result.fromExcept Error.input start.continuable
  let before ← elapsedMs rt.store hash
  if !withinBudget rt before then return (hash, .outOfTime)
  checkoutInto rt.toSandbox start.workspace
  let rec go (parent : Hash) (log : Log) (workspace : Hash) (elapsed taken : Nat) :
      Result (Hash × Halt) := do
    let (child, log, workspace, elapsed, halt) ← advance rt note parent log workspace elapsed
    onStep child
    match halt with
    | .continue =>
      if !withinBudget rt elapsed then pure (child, .outOfTime)
      else if turns?.any (taken + 1 ≥ ·) then pure (child, .outOfTurns)
      else go child log workspace elapsed (taken + 1)
    | halt => pure (child, halt)
  go hash (← logOf rt.store hash) start.workspace before 0

/-! ## Evaluation -/

/-- Where a grader finds its trusted input, read-only; a workdir may not be there. -/
def graderInput : String := "/grader"

/-- Keeps a grader's output readable in `show` without putting megabytes in a state blob. -/
private def truncateOutput (s : String) : String :=
  if s.length <= 20000 then s
  else
    let elided := s.length - 20000
    String.ofList (s.toList.take 10000) ++ s!"\n… {elided} characters elided …\n" ++
      String.ofList (s.toList.drop (s.length - 10000))

/-- Empties `dir`, creating it if needed. -/
private def emptyDir (dir : System.FilePath) : Result Unit := do
  -- A grader or a checkout may have left directories that cannot be deleted from.
  Workspaces.makeWritable dir
  Result.fromIO Error.storage do
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll dir

/-- Runs `command` with `/bin/sh -c` in a fresh container and records its verdict as a leaf child
of `hash`, whose workspace is the checkout after the grader ran, reports included.

The container is from `graderImage?`, pinned, or else the trajectory's image; it runs as `user?`
and without network. A fresh checkout of the state is mounted read-write at the trajectory's
workdir, which is the working directory. `input?`, a directory of trusted files such as hidden
tests, is snapshotted, and that snapshot is mounted read-only at `/grader`, so the grader sees
exactly what is recorded. The verdict comes from the TAP the grader prints on stdout
(`Alaya.Grader`). `scratch` is a directory the trajectory may wipe. Every call runs the grader
and adds a new evaluation. -/
def evaluate (store : Store) (workspaces : Workspaces) (scratch : System.FilePath) (hash : Hash)
    (command : String) (user? : Option String) (input? : Option System.FilePath := none)
    (graderImage? : Option String := none) (timeoutSeconds : Nat := 900) : Result Hash := do
  let state ← getState store hash
  if state.kind == .evaluation then
    throw <| .input "cannot evaluate an evaluation: it is already a leaf"
  let graderImage ← match graderImage? with
    | some reference => pure (← Executor.Docker.Settings.pin { image := reference }).image
    | none => pure state.image
  let inputId? ← input?.mapM fun dir => do
    if !(← Result.fromIO Error.storage dir.isDir) then
      throw <| .input s!"--input must be a directory: {dir}"
    workspaces.snapshot dir
  Result.fromIO Error.storage (IO.FS.createDirAll scratch)
  let scratch ← Result.fromIO Error.storage (IO.FS.realPath scratch)
  let checkout := scratch / "checkout"
  let input := scratch / "input"
  emptyDir checkout
  emptyDir input
  try
    workspaces.materialize state.workspace checkout
    if let some id := inputId? then workspaces.materialize id input
    let mounts := #[{ host := checkout, container := state.workdir : Executor.Docker.Mount }] ++
      (if inputId?.isSome then #[{ host := input, container := graderInput, readOnly := true }] else #[])
    let started ← Result.fromIO Error.storage IO.monoMsNow
    let captured ← Result.fromIO Error.storage <| Executor.Docker.runOnce
      { image := graderImage, user? } mounts state.workdir command timeoutSeconds
    let elapsedMs := (← Result.fromIO Error.storage IO.monoMsNow) - started
    let verdict := Grader.verdict captured.stdout captured.stopped?
    -- The evaluation's workspace is the checkout as the grader left it, so the tree shows what
    -- the grader did to the files, its reports included; the leaf rule keeps it out of any state
    -- a run continues from.
    let graded ← workspaces.snapshot checkout
    putState store {
      parent? := some hash, workspace := graded, kind := .evaluation, appended := #[]
      image := state.image, workdir := state.workdir
      evaluation? := some {
        command, graderImage, input? := inputId?, status := verdict.status
        checks := verdict.checks, reason := verdict.reason
        returncode? := captured.exitCode?.map fun c => Int.ofNat c.toNat, elapsedMs
        stdout := truncateOutput captured.stdout, stderr := truncateOutput captured.stderr } }
  finally
    Workspaces.makeWritable scratch
    Result.fromIO Error.storage do
      if ← checkout.pathExists then IO.FS.removeDirAll checkout
      if ← input.pathExists then IO.FS.removeDirAll input

/-! ## Root creation and what a person adds -/

/-- Creates a root state from the initial project directory: the agent's opening log — its
prompts — and a snapshot of `project`. -/
def createRoot (store : Store) (workspaces : Workspaces) (log : Log) (project : System.FilePath)
    (image : String) (note? : Option String := none) (agent : Lean.Json)
    (workdir : String := Executor.Docker.defaultWorkdir) : Result Hash := do
  let workspace ← workspaces.snapshot project
  putState store { parent? := none, workspace, kind := .root, appended := log, note?, image, workdir
                   agent? := some agent }

/-- The root of the tree `hash` is in. -/
partial def rootOf (store : Store) (hash : Hash) : Result Hash := do
  match (← getState store hash).parent? with
  | some parent => rootOf store parent
  | none => pure hash

/-- The agent configuration the run of `hash` was created with, from its root. -/
def agentOf (store : Store) (hash : Hash) : Result Lean.Json := do
  let root ← rootOf store hash
  let some agent := (← getState store root).agent?
    | throw <| .storage s!"the root {root.hex} records no agent"
  pure agent

/-- A state a person may build on: anything but an evaluation, which is a leaf, or a state
waiting for an answer, which `reply` alone grows. An ended run is fine: fixing something after a
submission and continuing is what interventions are for. -/
private def buildable (state : State) : Result Unit := do
  if state.kind == .evaluation then
    throw <| .input "cannot build on an evaluation: it is a verdict, not a point in the run"
  if let some q := state.question? then
    throw <| .input
      s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

/-- The workspace changes from `before` to `after`, one line each. -/
private def changedLines (workspaces : Workspaces) (before after : Hash) :
    Result (Array String) := do
  let changes ← workspaces.diff before after
  pure <| changes.map fun change =>
    match change.kind with
    | .added => s!"+ {change.path}"
    | .removed => s!"- {change.path}"
    | .modified => s!"M {change.path}"

/-- Records a hand-edited workspace `dir` as an intervention child of `hash`. The agent is always
told: the child's one event is a notice listing what changed, so its view never disagrees with
its files. A directory with no change is refused; `tell` sends a message alone. -/
def commit (store : Store) (workspaces : Workspaces) (hash : Hash) (dir : System.FilePath)
    (note? : Option String) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let workspace ← workspaces.snapshot dir
  let changed ← changedLines workspaces parent.workspace workspace
  if changed.isEmpty then
    throw <| .input s!"{dir} has no change from {hash.hex}: to send a message alone, use `tell`"
  let intervention : Intervention := { message := "", changed }
  putState store {
    parent? := some hash, workspace, kind := .intervention, note?
    appended := #[.message (.user (interventionNotice intervention))]
    intervention? := some intervention, image := parent.image, workdir := parent.workdir }

/-- Records a person's message to the agent as a child of `hash`: same workspace, and the log
grown by one user turn carrying the message in the intervention envelope. -/
def tell (store : Store) (hash : Hash) (message : String) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let intervention : Intervention := { message }
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .message
    appended := #[.message (.user (interventionNotice intervention))]
    intervention? := some intervention
    image := parent.image, workdir := parent.workdir }

/-- Validates an answer before creating a reply child. Its one event is the observation of
the asking call, carrying the valid `text` verbatim. -/
def reply (store : Store) (hash : Hash) (text : String) : Result Hash := do
  let parent ← getState store hash
  let question ← match parent.question? with
    | some q => pure q
    | none => throw <| .input "this state is not waiting for an answer"
  Result.fromExcept Error.input (question.toQuestion.validateReply text)
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .reply
    appended := #[.observation question.callId (.str text)]
    image := parent.image, workdir := parent.workdir }

/-- Records that a person cannot answer, for any question type. The structured status is
distinct from every ordinary string answer, including an open answer containing this JSON.
Like a normal reply, this continues the same workspace without consuming a model turn. -/
def replyUnavailable (store : Store) (hash : Hash) : Result Hash := do
  let parent ← getState store hash
  let question ← match parent.question? with
    | some q => pure q
    | none => throw <| .input "this state is not waiting for an answer"
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .reply
    appended := #[.observation question.callId (.mkObj [("status", "unavailable")])]
    image := parent.image, workdir := parent.workdir }

/-- Every question in the forest that has not been answered: waiting states without a `reply`
child. -/
def waiting (store : Store) : Result (Array (Hash × Question)) := do
  let states ← allStates store
  states.filterMapM fun hash => do
    let state ← getState store hash
    match state.question? with
    | none => pure none
    | some q =>
      let kids ← children store hash
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind == .reply)
      pure (if answered then none else some (hash, q))

/-! ## Rendering: generic over tools — a call by name and arguments, an observation by its
content. -/

private def take (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

private def short (h : Hash) : String := take h.hex 12

private def flatten (s : String) (limit : Nat := 60) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then take flat (limit - 3) ++ "..." else flat

/-- The arguments of a call as one string: the value of the one string field, or of a string
`command` field beside others — the shapes a command tool takes — otherwise the compact JSON, or
the raw text when it did not parse. -/
def argumentsSummary (call : Chat.ToolCall) : String :=
  match call.invalidArguments? with
  | some raw => raw
  | none =>
    match call.arguments with
    | .obj fields =>
      match fields.foldl (fun (acc : Array (String × Lean.Json)) k v => acc.push (k, v)) #[] with
      | #[(_, Lean.Json.str value)] => value
      | _ =>
        match call.arguments.getObjVal? "command" with
        | .ok (Lean.Json.str command) => command
        | _ => call.arguments.compress
    | other => other.compress

/-- `name  arguments`, flattened to one line. -/
def callSummary (call : Chat.ToolCall) : String :=
  call.name ++ "  " ++ flatten (argumentsSummary call)

private def observationText : Lean.Json -> String
  | .str s => s
  | other => other.pretty

private def label (state : State) : String :=
  match state.kind with
  | .root =>
    let family := match state.agent?.bind fun a => (a.getObjVal? "family" >>= Lean.Json.getStr?).toOption with
      | some family => s!"[{family}]  "
      | none => ""
    "root  " ++ family ++ flatten (state.note?.getD "")
  | .turn | .question =>
    let calls := state.calls
    let first := match calls[0]? with
      | some call => callSummary call
      | none => "turn  (no tool call)"
    let more := if calls.size > 1 then s!"  (+{calls.size - 1})" else ""
    first ++ more
  | .intervention => "commit  " ++ (state.note?.getD "")
  | .message => "tell  " ++ flatten (state.intervention?.map (·.message) |>.getD "")
  | .reply =>
    let text := match state.appended[0]? with
      | some (Event.observation _ (Lean.Json.str s)) => s
      | some (Event.observation _ other) => other.compress
      | _ => ""
    "reply  " ++ flatten text
  | .evaluation =>
    match state.evaluation? with
    | some e => s!"eval  [{e.verdict}]  " ++ flatten e.command
    | none => "eval"

private def outcomeSuffix (state : State) : String :=
  match state.outcome? with
  | some o => s!"  [{o.status}]"
  | none => ""

/-- Milliseconds as seconds with one decimal: `12.3 s`. -/
def seconds (ms : Nat) : String := s!"{ms / 1000}.{(ms % 1000) / 100} s"

/-- Renders the whole forest as indented lines, each `<short-hash> <label> [outcome]`. -/
partial def treeLines (store : Store) : Result (Array String) := do
  let states ← allStates store
  let mut roots := #[]
  for h in states do
    if (← getState store h).parent? == none then roots := roots.push h
  let rec render (hash : Hash) (depth : Nat) : Result (Array String) := do
    let state ← getState store hash
    let kids ← children store hash
    let indent := String.join (List.replicate depth "  ")
    -- A question is waiting until some child answers it.
    let mut waitingMark := ""
    if state.question?.isSome then
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind == .reply)
      if !answered then waitingMark := "  [Waiting]"
    let time := match state.elapsedMs? with | some ms => s!"  ({seconds ms})" | none => ""
    let line := s!"{indent}{short hash}  {label state}{outcomeSuffix state}{waitingMark}{time}"
    let mut lines := #[line]
    for kid in kids do
      lines := lines ++ (← render kid (depth + 1))
    pure lines
  let mut lines := #[]
  for root in roots do
    lines := lines ++ (← render root 0)
  pure lines

/-- One event as lines: who, then what. -/
private def eventLines : Event -> Array String
  | .message m =>
    match m with
    | .system c => #["[system]", c]
    | .user c => #["[user]", c]
    | .assistant c? calls _ =>
      #["[assistant]", c?.getD ""] ++ calls.map fun call => "[call] " ++ callSummary call
    | .tool id content => #[s!"[tool {id}]", observationText content]
  | .response r =>
    #["[response]", r.content?.getD ""] ++ r.toolCalls.map fun call => "[call] " ++ callSummary call
  | .observation id content => #[s!"[observation {id}]", observationText content]

/-- Renders a state for `show`: metadata, then the full reconstructed log — what happened — and,
given the agent's view, the context the model would be sent from here — what it sees. -/
def showLines (store : Store) (hash : Hash) (view? : Option View := none) :
    Result (Array String) := do
  let state ← getState store hash
  let log ← logOf store hash
  let mut lines := #[
    s!"state    {hash.hex}",
    s!"kind     {state.kind.toString}",
    s!"parent   {state.parent?.map (·.hex) |>.getD "(root)"}",
    s!"workspace {state.workspace.hex}"]
  if let some note := state.note? then lines := lines.push s!"note     {note}"
  lines := lines.push s!"image    {state.image}"
  lines := lines.push s!"workdir  {state.workdir}"
  if let some agent := state.agent? then lines := lines.push s!"agent    {agent.compress}"
  if let some ms := state.elapsedMs? then lines := lines.push s!"elapsed  {seconds ms}"
  let total ← elapsedMs store hash
  if total > 0 then lines := lines.push s!"run time {seconds total}, from the root"
  if let some e := state.evaluation? then
    lines := lines.push s!"grader   {e.command}"
    lines := lines.push s!"grader image {e.graderImage}"
    if let some input := e.input? then lines := lines.push s!"input    {input.hex}"
    let exit := e.returncode?.map (s!"exit {·}") |>.getD "no exit status"
    lines := lines.push s!"verdict  {e.verdict} ({exit}, {e.elapsedMs} ms)"
    if !e.reason.isEmpty then lines := lines.push s!"reason   {e.reason}"
    if !e.checks.isEmpty then
      lines := lines.push "--- checks ---"
      for c in e.checks do
        let directive := if c.directive.isEmpty then "" else s!"  # {c.directive}"
        lines := lines.push s!"{if c.ok then "ok    " else "not ok"}  {c.name}{directive}"
    lines := lines.push "--- grader stdout ---"
    lines := lines.push e.stdout
    if !e.stderr.isEmpty then
      lines := lines.push "--- grader stderr ---"
      lines := lines.push e.stderr
  if let some o := state.outcome? then
    lines := lines.push s!"outcome  {o.status}"
    if o.submission != "" then lines := lines.push s!"submission:\n{o.submission}"
  if let some q := state.question? then lines := lines.push s!"question {q.toQuestion.render}"
  if let some i := state.intervention? then lines := lines.push s!"message  {i.message}"
  lines := lines.push "--- log ---"
  for event in log do
    lines := lines ++ eventLines event
  if let some view := view? then
    lines := lines.push "--- view: the context sent from this state ---"
    for message in view log do
      lines := lines ++ eventLines (.message message)
  pure lines

/-- The workspace changes from `a`'s snapshot to `b`'s. -/
def diffLines (store : Store) (workspaces : Workspaces) (a b : Hash) : Result (Array String) := do
  let sa ← getState store a
  let sb ← getState store b
  changedLines workspaces sa.workspace sb.workspace

end Alaya.Trajectory
