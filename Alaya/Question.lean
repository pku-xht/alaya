import Lean

/-! Questions an agent asks a person, and the answers a person gives: shared by agents, the
log that records them, and whatever collects the answers. -/

namespace Alaya

/-- The form of answer a question asks for. -/
inductive Question.Form where
  | yesNo
  | openEnded
  /-- Exactly one of the candidates, or none of them. -/
  | singleChoice (options : Array String)
  deriving BEq, Repr, Inhabited

namespace Question.Form

/-- The form's name: a tool's `question_type`, and how a command's output gives it. -/
def name : Form -> String
  | .yesNo => "yes_no"
  | .openEnded => "open_ended"
  | .singleChoice _ => "single_choice"

/-- The candidates of a choice; none for the other forms. -/
def options : Form -> Array String
  | .singleChoice options => options
  | _ => #[]

end Question.Form

/-- A question: what is asked, and the form of answer it asks for. -/
structure Question where
  text : String
  form : Question.Form := .openEnded
  deriving BEq, Repr, Inhabited

/-- A person's answer to a question, or that they cannot give one. -/
inductive Reply where
  | yes
  | no
  /-- The candidate chosen, numbered from 1. -/
  | choice (number : Nat)
  /-- None of the candidates is right: an answer, unlike `unavailable`. -/
  | noneOfAbove
  /-- An answer in the person's own words, verbatim. -/
  | text (text : String)
  /-- The person cannot answer; it fits a question of any form. -/
  | unavailable
  deriving BEq, Repr, Inhabited

/-- What the asking call gives, and so what the model is shown as its result: `"yes"` or `"no"`,
the candidate's number, `"none_of_above"`, the person's text, or the object
`{"status": "unavailable"}`. The log keeps a reply by its kind instead (`Reply.toStored`), since
this form needs the question to read: the text `none_of_above` answers an open question in the
person's own words, and a choice with none of its candidates. -/
def Reply.toJson : Reply -> Lean.Json
  | .yes => "yes"
  | .no => "no"
  | .choice number => (number : Lean.Json)
  | .noneOfAbove => "none_of_above"
  | .text words => .str words
  | .unavailable => .mkObj [("status", "unavailable")]

namespace Question

/-- Whitespace as a browser's `String.trim()` has it, so that an answer page and this module
call the same answers blank. U+200B (zero-width space) is deliberately not whitespace here. -/
private def isBlank (text : String) : Bool :=
  text.toList.all fun c =>
    let n := c.toNat
    (0x0009 <= n && n <= 0x000D) || n == 0x0020 || n == 0x00A0 || n == 0x1680 ||
      (0x2000 <= n && n <= 0x200A) || n == 0x2028 || n == 0x2029 || n == 0x202F ||
      n == 0x205F || n == 0x3000 || n == 0xFEFF

/-- What a choice may not offer itself: the answer every choice has beside its candidates. -/
private def reserved (option : String) : Bool :=
  let key := option.toLower
  key == "none of the above" || key == "none_of_above"

/-- What is wrong with a question, if anything, whatever asks it: it says something, and a
choice has at least two candidates, each saying something, no two alike, and none the answer
every choice already has. Checked where a question is read from a call's arguments, at the
call and again off its opening in the log, and nowhere after. -/
def validate (question : Question) : Except String Unit := do
  if isBlank question.text then throw "A question must not be blank."
  if let .singleChoice options := question.form then
    if options.size < 2 then throw "A choice question needs at least two candidates."
    let mut seen : Array String := #[]
    for option in options do
      let key := option.trimAscii.toString
      if key.isEmpty then throw "Question choices must not be empty."
      if seen.contains key then throw "Question choices must be distinct."
      if reserved key then
        throw "Question choices must not include None of the above: every choice has it already."
      seen := seen.push key

/-- Whether a reply answers a question of this form. -/
def accepts (question : Question) : Reply -> Bool
  | .unavailable => true
  | .yes | .no => question.form == .yesNo
  | .text text => question.form == .openEnded && !isBlank text
  | .noneOfAbove => (question.form matches .singleChoice _)
  | .choice number => 1 <= number && number <= question.form.options.size

/-- The reply a person's `text` gives the question, or what is wrong with it: exactly `yes` or
`no`; a candidate's number, from 1, or `none_of_above`; or, to an open question, any text that
is not blank, kept verbatim. That the person cannot answer is not said in text
(`Reply.unavailable`). -/
def parseReply (question : Question) (text : String) : Except String Reply :=
  match question.form with
  | .yesNo =>
    if text == "yes" then pure .yes else if text == "no" then pure .no
    else throw "A yes_no answer must be exactly yes or no."
  | .openEnded =>
    if isBlank text then throw "An open_ended answer must not be blank." else pure (.text text)
  | .singleChoice options => do
    if text == "none_of_above" then return .noneOfAbove
    let digits := text.trimAscii.toString
    if digits.isEmpty || !digits.all Char.isDigit || digits.startsWith "0" then
      throw "A single_choice answer must be one candidate's number, from 1, or none_of_above."
    let number := digits.toNat!
    if number > options.size then
      throw s!"Option {number} is outside the range 1 to {options.size}."
    pure (.choice number)

def toJson (question : Question) : Lean.Json :=
  .mkObj [("text", question.text), ("form", .mkObj (("type", question.form.name) ::
    match question.form with
    | .singleChoice options => [("options", .arr (options.map Lean.Json.str))]
    | _ => []))]

/-- The question as a terminal or a plain report shows it, with how to answer it there. A
graphical collector lays out `text` and the form itself. -/
def render (question : Question) : String :=
  match question.form with
  | .yesNo => question.text ++ "\n\nReply yes or no."
  | .openEnded => question.text ++ "\n\nReply in your own words."
  | .singleChoice options =>
    let numbered := options.mapIdx fun i option => s!"{i + 1}. {option}"
    question.text ++ "\n\n" ++ "\n".intercalate numbered.toList ++
      "\nnone_of_above. None of the above\n\nSelect exactly one answer. Reply with one " ++
      "number from 1 to " ++ toString options.size ++
      ", or the plain text none_of_above if every listed candidate is incorrect. " ++
      "none_of_above is an answer, distinct from being unable to answer."

instance : ToString Question := ⟨render⟩

end Question

end Alaya
