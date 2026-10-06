import Test.Framework
import Alaya.Base.Tap
import Lean.Data.Json

/-! The TAP 14 parser, on two kinds of evidence: every example in the TAP 14 specification, with the
result the specification states for it, and tap-parser's fixtures (`Test/Tap/fixtures`), with
tap-parser's own results (`Test/Tap/expected.json`, printed by `Test/Tap/oracle.js`) as the
oracle. -/

namespace TapTests

open Testing
open Alaya.Base.Tap

/-- A stream of `lines`, each ended by a line break. -/
private def doc (lines : List String) : Document := parse (String.join (lines.map (· ++ "\n")))

private def point (document : Document) (index : Nat) : TestM Point := do
  let some p := document.points[index]? | fail s!"no test point {index}"
  pure p

private def subtest (p : Point) : TestM Document := do
  let some d := p.subtest? | fail s!"test point {p.id} closes no subtest"
  pure d

private def assertOk (label : String) (document : Document) (expected : Bool) : TestM Unit :=
  assertEqual s!"{label}: ok (errors {document.errors})" document.ok expected

/-! ## The specification's examples -/

def specSuite : Suite := Testing.suite "tap/spec" #[
  test "the introductory example: YAML diagnostics and a TODO" do
    let d := doc ["TAP version 14", "1..4", "ok 1 - Input file opened",
      "not ok 2 - First line of the input valid", "  ---", "  message: 'First line invalid'",
      "  severity: fail", "  data:", "    got: 'Flirble'", "    expect: 'Fnible'", "  ...",
      "ok 3 - Read the rest of the file", "not ok 4 - Summarized correctly # TODO Not written yet",
      "  ---", "  message: \"Can't make summary yet\"", "  severity: todo", "  ..."]
    assertOk "document" d false
    assertEqual "version" d.version? (some 14)
    assertEqual "plan" d.plan? (some { first := 1, last := 4 })
    assertEqual "count" d.points.size 4
    let second ← point d 1
    assertEqual "description" second.description "First line of the input valid"
    assertEqual "diagnostic" second.diagnostic? (some <| "\n".intercalate
      ["message: 'First line invalid'", "severity: fail", "data:", "  got: 'Flirble'",
       "  expect: 'Fnible'"])
    assertEqual "failed" second.failed true
    let fourth ← point d 3
    assertEqual "todo" fourth.directive (.todo "Not written yet")
    assertEqual "a failing TODO is not a failure" fourth.failed false,

  test "TAP version 13 is accepted as a version line" do
    assertEqual "version" (doc ["TAP version 13", "1..1", "ok"]).version? (some 13),

  test "a version after the first line is not TAP" do
    let d := doc ["1..1", "TAP version 14", "ok"]
    assertEqual "version" d.version? none
    assertOk "document" d true,

  test "a stream lacking a plan is a failed test" do
    assertOk "points, no plan" (doc ["ok 1", "ok 2"]) false
    assertOk "empty stream" (parse "") false
    assertOk "only noise" (doc ["one", "three"]) false,

  test "1..0 skips the whole test set, with its comment as the reason" do
    let d := doc ["TAP version 14", "1..0 # skip because English-to-French translator isn't installed"]
    assertOk "document" d true
    let some plan := d.plan? | fail "no plan"
    assertEqual "skips all" plan.skipsAll true
    assertEqual "reason" plan.reason "skip because English-to-French translator isn't installed"
    assertOk "1..0 with test points" (doc ["ok 1", "1..0"]) false,

  test "the plan may come first or last, and its comment is unescaped" do
    assertOk "first" (doc ["1..2", "ok 1", "ok 2"]) true
    assertOk "last" (doc ["ok 1", "ok 2", "1..2"]) true
    assertEqual "reason" ((doc ["1..1 # a \\# and a \\\\", "ok"]).plan?.map (·.reason))
      (some "a # and a \\"),

  test "a second plan is not TAP" do
    let d := doc ["1..2", "ok 1", "ok 2", "1..3"]
    assertEqual "plan" d.plan? (some { first := 1, last := 2 })
    assertOk "document" d true,

  test "test points without IDs are numbered by the harness" do
    let d := doc ["1..5", "not ok", "ok", "not ok", "ok", "ok"]
    assertEqual "ids" (d.points.map (·.id)) #[1, 2, 3, 4, 5]
    assertEqual "numbered" (d.points.map (·.numbered)) #[false, false, false, false, false]
    assertEqual "failed" (d.points.map (·.failed)) #[true, false, true, false, false]
    assertOk "document" d false,

  test "fewer test points than planned is not a successful run" do
    assertOk "1..6 with five" (doc ["TAP version 14", "1..6", "not ok", "ok", "not ok", "ok", "ok"]) false
    assertOk "one point short of 1..2" (doc ["1..2", "ok"]) false,

  test "test points may come in any order, but IDs must be within the plan" do
    assertOk "in range" (doc ["TAP version 14", "1..3", "ok 2", "ok 3", "ok 1"]) true
    assertOk "4 outside 1..3" (doc ["TAP version 14", "1..3", "ok 2", "ok 4", "ok 1"]) false
    assertOk "outside a trailing plan" (doc ["ok 2", "ok 4", "ok 1", "1..3"]) false,

  test "a repeated ID is still a test point, and fails the run" do
    let d := doc ["1..2", "ok 1", "ok 1"]
    assertEqual "count" d.points.size 2
    assertOk "document" d false,

  test "the \" - \" before a description is optional and not part of it" do
    let d := doc ["1..2", "ok 1 this is fine", "ok 2 - this is fine"]
    assertEqual "descriptions" (d.points.map (·.description)) #["this is fine", "this is fine"]
    assertEqual "a number after \" - \" is description"
      ((doc ["1..1", "ok 1 - 2 apples"]).points.map (·.description)) #["2 apples"],

  test "ok and not ok are case-sensitive" do
    let d := doc ["1..1", "OK 1", "Not ok 1", "ok 1"]
    assertEqual "count" d.points.size 1,

  test "a directive delimiter is an unescaped # preceded by whitespace" do
    let d := doc ["TAP version 14", "ok 1 - must be skipped test # SKIP",
      "ok 2 - must not be skipped test \\# SKIP", "ok 3 - may skip, but should warn# skip",
      "ok 4 - may skip, but should warn #skip", "ok 5 - may skip, but should warn#skip", "1..5"]
    assertEqual "directives" (d.points.map (·.directive))
      #[.skip "", .none, .none, .skip "", .none]
    assertEqual "descriptions" (d.points.map (·.description))
      #["must be skipped test", "must not be skipped test # SKIP",
        "may skip, but should warn# skip", "may skip, but should warn",
        "may skip, but should warn#skip"],

  test "TODO and SKIP may be followed by more characters; the reason follows a space" do
    let d := doc ["TAP version 14", "1..2", "ok 1 - do it later # Skipped",
      "ok 2 - works on windows # Skipped: only run on windows"]
    assertEqual "directives" (d.points.map (·.directive))
      #[.skip "", .skip "only run on windows"]
    assertEqual "descriptions" (d.points.map (·.description)) #["do it later", "works on windows"],

  test "more directive examples: an empty description, a URL, and letter case" do
    let d := doc ["TAP version 14", "ok 1 # skip this test is skipped",
      "ok 2 not skipped: https://example.com/page.html#skip is a url",
      "ok 3 - #SkIp case insensitive, so this is skipped", "1..3"]
    assertEqual "directives" (d.points.map (·.directive))
      #[.skip "this test is skipped", .none, .skip "case insensitive, so this is skipped"]
    assertEqual "descriptions" (d.points.map (·.description))
      #["", "not skipped: https://example.com/page.html#skip is a url", ""],

  test "an unrecognized directive stays in the description" do
    let d := doc ["1..1", "ok 1 - hello # description # todo"]
    assertEqual "directive" (d.points.map (·.directive)) #[.none]
    assertEqual "description" (d.points.map (·.description)) #["hello # description # todo"],

  test "failing TODO and SKIP test points are not failures" do
    let todo := doc ["1..1", "not ok 1 # TODO bend space and time"]
    assertOk "TODO in range" todo true
    assertEqual "todo" (todo.points.map (·.directive)) #[.todo "bend space and time"]
    assertOk "SKIP" (doc ["1..1", "not ok 1 - mung the gums # SKIP leave gums unmunged for now"]) true,

  test "a YAML block follows its test point, with blank lines kept" do
    let d := doc ["1..1", "not ok 1 - Resolve address", "  ---",
      "  message: \"Failed with error 'hostname peebles.example.com not found'\"", "",
      "  at:", "    line: 142", "  ..."]
    let p ← point d 0
    assertEqual "diagnostic" p.diagnostic? (some <| "\n".intercalate
      ["message: \"Failed with error 'hostname peebles.example.com not found'\"", "", "at:",
       "  line: 142"])
    assertOk "document" d false,

  test "an unterminated YAML block is not a diagnostic" do
    let d := doc ["1..1", "ok 1", "  ---", "  message: never closed"]
    assertEqual "diagnostic" (d.points.map (·.diagnostic?)) #[none]
    assertOk "document" d true,

  test "comments never fail a test" do
    assertOk "comments" (doc ["TAP version 14", "1..6", "#", "# Create a new Board and Tile, then place",
      "# the Tile onto the board.", "#", "ok 1 - The object isa Board", "ok 2 - Board size is zero",
      "ok 3 - The object isa Tile", "ok 4 - Get possible places to put the Tile",
      "ok 5 - Placing the tile produces no error", "ok 6 - Board size is 1"]) true
    assertOk "indented comment" (doc ["1..1", "   # indented", "ok"]) true,

  test "pragmas are not failures; +strict fails non-TAP output, -strict ends that" do
    assertOk "unknown pragmas" (doc ["TAP version 14", "pragma +bail", "pragma +strict",
      "pragma -bail", "pragma -strict", "1..1", "ok"]) true
    assertOk "strict" (doc ["pragma +strict", "1..1", "ok", "garbage"]) false
    assertOk "not strict" (doc ["pragma +strict", "pragma -strict", "1..1", "ok", "garbage"]) true
    assertOk "a pragma with a comment is not a pragma"
      (doc ["pragma +strict # comment", "1..1", "ok", "garbage"]) true,

  test "blank lines outside YAML are ignored" do
    assertOk "blank" (doc ["", "1..2", "  ", "ok 1", "\t", "", "ok 2", ""]) true,

  test "Bail out! stops the run with its unescaped reason, in any letter case" do
    let d := doc ["TAP version 14", "1..573", "not ok 1 - database handle",
      "Bail out! Couldn't connect to database.", "ok 2"]
    assertEqual "reason" d.bailout? (some "Couldn't connect to database.")
    assertEqual "nothing after it" d.points.size 1
    assertOk "document" d false
    assertEqual "escaped" (doc ["Bail out! \\# and \\\\ are not supported"]).bailout?
      (some "# and \\ are not supported")
    assertEqual "case" (doc ["BAIL OUT!"]).bailout? (some "")
    assertOk "after passing points" (doc ["1..1", "ok 1", "Bail out!"]) false,

  test "anything else is ignored" do
    assertOk "noise" (doc ["1..2", "hello", "ok 1", "not a test point", "ok 2", "okay"]) true,

  test "escaping # and \\ in descriptions and reasons" do
    let d := doc ["TAP version 14", "ok 1 - hello # todo", "ok 2 - hello \\# todo",
      "ok 3 - hello # todo hash \\# character", "ok 4 - hello # todo hash # character",
      "ok 5 - hello \\\\# todo hash \\# character", "ok 6 - hello \\\\# todo hash # character",
      "ok 7 - hello # description # todo", "ok 8 - hello \\\\\\\\\\\\\\# todo", "1..8"]
    assertEqual "descriptions" (d.points.map (·.description))
      #["hello", "hello # todo", "hello", "hello", "hello \\", "hello \\",
        "hello # description # todo", "hello \\\\\\# todo"]
    assertEqual "directives" (d.points.map (·.directive))
      #[.todo "", .none, .todo "hash # character", .todo "hash # character",
        .todo "hash # character", .todo "hash # character", .none, .none]
    assertOk "document" d true,

  test "subtests: commented, with YAML, and a failing child under a failing point" do
    let d := doc ["TAP version 14", "1..2", "", "# Subtest: foo.tap", "    1..2", "    ok 1",
      "    ok 2 - this passed", "ok 1 - foo.tap", "", "# Subtest: bar.tap",
      "    ok 1 - object should be a Bar", "    not ok 2 - object.isBar should return true",
      "      ---", "      found: false", "      wanted: true", "      ...",
      "    ok 3 - object can bar bears # TODO", "    1..3", "not ok 2 - bar.tap", "  ---",
      "  fail: 1", "  todo: 1", "  ..."]
    assertOk "document" d false
    assertEqual "top-level points" d.points.size 2
    let foo ← subtest (← point d 0)
    assertOk "foo" foo true
    assertEqual "foo points" foo.points.size 2
    let bar ← subtest (← point d 1)
    assertOk "bar" bar false
    assertEqual "bar plan" bar.plan? (some { first := 1, last := 3 })
    assertEqual "bar diagnostic" ((← point bar 1).diagnostic?) (some "found: false\nwanted: true")
    assertEqual "bar todo" ((← point bar 2).directive) (.todo "")
    assertEqual "parent diagnostic" ((← point d 1).diagnostic?) (some "fail: 1\ntodo: 1"),

  test "a failing subtest fails its parent even under an ok point" do
    let d := doc ["TAP version 14", "ok 1 - true is ok", "# Subtest: this is a subtest",
      "    ok 1 - this is fine", "    not ok 2 - this is not fine", "    1..2",
      "ok 2 - this is a subtest", "1..2"]
    assertOk "document" d false
    assertOk "subtest" (← subtest (← point d 1)) false,

  test "bare subtests, nested by multiples of four spaces" do
    let bare := doc ["TAP version 14", "    ok 1 - subtest test point", "    1..1",
      "ok 1 - subtest passing", "1..1"]
    assertOk "bare" bare true
    assertEqual "bare child" (← subtest (← point bare 0)).points.size 1
    let nested := doc ["TAP version 14", "        ok 1 - nested twice", "        1..1",
      "    ok 1 - nested parent", "    1..1", "ok 1 - double nest passing", "1..1"]
    assertOk "nested" nested true
    let inner ← subtest (← point (← subtest (← point nested 0)) 0)
    assertEqual "innermost" (inner.points.map (·.description)) #["nested twice"],

  test "commented subtests, including an empty one and an unnamed one" do
    let d := doc ["TAP version 14", "", "ok 1 - in the parent", "", "# Subtest: nested", "    1..1",
      "    ok 1 - in the subtest", "ok 2 - nested", "", "# Subtest: empty", "    1..0",
      "ok 3 - empty", "", "# Subtest", "    ok 1 - name is optional", "    1..1", "ok 4", "",
      "1..4"]
    assertOk "document" d true
    assertEqual "subtests" (d.points.map (·.subtest?.isSome)) #[false, true, true, true]
    assertEqual "empty subtest plan" ((← subtest (← point d 2)).plan?.map (·.skipsAll)) (some true),

  test "a bail-out in a subtest bails out the whole run" do
    let d := doc ["1..2", "ok 1", "# Subtest: child", "    1..2", "    ok 1", "    Bail out! gone",
      "ok 2 - child"]
    assertEqual "reason" d.bailout? (some "gone")
    assertEqual "no correlated point" d.points.size 1
    assertOk "document" d false,

  test "a pragma in a subtest affects only the subtest" do
    assertOk "parent not strict" (doc ["TAP version 14", "pragma -strict", "# Subtest: child test",
      "    1..1", "    pragma +strict", "    ok 1", "ok 1 - child test",
      "!!This is not valid TAP content!!", "1..1"]) true
    assertOk "child strict" (doc ["# Subtest: child test", "    1..1", "    pragma +strict",
      "    ok 1", "    garbage", "ok 1 - child test", "1..1"]) false,

  test "a broken subtest's errors are the parent's, named by its # Subtest comment" do
    let d := doc ["1..1", "# Subtest: child", "    ok 1", "ok 1 - child"]
    assertOk "document" d false
    assertEqual "errors" d.errors #["subtest 'child': no plan"]
    assertEqual "no failed point" (d.points.filter (·.failed)).size 0
    let indented := doc ["1..1", "    # Subtest: child", "    1..2", "    ok 1", "ok 1 - child"]
    assertEqual "named by an indented comment" indented.errors
      #["subtest 'child': planned 2 test points, but found 1"]
    let bare := doc ["1..1", "    ok 1", "ok 1 - child"]
    assertEqual "a bare subtest" bare.errors #["subtest: no plan"]
    let nested := doc ["1..1", "# Subtest: outer", "    1..1", "    # Subtest: inner",
      "        ok 1", "    ok 1 - inner", "ok 1 - outer"]
    assertEqual "nested" nested.errors #["subtest 'outer': subtest 'inner': no plan"]
    let strict := doc ["1..1", "# Subtest: child", "    pragma +strict", "    1..1", "    ok 1",
      "    garbage", "ok 1 - child"]
    assertEqual "strict in the subtest" strict.errors
      #["subtest 'child': non-TAP output in strict mode: garbage"],

  test "the # Subtest name is not matched against the test point that ends the subtest" do
    let d := doc ["1..1", "# Subtest: a", "    1..1", "    ok 1", "ok 1 - b"]
    assertOk "document" d true
    assertEqual "errors" d.errors #[],

  test "Bail out! after a trailing plan still bails out" do
    let d := doc ["ok 1", "1..1", "Bail out! report failed"]
    assertEqual "reason" d.bailout? (some "report failed")
    assertOk "document" d false
    assertEqual "points" d.points.size 1,

  test "a test point after a trailing plan is not TAP" do
    let d := doc ["ok 1", "1..1", "not ok 2"]
    assertEqual "points" d.points.size 1
    assertOk "document" d true
    assertOk "strict" (doc ["pragma +strict", "ok 1", "1..1", "not ok 2"]) false,

  test "subtest: a version line in a subtest is ignored" do
    assertOk "document" (doc ["TAP version 14", "# Subtest: child", "    TAP version 14", "    1..1",
      "    ok 1", "ok 1 - child", "1..1"]) true,

  test "unknown amount and failures: the plan at the end" do
    let d := doc ["TAP version 14", "ok 1 - retrieving servers from the database",
      "# need to ping 6 servers", "ok 2 - pinged diamond", "ok 3 - pinged ruby",
      "not ok 4 - pinged saphire", "  ---", "  message: 'hostname \"saphire\" unknown'",
      "  severity: fail", "  ...", "ok 5 - pinged onyx", "not ok 6 - pinged quartz", "  ---",
      "  message: 'timeout'", "  severity: fail", "  ...", "ok 7 - pinged gold", "1..7"]
    assertOk "document" d false
    assertEqual "failed" (d.points.filter (·.failed) |>.map (·.id)) #[4, 6]
    assertEqual "errors" d.errors #[],

  test "skipping a few" do
    let d := doc ["TAP version 14", "1..5", "ok 1 - approved operating system", "# $^0 is solaris",
      "ok 2 - # SKIP no /sys directory", "ok 3 - # SKIP no /sys directory",
      "ok 4 - # SKIP no /sys directory", "ok 5 - # SKIP no /sys directory"]
    assertOk "document" d true
    assertEqual "skips" (d.points.map (·.directive))
      #[.none, .skip "no /sys directory", .skip "no /sys directory", .skip "no /sys directory",
        .skip "no /sys directory"],

  test "procrastination considered ok" do
    assertOk "document" (doc ["TAP version 14", "1..4", "ok 1 - Creating test program",
      "ok 2 - Test program runs, no error", "not ok 3 - infinite loop # TODO halting problem unsolved",
      "not ok 4 - infinite loop 2 # TODO halting problem unsolved"]) true,

  test "creative liberties: no IDs, a YAML dump, the plan last" do
    let d := doc ["TAP version 14", "ok - created Board", "ok", "ok", "ok", "ok", "ok", "ok", "ok",
      "  ---", "  message: \"Board layout\"", "  severity: comment", "  dump:", "     board:",
      "       - '      16G         05C        '", "  ...", "ok - board has 7 tiles + starter tile",
      "1..9"]
    assertOk "document" d true
    assertEqual "count" d.points.size 9
    assertEqual "diagnostic on the eighth" (d.points.map (·.diagnostic?.isSome))
      #[false, false, false, false, false, false, false, true, false],

  test "line endings: \\r\\n and \\r are line breaks, and the last break is optional" do
    assertOk "crlf" (parse "TAP version 14\r\n1..2\r\nok 1\r\nok 2\r\n") true
    assertOk "cr" (parse "1..2\rok 1\rok 2") true
    assertOk "no final break" (parse "1..1\nok 1") true
]

/-! ## tap-parser's fixtures -/

private def fixtures : System.FilePath := "Test" / "Tap" / "fixtures"

/-- Fixtures using tap-parser's buffered subtests (`ok 1 - name {` … `}`, or `{` on its own line
after a diagnostic), an extension that is not in the specification. -/
private def buffered : List String := [
  "buffered-nested-failure-top-ok-diag.tap", "buffered-nested-failure-top-ok-no-msg.tap",
  "buffered-nested-failure-top-ok.tap", "buffered-nested-ok-top-failure-diag.tap",
  "buffered-nested-ok-top-failure.tap", "buffered-with-diag-not-ok.tap",
  "buffered-with-diag-ok.tap", "confusing-json.tap", "empty-buffered-child.tap",
  "perl-test2-buffered.tap", "plan-in-bad-places-post.tap", "plan-in-bad-places-pre.tap",
  "subtest-buffer-diags-time.tap", "subtest-buffer-todo.tap", "subtest-buffer.tap",
  "subtest-confusing.tap", "subtest-mixing.tap", "version-in-yaml.tap"]

/-- Fixtures with no plan and no test points: tap-parser reads them as a skipped test set, but "A
Harness _must_ treat a TAP stream lacking a plan as a failed test". -/
private def withoutPlan : List String := ["die.tap", "empty.tap", "out_err_mix.tap"]

/-- tap-parser reads its own `# time=…` directive; the specification keeps an unrecognized directive
in the description, which is where this parser leaves it. -/
private def withoutTime (description : String) : String :=
  match description.splitOn " # time=" with
  | [plain, _] => plain
  | _ => description

private def directiveJson (directive : Directive) (skip : Bool) : Lean.Json :=
  match directive, skip with
  | .skip reason, true | .todo reason, false => .str reason
  | _, _ => .null

/-- The shape `oracle.js` prints for tap-parser: an unnumbered point has ID 0. -/
private def summary (document : Document) : Lean.Json :=
  let points := document.points
  let count (keep : Point -> Bool) : Nat := (points.filter keep).size
  .mkObj [
    ("ok", document.ok), ("count", points.size), ("pass", count (·.ok)),
    ("todo", count fun p => match p.directive with | .todo _ => true | _ => false),
    ("skip", count fun p => match p.directive with | .skip _ => true | _ => false),
    ("bailout", document.bailout?.map Lean.Json.str |>.getD .null),
    ("plan", match document.plan? with
      | none => .null
      | some plan => .mkObj [("start", plan.first), ("end", plan.last),
          ("skipAll", plan.skipsAll), ("reason", plan.reason)]),
    ("points", .arr (points.map fun p => .mkObj [
      ("ok", p.ok), ("id", if p.numbered then p.id else 0), ("name", withoutTime p.description),
      ("todo", directiveJson p.directive false), ("skip", directiveJson p.directive true)]))]

private def oracle : TestM (Array (String × Lean.Json)) := do
  let json ← match Lean.Json.parse (← IO.FS.readFile ("Test" / "Tap" / "expected.json")) with
    | .ok json => pure json | .error e => fail e
  let .ok cases := json.getObj? | fail "expected.json is not an object"
  pure (cases.toArray.map fun ⟨name, want⟩ => (name, want))

def fixtureSuite : Suite := Testing.suite "tap/fixtures" #[
  test "every fixture has an expected result" do
    let names := (← oracle).map (·.1)
    for entry in ← fixtures.readDir do
      check (names.contains entry.fileName) s!"{entry.fileName} has no expected result"
    for name in buffered ++ withoutPlan do
      check (names.contains name) s!"{name} is listed but not a fixture",

  test "buffered fixtures use buffered subtests" do
    for name in buffered do
      let text ← IO.FS.readFile (fixtures / name)
      let lines := (text.splitOn "\n").map (·.trimAscii.toString)
      check (lines.any fun l => l == "{" || (l.startsWith "ok" || l.startsWith "not ok") && l.endsWith "{")
        s!"{name} has no buffered subtest",

  test "tap-parser synthesizes a skip-all plan for the fixtures without one" do
    for (name, want) in ← oracle do
      if withoutPlan.contains name then
        assertEqual s!"{name}: tap-parser's plan reason"
          (want.getObjValD "plan" |>.getObjValD "reason").compress "\"no tests found\""
        let got := parse (← IO.FS.readFile (fixtures / name))
        assertEqual s!"{name}: ok" got.ok false
        assertEqual s!"{name}: errors" got.errors #["no plan"],

  test "the results agree with tap-parser's" do
    let mut mismatches := #[]
    for (name, want) in ← oracle do
      if buffered.contains name || withoutPlan.contains name then continue
      let got := summary (parse (← IO.FS.readFile (fixtures / name)))
      if got != want then
        mismatches := mismatches.push s!"{name}\n  want {want.compress}\n  got  {got.compress}"
    check mismatches.isEmpty s!"{mismatches.size} mismatches:\n{"\n".intercalate mismatches.toList}"
]

end TapTests
