import Test.Framework
import Test.DirectoryWorkspaces
import Test.Container
import Alaya

/-! `recover_output`: a cut output names a file holding the whole of it, derived from the log
and written beside the workdir, never into it. -/

namespace OutputFilesTests

open Testing Alaya Alaya.Agent Alaya.Trajectory
open Alaya.Agent.MiniSwe

/-- 30,000 characters in 3,000 numbered lines: far past `outputLimit`, so the view keeps its
head and tail and loses the middle. -/
private def longOutput : String :=
  "\n".intercalate ((List.range 3000).map fun i => s!"line {i + 1} " ++ String.ofList (List.replicate 4 'x')) ++ "\n"

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

private def observed (id output : String) : Event :=
  .observation id (Output.toJson { output, exitCode? := some 0 })

/-- A log in which bash call `c1` produced `longOutput`, at index 1. -/
private def recorded : Log := #[.response (response #[bashCall "c1"]), observed "c1" longOutput]

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

  iotest "the files are the cut outputs, whole, one per position" do
    -- A provider may reuse an id; the position keeps the files apart.
    let log := recorded ++ #[.response (response #[bashCall "c1", bashCall "c/2"]),
      observed "c1" (longOutput ++ "again"), observed "c/2" "short"]
    let outputs := outputs config log
    if outputs != #[("1-c1.txt", longOutput), ("3-c1.txt", longOutput ++ "again")] then
      throw <| IO.userError s!"wrong files: {outputs.map (·.1)}"
    if !(MiniSwe.outputs {} log).isEmpty then throw <| IO.userError "files with recovery off"
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
    let executor : Executor := { exec := fun _ _ _ => pure { output := longOutput, exitCode? := some 0 }
                                 uname := pure default }
    -- The fork is the root's second draw, so it takes two responses and keeps the second.
    let model ← scripted #[response #[bashCall "c2"], response #[bashCall "c3"],
      response #[bashCall "x"], response #[bashCall "c4"]]
    let rt : Runtime := { store, workspaces, workDir := work, outputsDir, executor, model
                          agent := agent config }
    let root ← assertOk <| createRoot store workspaces (initialLog config "t" testUname ++ recorded) project
      (← testImage) (agent := testAgent) (model := testModel)
    -- The root's own cut output is there before the first turn; the turn's own after it runs.
    let child ← stepped <| step rt root
    assertEqual "after a turn" (← files outputsDir) #["3-c1.txt", "5-c2.txt"]
    assertEqual "whole" (← IO.FS.readFile (outputsDir / "5-c2.txt")) longOutput
    let _ ← stepped <| step rt child
    assertEqual "the branch grows" (← files outputsDir) #["3-c1.txt", "5-c2.txt", "7-c3.txt"]
    -- A fork from the root: the other branch's files are gone.
    let _ ← stepped <| step rt root
    assertEqual "a fork's files" (← files outputsDir) #["3-c1.txt", "5-c4.txt"]
    -- Nothing reaches the workspace or the states.
    assertEqual "workspace untouched" (← files work) #["a.txt"]
    assertEqual "nothing recorded" (← assertOk <| getState store child).appended.size 2
]

end OutputFilesTests
