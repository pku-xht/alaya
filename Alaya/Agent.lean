import Alaya.Replay
import Alaya.Model
import Alaya.Executor
import Alaya.Chat.Stored

/-! What an agent of Alaya may ask the world for: its signature, `Agent`. A model samples, a
command runs in the workspace, the clock tells the run's time, and an external program runs in a
container of its own on a checkout of the workspace, which is how a grader works. Each has its
type of answer, and the log keeps every operation by a key and every answer as JSON
(`docs/log-schema.md`). See `docs/agent-api.md`. -/

namespace Alaya

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

/-- What an external program left: how it ended, what it printed, and the checkout it ran on, as
it left it. `error?` says why it did not finish, when it did not: a timeout, or a failure to
start it. -/
structure External where
  exitCode? : Option Int := none
  stdout : String
  stderr : String
  checkout : Snapshot
  elapsedMs : Nat
  error? : Option String := none
  deriving Inhabited

/-- What an agent may ask for. -/
inductive Op where
  /-- A response of the model to `request`. -/
  | sample (request : Chat.Request)
  /-- `command`, run in the workspace at the version the log has reached, as `config` says. -/
  | exec (command : String) (config : Executor.Config)
  /-- The run's time. -/
  | time
  /-- An external program, opaque to the run: `command` in a fresh container of `image`, with no
  network, on a checkout of the workspace, with `input?`, files that are not in the workspace,
  mounted to read at `/grader`. The checkout it leaves is in its answer; the workspace of the run
  stays where it is. -/
  | external (command image : String) (input? : Option Snapshot) (timeoutSeconds : Nat)
  deriving Inhabited

def Op.Answer : Op → Type
  | .sample _ => Chat.Response
  | .exec .. => Execution
  | .time => Timing
  | .external .. => External

/-- What the log keeps of an operation: all of it, except that a sample is kept by the digest of
its request (`Model.requestDigest`), so the log does not hold the dialogue again with every
response. The request itself is what replay asks for at that point. -/
inductive Op.Key where
  | sample (digest : Hash)
  | exec (command : String) (config : Executor.Config)
  | time
  | external (command image : String) (input? : Option Snapshot) (timeoutSeconds : Nat)
  deriving BEq, Inhabited

def Op.key : Op → Op.Key
  | .sample request => .sample (Model.requestDigest request)
  | .exec command config => .exec command config
  | .time => .time
  | .external command image input? timeout => .external command image input? timeout

/-- An answer, of whichever operation, as the log keeps it. -/
inductive Stored where
  | response (response : Chat.Response)
  | execution (execution : Execution)
  | timing (timing : Timing)
  | external (external : External)
  deriving Inhabited

def Op.store : (op : Op) → op.Answer → Stored
  | .sample _, r => .response r
  | .exec .., e => .execution e
  | .time, t => .timing t
  | .external .., ran => .external ran

def Op.read : (op : Op) → Stored → Option op.Answer
  | .sample _, .response r => some r
  | .exec .., .execution e => some e
  | .time, .timing t => some t
  | .external .., .external ran => some ran
  | _, _ => none

/-- The signature of Alaya's agents. -/
abbrev Agent : Signature :=
  { Op, Answer := Op.Answer, Key := Op.Key, key := Op.key, sameKey := (· == ·)
    Stored, store := Op.store, read := Op.read }

/-- The operations, as programs: each fails where it was performed when the world could not
answer it. -/
def sample (request : Chat.Request) : Program Agent Chat.Response := perform (σ := Agent) (.sample request)
def exec (command : String) (config : Executor.Config := {}) : Program Agent Execution :=
  perform (σ := Agent) (.exec command config)
def time : Program Agent Timing := perform (σ := Agent) .time
def external (command image : String) (input? : Option Snapshot) (timeoutSeconds : Nat) :
    Program Agent External :=
  perform (σ := Agent) (.external command image input? timeoutSeconds)

/-- The operation in a few words, for messages. -/
def Op.describe : Op → String
  | .sample request => s!"sample a request of {request.messages.size} messages"
  | .exec command _ => s!"run {command}"
  | .time => "time the run"
  | .external command image _ _ => s!"run {command} in {image}"

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

def Frame.toJson (frame : Frame) : Json := .arr (frame.map fun (n : Nat) => (n : Json))

def Frame.fromJson (json : Json) : Except String Frame := do
  (← json.getArr?).mapM Json.getNat?

def RoutineCall.toJson (call : RoutineCall) : Json :=
  .mkObj [("name", call.name), ("arguments", call.arguments)]

def RoutineCall.fromJson (json : Json) : Except String RoutineCall := do
  pure { name := ← str json "name", arguments := ← json.getObjVal? "arguments" }

/-- A reply as the log keeps it: its kind under `type`, which needs no question to read. -/
def Reply.toStored : Reply → Json
  | .yes => .mkObj [("type", "yes")]
  | .no => .mkObj [("type", "no")]
  | .choice number => .mkObj [("type", "choice"), ("number", number)]
  | .noneOfAbove => .mkObj [("type", "none_of_above")]
  | .text words => .mkObj [("type", "text"), ("text", words)]
  | .unavailable => .mkObj [("type", "unavailable")]

def Reply.ofStored (json : Json) : Except String Reply := do
  match ← str json "type" with
  | "yes" => pure .yes
  | "no" => pure .no
  | "choice" => .choice <$> nat json "number"
  | "none_of_above" => pure .noneOfAbove
  | "text" => .text <$> str json "text"
  | "unavailable" => pure .unavailable
  | other => throw s!"unknown reply: {other}"

def Notice.toJson : Notice → Json
  | .said message => .mkObj [("type", "said"), ("message", message)]
  | .changed workspace summary =>
    .mkObj [("type", "changed"), ("workspace", workspace.hex), ("summary", summary)]
  | .replied to reply => .mkObj [("type", "replied"), ("to", to.toJson), ("reply", reply.toStored)]
  | .assigned grader => .mkObj [("type", "assigned"), ("grader", grader)]

def Notice.fromJson (json : Json) : Except String Notice := do
  match ← str json "type" with
  | "said" => .said <$> str json "message"
  | "changed" => pure (.changed (← json.getObjVal? "workspace" >>= hashOf) (← str json "summary"))
  | "replied" =>
    pure (.replied (← json.getObjVal? "to" >>= Frame.fromJson) (← json.getObjVal? "reply" >>= Reply.ofStored))
  | "assigned" => .assigned <$> json.getObjVal? "grader"
  | other => throw s!"unknown notice: {other}"

def Op.Key.toJson : Op.Key → Json
  | .sample digest => .mkObj [("type", "sample"), ("request", digest.hex)]
  | .exec command config => .mkObj [("type", "exec"), ("command", command), ("config", config.toJson)]
  | .time => .mkObj [("type", "time")]
  | .external command image input? timeout =>
    .mkObj [("type", "external"), ("command", command), ("image", image),
      ("input", orNull input? (Json.str ·.hex)), ("timeout_seconds", timeout)]

def Op.Key.fromJson (json : Json) : Except String Op.Key := do
  match ← str json "type" with
  | "sample" => .sample <$> (json.getObjVal? "request" >>= hashOf)
  | "exec" => pure (.exec (← str json "command") (← json.getObjVal? "config" >>= Executor.Config.fromJson))
  | "time" => pure .time
  | "external" =>
    pure (.external (← str json "command") (← str json "image") (← nullable json "input" hashOf)
      (← nat json "timeout_seconds"))
  | other => throw s!"unknown operation: {other}"

def Stored.toJson : Stored → Json
  | .response r => r.toStored
  | .execution e =>
    .mkObj [("output", e.output.toJson), ("workspace", e.workspace.hex), ("file", orNull e.file? .str)]
  | .timing t => .mkObj [("spent_ms", t.spentMs), ("budget_ms", orNull t.budgetMs? fun n => (n : Json))]
  | .external e =>
    .mkObj [("exit_code", orNull e.exitCode? fun n => (n : Json)), ("stdout", e.stdout),
      ("stderr", e.stderr), ("checkout", e.checkout.hex), ("elapsed_ms", e.elapsedMs),
      ("error", orNull e.error? .str)]

/-- An answer, read as the answer of the operation `key` names. -/
def Stored.fromJson (key : Op.Key) (json : Json) : Except String Stored := do
  match key with
  | .sample _ => .response <$> Chat.Response.ofStored json
  | .exec .. =>
    let some output := Output.fromJson? (← json.getObjVal? "output")
      | throw "an execution's output is not a command's output"
    pure (.execution { output, workspace := ← json.getObjVal? "workspace" >>= hashOf
                       file? := ← nullable json "file" Json.getStr? })
  | .time => pure (.timing { spentMs := ← nat json "spent_ms", budgetMs? := ← nullable json "budget_ms" Json.getNat? })
  | .external .. =>
    pure (.external {
      exitCode? := ← nullable json "exit_code" Json.getInt?
      stdout := ← str json "stdout", stderr := ← str json "stderr"
      checkout := ← json.getObjVal? "checkout" >>= hashOf
      elapsedMs := ← nat json "elapsed_ms"
      error? := ← nullable json "error" Json.getStr? })

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
  | .failed frame error => .mkObj [("type", "failed"), ("frame", frame.toJson), ("error", error)]
  | .stopped reason => .mkObj [("type", "stopped"), ("reason", reason)]
  | .commented frame? text =>
    .mkObj [("type", "commented"), ("frame", orNull frame? Frame.toJson), ("text", text)]

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
  | "failed" => pure (.failed (← frame) (← str json "error"))
  | "stopped" => .stopped <$> str json "reason"
  | "commented" => pure (.commented (← nullable json "frame" Frame.fromJson) (← str json "text"))
  | other => throw s!"unknown event: {other}"

end Alaya
