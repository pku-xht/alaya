import Test.Framework
import Test.DirectoryWorkspaces
import Alaya

/-! `read_output`: a page of an earlier command's full output, answered from the log without
running anything. -/

namespace OutputReadTests

open Testing Alaya Alaya.Agent Alaya.Trajectory
open Alaya.Agent.MiniSwe

private def str (json : Lean.Json) (key : String) : String :=
  (json.getObjVal? key >>= Lean.Json.getStr?).toOption.getD ""

private def arguments (callId : String) (offset limit : Nat) : Lean.Json :=
  .mkObj [("call_id", callId), ("offset", offset), ("limit", limit)]

/-- 30,000 characters in 3,000 numbered lines: far past `outputLimit`, so the view keeps its
head and tail and loses the middle. -/
private def longOutput : String :=
  "\n".intercalate ((List.range 3000).map fun i => s!"line {i + 1} " ++ String.ofList (List.replicate 4 'x')) ++ "\n"

private def bashCall (id : String) : Chat.ToolCall :=
  { id, name := "bash", arguments := .mkObj [("command", "make")] }

private def readCall (id callId : String) (offset limit : Nat) : Chat.ToolCall :=
  { id, name := "read_output", arguments := arguments callId offset limit }

private def response (calls : Array Chat.ToolCall) : Chat.Response :=
  { toolCalls := calls, finishReason? := some "tool_calls" }

/-- A log in which bash call `c1` produced `longOutput`. -/
private def recorded : Log :=
  #[.response (response #[bashCall "c1"]),
    .observation "c1" (Output.toJson { output := longOutput, exitCode? := some 0 })]

private def config : Config := { recoverOutput := true }

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

def suite : Suite := Testing.suite "read_output" #[
  iotest "a page is the lines asked for, and the view shows it whole" do
    let page := Tools.ReadOutput.read recorded (arguments "c1" 1500 3) outputLimit
    if str page "text" != "line 1500 xxxx\nline 1501 xxxx\nline 1502 xxxx" then
      throw <| IO.userError s!"wrong page: {page}"
    if str page "lines" != "1500-1502 of 3000" then throw <| IO.userError s!"wrong range: {page}"
    -- Shown as recorded: a page has no `output` field to be cut like a command's result.
    let log := recorded ++ #[.response (response #[readCall "r" "c1" 1500 3]), .observation "r" page]
    match (view config log).back? with
    | some (.tool "r" (.str shown)) =>
      if shown != page.pretty then throw <| IO.userError "the view changed the page"
    | _ => throw <| IO.userError "the page is not the last tool message of the view",

  iotest "a page is at most outputLimit characters, whole lines, or one line cut" do
    let page := Tools.ReadOutput.read recorded (arguments "c1" 1 3000) outputLimit
    let text := str page "text"
    if text.length > outputLimit then throw <| IO.userError "page over the limit"
    if !(text.endsWith "xxxx") then throw <| IO.userError "a line was split"
    let oneLine : Log := #[.observation "big" (Output.toJson
      { output := String.ofList (List.replicate 20000 'y'), exitCode? := some 0 })]
    let cut := Tools.ReadOutput.read oneLine (arguments "big" 1 1) outputLimit
    if (str cut "text").length != outputLimit then throw <| IO.userError "the long line was not cut"
    if !(str cut "lines").endsWith s!"the line cut to {outputLimit} characters" then
      throw <| IO.userError s!"the cut is not said: {str cut "lines"}",

  iotest "an unknown call, an offset past the end, or bad arguments are error observations" do
    for (args, expected) in [
        (arguments "nope" 1 1, "no bash call with id nope"),
        (arguments "c1" 3001 1, "past its end"),
        (arguments "c1" 0 1, "counting from 1"),
        (.mkObj [("call_id", "c1"), ("offset", 1)], "needs 'limit'")] do
      let page := Tools.ReadOutput.read recorded args outputLimit
      if ((str page "error").splitOn expected).length < 2 then
        throw <| IO.userError s!"expected an error about {expected}, got {page}",

  iotest "an id a provider reuses names the most recent output" do
    let log := recorded ++ #[.response (response #[bashCall "c1"]),
      .observation "c1" (Output.toJson { output := "later\n", exitCode? := some 0 })]
    if str (Tools.ReadOutput.read log (arguments "c1" 1 1) outputLimit) "text" != "later" then
      throw <| IO.userError "did not read the latest",

  test "the trajectory records a read without running anything or snapshotting" do
    let store ← assertOk <| Store.create ((← scratch) / "states")
    let workspaces ← Testing.workspaces
    let project := (← scratch) / "proj"
    IO.FS.createDirAll project
    IO.FS.writeFile (project / "a.txt") "a"
    let work := (← scratch) / "work"
    IO.FS.createDirAll work
    -- The executor fails if asked to run anything: a read must not reach it.
    let executor : Executor := { exec := fun _ _ _ => throw (IO.userError "ran a command"), uname := pure default }
    let model ← scripted #[response #[readCall "r" "c1" 2 2], response #[bashCall "c2"]]
    let rt : Runtime := { store, workspaces, workDir := work, executor, model
                          agent := agent executor config }
    let root ← assertOk <| createRoot store workspaces (initialLog config "t" testUname ++ recorded) project
    let child ← assertOk <| stepOnce rt "test" root
    let state ← assertOk <| getState store child
    assertEqual "same workspace" state.workspace (← assertOk <| getState store root).workspace
    match state.appended.back? with
    | some (.observation "r" page) => assertEqual "page" (str page "text") "line 2 xxxx\nline 3 xxxx"
    | _ => fail "expected the page as the last event"
    -- A fork from the child still reads the ancestor's output; nothing was copied.
    let log ← assertOk <| logOf store child
    assertEqual "ancestor readable" (str (Tools.ReadOutput.read log (arguments "c1" 3000 1) outputLimit) "lines")
      "3000-3000 of 3000"
]

end OutputReadTests
