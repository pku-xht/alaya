import Alaya.Agent
import Alaya.Executor
import Alaya.Sha256

/-! Recoverable character pages over the full executor output already in recorded events.
The digest identifies text in the current log, not a host path or a separate storage object. -/

namespace Alaya.Agent.OutputRead

/-- Maximum characters in one page, independent of newline placement or UTF-8 byte width. -/
def pageLimit : Nat := 10000

/-- Content identity of a recorded output. Its bytes remain inside the recorded state event. -/
def reference (text : String) : String := "sha256:" ++ Sha256.sumHex text.toUTF8

/-- The default tool policy shared by opening prompts, repair guidance, and this tool. -/
def usageGuidance : String :=
  "Use bash by default for workspace inspection, edits, and command execution. " ++
  "Use read_output only when omitted text from a recorded output is needed for your next decision. " ++
  "read_output may be the only tool call in that response. " ++
  "Read only what you need; you do not have to reach EOF."

def tool : Chat.ToolDefinition := {
  name := "read_output"
  description := "Read a character page of a full recorded tool output by its output_ref. " ++
    "Works across resumed and forked runs. Offsets count Unicode characters, not bytes or lines. " ++
    usageGuidance
  parameters := .object #[
    ("ref", .string (description? := some "The exact output_ref from a truncated result")),
    ("offset", .integer (description? := some "Zero-based character offset, inclusive")),
    ("limit", .integer (description? := some "Number of characters to read, from 1 to 10000"))]
}

structure Request where
  ref : String
  offset : Nat
  limit : Nat

def parse (arguments : Lean.Json) : Except String Request := do
  let ref ← (arguments.getObjVal? "ref" >>= Lean.Json.getStr?).mapError
    (fun _ => "read_output requires a string 'ref'.")
  let offset ← (arguments.getObjVal? "offset" >>= Lean.Json.getNat?).mapError
    (fun _ => "read_output requires a nonnegative integer 'offset'.")
  let limit ← (arguments.getObjVal? "limit" >>= Lean.Json.getNat?).mapError
    (fun _ => "read_output requires an integer 'limit' from 1 to 10000.")
  if limit == 0 || limit > pageLimit then
    throw "read_output requires an integer 'limit' from 1 to 10000."
  pure { ref, offset, limit }

private def error (message : String) : Lean.Json := .mkObj [("error", message)]

/-- Looks only in this trajectory's observations, never in an unrelated workspace or grading
checkout. Pages deliberately use `content`, not executor `output`, so views keep them intact. -/
def read (log : Log) (arguments : Lean.Json) : Lean.Json := Id.run do
  let request ← match parse arguments with
    | .ok request => pure request
    | .error message => return error message
  for event in log.reverse do
    if let .observation _ json := event then
      if let some output := Output.fromJson? json then
        if reference output.output == request.ref then
          let total := output.output.length
          if request.offset > total then
            return error s!"read_output offset {request.offset} exceeds output length {total}."
          let content := String.ofList (output.output.toList.drop request.offset |>.take request.limit)
          let ending := request.offset + content.length
          return .mkObj [
            ("output_ref", request.ref), ("content", content),
            ("offset", request.offset), ("end_offset", ending), ("total_chars", total),
            ("next_offset", if ending < total then (ending : Lean.Json) else .null),
            ("eof", ending == total)]
  return error "Full output unavailable: this reference does not identify a raw output in the current trajectory log. No content was recovered."

end Alaya.Agent.OutputRead
