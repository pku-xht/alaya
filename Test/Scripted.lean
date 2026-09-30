import Test.Framework
import Alaya

/-! Helpers shared by tests that drive an agent with a scripted model: the model itself, builders
for the tool calls it answers with, a fixed `uname`, and string assertions. -/

namespace Scripted

open Testing
open Alaya

def contains (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length >= 2

/-- Reports the first differing character index, so a golden mismatch is diagnosable. -/
def assertStringEq (label actual expected : String) : TestM Unit := do
  if actual == expected then return ()
  let a := actual.toList
  let e := expected.toList
  let mut i := 0
  while i < a.length && i < e.length && a[i]? == e[i]? do
    i := i + 1
  fail s!"{label}: differ at char {i}\n  actual  ({actual.length}): {repr (actual.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}\n  expected({expected.length}): {repr (expected.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}"

/-- A fixed `uname`, so prompts do not depend on the machine the tests run on. -/
def testUname : Uname :=
  { system := "Linux", release := "6.1.0", version := "#1 SMP", machine := "x86_64" }

def call (id name command : String) : Chat.ToolCall :=
  { id, name, arguments := .mkObj [("command", (command : Lean.Json))] }

def submitCall (id : String) (message : String := "") : Chat.ToolCall :=
  { id, name := "submit", arguments := .mkObj [("message", (message : Lean.Json))] }

def responseWith (calls : Array Chat.ToolCall) (finish := "tool_calls") : Chat.Response :=
  { toolCalls := calls, finishReason? := some finish }

def scriptedModel (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

def workDir : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

end Scripted
