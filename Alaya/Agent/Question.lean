import Lean

/-! Structured questions shared by agents, persisted trajectories, and answer collectors. -/

namespace Alaya.Agent

inductive QuestionType where
  | yesNo
  | singleChoice
  /-- Retired: retained only to read and display existing trajectories. -/
  | multipleChoice
  | openEnded
  deriving BEq, Repr, Inhabited

def QuestionType.toString : QuestionType -> String
  | .yesNo => "yes_no"
  | .singleChoice => "single_choice"
  | .multipleChoice => "multiple_choice"
  | .openEnded => "open_ended"

def QuestionType.fromString : String -> Except String QuestionType
  | "yes_no" => .ok .yesNo
  | "single_choice" => .ok .singleChoice
  | "multiple_choice" => .ok .multipleChoice
  | "open_ended" => .ok .openEnded
  | other => .error s!"Unknown question_type: {other}."

/-- The original question and its answer form. Presentation keeps the options separate from
the question text. A generic question without an answer form is open-ended. -/
structure Question where
  text : String
  questionType : QuestionType := .openEnded
  options : Array String := #[]
  deriving BEq, Repr, Inhabited

namespace Question

/-- Match JavaScript `String.trim()` so browser and core reject the same blank
open answer. U+200B (zero-width space) is deliberately not whitespace here. -/
private def isReplyWhitespace (c : Char) : Bool :=
  let n := c.toNat
  (0x0009 <= n && n <= 0x000D) || n == 0x0020 || n == 0x00A0 || n == 0x1680 ||
    (0x2000 <= n && n <= 0x200A) || n == 0x2028 || n == 0x2029 || n == 0x202F ||
    n == 0x205F || n == 0x3000 || n == 0xFEFF

/-- Checks the answer form, without judging the question or its candidates. -/
def validate (question : Question) : Except String Unit := do
  match question.questionType with
  | .yesNo | .openEnded =>
    if !question.options.isEmpty then
      throw "Question options must be empty for yes_no and open_ended questions."
  | .singleChoice | .multipleChoice =>
    if question.options.size < 2 then throw "A choice question needs at least two candidates."
    let mut seen : Array String := #[]
    for option in question.options do
      let key := option.trimAscii.toString
      if key.isEmpty then throw "Question choices must not be empty."
      if seen.contains key then throw "Question choices must be distinct."
      seen := seen.push key

/-- Retired question forms remain readable, but cannot accept new answers, even
an unavailable response. No old answer or record is reinterpreted. -/
def validateAnswerable (question : Question) : Except String Unit := do
  question.validate
  if question.questionType == .multipleChoice then
    throw "The multiple_choice format is retired and read-only; start a new run to answer."

def toJson (question : Question) : Lean.Json :=
  .mkObj [("text", question.text), ("question_type", question.questionType.toString),
    ("options", .arr (question.options.map Lean.Json.str))]

/-- Only an old record lacking both form fields defaults to open-ended. Explicit malformed
metadata is rejected instead of silently disabling answer validation. -/
def fromJson (json : Lean.Json) : Except String Question := do
  let text ← json.getObjVal? "text" >>= Lean.Json.getStr?
  let question ← match json.getObjVal? "question_type", json.getObjVal? "options" with
    | .error _, .error _ => pure ({ text } : Question)
    | .ok kind, .ok choices => do
      let questionType ← kind.getStr? >>= QuestionType.fromString
      let options ← choices.getArr? >>= (·.mapM Lean.Json.getStr?)
      pure { text, questionType, options }
    | _, _ => throw "A structured question requires both question_type and options."
  question.validate
  pure question

/-- Text presentation for terminals and plain reports. Graphical collectors use the clean
`text`, `questionType`, and `options` fields instead. -/
def render (question : Question) : String :=
  match question.questionType with
  | .yesNo => question.text ++ "\n\nReply yes or no."
  | .openEnded => question.text ++ "\n\nReply in your own words."
  | .singleChoice =>
    let numbered := question.options.mapIdx fun i option => s!"{i + 1}. {option}"
    question.text ++ "\n\n" ++ "\n".intercalate numbered.toList ++
      "\nnone_of_above. None of the above\n\nSelect exactly one answer. Reply with one " ++
      "JSON integer from 1 to " ++ toString question.options.size ++
      ", or the plain text none_of_above if every listed candidate is incorrect. " ++
      "none_of_above is an answer, distinct from being unable to answer."
  | .multipleChoice =>
    let numbered := question.options.mapIdx fun i option => s!"{i + 1}. {option}"
    question.text ++ "\n\n" ++ "\n".intercalate numbered.toList ++
      "\n\nHistorical multiple-choice answers selected zero or more option numbers; [] meant " ++
      "none applied. This retired format is read-only; start a new run to answer."

instance : ToString Question := ⟨render⟩

/-- Validates before a reply is recorded. Successful answers retain their exact original
text, including whitespace; open-ended answers must contain non-whitespace text. -/
def validateReply (question : Question) (text : String) : Except String Unit := do
  question.validateAnswerable
  match question.questionType with
  | .openEnded =>
    if text.toList.all isReplyWhitespace then throw "An open_ended answer must not be blank."
  | .yesNo =>
    if text != "yes" && text != "no" then throw "A yes_no answer must be exactly yes or no."
  | .singleChoice =>
    if text == "none_of_above" then return
    let isJsonWhitespace := fun c => c == ' ' || c == '\t' || c == '\n' || c == '\r'
    let token := (text.toList.dropWhile isJsonWhitespace).reverse.dropWhile isJsonWhitespace
    let token := token.reverse
    match token with
    | first :: rest =>
      if first < '1' || first > '9' || !(rest.all fun c => '0' <= c && c <= '9') then
        throw "The selected option must be one JSON integer numbered from 1."
    | [] => throw "A single_choice answer must be one JSON integer or the plain text none_of_above."
    let json ← (Lean.Json.parse text).mapError
      fun _ => "A single_choice answer must be one JSON integer or the plain text none_of_above."
    let number ← json.getNat?.mapError
      fun _ => "The selected option must be one integer numbered from 1."
    if number == 0 || number > question.options.size then
      throw s!"Option {number} is outside the range 1 to {question.options.size}."
  | .multipleChoice =>
    throw "The multiple_choice format is retired and read-only; start a new run to answer."

end Question

end Alaya.Agent
