import Alaya.Agent
import Alaya.Chat.Stored
import Alaya.Trajectory.Store
import Alaya.Workspaces
import Alaya.Executor
import Alaya.Executor.Docker
import Alaya.Grader

/-! The trajectory: a run recorded as a tree of immutable, content-addressed states, each holding
a slice of the log, and the queries over it. It remembers and does nothing else: the driver
(`Alaya.Driver`) grows it for the agent, a person through `Alaya.Trajectory.Interventions`, a
grader through `Alaya.Trajectory.Evaluation`. See `docs/trajectory-schema.md`. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect CallRef Question Reply)

/-! ## Event serialization -/

def callRefToJson (call : CallRef) : Lean.Json :=
  .mkObj [("response", call.response), ("index", call.index)]

def callRefFromJson (json : Lean.Json) : Except String CallRef := do
  pure { response := ← json.getObjVal? "response" >>= Lean.Json.getNat?
         index := ← json.getObjVal? "index" >>= Lean.Json.getNat? }

def eventToJson : Event -> Lean.Json
  | .told m => .mkObj [("type", "told"), ("message", m.toStored)]
  | .placed snapshot => .mkObj [("type", "placed"), ("snapshot", snapshot.hex)]
  | .sampled request purpose r =>
    .mkObj [("type", "sampled"), ("request", request.hex), ("purpose", purpose.toString),
      ("response", r.toStored)]
  | .executed call command config output snapshot =>
    .mkObj [("type", "executed"), ("call", callRefToJson call),
      ("command", command), ("config", config.toJson), ("output", output.toJson),
      ("snapshot", snapshot.hex)]
  | .recorded call content =>
    .mkObj [("type", "recorded"), ("call", callRefToJson call), ("content", content)]
  | .timed runTimeMs budgetMs? =>
    .mkObj [("type", "timed"), ("run_time_ms", runTimeMs),
      ("budget_ms", budgetMs?.map (fun ms => (ms : Lean.Json)) |>.getD .null)]

def eventFromJson (json : Lean.Json) : Except String Event := do
  let hash (field : String) : Except String Hash := do
    pure ⟨← json.getObjVal? field >>= Lean.Json.getStr?⟩
  let call : Except String CallRef := json.getObjVal? "call" >>= callRefFromJson
  match ← json.getObjVal? "type" >>= Lean.Json.getStr? with
  | "told" => .told <$> (json.getObjVal? "message" >>= Chat.Message.ofStored)
  | "placed" => .placed <$> hash "snapshot"
  | "sampled" =>
    pure (.sampled (← hash "request") (.ofString (← json.getObjVal? "purpose" >>= Lean.Json.getStr?))
      (← json.getObjVal? "response" >>= Chat.Response.ofStored))
  | "executed" =>
    let some output := Output.fromJson? (← json.getObjVal? "output")
      | throw "an executed event's output is not a command's output"
    pure (.executed (← call) (← json.getObjVal? "command" >>= Lean.Json.getStr?)
      (← json.getObjVal? "config" >>= Executor.Config.fromJson) output (← hash "snapshot"))
  | "recorded" => pure (.recorded (← call) (← json.getObjVal? "content"))
  | "timed" =>
    let budgetMs? ← match ← json.getObjVal? "budget_ms" with
      | .null => pure none
      | value => some <$> value.getNat?
    pure (.timed (← json.getObjVal? "run_time_ms" >>= Lean.Json.getNat?) budgetMs?)
  | other => throw s!"unknown event type: {other}"

/-! ## State objects

A state is stored as it is held: `toJson` writes each structure as an object of its fields, a
constructor as its name under `type` beside its arguments, and nothing else. Every field is
written, `null` for none, and a missing field, or one of another type, is an error: nothing is
read with a default. -/

/-- A field that is written `null` for none. -/
private def nullable (json : Lean.Json) (name : String) (read : Lean.Json → Except String α) :
    Except String (Option α) := do
  match ← json.getObjVal? name with
  | .null => pure none
  | value => some <$> read value

private def orNull (value? : Option α) (write : α → Lean.Json) : Lean.Json :=
  value?.map write |>.getD .null

private def hashFromJson (json : Lean.Json) : Except String Hash := (⟨·⟩) <$> json.getStr?

/-- What a person told the agent between steps, and what they changed: both are in the notice
the agent is shown (`interventionNotice`). -/
structure Intervention where
  /-- What the person said, verbatim: the whole of a `tell`, and what a `commit` says of its
  change, or nothing. -/
  message : String
  /-- The workspace changes, one `M path` / `+ path` / `- path` line each; empty for a `tell`. -/
  changed : Array String := #[]
  deriving Inhabited

def Intervention.toJson (i : Intervention) : Lean.Json :=
  .mkObj [("message", i.message), ("changed", .arr (i.changed.map Lean.Json.str))]

def Intervention.fromJson (json : Lean.Json) : Except String Intervention := do
  pure { message := ← json.getObjVal? "message" >>= Lean.Json.getStr?
         changed := ← (← json.getObjVal? "changed" >>= Lean.Json.getArr?).mapM Lean.Json.getStr? }

/-- The user turn an intervention becomes in the log. -/
def interventionNotice (i : Intervention) : String :=
  let header :=
    if i.changed.isEmpty then "A person sent you a message while you were paused."
    else "A person changed the workspace while you were paused:"
  let changes := String.join (i.changed.toList.map fun line => "\n  " ++ line)
  let message := if i.message.isEmpty then "" else s!"\n{i.message}"
  s!"<intervention>\n{header}{changes}{message}\n</intervention>"

/-- What a step that waits has asked: the question, and the tool call that asked it, whose
result the answer will be. It is the `ask` effect the step stopped at. -/
structure Asked where
  call : CallRef
  question : Question
  deriving Inhabited, BEq, Repr

/-- The effect a reply answers. -/
def Asked.effect (asked : Asked) : Effect := .ask asked.call asked.question

def Asked.toJson (asked : Asked) : Lean.Json :=
  .mkObj [("call", callRefToJson asked.call), ("question", asked.question.toJson)]

def Asked.fromJson (json : Lean.Json) : Except String Asked := do
  pure { call := ← json.getObjVal? "call" >>= callRefFromJson
         question := ← json.getObjVal? "question" >>= Question.fromJson }

/-- A grader's verdict on a state (`Alaya.Grader`). A separate axis from `Outcome`, which says how
a *run* ended: a submitted run can fail its grader and a run that hit the step limit can pass it. -/
structure Evaluation where
  /-- The grader command, run with `/bin/sh -c` in the grader's container. -/
  command : String
  /-- The pinned image the grader ran in. -/
  graderImage : String
  /-- A snapshot of the trusted input, mounted read-only at `/grader`, when there was one. -/
  input? : Option Snapshot := none
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
  /-- A snapshot of the checkout as the grader left it, its reports included: what the tree shows
  of the evaluation, and no state of a run. -/
  checkout : Snapshot
  deriving Inhabited

/-- How many checks passed, out of how many. -/
def Evaluation.score (e : Evaluation) : Nat × Nat := Grader.Verdict.score e.checks

/-- The status, with the score when there are checks: `pass 3/3`, `fail 2/3`, `error`. -/
def Evaluation.verdict (e : Evaluation) : String :=
  let (passed, total) := e.score
  if total == 0 then e.status.toString else s!"{e.status.toString} {passed}/{total}"

def Evaluation.toJson (e : Evaluation) : Lean.Json :=
  .mkObj [
    ("command", e.command), ("grader_image", e.graderImage),
    ("input", orNull e.input? (Lean.Json.str ·.hex)),
    ("status", e.status.toString),
    ("checks", .arr (e.checks.map fun c =>
      .mkObj [("ok", c.ok), ("name", c.name), ("directive", c.directive)])),
    ("reason", e.reason),
    ("returncode", orNull e.returncode? fun code => (code : Lean.Json)),
    ("elapsed_ms", (e.elapsedMs : Lean.Json)),
    ("stdout", e.stdout), ("stderr", e.stderr),
    ("checkout", e.checkout.hex)]

def Evaluation.fromJson (json : Lean.Json) : Except String Evaluation := do
  let some status := Grader.Status.ofString? (← json.getObjVal? "status" >>= Lean.Json.getStr?)
    | throw "unknown evaluation status"
  let checks ← (← json.getObjVal? "checks" >>= Lean.Json.getArr?).mapM fun c => do
    pure ({ ok := ← c.getObjVal? "ok" >>= Lean.Json.getBool?
            name := ← c.getObjVal? "name" >>= Lean.Json.getStr?
            directive := ← c.getObjVal? "directive" >>= Lean.Json.getStr? } : Grader.Check)
  pure {
    command := ← json.getObjVal? "command" >>= Lean.Json.getStr?
    graderImage := ← json.getObjVal? "grader_image" >>= Lean.Json.getStr?
    input? := ← nullable json "input" hashFromJson
    status, checks
    reason := ← json.getObjVal? "reason" >>= Lean.Json.getStr?
    returncode? := ← nullable json "returncode" Lean.Json.getInt?
    elapsedMs := ← json.getObjVal? "elapsed_ms" >>= Lean.Json.getNat?
    stdout := ← json.getObjVal? "stdout" >>= Lean.Json.getStr?
    stderr := ← json.getObjVal? "stderr" >>= Lean.Json.getStr?
    checkout := ← json.getObjVal? "checkout" >>= hashFromJson }

/-- What a root records of its run, and no other state repeats: every later command reads it
from the root (`runOf`), so it builds the same agent and the same model, whichever provider
serves it, and runs in the same container. -/
structure Root where
  /-- The agent that runs the trajectory, as its complete configuration: its `name` and every
  field. -/
  agent : Lean.Json
  /-- The model the trajectory samples from, as its complete spec (`Models.Spec`). -/
  model : Lean.Json
  /-- The pinned container image every command of the trajectory runs in. -/
  image : String
  /-- Where the workspace is mounted in the image, and where commands run. -/
  workdir : String
  /-- The task the run was created for, for a reader of the tree; the agent has it in its
  opening log. -/
  task? : Option String := none
  deriving Inhabited

def Root.toJson (root : Root) : Lean.Json :=
  .mkObj [("agent", root.agent), ("model", root.model), ("image", root.image),
    ("workdir", root.workdir), ("task", orNull root.task? Lean.Json.str)]

def Root.fromJson (json : Lean.Json) : Except String Root := do
  let object (field what : String) : Except String Lean.Json := do
    match ← json.getObjVal? field with
    | j@(.obj _) => pure j
    | _ => throw s!"the {what} is not an object"
  pure { agent := ← object "agent" "agent configuration"
         model := ← object "model" "model spec"
         image := ← json.getObjVal? "image" >>= Lean.Json.getStr?
         workdir := ← json.getObjVal? "workdir" >>= Lean.Json.getStr?
         task? := ← nullable json "task" Lean.Json.getStr? }

private def outcomeToJson (o : Outcome) : Lean.Json :=
  .mkObj [("status", o.status), ("submission", o.submission), ("reason", orNull o.reason? Lean.Json.str)]

private def outcomeFromJson (json : Lean.Json) : Except String Outcome := do
  pure { status := ← json.getObjVal? "status" >>= Lean.Json.getStr?
         submission := ← json.getObjVal? "submission" >>= Lean.Json.getStr?
         reason? := ← nullable json "reason" Lean.Json.getStr? }

/-- What produced a state, with what only a state of that kind holds. -/
inductive Kind where
  /-- The start of a run, and what it records of it. -/
  | root (root : Root)
  /-- A step: what `resume` adds, the answers to the agent's effects from its parent's log
  until the agent wants a second sample, stops, or asks — at most one sample, and only as its
  first event. `elapsedMs?` is its wall-clock time, from before the model call to after its last
  act and snapshot; a run's time is the sum along its path from the root. `stop?` is how it
  stopped the run, if it did: the run's outcome, or what it asked a person and waits on, which
  only `reply` grows. -/
  | step (elapsedMs? : Option Nat := none) (stop? : Option (Outcome ⊕ Asked) := none)
  /-- A person's notice to the agent: a change to the workspace, listing what changed and saying
  what the person says of it (`commit`), or a message alone, with no change (`tell`). The notice
  in `appended` is `interventionNotice` of it. -/
  | intervention (intervention : Intervention)
  /-- A grader's verdict on a state; always a leaf. -/
  | evaluation (evaluation : Evaluation)
  /-- A person's answer to a question, recorded as the tool result of the asking call. -/
  | reply
  deriving Inhabited

namespace Kind

def toString : Kind -> String
  | .root _ => "root"
  | .step .. => "step"
  | .intervention _ => "intervention"
  | .evaluation _ => "evaluation"
  | .reply => "reply"

/-- A kind as its name under `type`, beside its constructor's arguments; a step's `stop` is
`{"outcome": …}` or `{"asked": …}`. -/
def toJson (kind : Kind) : Lean.Json :=
  .mkObj <| ("type", kind.toString) :: match kind with
    | .root run => [("root", run.toJson)]
    | .step elapsedMs? stop? =>
      [("elapsed_ms", orNull elapsedMs? fun ms => (ms : Lean.Json)),
       ("stop", orNull stop? fun
         | .inl outcome => .mkObj [("outcome", outcomeToJson outcome)]
         | .inr asked => .mkObj [("asked", asked.toJson)])]
    | .intervention i => [("intervention", i.toJson)]
    | .evaluation e => [("evaluation", e.toJson)]
    | .reply => []

def fromJson (json : Lean.Json) : Except String Kind := do
  match ← json.getObjVal? "type" >>= Lean.Json.getStr? with
  | "root" => .root <$> (json.getObjVal? "root" >>= Root.fromJson)
  | "step" =>
    let stop? ← nullable json "stop" fun stop =>
      match stop.getObjVal? "outcome", stop.getObjVal? "asked" with
      | .ok outcome, .error _ => .inl <$> outcomeFromJson outcome
      | .error _, .ok asked => .inr <$> Asked.fromJson asked
      | _, _ => throw "a step stops at an outcome or at a question"
    pure (.step (← nullable json "elapsed_ms" Lean.Json.getNat?) stop?)
  | "intervention" => .intervention <$> (json.getObjVal? "intervention" >>= Intervention.fromJson)
  | "evaluation" => .evaluation <$> (json.getObjVal? "evaluation" >>= Evaluation.fromJson)
  | "reply" => pure .reply
  | other => throw s!"unknown state kind: {other}"

end Kind

/-- A node of the trajectory tree, content-addressed in the store: what every state holds, and
in `kind` what only one of its kind does. -/
structure State where
  parent? : Option Hash
  /-- The workspace the run is at: the latest snapshot the state's log names. -/
  workspace : Snapshot
  kind : Kind
  /-- Events appended on the edge from the parent to this state. -/
  appended : Log
  deriving Inhabited

namespace State

/-- Whether the state sampled: a step whose first event is a response. -/
def sampled (state : State) : Bool := state.appended[0]? matches some (Event.sampled ..)

/-- What the run was created with, on a root. -/
def root? (state : State) : Option Root :=
  match state.kind with
  | .root root => some root
  | _ => none

/-- The run's outcome, when this state ended the run. -/
def outcome? (state : State) : Option Outcome :=
  match state.kind with
  | .step _ (some (.inl outcome)) => some outcome
  | _ => none

/-- What a step that waits has asked. Nothing but `reply` continues from it. -/
def asked? (state : State) : Option Asked :=
  match state.kind with
  | .step _ (some (.inr asked)) => some asked
  | _ => none

/-- The open question, on a step that waits. -/
def question? (state : State) : Option Question := state.asked?.map (·.question)

/-- A step's wall-clock time. -/
def elapsedMs? (state : State) : Option Nat :=
  match state.kind with
  | .step elapsedMs? _ => elapsedMs?
  | _ => none

/-- What a person said or changed, on an intervention. -/
def intervention? (state : State) : Option Intervention :=
  match state.kind with
  | .intervention intervention => some intervention
  | _ => none

/-- The verdict, on an evaluation. -/
def evaluation? (state : State) : Option Evaluation :=
  match state.kind with
  | .evaluation evaluation => some evaluation
  | _ => none

/-- The files a reader of the state is shown: the checkout as the grader left it, on an
evaluation; the workspace, on any other. -/
def snapshot (state : State) : Snapshot :=
  match state.kind with
  | .evaluation evaluation => evaluation.checkout
  | _ => state.workspace

/-- What a state of its kind may hold, the rules that tie the tree to the log
(`docs/architecture.md` §5.1). A root is the agent's opening messages and then its project's
workspace; a step only answers the agent's effects, sampling at most once and only first; an
intervention is a person's workspace and notice, or notice alone; a reply is one answer; an
evaluation adds nothing. -/
def validate (state : State) : Except String Unit := do
  let needsParent := do
    if state.parent?.isNone then throw s!"a {state.kind.toString} has a parent"
  match state.kind with
  | .root _ =>
    if state.parent?.isSome then throw "a root has no parent"
    if !(state.appended.back? matches some (.placed _)) then
      throw "a root ends with its project's workspace"
    if state.appended.pop.any (!· matches .told _) then
      throw "a root opens with the agent's messages only"
    if state.appended.workspace? != some state.workspace then
      throw "a root's last event is its own workspace"
  | .step .. =>
    needsParent
    if state.appended.any (!·.isAnswer) then
      throw "a step holds only answers to the agent's effects, no message or workspace"
    if (state.appended.extract 1 state.appended.size).any (· matches .sampled ..) then
      throw "a step samples at most once, as its first event"
  | .intervention intervention =>
    needsParent
    match state.appended with
    | #[.placed _, .told _] =>
      if intervention.changed.isEmpty then throw "a commit lists what changed"
    | #[.told _] =>
      if !intervention.changed.isEmpty then throw "a tell changes no file"
    | _ => throw "an intervention is a workspace and a notice, or a notice alone"
  | .reply =>
    needsParent
    if !(state.appended matches #[.recorded ..]) then throw "a reply is one answer"
  | .evaluation _ =>
    needsParent
    if !state.appended.isEmpty then throw "an evaluation adds no event"

/-- What a state must agree with in the branch it grows, whose tip is `parent` and whose log is
`before`: nothing grows from an evaluation; from a state that waits, only a reply, which
answers the question, or an evaluation, which is a verdict on any state; each of its answers
names a call made before it that nothing has answered (`Log.checkAnswers`); and its workspace is
the latest snapshot its log names. -/
def continues (state parent : State) (before : Log) : Except String Unit := do
  if parent.kind matches .evaluation _ then throw "nothing grows from an evaluation"
  match parent.asked?, state.kind with
  | some asked, .reply =>
    if !state.appended.all (asked.effect.answer? · |>.isSome) then
      throw "a reply answers its parent's question, in the form it asks for"
  | some _, .evaluation _ => pure ()
  | some _, _ => throw "a state that waits for an answer grows only by a reply"
  | none, .reply => throw "a reply answers a question, and its parent asks none"
  | none, _ => pure ()
  let log := before ++ state.appended
  log.checkAnswers before.size
  if log.workspace? != some state.workspace then
    throw "a state's workspace is the latest snapshot its log names"

/-- The tool calls this state's response made. -/
def calls (state : State) : Array Chat.ToolCall := Agent.Log.calls state.appended

/-- A state a run can be continued from: not ended, not an evaluation, not waiting. -/
def continuable (state : State) : Except String Unit := do
  if state.outcome?.isSome then throw "cannot continue: this state already ended the run"
  if state.kind matches .evaluation _ then
    throw "cannot continue from an evaluation: it is a verdict on its parent, not a point in the run"
  if let some q := state.question? then
    throw s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

/-- The schema version written in every state object, so a reader can refuse what it does not
understand. -/
def schemaVersion : Nat := 2

def toJson (state : State) : Lean.Json :=
  .mkObj [
    ("v", (schemaVersion : Lean.Json)),
    ("parent", orNull state.parent? (Lean.Json.str ·.hex)),
    ("workspace", state.workspace.hex),
    ("kind", state.kind.toJson),
    ("appended", .arr (state.appended.map eventToJson))]

def fromJson (json : Lean.Json) : Except String State := do
  let version ← json.getObjVal? "v" >>= Lean.Json.getNat?
  if version != schemaVersion then
    throw s!"state object has schema version {version}; this build reads version {schemaVersion}"
  pure { parent? := ← nullable json "parent" hashFromJson
         workspace := ← json.getObjVal? "workspace" >>= hashFromJson
         kind := ← json.getObjVal? "kind" >>= Kind.fromJson
         appended := ← (← json.getObjVal? "appended" >>= Lean.Json.getArr?).mapM eventFromJson }

end State

/-! ## The store as a trajectory tree -/

/-- The snapshots a state keeps alive: its workspace, every workspace its events name, and an
evaluation's checkout and trusted input. -/
private def snapshotsOf (state : State) : Array Snapshot :=
  #[state.workspace, state.snapshot] ++ state.appended.workspaces ++
    (state.evaluation?.bind (·.input?)).toArray

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

/-- The states from the root to `hash`, inclusive, oldest first: the one walk up the tree, which
the log, the run's time and the root are read from. Corrupt data whose parents form a cycle is
an error, not a walk that never ends. -/
partial def ancestors (store : Store) (hash : Hash) : Result (Array (Hash × State)) := do
  let rec climb (hash : Hash) (seen : Std.HashSet Hash) (above : List (Hash × State)) :
      Result (Array (Hash × State)) := do
    if seen.contains hash then throw <| .storage s!"the states above {hash.hex} form a cycle"
    let state ← getState store hash
    let above := (hash, state) :: above
    match state.parent? with
    | some parent => climb parent (seen.insert hash) above
    | none => pure above.toArray
  climb hash {} []

/-! ## Branches: the log, a state at a time -/

/-- The states from a root to one state, oldest first, each with its hash: the log at that
state, a slice at a time. Every position of the log is in exactly one state's `appended`, and a
state's slice begins where the events of the states above it end. -/
structure Branch where
  states : Array (Hash × State)
  deriving Inhabited

namespace Branch

/-- The log at the branch's last state: the states' events, in order. -/
def log (branch : Branch) : Log :=
  branch.states.foldl (fun log (_, state) => log ++ state.appended) #[]

/-- The branch's last state, whose log it is. -/
def tip (branch : Branch) : Hash × State := branch.states.back!

def root (branch : Branch) : Hash × State := branch.states[0]!

/-- How long the run has taken: its steps' recorded times. -/
def elapsedMs (branch : Branch) : Nat :=
  branch.states.foldl (fun ms (_, state) => ms + state.elapsedMs?.getD 0) 0

end Branch

/-- The branch from the root to `hash`. -/
def branchOf (store : Store) (hash : Hash) : Result Branch := do
  pure { states := ← ancestors store hash }

/-- The full log at `hash`: the events each state appended, from the root. -/
def logOf (store : Store) (hash : Hash) : Result Log := do
  pure (← branchOf store hash).log

/-- Persists a state, returning its content hash, or refuses it: a state holds only what its
kind may (`State.validate`), and agrees with the branch it grows (`State.continues`). Its
snapshots are kept by `Workspaces` from the moment they were taken. -/
def putState (store : Store) (state : State) : Result Hash := do
  let checked (check : Except String Unit) : Result Unit :=
    Result.fromExcept (fun message => .storage s!"refusing a malformed {state.kind.toString}: {message}") check
  checked state.validate
  if let some parent := state.parent? then
    let branch ← branchOf store parent
    checked (state.continues branch.tip.2 branch.log)
  store.put state.toJson.compress.toUTF8

/-- How long the run up to `hash` has taken: its steps' times, from the root. -/
def elapsedMs (store : Store) (hash : Hash) : Result Nat := do
  pure (← branchOf store hash).elapsedMs

/-- The transitive subtree rooted at `hash` (inclusive). -/
partial def subtree (store : Store) (hash : Hash) : Result (Array Hash) := do
  let kids ← children store hash
  let mut acc := #[hash]
  for kid in kids do
    acc := acc ++ (← subtree store kid)
  pure acc

/-- Deletes a state and its whole subtree, then drops the snapshots no surviving state names. -/
def removeSubtree (store : Store) (workspaces : Workspaces) (hash : Hash) : Result Nat := do
  let doomed ← subtree store hash
  for h in doomed do
    store.delete h
  let mut kept : Array Snapshot := #[]
  for survivor in ← allStates store do
    kept := kept ++ snapshotsOf (← getState store survivor)
  workspaces.retainOnly kept
  pure doomed.size

/-! ## Queries -/

/-- The root of the tree `hash` is in. -/
def rootOf (store : Store) (hash : Hash) : Result Hash := do
  match (← ancestors store hash)[0]? with
  | some (root, _) => pure root
  | none => pure hash

/-- What the run of `hash` was created with, from its root. -/
def runOf (store : Store) (hash : Hash) : Result Root := do
  let (root, state) := (← branchOf store hash).root
  match state.root? with
  | some run => pure run
  | none => throw <| .storage s!"the state {root.hex} has no parent and is not a root"

/-- The agent configuration the run of `hash` was created with. -/
def agentOf (store : Store) (hash : Hash) : Result Lean.Json := do
  pure (← runOf store hash).agent

/-- The model spec the run of `hash` was created with. -/
def modelOf (store : Store) (hash : Hash) : Result Lean.Json := do
  pure (← runOf store hash).model

/-- The workspace changes from `before` to `after`, one line each. -/
def changedLines (workspaces : Workspaces) (before after : Snapshot) :
    Result (Array String) := do
  let changes ← workspaces.diff before after
  pure <| changes.map fun change =>
    match change.kind with
    | .added => s!"+ {change.path}"
    | .removed => s!"- {change.path}"
    | .modified => s!"M {change.path}"

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
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind matches .reply)
      pure (if answered then none else some (hash, q))

end Alaya.Trajectory
