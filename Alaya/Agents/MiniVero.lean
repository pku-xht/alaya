import Alaya.Agents.MiniSwe

/-! A minimal MiniSwe specialization for Vero: MiniSwe's loop with Vero's prompts. Rendering and
grading are external; the log, model providers and executor are shared with MiniSwe. -/
namespace Alaya.Agents.MiniVero

open Alaya (Executor Uname)

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

/-- MiniSwe's configuration, offering `time_budget` too, and Vero's evaluation mode. -/
structure Config where
  base : MiniSwe.Config := {
    executor := { timeoutSeconds := 600, env := #[] }
    tools := #["bash", "submit", "time_budget"] }
  mode : Mode := .proof
  deriving Inhabited

/-- The configuration as JSON: MiniSwe's fields, and `mode`. -/
def Config.toJson (config : Config) : Lean.Json :=
  match config.base.toJson with
  | .obj fields => .obj (fields.insert "mode" (toString config.mode))
  | other => other

/-- Whether the run is offered `time_budget`, and so asked to pace itself by it. -/
def Config.pacing (config : Config) : Bool :=
  config.base.tools.contains "time_budget"

def Config.fromJson (json : Lean.Json) : Except String Config := do
  let mode ← match json.getObjVal? "mode" with
    | .error _ => pure Mode.proof
    | .ok (.str name) =>
      match Mode.ofString? name with
      | some mode => pure mode
      | none => throw s!"unknown mode: {name} (use {" or ".intercalate (Mode.all.map toString)})"
    | .ok other => throw s!"'mode' must be a string, not {other.compress}"
  let defaults := ({} : Config).base
  -- The rest is MiniSwe's, read without the field that is this agent's own.
  let base ← match json with
    | .obj fields => MiniSwe.Config.fromJson (.obj (fields.erase "mode")) defaults #["mode"]
    | other => MiniSwe.Config.fromJson other defaults
  pure { base, mode }

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
the files above, not Vero's to the byte (`docs/minivero.md` lists the changes). -/
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
def taskMessage (task : String) (mode : Mode) (uname : Uname) (pacing : Bool := false) : String :=
  "\n\n".intercalate <| [
    framing,
    "Solve this Vero task:\n\n" ++ task,
    rules,
    grading mode,
    doneCondition] ++ (if pacing then [checkpointing] else []) ++ [
    antiCheating,
    scoring,
    mechanics,
    "Environment: " ++
      uname.system ++ " " ++ uname.machine]

/-- The opening of a conversation: the system message and the task. -/
def openingMessages (config : Config) (task : String) (uname : Uname) : Array Chat.Message :=
  #[.system systemMessage,
    .user (MiniSwe.withInstructions config.base (taskMessage task config.mode uname config.pacing))]

/-- MiniVero, for a call of `model` on `task`, on the machine the call names, which
`subagent` calls as `itself`: MiniSwe's loop, with its linear context, and Vero's opening. -/
def computation (config : Config) (model : Models.Spec) (task : String)
    (itself : String × Lean.Json := ("", .null)) : Computation Agent Lean.Json := do
  let uname ← Tools.Uname.ask
  MiniSwe.converse { config.base with model? := some model
                                      contextLimit? := MiniSwe.contextLimit? config.base model, itself }
    (openingMessages config task uname)

end Alaya.Agents.MiniVero
