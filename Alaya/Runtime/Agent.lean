import Alaya.Core.Replay
import Alaya.LLM.Model
import Alaya.LLM.Models
import Alaya.Runtime.Executor
import Alaya.LLM.Chat.Stored

/-! What a computation of Alaya may ask the world for: its signature, `Agent`. A model samples, a
command runs in the workspace, in the container of the call it is made in, and the clock tells
the run's time. Each has its type of answer, and the log keeps every operation by a key and every
answer as JSON (`docs/log-schema.md`). See `docs/language.md`. -/

namespace Alaya.Runtime

open Alaya.Base Alaya.Core Alaya.LLM

open Lean (Json)

/-- What a command left: its output, the version of the workspace it left, and, when the command
was run so, the file where a later command finds the whole of its output. -/
structure Execution where
  output : Output
  workspace : Snapshot
  file? : Option String := none
  deriving Inhabited

/-- The run's time so far, along its log, and the time budget of the invocation that timed it. -/
structure Timing where
  spentMs : Nat
  budgetMs? : Option Nat := none
  deriving Inhabited

/-- What an agent may ask for. -/
inductive Op where
  /-- A response of `model` to `request`. -/
  | sample (model : Models.Spec) (request : Chat.Request)
  /-- `command`, run in the workspace at the version the log has reached, in the container of the
  call it is made in, as `config` says. -/
  | exec (command : String) (config : Executor.Config)
  /-- The run's time. -/
  | time
  deriving Inhabited

def Op.Answer : Op → Type
  | .sample .. => Chat.Response
  | .exec .. => Execution
  | .time => Timing

/-- What the log keeps of an operation: all of it, except that a sample is kept by its model's
spec and the digest of its request (`Model.requestDigest`), so the log does not hold the dialogue
again with every response. The request itself is what replay asks for at that point. -/
inductive Op.Key where
  | sample (model : Json) (digest : Hash)
  | exec (command : String) (config : Executor.Config)
  | time
  deriving BEq, Inhabited

def Op.key : Op → Op.Key
  | .sample model request => .sample model.toJson (Model.requestDigest request)
  | .exec command config => .exec command config
  | .time => .time

/-- An answer, of whichever operation, as the log keeps it. -/
inductive Stored where
  | response (response : Chat.Response)
  | execution (execution : Execution)
  | timing (timing : Timing)
  deriving Inhabited

def Op.store : (op : Op) → op.Answer → Stored
  | .sample .., r => .response r
  | .exec .., e => .execution e
  | .time, t => .timing t

def Op.read : (op : Op) → Stored → Option op.Answer
  | .sample .., .response r => some r
  | .exec .., .execution e => some e
  | .time, .timing t => some t
  | _, _ => none

/-- The signature of Alaya's agents. -/
abbrev Agent : Signature :=
  { Op, Answer := Op.Answer, Key := Op.Key, key := Op.key, sameKey := (· == ·)
    Stored, store := Op.store, read := Op.read }

/-- The operations, as programs: each fails where it was performed when the world could not
answer it. -/
def sample (model : Models.Spec) (request : Chat.Request) : Computation Agent Chat.Response :=
  perform (σ := Agent) (.sample model request)
def exec (command : String) (config : Executor.Config := {}) : Computation Agent Execution :=
  perform (σ := Agent) (.exec command config)
def time : Computation Agent Timing := perform (σ := Agent) .time

/-- The operation in a few words, for messages. -/
def Op.describe : Op → String
  | .sample model request => s!"sample {model.name} on a request of {request.messages.size} messages"
  | .exec command _ => s!"run {command}"
  | .time => "time the run"

/-! ## The workspace a log has reached -/

/-- The version of the workspace an event leaves, when it leaves one: a command does, and so
does a change from outside. -/
def versionAfter? : Event Agent → Option Snapshot
  | .answered _ _ (.ok (.execution execution)) => some execution.workspace
  | .arrived (.changed workspace _) => some workspace
  | _ => none

/-- The version of the workspace a log has reached; the first is the root's. -/
def workspace? (log : Log Agent) : Option Snapshot :=
  log.foldl (init := none) fun version event => (versionAfter? event).or version

/-! ## The log as JSON -/

private def nullable (json : Json) (name : String) (read : Json → Except String α) :
    Except String (Option α) := do
  match json.getObjVal? name with
  | .error _ | .ok .null => pure none
  | .ok value => some <$> read value

private def orNull (value? : Option α) (write : α → Json) : Json :=
  value?.map write |>.getD .null

private def str (json : Json) (name : String) : Except String String :=
  json.getObjVal? name >>= Json.getStr?

private def nat (json : Json) (name : String) : Except String Nat :=
  json.getObjVal? name >>= Json.getNat?

private def hashOf (json : Json) : Except String Hash := do
  let hex ← json.getStr?
  if Hash.valid hex then pure ⟨hex⟩ else throw s!"not a digest: {hex}"

/-- A frame as the log keeps it: its steps, each as `Frame.Segment.render` writes it. -/
def _root_.Alaya.Core.Frame.toJson (frame : Frame) : Json := .arr (frame.map fun segment => .str segment.render)

def _root_.Alaya.Core.Frame.fromJson (json : Json) : Except String Frame := do
  (← json.getArr?).mapM fun step => do Frame.Segment.parse (← step.getStr?)

def _root_.Alaya.Core.RoutineCall.toJson (call : RoutineCall) : Json :=
  .mkObj (([("name", .str call.name), ("arguments", call.arguments)] : List (String × Json)) ++
    (call.environment?.map fun environment => ("environment", environment)).toList)

def _root_.Alaya.Core.RoutineCall.fromJson (json : Json) : Except String RoutineCall := do
  let environment? := (json.getObjVal? "environment").toOption
  pure { name := ← str json "name", arguments := ← json.getObjVal? "arguments", environment? }

/-- A reply as the log keeps it: its kind under `type`, which needs no question to read. -/
def _root_.Alaya.Base.Reply.toStored : Reply → Json
  | .yes => .mkObj [("type", "yes")]
  | .no => .mkObj [("type", "no")]
  | .choice number => .mkObj [("type", "choice"), ("number", number)]
  | .noneOfAbove => .mkObj [("type", "none_of_above")]
  | .text words => .mkObj [("type", "text"), ("text", words)]
  | .unavailable => .mkObj [("type", "unavailable")]

def _root_.Alaya.Base.Reply.ofStored (json : Json) : Except String Reply := do
  match ← str json "type" with
  | "yes" => pure .yes
  | "no" => pure .no
  | "choice" => .choice <$> nat json "number"
  | "none_of_above" => pure .noneOfAbove
  | "text" => .text <$> str json "text"
  | "unavailable" => pure .unavailable
  | other => throw s!"unknown reply: {other}"

def _root_.Alaya.Core.Notice.toJson : Notice → Json
  | .said message => .mkObj [("type", "said"), ("message", message)]
  | .changed workspace summary =>
    .mkObj [("type", "changed"), ("workspace", workspace.hex), ("summary", summary)]
  | .replied to reply => .mkObj [("type", "replied"), ("to", to.toJson), ("reply", reply.toStored)]
  | .called call => .mkObj [("type", "called"), ("call", call.toJson)]

def _root_.Alaya.Core.Notice.fromJson (json : Json) : Except String Notice := do
  match ← str json "type" with
  | "said" => .said <$> str json "message"
  | "changed" => pure (.changed (← json.getObjVal? "workspace" >>= hashOf) (← str json "summary"))
  | "replied" =>
    pure (.replied (← json.getObjVal? "to" >>= Frame.fromJson) (← json.getObjVal? "reply" >>= Reply.ofStored))
  | "called" => .called <$> (json.getObjVal? "call" >>= RoutineCall.fromJson)
  | other => throw s!"unknown notice: {other}"

def Op.Key.toJson : Op.Key → Json
  | .sample model digest => .mkObj [("type", "sample"), ("model", model), ("request", digest.hex)]
  | .exec command config => .mkObj [("type", "exec"), ("command", command), ("config", config.toJson)]
  | .time => .mkObj [("type", "time")]

def Op.Key.fromJson (json : Json) : Except String Op.Key := do
  match ← str json "type" with
  | "sample" => pure (.sample (← json.getObjVal? "model") (← json.getObjVal? "request" >>= hashOf))
  | "exec" => pure (.exec (← str json "command") (← json.getObjVal? "config" >>= Executor.Config.fromJson))
  | "time" => pure .time
  | other => throw s!"unknown operation: {other}"

def Stored.toJson : Stored → Json
  | .response r => r.toStored
  | .execution e =>
    .mkObj [("output", e.output.toJson), ("workspace", e.workspace.hex), ("file", orNull e.file? .str)]
  | .timing t => .mkObj [("spent_ms", t.spentMs), ("budget_ms", orNull t.budgetMs? fun n => (n : Json))]

/-- An answer, read as the answer of the operation `key` names. -/
def Stored.fromJson (key : Op.Key) (json : Json) : Except String Stored := do
  match key with
  | .sample .. => .response <$> Chat.Response.ofStored json
  | .exec .. =>
    let some output := Output.fromJson? (← json.getObjVal? "output")
      | throw "an execution's output is not a command's output"
    pure (.execution { output, workspace := ← json.getObjVal? "workspace" >>= hashOf
                       file? := ← nullable json "file" Json.getStr? })
  | .time => pure (.timing { spentMs := ← nat json "spent_ms", budgetMs? := ← nullable json "budget_ms" Json.getNat? })

def eventToJson : Event Agent → Json
  | .arrived notice => .mkObj [("type", "arrived"), ("notice", notice.toJson)]
  | .heard frame notices =>
    .mkObj [("type", "heard"), ("frame", frame.toJson), ("notices", .arr (notices.map fun (n : Nat) => (n : Json)))]
  | .asked frame question =>
    .mkObj [("type", "asked"), ("frame", frame.toJson), ("question", question.toJson)]
  | .answered frame key answer =>
    .mkObj [("type", "answered"), ("frame", frame.toJson), ("op", key.toJson),
      ("answer", match answer with | .ok stored => Stored.toJson stored | .error _ => .null),
      ("error", match answer with | .ok _ => .null | .error error => .str error)]
  | .opened frame call => .mkObj [("type", "opened"), ("frame", frame.toJson), ("routine", call.toJson)]
  | .returned frame value => .mkObj [("type", "returned"), ("frame", frame.toJson), ("value", value)]
  | .failed frame failure => .mkObj [("type", "failed"), ("frame", frame.toJson),
      ("kind", failure.kind), ("error", failure.reason)]
  | .broke frame reason => .mkObj [("type", "broke"), ("frame", frame.toJson), ("reason", reason)]
  | .commented text => .mkObj [("type", "commented"), ("text", text)]

def eventFromJson (json : Json) : Except String (Event Agent) := do
  let frame : Except String Frame := json.getObjVal? "frame" >>= Frame.fromJson
  match ← str json "type" with
  | "arrived" => .arrived <$> (json.getObjVal? "notice" >>= Notice.fromJson)
  | "heard" => pure (.heard (← frame) (← (← json.getObjVal? "notices" >>= Json.getArr?).mapM Json.getNat?))
  | "asked" => pure (.asked (← frame) (← json.getObjVal? "question" >>= Question.fromJson))
  | "answered" =>
    let key ← json.getObjVal? "op" >>= Op.Key.fromJson
    let answer ← match ← nullable json "error" Json.getStr? with
      | some error => pure (.error error)
      | none => .ok <$> (json.getObjVal? "answer" >>= Stored.fromJson key)
    pure (.answered (← frame) key answer)
  | "opened" => pure (.opened (← frame) (← json.getObjVal? "routine" >>= RoutineCall.fromJson))
  | "returned" => pure (.returned (← frame) (← json.getObjVal? "value"))
  | "failed" =>
    let kind ← str json "kind"
    let some failure := Failure.ofKind? kind (← str json "error")
      | throw s!"unknown kind of failure: {kind} (the kinds are refused, defect, broken)"
    pure (.failed (← frame) failure)
  | "broke" => pure (.broke (← frame) (← str json "reason"))
  | "commented" => .commented <$> str json "text"
  | other => throw s!"unknown event: {other}"

end Alaya.Runtime
