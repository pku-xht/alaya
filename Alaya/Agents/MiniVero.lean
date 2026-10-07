import Alaya.Agents.MiniSwe

/-! Alaya's agent for Vero's Lean implementation and proof tasks: MiniSwe's loop with Vero's
instructions, and every extension of that loop on. It ends with the `submit` tool, paces
itself by `time_budget`, can hand work to a sub-agent like it, names the file a long output is
kept in, and leaves old outputs out of its view; `ask_user` is offered when its configuration
names the kinds of question it may ask. Rendering and grading are external. See
`docs/agents.md` §5. -/
namespace Alaya.Agents.MiniVero

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

/-- Vero's evaluation modes. A run is sent the grading rules of its own mode only, as Vero's
per-mode instruction templates do. -/
inductive Mode where
  | proof
  | codeproof
  deriving Inhabited, BEq, Repr

def Mode.toString : Mode -> String
  | .proof => "proof"
  | .codeproof => "codeproof"

instance : ToString Mode := ⟨Mode.toString⟩

def Mode.all : List Mode := [.proof, .codeproof]

def Mode.ofString? (name : String) : Option Mode :=
  Mode.all.find? (·.toString == name)

/-! ## Configuration -/

/-- How MiniVero runs a command: a ten-minute limit, for Lake builds, and no overrides. -/
def defaultExecutor : Executor.Config := { timeoutSeconds := 600, env := #[] }

/-- Which old outputs the view omits: those of the turns before a boundary that keeps the last
`keepTurns` turns whole and moves `block` turns at a time, so between its moves the context only
grows at its end and the provider's prompt cache holds. -/
structure Masking where
  keepTurns : Nat
  block : Nat
  deriving Inhabited, BEq, Repr

/-- How many turns from the first are omitted when the conversation holds `turns`: none until
the boundary first moves, then a multiple of `block`. -/
def Masking.omittedTurns (m : Masking) (turns : Nat) : Nat :=
  if turns < m.keepTurns + m.block then 0 else ((turns - m.keepTurns) / m.block) * m.block

/-- The old outputs its view omits: all but the last 20 turns', the boundary moving 10 turns at a
time. -/
def masking : Masking := { keepTurns := 20, block := 10 }

structure Config where
  /-- The model it samples: its complete spec. There is no default: whoever calls the agent
  names one. -/
  model? : Option Models.Spec := none
  /-- The task, verbatim. There is no default: whoever calls the agent gives one. -/
  task? : Option String := none
  mode : Mode := .proof
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  /-- Tokens kept free for the next response when deciding whether the context is full, or the
  model's `output_tokens` when that is less. -/
  contextReserve : Nat := 8000
  /-- The kinds of question `ask_user` lets the model ask; none, the default, offers no
  `ask_user`. -/
  questionTypes : Array Question.Kind := #[]
  deriving Inhabited

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Lean.Json :=
  .mkObj [
    ("model", config.model?.map (·.toJson) |>.getD .null),
    ("task", config.task?.map Lean.Json.str |>.getD .null),
    ("mode", toString config.mode),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("executor", .mkObj [
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json)),
      ("env", .arr (config.executor.env.map fun (name, value) => .arr #[.str name, .str value]))]),
    ("context_reserve", (config.contextReserve : Lean.Json)),
    ("question_types", .arr (config.questionTypes.map fun kind => .str kind.name))]

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Lean.Json) : Except String Config := do
  let object ← ConfigJson.object json
    #["model", "task", "mode", "max_consecutive_format_errors", "executor", "context_reserve", "question_types"]
  let defaults : Config := {}
  let model? ← match ← object.field? "model" with
    | none => pure defaults.model?
    | some json => MiniSwe.modelFromJson json
  let task? ← match ← object.field? "task" with
    | none => pure defaults.task?
    | some json => MiniSwe.taskFromJson json
  let mode ← match ← object.field? "mode" with
    | none => pure defaults.mode
    | some (.str name) => match Mode.ofString? name with
      | some mode => pure mode
      | none => throw s!"unknown mode: {name} (use {" or ".intercalate (Mode.all.map toString)})"
    | some other => throw s!"'mode' must be a string, not {other.compress}"
  let executor ← match ← object.field? "executor" with
    | none => pure defaults.executor
    | some json => MiniSwe.executorFromJson json defaults.executor
  let wrongTypes := s!"'question_types' must be an array of {Question.Kind.names}"
  let questionTypes ← match ← object.field? "question_types" with
    | none => pure defaults.questionTypes
    | some (.arr names) => names.mapM fun
      | .str name => match Question.Kind.ofName? name with
        | some kind => pure kind
        | none => throw s!"unknown kind of question '{name}': {wrongTypes}"
      | other => throw s!"{wrongTypes}, not {other.compress}"
    | some other => throw s!"{wrongTypes}, not {other.compress}"
  for kind in questionTypes do
    if (questionTypes.filter (· == kind)).size > 1 then throw s!"'question_types' names {kind.name} twice"
  pure { model?, task?, mode, executor, questionTypes
         maxConsecutiveFormatErrors := ← object.nat "max_consecutive_format_errors" defaults.maxConsecutiveFormatErrors
         contextReserve := ← object.nat "context_reserve" defaults.contextReserve }

/-- The tools it offers: `bash`, its commands' outputs kept as files; `submit`; `ask_user`, for
the kinds of question its configuration names; `time_budget`; and `subagent`, calling the agent
itself with its configuration. -/
def Config.tools (config : Config) : Array Tool :=
  #[Tools.Bash.tool { config.executor with outputs := true }, Tools.Submit.tool] ++
    (if config.questionTypes.isEmpty then #[] else #[Tools.AskUser.tool config.questionTypes]) ++
    #[Tools.TimeBudget.tool, Tools.Subagent.tool "mini-vero" config.toJson]

/-- `text` with the instructions of the offered tools after it, a blank line before each: what
a tool adds to the prompt, which is only ever added. -/
def withInstructions (config : Config) (text : String) : String :=
  config.tools.foldl (init := text) fun text tool =>
    match tool.instruction? with
    | some instruction => text ++ "\n\n" ++ instruction
    | none => text

def systemMessage : String :=
  "You are MiniVero, a Lean 4 implementation and proof agent working in a Vero sandbox. " ++
  "Work on the task using the provided bash tool and finish with the submit tool; " ++
  "Vero's independent grader decides correctness."

/-! ## Vero's instructions

The files in `MiniVero/` are sections of Vero's instruction templates
(`templates/instruction/{base,proof,codeproof}.md.j2` at sunblaze-ucb/vero `0a7325d`), byte for
byte, cut where the templates themselves branch, so each can be compared with `diff`. Lake does
not track `include_str`: after editing one, touch this module to have it rebuilt. -/

private def quoted (text : String) : String := text.trimAsciiEnd.toString

def framing : String := quoted (include_str "MiniVero/framing.md")
def rules : String := quoted (include_str "MiniVero/rules.md")
def gradingProof : String := quoted (include_str "MiniVero/grading-proof.md")
def gradingCodeproof : String := quoted (include_str "MiniVero/grading-codeproof.md")
def doneCondition : String := quoted (include_str "MiniVero/done.md")
def antiCheating : String := quoted (include_str "MiniVero/anti-cheating.md")

/-- Vero's `Checkpointing` section, adapted: its chunk of a known number of minutes is a time
budget the `time_budget` tool reports, and it names that tool where Vero says `date`. Unlike
the files above, not Vero's to the byte (`docs/agents.md` §5 lists the changes). -/
def checkpointing : String := quoted (include_str "MiniVero/checkpointing.md")

def grading : Mode -> String
  | .proof => gradingProof
  | .codeproof => gradingCodeproof

/-- The two scoring facts of Vero's `Persistence` section, without its advice. -/
def scoring : String :=
  "## Scoring\n\n" ++
  "An unfilled slot scores the same as a wrong proof: zero. Every additional spec you " ++
  "close strictly increases the score."

/-- What this agent adds to Vero's rules: how its tools behave, and how a run ends. -/
def mechanics : String :=
  "Use repository-relative paths. Shell directory and environment changes do not persist " ++
  "across tool calls. When the Done condition holds, call the submit tool once with a " ++
  "short summary."

/-- The opening task message: the sections of this run, a blank line between them. Only
`grading` depends on the mode. -/
def taskMessage (task : String) (mode : Mode) (uname : Uname) : String :=
  "\n\n".intercalate <| [
    framing,
    "Solve this Vero task:\n\n" ++ task,
    rules,
    grading mode,
    doneCondition,
    checkpointing,
    antiCheating,
    scoring,
    mechanics,
    "Environment: " ++
      uname.system ++ " " ++ uname.machine]

/-- The opening of a conversation: the system message and the task. -/
def openingMessages (config : Config) (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system systemMessage, .user (withInstructions config (taskMessage task config.mode uname))]

/-! ## Format errors

Mini's format error (`MiniSwe.formatErrorMessage`), told in this agent's terms: the line that
names mini's sentinel names the `submit` tool, the sentences that require a `bash` call require a
tool call, so that no tool offered beside it is contradicted, and the tools' instructions follow. -/

/-- The last line of mini's format-error message, and this agent's. -/
def sentinelHint : String :=
  "If you want to end the task, please issue the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`\nwithout any other command."

def endHint : String :=
  "If you want to end the task, call the `submit` tool\nwithout any other tool call."

/-- Mini's sentences that require a `bash` call, requiring a tool call. -/
def toolNeutral (text : String) : String :=
  let text := text.replace "Every response needs to use the 'bash' tool at least once to execute commands."
    "Every response needs at least one tool call."
  text.replace "exactly one bash tool call" "exactly one tool call"

def formatErrorMessage (config : Config) (error : String) (hasToolCalls : Bool) (finishReason? : Option String) :
    String :=
  withInstructions config <| toolNeutral <|
    (MiniSwe.formatErrorMessage error hasToolCalls finishReason?).replace sentinelHint endHint

/-! ## The loop

MiniSwe's loop, with its extensions: the `submit` tool ends the run before its call is made,
outputs are kept as files and old ones left out of the view, and a request that would not fit
the model's context ends the agent before it is sent. -/

open MiniSwe (Dialogue Item Parsed outcome)

/-- Reads a response's tool calls against its tools, in its format error. -/
def parseActions (config : Config) (response : Chat.Response) : Parsed :=
  MiniSwe.parse config.tools (formatErrorMessage config) response

/-- The state of the loop: MiniSwe's, and the latest request whose response reported its size:
its messages, the tokens it held, and the tokens of the response. -/
structure History extends MiniSwe.History where
  measured? : Option (Dialogue × Nat × Option Nat) := none

/-- How the model sees a command: as JSON, cut to its head and tail when long, with the file the
whole of it is in; and, in a turn the view leaves old outputs out of, as that file alone, unless
the output is shorter than saying so. -/
def observe (output : Output) (file? : Option String) (omittedTurn : Bool) : String :=
  let content := match file? with
    | some file =>
      if omittedTurn && output.output.length > (Tools.Bash.omittedNotice file).length then
        Tools.Bash.omitted output file
      else Tools.Bash.observation output MiniSwe.outputLimit file?
    | none => Tools.Bash.observation output MiniSwe.outputLimit none
  content.pretty

/-- The view: MiniSwe's, with each command as `observe` shows it, and the outputs of the turns
`masking` omits left out. -/
def view (history : History) (masking : Masking := masking) : Dialogue :=
  let turns := history.items.foldl (init := 0) fun n item => match item with | .told _ => n | _ => n + 1
  let omitted := masking.omittedTurns turns
  MiniSwe.viewWith (items := history.items) fun turn call result =>
    match call.name, Tools.Bash.ofResult? result with
    | "bash", some (output, file?) => observe output file? (omitted > 0 && turn ≤ omitted)
    | _, _ => result.pretty

/-- The tokens `full`, the messages of the next request, holds, known without a tokenizer. The
latest response that reported its size says how many the request it answered held, and how many
it returned; what `full` holds after that request and the message that shows the response is
estimated. When `full` no longer begins with that request, as when old outputs have since been
masked, or nothing reported a size, the whole is estimated. -/
def contextTokens (history : History) (full : Dialogue) : Nat :=
  let wire (dialogue : Dialogue) := dialogue.map (·.toJson.compress)
  match history.measured? with
  | none => Chat.estimateTokens full
  | some (before, input, output?) =>
    if before.size < full.size && wire (full.extract 0 before.size) == wire before then
      let response := output?.getD (Chat.estimateTokens (full.extract before.size (before.size + 1)))
      input + response + Chat.estimateTokens (full.extract (before.size + 1) full.size)
    else Chat.estimateTokens full

/-- The tokens a request to `model` may hold: its context less the room kept for a response;
`none` when its context is not known. -/
def contextLimit? (config : Config) (model : Models.Spec) : Option Nat :=
  model.contextTokens?.map fun tokens =>
    tokens - min config.contextReserve (model.outputTokens?.getD config.contextReserve)

/-- One round: MiniSwe's, except that it ends before a request too large for the context, and
when the model calls `submit`, whose message is the submission; calls after it do not run. -/
def round (config : Config) (model : Models.Spec) (history : History) : Computation Agent (History ⊕ Lean.Json) := do
  let history := { history with items := ← MiniSwe.listen history.items }
  let request : Chat.Request := { messages := view history, tools := config.tools.map (·.definition) }
  if let some limit := contextLimit? config model then
    if contextTokens history request.messages >= limit then return .inr (outcome "ContextExceeded")
  let response ← try sample model request catch refusal => return .inr (MiniSwe.refused refusal)
  let history := { history with measured? := match response.usage?.bind (·.input?) with
    | some input => some (request.messages, input, response.usage?.bind (·.output?))
    | none => history.measured? }
  match parseActions config response with
  | .formatError message =>
    let history := { history with toHistory := history.toHistory.malformed message }
    let limit := config.maxConsecutiveFormatErrors
    if limit > 0 && history.formatErrors >= limit then return .inr (outcome "RepeatedFormatError")
    return .inl history
  | .calls calls =>
    let mut results : Array (Chat.ToolCall × Lean.Json) := #[]
    for asked in calls do
      if asked.name == Tools.Submit.definition.name then
        return .inr (outcome "Submitted" (Tools.Submit.message asked.arguments))
      results := results.push (asked, ← Tools.make config.tools asked)
    return .inl { history with items := history.items.push (.turn response results), formatErrors := 0 }

/-! ## The agent -/

/-- MiniVero, for a call of `model` on `task`, on the machine the call names. -/
def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Lean.Json := do
  let uname ← Tools.Uname.read
  iter (round config model) { items := (openingMessages config task uname).map .told }

/-- MiniVero as a routine. A call's arguments are its configuration, its model and its task
among it; one it cannot run on fails in the call's frame. Its scope is its tools, and itself,
which `subagent` calls with its configuration and another task. -/
def routine : Routine Agent :=
  let body (arguments : Lean.Json) : Computation Agent Lean.Json :=
    match Config.fromJson arguments with
    | .error problem => .fail s!"mini-vero: {problem}"
    | .ok config => match config.model?, config.task? with
      | some model, some task => computation config model task
      | none, _ => .fail "mini-vero: it samples a model, and its configuration names none"
      | _, none => .fail "mini-vero: it works on a task, and its configuration names none"
  { name := "mini-vero", body, scope := Scope.fix fun scope => Tools.routines.push { name := "mini-vero", body, scope } }

end Alaya.Agents.MiniVero
