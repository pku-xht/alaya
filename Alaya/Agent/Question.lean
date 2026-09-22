import Lean

/-! Structured questions shared by agents, persisted trajectories, and answer collectors. -/

namespace Alaya.Agent

inductive QuestionType where
  | yesNo
  | multipleChoice
  | openEnded
  deriving BEq, Repr, Inhabited

def QuestionType.toString : QuestionType -> String
  | .yesNo => "yes_no"
  | .multipleChoice => "multiple_choice"
  | .openEnded => "open_ended"

def QuestionType.fromString : String -> Except String QuestionType
  | "yes_no" => .ok .yesNo
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

/-- Checks the answer form, without judging the question or its candidates. -/
def validate (question : Question) : Except String Unit := do
  match question.questionType with
  | .yesNo | .openEnded =>
    if !question.options.isEmpty then
      throw "Question options must be empty for yes_no and open_ended questions."
  | .multipleChoice =>
    if question.options.size < 2 then throw "A multiple-choice question needs at least two choices."
    let mut seen : Array String := #[]
    for option in question.options do
      let key := option.trimAscii.toString
      if key.isEmpty then throw "Question choices must not be empty."
      if seen.contains key then throw "Question choices must be distinct."
      seen := seen.push key

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
  | .multipleChoice =>
    let numbered := question.options.mapIdx fun i option => s!"{i + 1}. {option}"
    question.text ++ "\n\n" ++ "\n".intercalate numbered.toList ++
      "\n\nSelect zero or more options, up to all of them. Reply with a JSON array of " ++
      "distinct option numbers, such as [1, 2]. Reply [] if none of the options apply."

instance : ToString Question := ⟨render⟩

/-- Validates before a reply is recorded. Successful answers retain their exact original
text, including whitespace; open-ended answers impose no format restriction. -/
def validateReply (question : Question) (text : String) : Except String Unit := do
  question.validate
  match question.questionType with
  | .openEnded => pure ()
  | .yesNo =>
    if text != "yes" && text != "no" then throw "A yes_no answer must be exactly yes or no."
  | .multipleChoice =>
    let json ← (Lean.Json.parse text).mapError
      fun _ => "A multiple_choice answer must be a JSON array of option numbers."
    let choices ← json.getArr?.mapError
      fun _ => "A multiple_choice answer must be a JSON array of option numbers."
    let mut seen : Array Nat := #[]
    for choice in choices do
      let number ← choice.getNat?.mapError
        fun _ => "Every selected option must be an integer numbered from 1."
      if number == 0 || number > question.options.size then
        throw s!"Option {number} is outside the range 1 to {question.options.size}."
      if seen.contains number then throw s!"Option {number} was selected more than once."
      seen := seen.push number

end Question

end Alaya.Agent
