import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! `recover_output`: a cut output names a file holding the whole of it, derived from the log
and written beside the workdir, never into it. -/

namespace OutputFilesTests

open Testing Alaya Alaya.Agent Alaya.Trajectory Alaya.Driver
open Alaya.Agent.MiniSwe

/-- 30,000 characters in 3,000 numbered lines: far past `outputLimit`, so the view keeps its
head and tail and loses the middle. -/
private def longOutput : String :=
  "\n".intercalate ((List.range 3000).map fun i => s!"line {i + 1} " ++ String.ofList (List.replicate 4 'x')) ++ "\n"

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def observed (output : String) (response : Nat) (index : Nat := 0)
    (workspace : Hash := default) : Event :=
  ran output (response := response) (index := index) (workspace := workspace)

/-- A log, after `before` events, in which bash call `c1` produced `longOutput`, at index
`before + 1`. -/
private def recordedAfter (before : Nat) (workspace : Hash := default) : Log :=
  #[.sampled default .turn (response #[bashCall "c1"]), observed longOutput before (workspace := workspace)]

private def recorded : Log := recordedAfter 0

private def config : Config := { recoverOutput := true }

private def warning (dialogue : Dialogue) (id : String) : Option String :=
  dialogue.findSome? fun
    | .tool callId (.str shown) => if callId != id then none else
      (Lean.Json.parse shown).toOption >>= fun json =>
        (json.getObjVal? "warning" >>= Lean.Json.getStr?).toOption
    | _ => none

private def testUname : Uname :=
  { system := "Linux", release := "6.1.0", version := "#1 SMP", machine := "x86_64" }

private def scripted (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| Error.protocol "scripted model exhausted" } }

private def files (dir : System.FilePath) : IO (Array String) := do
  if !(← dir.pathExists) then return #[]
  return ((← dir.readDir).map (·.fileName)).qsort (· < ·)

def suite : Suite := Testing.suite "output files" #[
  iotest "a cut output names its file by position; off, the warning is mini's" do
    match warning (view config recorded) "c1" with
    | some "[output truncated; full output: /alaya/outputs/1-c1.txt]" => pure ()
    | other => throw <| IO.userError s!"wrong notice: {other}"
    match warning (view {} recorded) "c1" with
    | some "Output too long." => pure ()
    | other => throw <| IO.userError s!"mini's warning changed: {other}",

  iotest "a file is named by its output's position, made safe" do
    if outputFile 7 "functions.bash:0/x" != "7-functions.bash_0_x.txt" then
      throw <| IO.userError s!"unsafe name: {outputFile 7 "functions.bash:0/x"}",

  test "resume writes its branch's files beside the workdir, and a fork sees only its own" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    let workspaces ← Testing.workspaces
    let project := (← scratch) / "proj"
    IO.FS.createDirAll project
    IO.FS.writeFile (project / "a.txt") "a"
    let work := (← scratch) / "work"
    IO.FS.createDirAll work
    let outputsDir := (← scratch) / "outputs"
    let executor : Executor := { exec := fun _ _ _ _ => pure { output := longOutput, exitCode? := some 0 }
                                 uname := pure default }
    -- The fork is the root's second draw, so it takes two responses and keeps the second.
    let model ← scripted #[response #[bashCall "c2"], response #[bashCall "c3"],
      response #[bashCall "x"], response #[bashCall "c4"]]
    let rt : Runtime := { store, workspaces, workDir := work, outputsDir, executor, model
                          agent := agent config }
    let root ← assertOk <| createRoot store workspaces (initialLog config "t" testUname) project
      (← testImage) (agent := testAgent) (model := testModel)
    -- The recorded command is a step after the root's opening and workspace, at positions 3 and 4.
    let recordedStep ← putStep store root
      (recordedAfter 3 (← assertOk <| getState store root).workspace)
    -- Each file is there before a command that may read it.
    let child ← stepped <| step rt recordedStep
    assertEqual "before the first command" (← files outputsDir) #["4-c1.txt"]
    let _ ← stepped <| step rt child
    assertEqual "the branch grows" (← files outputsDir) #["4-c1.txt", "6-c2.txt"]
    assertEqual "whole" (← IO.FS.readFile (outputsDir / "6-c2.txt")) longOutput
    -- A fork from the recorded step: the other branch's files are gone.
    let _ ← stepped <| step rt recordedStep
    assertEqual "a fork's files" (← files outputsDir) #["4-c1.txt"]
    -- Nothing reaches the workspace or the states.
    assertEqual "workspace untouched" (← files work) #["a.txt"]
    assertEqual "nothing recorded" (← assertOk <| getState store child).appended.size 2
]

end OutputFilesTests
