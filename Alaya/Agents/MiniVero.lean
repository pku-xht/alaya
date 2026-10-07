import Alaya.Agents.Basic

/-! Alaya's agent for Vero's Lean implementation and proof tasks: the basic agent with Vero's
instructions, and every extension of its loop on. It ends with the `submit` tool, once the task
is done or the budget nearly spent; is told the time left as it goes; can hand work to a
sub-agent like it; names the file a long output is kept in; and leaves old outputs out of its
view. `ask_user` is offered when its configuration names the kinds of question it may ask. Rendering and grading are external. See
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

/-- The basic agent's configuration, with Vero's mode, the room kept for a response, and the
kinds of question it may ask. -/
structure Config extends Basic.Config where
  mode : Mode := .proof
  /-- Tokens kept free for the next response when deciding whether the context is full, or the
  model's `output_tokens` when that is less. -/
  contextReserve : Nat := 8000
  deriving Inhabited

def fields : Fields Config :=
  Basic.fields.lift (·.toConfig) (fun b c => { c with toConfig := b }) ++ #[
  .of "mode" (.enum toString Mode.all) (·.mode) fun v c => { c with mode := v },
  .of "context_reserve" .nat (·.contextReserve) fun v c => { c with contextReserve := v }]

/-- The configuration as JSON: what a run records, and what `alaya config` shows. -/
def Config.toJson (config : Config) : Lean.Json := fields.toJson config

/-- Reads a configuration; a field left out is its default, and an unknown one is an error. -/
def Config.fromJson (json : Lean.Json) : Except String Config := fields.read json {}

/-- The tools it offers: the basic agent's, `bash`, `submit` and `ask_user` when its
configuration names kinds of question; and `subagent`, calling the agent itself
with its configuration. -/
def Config.tools (config : Config) : Array Tool :=
  Basic.tools config.toConfig ++ #[Tools.Subagent.tool "mini-vero" config.toJson]

/-- `text` with the instructions of the offered tools after it, as the basic agent adds them. -/
def withInstructions (config : Config) (text : String) : String :=
  Basic.withInstructions config.tools text

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
/-- Vero's `Persistence` section up to its advice: its heading and first three paragraphs, to the
byte. What follows them in Vero is said in `Checkpointing`, or is advice on how to work. -/
def persistence : String := quoted (include_str "MiniVero/persistence.md")
def antiCheating : String := quoted (include_str "MiniVero/anti-cheating.md")

/-- Vero's `Checkpointing` section, adapted: its chunk of a known number of minutes is a time
budget the model is told the rest of as it goes, which it paces itself by where Vero says `date`. Unlike
the files above, not Vero's to the byte (`docs/agents.md` §5 lists the changes). -/
def checkpointing : String := quoted (include_str "MiniVero/checkpointing.md")

def grading : Mode -> String
  | .proof => gradingProof
  | .codeproof => gradingCodeproof

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
    persistence,
    checkpointing,
    antiCheating,
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
  /-- The budget the model was last told the time left of, and how many tenths of it were
  spent then. -/
  reported : Nat × Nat := (0, 0)

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
    | _, _ => Basic.shown call result

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

/-- The note that tells the model how much of the run's time is left. -/
def timeNote (timing : Timing) (budget : Nat) : String :=
  s!"[time] {(budget - timing.spentMs) / 60000} of {budget / 60000} minutes remain."

/-- How many tenths of `budget` the run has spent, from none to all ten. -/
def tenths (timing : Timing) (budget : Nat) : Nat :=
  if budget == 0 then 10 else min 10 (timing.spentMs * 10 / budget)

/-- The note due at `timing`, if one is, and what the model has then been told: one each time
another tenth of the budget is spent, counted afresh when the budget is another. -/
def notice? (reported : Nat × Nat) (timing : Timing) : Option (String × (Nat × Nat)) := do
  let budget ← timing.budgetMs?
  let told := if reported.1 == budget then reported.2 else 0
  if tenths timing budget ≤ told then none
  else some (timeNote timing budget, (budget, tenths timing budget))

/-- What tells the agent the task is done, as Vero's Done condition has it: `lake build`
succeeds, and no slot still holds `sorry`, which Lean warns of, on every build. -/
def doneCheck : String :=
  "out=$(lake build 2>&1); s=$?; printf '%s\n' \"$out\" | tail -n 30; " ++
  "[ $s -eq 0 ] && ! printf '%s\n' \"$out\" | grep -q \"uses 'sorry'\""

/-- The conversation after `response`, a `submit` alone in it, when the task is not done: the
call answered with what the check found and the time left. `none` when the submission stands:
the check passes, or no more than a tenth of the budget is left. -/
def checkSubmit (config : Config) (timing : Timing) (items : Array Item) (response : Chat.Response) :
    Computation Agent (Option (Array Item)) := do
  let some budget := timing.budgetMs? | return none
  let #[asked] := response.toolCalls | return none
  if asked.name != Tools.Submit.definition.name || tenths timing budget ≥ 9 then return none
  let ran ← exec doneCheck config.executor
  if ran.output.exitCode? == some 0 then return none
  let told := "Not done: by the Done condition, `lake build` must succeed and no slot may hold " ++
    s!"`sorry`. {timeNote timing budget} Keep working, and submit once the Done condition holds." ++
    "\n\n" ++ ran.output.output
  return some (items.push (.turn response #[(asked, .error told)]))

/-- One round: the basic agent's, except that it tells the model the time left each time
another tenth of the budget is spent; ends before a request too large for the context, keeping
the size of the last request a response reported; and answers a `submit` that comes before the
last tenth of the budget, when the task is not done, instead of ending. -/
def round (config : Config) (model : Models.Spec) (history : History) : Computation Agent (History ⊕ Lean.Json) := do
  let history := { history with items := history.items ++ (← Basic.heard).map .told }
  -- The time left, told once each tenth of the budget is spent.
  let timing ← time
  let history := match notice? history.reported timing with
    | some (note, reported) => { history with items := history.items.push (.told (.user note)), reported }
    | none => history
  let request : Chat.Request := { messages := view history, tools := config.tools.map (·.definition) }
  if let some limit := contextLimit? config model then
    if contextTokens history request.messages >= limit then return .inr (outcome "ContextExceeded")
  let response ← try sample model request catch
    | .refused refusal => return .inr (Basic.refused refusal)
    | failure => throw failure
  let measured? := match response.usage?.bind (·.input?) with
    | some input => some (request.messages, input, response.usage?.bind (·.output?))
    | none => history.measured?
  if let some items ← checkSubmit config timing history.items response then
    return .inl { history with items, measured? }
  return match ← Basic.respond config.tools history.items response with
    | .inl items => .inl { history with items, measured? }
    | .inr ended => .inr ended

/-! ## The agent -/

/-- MiniVero, for a call of `model` on `task`, on the machine the call names. -/
def computation (config : Config) (model : Models.Spec) (task : String) : Computation Agent Lean.Json := do
  let uname ← Tools.Uname.read
  iter (round config model) { items := (openingMessages config task uname).map .told }

/-- MiniVero as a routine. Its scope is its tools' routines, and itself: the `subagent` routine,
given this same scope, finds MiniVero there and calls it with its configuration and another
task. -/
def routine : Routine Agent :=
  let make := Basic.agent "mini-vero" fields {} (·.toCommon) computation
  make (Scope.fix fun scope => Tools.routines ++ #[make scope, { Tools.Subagent.routine with scope }])

end Alaya.Agents.MiniVero
