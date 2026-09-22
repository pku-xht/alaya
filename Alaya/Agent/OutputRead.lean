import Alaya.Agent
import Alaya.Executor

/-! Reading back the whole of a command's output. The model is shown the head and the tail of
a long output; the full text is in the recorded observation, and `read_output` shows any of
its lines. It is answered from the log — the observation of the call the model names — so it
runs nothing and takes no snapshot (`Directive.observe`). -/

namespace Alaya.Agent.OutputRead

open Alaya (Output)

def tool : Chat.ToolDefinition := {
  name := "read_output"
  description := "Show lines of the full output of an earlier bash call, when it was too long " ++
    "and only its beginning and end were shown. Name the call by its id."
  parameters := .object #[
    ("call_id", .string (description? := some "The id of the bash call")),
    ("offset", .integer (description? := some "The first line to show, counting from 1")),
    ("limit", .integer (description? := some "How many lines to show"))]
}

structure Request where
  callId : String
  offset : Nat
  limit : Nat

/-- Reads the arguments; the message says what is wrong with them. -/
def parse (arguments : Lean.Json) : Except String Request := do
  let callId ← (arguments.getObjVal? "call_id" >>= Lean.Json.getStr?).mapError
    fun _ => "read_output needs 'call_id', the id of a bash call."
  let offset ← (arguments.getObjVal? "offset" >>= Lean.Json.getNat?).mapError
    fun _ => "read_output needs 'offset', a line number counting from 1."
  let limit ← (arguments.getObjVal? "limit" >>= Lean.Json.getNat?).mapError
    fun _ => "read_output needs 'limit', a number of lines."
  if offset == 0 then throw "read_output needs 'offset', a line number counting from 1."
  if limit == 0 then throw "read_output needs 'limit', a number of lines, at least 1."
  pure { callId, offset, limit }

/-- The full output the log recorded for the bash call `callId`: the most recent observation
with that id whose content is a command's output, so an id a provider reuses across turns
names the latest. -/
def outputOf? (log : Log) (callId : String) : Option Output :=
  log.reverse.findSome? fun
    | .observation id content => if id == callId then Output.fromJson? content else none
    | _ => none

private def lines (text : String) : Array String :=
  let all := (text.splitOn "\n").toArray
  -- A trailing newline ends the last line rather than starting an empty one.
  if text.endsWith "\n" then all.pop else all

/-- The page: lines `offset` onward, at most `limit` of them and at most `maxChars` characters,
as `text`, with `lines` saying which of how many they are. The field is not `output`, which
would make the page look like a command's result to the view, and be cut down again. -/
def page (output : Output) (request : Request) (maxChars : Nat) : Lean.Json :=
  let all := lines output.output
  let total := all.size
  if request.offset > total then
    .mkObj [("error", s!"the output has {total} lines; offset {request.offset} is past its end")]
  else
    let wanted := all.extract (request.offset - 1) (request.offset - 1 + request.limit)
    -- Whole lines while they fit; the first line always, cut to the limit if it alone is over.
    let (taken, _) := wanted.foldl (init := (#[], 0)) fun (taken, shown) line =>
      if taken.isEmpty then (#[(line.take maxChars).toString], min line.length maxChars)
      else if shown + 1 + line.length <= maxChars then (taken.push line, shown + 1 + line.length)
      else (taken, maxChars)
    let last := request.offset - 1 + taken.size
    let cut := taken.size == 1 && wanted[0]!.length > maxChars
    .mkObj [
      ("text", "\n".intercalate taken.toList),
      ("lines", s!"{request.offset}-{last} of {total}" ++ (if cut then s!", the line cut to {maxChars} characters" else ""))]

/-- What `read_output` observes: the page, or why there is none. -/
def read (log : Log) (arguments : Lean.Json) (maxChars : Nat) : Lean.Json :=
  match parse arguments with
  | .error message => .mkObj [("error", message)]
  | .ok request =>
    match outputOf? log request.callId with
    | some output => page output request maxChars
    | none => .mkObj [("error", s!"no bash call with id {request.callId} in this run")]

end Alaya.Agent.OutputRead
