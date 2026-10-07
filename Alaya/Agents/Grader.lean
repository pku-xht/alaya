import Alaya.Runtime.Agent
import Alaya.Agents.Verdict
import Alaya.Base.ConfigJson

/-! The grader: a routine that runs one command, in its call's container, and returns the verdict
read off the TAP the command prints on stdout (`Alaya.Agents.Verdict`, under `Alaya.Agents.Grader`). Its trusted input — the tests, a
reference — is in its image, so a call needs nothing besides the image and the command. What
the command writes lands in the workspace, after the agent's last version: the agent is over by
then, and nothing reads it but a person. See `docs/agents.md` §6. -/

namespace Alaya.Agents.Grader

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

structure Config where
  /-- The command, which prints TAP on stdout; what it prints on stderr is kept apart. -/
  command : String := ""
  /-- How long it may take, in seconds; 0 is no limit. -/
  timeoutSeconds : Nat := 900
  deriving Inhabited

def Config.toJson (config : Config) : Json :=
  .mkObj [("command", config.command), ("timeout_seconds", config.timeoutSeconds)]

/-- Reads a configuration; a field left out is the default, and an unknown one is an error. -/
def Config.fromJson (json : Json) : Except String Config := do
  let object ← ConfigJson.object json #["command", "timeout_seconds"]
  pure { command := ← object.string "command" "", timeoutSeconds := ← object.nat "timeout_seconds" 900 }

/-- The verdict as the grader returns it: the status, the score, why, every check, and how the
command ended. -/
def verdictJson (verdict : Grader.Verdict) (output : Output) : Json :=
  let (passed, total) := Grader.Verdict.score verdict.checks
  .mkObj [("status", verdict.status.toString), ("passed", passed), ("total", total),
    ("reason", verdict.reason),
    ("checks", .arr (verdict.checks.map fun check =>
      .mkObj [("ok", check.ok), ("name", check.name), ("directive", check.directive)])),
    ("exit_code", output.exitCode?.map (fun c => (c.toNat : Json)) |>.getD .null)]

/-- The status of a verdict: `pass`, `fail` or `error`. -/
def verdictStatus (verdict : Json) : String :=
  (verdict.getObjVal? "status" >>= Json.getStr?).toOption.getD "error"

/-- The grader: its command, and the verdict on what it printed. -/
def computation (config : Config) : Computation Agent Json := do
  let ran ← exec config.command { timeoutSeconds := config.timeoutSeconds, merge := false }
  return verdictJson (Grader.verdict ran.output.output ran.output.failure?) ran.output

/-- The grader as a routine. A call's arguments are its configuration; one with no command fails
in the call's frame. -/
def routine : Routine Agent where
  name := "grader"
  body arguments := match Config.fromJson arguments with
    | .error problem => .fail s!"grader: {problem}"
    | .ok config =>
      if config.command.trimAscii.isEmpty then
        .fail "grader: it needs its command, which prints TAP, and its configuration names none"
      else computation config
  scope := .empty

end Alaya.Agents.Grader
