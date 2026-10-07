import Alaya.Agents.Basic

/-! Alaya's agent for Vero's Lean implementation and proof tasks: the basic agent with Vero's
instructions, and every extension of its loop on. It ends with the `submit` tool, paces
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
  /-- How commands are run. -/
  executor : Executor.Config := Basic.defaultExecutor
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
    ("executor", Basic.executorToJson config.executor),
    ("context_reserve", (config.contextReserve : Lean.Json)),
    ("question_types", .arr (config.questionTypes.map fun kind => .str kind.name))]

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Lean.Json) : Except String Config := do
  let object ← ConfigJson.object json
    #["model", "task", "mode", "executor", "context_reserve", "question_types"]
  let defaults : Config := {}
  let model? ← match ← object.field? "model" with
    | none => pure defaults.model?
    | some json => Basic.modelFromJson json
  let task? ← match ← object.field? "task" with
    | none => pure defaults.task?
    | some json => Basic.taskFromJson json
  let mode ← match ← object.field? "mode" with
    | none => pure defaults.mode
    | some (.str name) => match Mode.ofString? name with
      | some mode => pure mode
      | none => throw s!"unknown mode: {name} (use {" or ".intercalate (Mode.all.map toString)})"
    | some other => throw s!"'mode' must be a string, not {other.compress}"
  let executor ← match ← object.field? "executor" with
    | none => pure defaults.executor
    | some json => Basic.executorFromJson json defaults.executor
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
         contextReserve := ← object.nat "context_reserve" defaults.contextReserve }

/-- The tools it offers: the basic agent's, `bash` and `submit`; `ask_user`, for the kinds of
question its configuration names; `time_budget`; and `subagent`, calling the agent itself with
its configuration. -/
def Config.tools (config : Config) : Array Tool :=
  Basic.tools config.executor ++
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

/-! ## The loop

The basic agent's loop, with its extensions: old outputs are left out of the view, and a request
that would not fit the model's context ends the agent before it is sent. -/

open Basic (Dialogue Item outcome)

/-- The state of the loop: the conversation, and the latest request whose response reported its
size: its messages, the tokens it held, and the tokens of the response. -/
structure History where
  items : Array Item := #[]
  measured? : Option (Dialogue × Nat × Option Nat) := none

/-- What an omitted output says in its place. -/
def omittedNotice (file : String) : String := s!"[output omitted; full output: {file}]"

/-- How the model sees a command: as the basic agent shows it; and, in a turn the view leaves old
outputs out of, as the file that holds it, unless the output is shorter than saying so. -/
def observe (output : Output) (file? : Option String) (omittedTurn : Bool) : String :=
  match file? with
  | some file =>
    if omittedTurn && output.output.length > (omittedNotice file).length then
      Basic.withStatus output (omittedNotice file)
    else Basic.observation output file?
  | none => Basic.observation output none

/-- The view: the basic agent's, with the outputs of the turns `masking` omits left out. -/
def view (history : History) (masking : Masking := masking) : Dialogue :=
  let turns := history.items.foldl (init := 0) fun n item => match item with | .told _ => n | _ => n + 1
  let omitted := masking.omittedTurns turns
  Basic.viewWith (items := history.items) fun turn call result =>
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

/-- One round: the basic agent's, except that it ends before a request too large for the
context, and keeps the size of the last request a response reported. -/
def round (config : Config) (model : Models.Spec) (history : History) : Computation Agent (History ⊕ Lean.Json) := do
  let history := { history with items := history.items ++ (← Basic.heard).map .told }
  let request : Chat.Request := { messages := view history, tools := config.tools.map (·.definition) }
  if let some limit := contextLimit? config model then
    if contextTokens history request.messages >= limit then return .inr (outcome "ContextExceeded")
  let response ← try sample model request catch refusal => return .inr (Basic.refused refusal)
  let measured? := match response.usage?.bind (·.input?) with
    | some input => some (request.messages, input, response.usage?.bind (·.output?))
    | none => history.measured?
  return match ← Basic.respond config.tools history.items response with
    | .inl items => .inl { items, measured? }
    | .inr ended => .inr ended

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
