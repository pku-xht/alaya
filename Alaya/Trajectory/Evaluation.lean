import Alaya.Trajectory
import Alaya.Executor.Docker
import Alaya.Grader

/-! Grading a state: a grader's verdict, recorded as an evaluation leaf. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect CallRef Question Reply)

/-! ## Evaluation -/

/-- Where a grader finds its trusted input, read-only; a workdir may not be there. -/
def graderInput : String := "/grader"

/-- Keeps a grader's output readable in `show` without putting megabytes in a state blob. -/
private def truncateOutput (s : String) : String :=
  if s.length <= 20000 then s
  else
    let elided := s.length - 20000
    String.ofList (s.toList.take 10000) ++ s!"\n… {elided} characters elided …\n" ++
      String.ofList (s.toList.drop (s.length - 10000))

/-- Empties `dir`, creating it if needed. -/
private def emptyDir (dir : System.FilePath) : Result Unit := do
  -- A grader or a checkout may have left directories that cannot be deleted from.
  Workspaces.makeWritable dir
  Result.fromIO Error.storage do
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll dir

/-- Runs `command` with `/bin/sh -c` in a fresh container and records its verdict as a leaf child
of `hash`, whose workspace is the checkout after the grader ran, reports included.

The container is from `graderImage?`, pinned, or else the trajectory's image; it runs as `user?`
and without network. A fresh checkout of the state is mounted read-write at the trajectory's
workdir, which is the working directory. `input?`, a directory of trusted files such as hidden
tests, is snapshotted, and that snapshot is mounted read-only at `/grader`, so the grader sees
exactly what is recorded. The verdict comes from the TAP the grader prints on stdout
(`Alaya.Grader`). `scratch` is a directory the trajectory may wipe. Every call runs the grader
and adds a new evaluation. -/
def evaluate (store : Store) (workspaces : Workspaces) (scratch : System.FilePath) (hash : Hash)
    (command : String) (user? : Option String) (input? : Option System.FilePath := none)
    (graderImage? : Option String := none) (timeoutSeconds : Nat := 900) : Result Hash := do
  let state ← getState store hash
  if state.kind matches .evaluation _ then
    throw <| .input "cannot evaluate an evaluation: it is already a leaf"
  let run ← runOf store hash
  let graderImage ← match graderImage? with
    | some reference => pure (← Executor.Docker.Settings.pin { image := reference }).image
    | none => pure run.image
  let inputId? ← input?.mapM fun dir => do
    if !(← Result.fromIO Error.storage dir.isDir) then
      throw <| .input s!"--input must be a directory: {dir}"
    workspaces.snapshot dir
  Result.fromIO Error.storage (IO.FS.createDirAll scratch)
  let scratch ← Result.fromIO Error.storage (IO.FS.realPath scratch)
  let checkout := scratch / "checkout"
  let input := scratch / "input"
  emptyDir checkout
  emptyDir input
  try
    workspaces.materialize state.workspace checkout
    if let some id := inputId? then workspaces.materialize id input
    let mounts := #[{ host := checkout, container := run.workdir : Executor.Docker.Mount }] ++
      (if inputId?.isSome then #[{ host := input, container := graderInput, readOnly := true }] else #[])
    let started ← Result.fromIO Error.storage IO.monoMsNow
    let captured ← Result.fromIO Error.storage <| Executor.Docker.runOnce
      { image := graderImage, user? } mounts run.workdir command timeoutSeconds
    let elapsedMs := (← Result.fromIO Error.storage IO.monoMsNow) - started
    let verdict := Grader.verdict captured.stdout captured.stopped?
    -- The evaluation keeps the checkout as the grader left it, so the tree shows what the
    -- grader did to the files, its reports included; it is the verdict's, not the run's
    -- workspace, which the evaluation leaves where its parent has it.
    putState store {
      parent? := some hash, workspace := state.workspace, appended := #[]
      kind := .evaluation {
        command, graderImage, input? := inputId?, status := verdict.status
        checks := verdict.checks, reason := verdict.reason
        returncode? := captured.exitCode?.map fun c => Int.ofNat c.toNat, elapsedMs
        stdout := truncateOutput captured.stdout, stderr := truncateOutput captured.stderr
        checkout := ← workspaces.snapshot checkout } }
  finally
    Workspaces.makeWritable scratch
    Result.fromIO Error.storage do
      if ← checkout.pathExists then IO.FS.removeDirAll checkout
      if ← input.pathExists then IO.FS.removeDirAll input

end Alaya.Trajectory
