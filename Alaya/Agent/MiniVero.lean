import Alaya.Agent.MiniSwe

/-! A minimal MiniSwe specialization for Vero. Rendering and grading are external;
the trajectory machinery, model providers and executor are shared with MiniSwe. -/
namespace Alaya.Agent.MiniVero

open Alaya (Executor Uname)
open Alaya.Agent (Agent Log)

abbrev Config := MiniSwe.Config

def defaultConfig : Config := {
  task := ""
  stepLimit := 200
  executor := { MiniSwe.defaultExecutor with timeoutSeconds := 600 }
}

def systemMessage : String :=
  "You are MiniVero, a Lean 4 implementation and proof agent working in a Vero sandbox. " ++
  "Work on the task using the provided bash tool and finish with the submit tool; " ++
  "Vero's independent grader decides correctness."

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
  "\n\n".intercalate [
    framing,
    "Solve this Vero task:\n\n" ++ task,
    rules,
    grading mode,
    doneCondition,
    antiCheating,
    scoring,
    mechanics,
    "Environment: " ++
      uname.system ++ " " ++ uname.release ++ " " ++ uname.version ++ " " ++ uname.machine]

/-- MiniVero's own mechanics paragraph names the bash tool; with `read_output` offered, it
says so too. -/
def withRecovery (recover : Bool) (text : String) : String :=
  if !recover then text else
    text.replace "Use repository-relative paths."
      "When a command's output was too long and only its beginning and end were shown, read_output shows any lines of the whole of it. Use repository-relative paths."

def initialLog (config : Config) (mode : Mode) (uname : Uname) : Log :=
  #[.message (.system systemMessage),
    .message (.user (withRecovery config.recoverOutput (taskMessage config.task mode uname)))]

/-- MiniVero currently uses MiniSwe's linear model context. Experimental context
management must be evaluated separately before changing the baseline. -/
abbrev view := MiniSwe.view

abbrev tools := MiniSwe.tools

def agent (executor : Executor) (config : Config := defaultConfig) : Agent :=
  { MiniSwe.agent executor config with
    identity := .mkObj [
      ("agent", "mini-vero"), ("version", "1"),
      ("step_limit", (config.stepLimit : Lean.Json)),
      ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json)),
      ("recover_output", (config.recoverOutput : Lean.Json))]
  }

end Alaya.Agent.MiniVero
