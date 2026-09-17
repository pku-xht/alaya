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

def taskMessage (task : String) (uname : Uname) : String :=
  "Solve this Vero task:\n\n" ++ task ++
  "\n\nThe task contract above names every editable file and every required check. Inspect the " ++
  "relevant Lean declarations before editing. An editable marker pair is an existing line " ++
  "`-- !benchmark @start <key> ...` followed by its matching existing line " ++
  "`-- !benchmark @end <key> ...`. Replace only the text strictly between those two lines. " ++
  "Do not add, remove, move, or alter either marker line, and do not edit text outside the " ++
  "listed marker interiors.\n" ++
  "Use the proof or codeproof alternatives permitted by the task contract. Do not introduce " ++
  "sorry, admit, axioms, unsafe code, Classical.arbitrary, trivializing instances, or " ++
  "@[implemented_by]. A graded theorem may depend only on Classical.choice, propext, Quot.sound, " ++
  "and any additional trusted axioms explicitly listed in the task contract; sorryAx and any " ++
  "other axiom dependency fail grading. Use only imports and libraries available in this " ++
  "rendered project.\n" ++
  "Before submission, run every `lake lean` command listed in the task contract and then run " ++
  "`lake build`. Call submit only after every required marker is filled with a permitted body, " ++
  "all listed proof checks and lake build succeed, and the completion conditions in the task " ++
  "contract hold. Compilation is necessary but Vero independently checks every obligation and " ++
  "axiom dependency in a fresh project.\n" ++
  "Use repository-relative paths. Shell directory and environment changes do not persist across " ++
  "tool calls. When the completion conditions hold, call the submit tool once with a short " ++
  "summary.\n\nEnvironment: " ++
  uname.system ++ " " ++ uname.release ++ " " ++ uname.version ++ " " ++ uname.machine

def initialLog (config : Config) (uname : Uname) : Log :=
  #[.message (.system systemMessage), .message (.user (taskMessage config.task uname))]

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
      ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json))]
    view := view
  }

end Alaya.Agent.MiniVero
