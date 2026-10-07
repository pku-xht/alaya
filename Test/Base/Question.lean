import Test.Support.Framework
import Alaya.Base.Question

/-! Questions for a person: what may be asked, which replies answer which form, how a reply is
typed, and how a question is kept in the log. -/

namespace QuestionTests

open Testing Alaya.Base

def suite : Suite := Testing.suite "base/question" #[
  test "invalid and blank answers are refused for every form" do
    let blankCodepoints : Array Nat := #[0x0009, 0x000A, 0x000B, 0x000C, 0x000D,
      0x0020, 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
      0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    let blanks := #["", " \n\t\r", String.ofList (blankCodepoints.toList.map Char.ofNat)] ++
      blankCodepoints.map (fun n => String.ofList [Char.ofNat n])
    let choice : Question := { text := "Which?", form := .singleChoice #["first", "second", "third"] }
    for text in #["", " ", "true", "null", "{}", "\"1\"", "[]", "[1]", "1.5", "1.0", "1e0", "+1", "-1",
        "0", "4", "999999999999999999999999999", "1 trailing", "01", "\"none_of_above\"",
        "None of the above", "NONE_OF_ABOVE", " none_of_above ", "{\"status\":\"unavailable\"}"] do
      check (choice.parseReply text).toOption.isNone s!"{repr text} answers a choice"
    let open' : Question := { text := "What?" }
    for text in blanks do
      check (open'.parseReply text).toOption.isNone s!"{repr text} is no open answer"
    check (open'.parseReply (String.ofList [Char.ofNat 0x00A0] ++ " Keep it. ")).toOption.isSome
      "an answer with blank around it is kept verbatim"
    -- A candidate's number may have blank around it, as a person types it.
    assertEqual "a number typed with blank around it" (choice.parseReply " 2\n").toOption (some (.choice 2)),

  test "a question says something, and a choice offers at least two distinct candidates, none the reserved answer" do
    let valid (question : Question) := question.validate.toOption.isSome
    check (valid { text := "Go on?", form := .yesNo }) "a yes/no question"
    check (valid { text := "Which?", form := .singleChoice #["a", "b"] }) "a choice of two"
    for (label, question) in [("blank", ({ text := " \n" } : Question)),
        ("one candidate", { text := "Which?", form := .singleChoice #["a"] }),
        ("a blank candidate", { text := "Which?", form := .singleChoice #["a", " "] }),
        ("two alike once trimmed", { text := "Which?", form := .singleChoice #["a", " a "] }),
        ("the reserved answer offered", { text := "Which?", form := .singleChoice #["a", "None of the Above"] })] do
      check (!valid question) label,

  test "each form takes the replies of its kind, and every form takes that the person cannot answer" do
    let yesNo : Question := { text := "Go on?", form := .yesNo }
    let choice : Question := { text := "Which?", form := .singleChoice #["a", "b"] }
    let open' : Question := { text := "Why?" }
    let table : List (Question × Reply × Bool) := [
      (yesNo, .yes, true), (yesNo, .text "yes", false), (yesNo, .choice 1, false),
      (choice, .choice 1, true), (choice, .choice 2, true), (choice, .choice 0, false), (choice, .choice 3, false),
      (choice, .noneOfAbove, true), (choice, .yes, false),
      (open', .text "because", true), (open', .text " ", false), (open', .noneOfAbove, false),
      (yesNo, .unavailable, true), (choice, .unavailable, true), (open', .unavailable, true)]
    for (question, reply, accepted) in table do
      assertEqual s!"{question.form.name} takes {reply.line}" (question.accepts reply) accepted
    -- `none_of_above` is the reserved answer only to a choice; to an open question it is words.
    assertEqual "to a choice" (choice.parseReply "none_of_above").toOption (some .noneOfAbove)
    assertEqual "to an open question" (open'.parseReply "none_of_above").toOption (some (.text "none_of_above"))
    assertEqual "yes is exact" (yesNo.parseReply "Yes").toOption none,

  test "a question reads back from its JSON as itself, and an unknown kind is refused" do
    for question in [({ text := "Go on?", form := .yesNo } : Question), { text := "Which?", form := .singleChoice #["a", "b"] },
        { text := "Why?" }] do
      assertEqual question.text (Question.fromJson question.toJson).toOption (some question)
    let unknown := Lean.Json.mkObj [("text", "q"), ("form", .mkObj [("type", "multiple_choice")])]
    match Question.fromJson unknown with
    | .ok _ => fail "an unknown kind was read"
    | .error message => assertContains "names the kinds" message "the kinds are"
]

end QuestionTests
