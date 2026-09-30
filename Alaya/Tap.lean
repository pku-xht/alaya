/-!
TAP 14, the Test Anything Protocol (https://testanything.org/tap-version-14-specification.html).

A grader reports its checks as TAP on stdout. `parse` reads a whole stream into a `Document`: the
version, the plan, the test points with their directives and YAML diagnostics, subtests, and a
bail-out. `Document.ok` is the verdict the specification asks a harness for: a plan, as many test
points as it announces, no failing test point other than a `TODO` or `SKIP` one, no failing
subtest, and no bail-out.

Where the specification leaves a choice to the harness, this parser does what tap-parser
(node-tap's parser, written by the specification's author) does, and the tests compare the two on
tap-parser's fixtures. It departs from tap-parser in three places, each to follow the
specification:

- A stream without a plan is never ok, even an empty one ("A Harness _must_ treat a TAP stream
  lacking a plan as a failed test"); tap-parser treats an empty stream as a skipped test set.
- A line of only whitespace is blank and ignored, rather than non-TAP.
- A `TODO`/`SKIP` reason is the text after `TODO\S*\s+`, as the specification's regular
  expression puts it.

It does not implement tap-parser's own extensions: buffered subtests (`ok 1 - name {` … `}`) and
`time=` directives. YAML diagnostics are kept as text and not parsed.
-/

namespace Alaya.Tap

/-- A test point's `# SKIP` or `# TODO`, with its reason (empty when none is given). -/
inductive Directive where
  | none
  | skip (reason : String)
  | todo (reason : String)
  deriving BEq, Repr, Inhabited

structure Plan where
  first : Nat
  last : Nat
  /-- The text after `#`, unescaped: why a `1..0` plan skipped everything. -/
  reason : String := ""
  deriving BEq, Repr, Inhabited

/-- `1..0`: the whole test set was skipped. -/
def Plan.skipsAll (plan : Plan) : Bool := plan.first == 1 && plan.last == 0

/-- How many test points the plan announces. -/
def Plan.count (plan : Plan) : Nat := plan.last + 1 - plan.first

mutual
  /-- One `ok` or `not ok` line. -/
  structure Point where
    ok : Bool
    /-- The Test Point ID on the line, or the harness's own count when the line has none. -/
    id : Nat
    /-- Whether the line gave `id`. -/
    numbered : Bool := true
    /-- Unescaped, without a leading `" - "`. -/
    description : String := ""
    directive : Directive := .none
    /-- The YAML diagnostic block after the point, without its markers and indentation. -/
    diagnostic? : Option String := none
    /-- The subtest this point terminates, if it is a subtest's correlated test point. -/
    subtest? : Option Document := none

  structure Document where
    version? : Option Nat := none
    plan? : Option Plan := none
    points : Array Point := #[]
    /-- The reason after `Bail out!`, unescaped. -/
    bailout? : Option String := none
    /-- Why the stream is invalid TAP as a whole: no plan, a count or Test Point ID that disagrees
    with it, a duplicate ID, non-TAP output under `pragma +strict`. -/
    errors : Array String := #[]
    ok : Bool
end

instance : Inhabited Document := ⟨{ ok := false }⟩

/-- A failure the harness must count: `not ok` without a `TODO` or `SKIP` directive. -/
def Point.failed (point : Point) : Bool := !point.ok && point.directive == .none

/-! ## Lines -/

private def dropChars (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)

private def trim (s : String) : String := s.trimAscii.toString

/-- `\\` is a literal `\`, `\#` a literal `#`; any other `\` is itself. -/
def unescape (s : String) : String := Id.run do
  let chars := s.toList.toArray
  let mut out := ""
  let mut i := 0
  while i < chars.size do
    let c := chars[i]!
    if c == '\\' && i + 1 < chars.size && (chars[i+1]! == '\\' || chars[i+1]! == '#') then
      out := out.push chars[i+1]!
      i := i + 2
    else
      out := out.push c
      i := i + 1
  return out

/-- `s` without its leading run of `pre`s, when there is at least one. -/
private partial def stripRepeated (pre s : String) : Option String :=
  if s.startsWith pre then
    let rest := dropChars s pre.length
    some ((stripRepeated pre rest).getD rest)
  else none

private def isDigits (s : String) : Bool := !s.isEmpty && s.all Char.isDigit

/-- `TAP version N`, in any letter case. -/
private def versionOf? (line : String) : Option Nat :=
  if line.toLower.startsWith "tap version " then (dropChars line 12).toNat? else none

/-- `1..N`, optionally followed by whitespace, `#` and a reason. -/
private def planOf? (line : String) : Option Plan := do
  let chars := line.toList
  let first := chars.takeWhile Char.isDigit
  guard (!first.isEmpty)
  let rest := chars.drop first.length
  guard (rest.take 2 == ['.', '.'])
  let rest := rest.drop 2
  let last := rest.takeWhile Char.isDigit
  guard (!last.isEmpty)
  let tail := rest.drop last.length
  let reason ← if tail.isEmpty then pure "" else do
    let comment := tail.dropWhile Char.isWhitespace
    guard (comment.length < tail.length && comment.head? == some '#')
    pure (trim (unescape (String.ofList (comment.drop 1))))
  pure { first := (String.ofList first).toNat!, last := (String.ofList last).toNat!, reason }

/-- `pragma +key` or `pragma -key`. -/
private def pragmaOf? (line : String) : Option (Bool × String) := do
  guard (line.startsWith "pragma ")
  let rest := dropChars line 7
  let sign := rest.toList.head?
  guard (sign == some '+' || sign == some '-')
  let key := dropChars rest 1
  guard (!key.isEmpty && key.all fun c => c.isAlphanum || c == '_' || c == '-')
  pure (sign == some '+', key)

/-- The reason after `Bail out!`, in any letter case. -/
private def bailoutOf? (line : String) : Option String :=
  if line.toLower.startsWith "bail out!" then some (trim (unescape (dropChars line 9))) else none

/-- `# Subtest` or `# Subtest: NAME`. -/
private def subtestOf? (line : String) : Option String :=
  if line == "# Subtest" then some ""
  else if line.startsWith "# Subtest: " then some (dropChars line 11)
  else none

private def isComment (line : String) : Bool :=
  (line.toList.dropWhile Char.isWhitespace).head? == some '#'

/-- `TODO` or `SKIP` at the start of the text after the directive delimiter, in any letter case,
optionally followed by more non-space characters; the reason is what follows the next space. -/
private def directiveOf? (text : String) : Option Directive := do
  let lower := text.toLower
  let skip := lower.startsWith "skip"
  guard (skip || lower.startsWith "todo")
  let chars := text.toList.drop 4
  let word := chars.takeWhile (!·.isWhitespace)
  let reason := trim (String.ofList (chars.drop word.length))
  pure (if skip then .skip reason else .todo reason)

/-- The description and directive after the status and ID. The directive starts at the first `#`
that is unescaped and preceded by whitespace (or an escaped `\`); an unrecognized directive stays
part of the description. -/
private def describe (rest : String) : String × Directive := Id.run do
  let chars := rest.toList.toArray
  let mut description := ""
  let mut i := 0
  let mut delimits := true
  while i < chars.size do
    let c := chars[i]!
    if c == '\\' && i + 1 < chars.size && (chars[i+1]! == '\\' || chars[i+1]! == '#') then
      description := description.push chars[i+1]!
      delimits := chars[i+1]! == '\\'
      i := i + 2
    else if c == '#' && delimits then
      let text := unescape (String.ofList (chars.toList.drop (i + 1)))
      match directiveOf? (trim text) with
      | some directive => return (trim description, directive)
      | none => return (trim (description ++ "#" ++ text), .none)
    else
      description := description.push c
      delimits := c.isWhitespace
      i := i + 1
  return (trim description, .none)

/-- `ok` or `not ok`, then optionally an ID, `" - "` and a description with a directive. -/
private def pointOf? (line : String) (count : Nat) : Option Point := do
  let (ok, after) ←
    if line.startsWith "not ok" then pure (false, dropChars line 6)
    else if line.startsWith "ok" then pure (true, dropChars line 2)
    else none
  guard (after.isEmpty || after.startsWith " ")
  let digits := String.ofList ((after.toList.drop 1).takeWhile Char.isDigit)
  let afterId := dropChars after (1 + digits.length)
  let (id?, rest) :=
    if isDigits digits && (afterId.isEmpty || afterId.startsWith " ") then (digits.toNat?, afterId)
    else (none, after)
  let rest := if rest.startsWith " - " then dropChars rest 2 else rest
  let (description, directive) := describe rest
  pure { ok, id := id?.getD (count + 1), numbered := id?.isSome, description, directive }

/-! ## Parsing -/

private structure Parser where
  /-- A subtest: its version lines are ignored. -/
  nested : Bool := false
  strict : Bool := false
  version? : Option Nat := none
  plan? : Option Plan := none
  /-- The plan came after test points, or was `1..0`: no more TAP may follow. -/
  closed : Bool := false
  points : Array Point := #[]
  /-- The last test point, which diagnostics may still follow. -/
  current? : Option Point := none
  /-- An open YAML block: its indentation and lines so far. -/
  yaml? : Option (String × Array String) := none
  child? : Option Parser := none
  /-- A `# Subtest` comment that the next indented line may open. -/
  announced : Bool := false
  seen : Array Nat := #[]
  bailout? : Option String := none
  errors : Array String := #[]
  ok : Bool := true

namespace Parser

private def error (p : Parser) (message : String) : Parser :=
  { p with errors := p.errors.push message, ok := false }

/-- Output that is not TAP; a failure only under `pragma +strict`. -/
private def nonTap (p : Parser) (line : String) : Parser :=
  if p.strict then p.error s!"non-TAP output in strict mode: {line}" else p

private def idError? (plan : Plan) (id : Nat) : Option String :=
  if id < plan.first then some s!"test point id {id} is less than the plan start"
  else if id > plan.last then some s!"test point id {id} is greater than the plan end"
  else none

mutual
  /-- Ends the subtest, if one is open. A failing subtest fails its parent. -/
  private partial def closeChild (p : Parser) : Parser × Option Document :=
    match p.child? with
    | none => (p, none)
    | some child =>
      let document := child.finish
      ({ p with child? := none, ok := p.ok && document.ok }, some document)

  /-- Records the current test point: nothing more can be attached to it. -/
  private partial def settle (p : Parser) : Parser :=
    if p.bailout?.isSome then p else
    let (p, _) := p.closeChild
    let p := { p with yaml? := none }
    match p.current? with
    | none => p
    | some point =>
      { p with current? := none, points := p.points.push point, ok := p.ok && !point.failed }

  /-- An unterminated YAML block is not TAP. -/
  private partial def yamlGarbage (p : Parser) : Parser :=
    match p.yaml? with
    | none => p
    | some (indent, lines) =>
      let p := p.settle
      ((indent ++ "---") :: lines.toList.map (indent ++ ·)).foldl nonTap p

  private partial def bail (p : Parser) (reason : String) : Parser :=
    if p.bailout?.isSome then p else
    let p := p.settle
    { p with bailout? := some reason, ok := false, current? := none }

  private partial def plan (p : Parser) (plan : Plan) (line : String) : Parser :=
    if p.plan?.isSome || p.child?.isSome || p.yaml?.isSome then p.nonTap line else
    let p := p.settle
    if plan.last < plan.first && !(plan.last == 0 && plan.first == 1) then p.nonTap line else
    let p := { p with plan? := some plan }
    if p.points.isEmpty && plan.last != 0 then p else
    let p := p.points.foldl (init := p) fun p point =>
      if !point.numbered then p else
      match idError? plan point.id with
      | some message => p.error message
      | none => p
    { p with closed := true }

  private partial def point (p : Parser) (point : Point) : Parser :=
    let p := if p.child?.isSome then p else p.settle
    let p := match p.plan?, point.numbered with
      | some plan, true => match idError? plan point.id with
        | some message => p.error message
        | none => p
      | _, _ => p
    let p :=
      if !point.numbered then p
      else if p.seen.contains point.id then p.error s!"test point id {point.id} appears multiple times"
      else { p with seen := p.seen.push point.id }
    let (p, subtest?) := p.closeChild
    { p with current? := some { point with subtest? } }

  /-- Opens a subtest with `line`, which is indented by at least four spaces. -/
  private partial def openChild (p : Parser) (line : String) : Parser :=
    let p := p.settle
    let child : Parser := { nested := true, strict := p.strict }
    let child := if (subtestOf? (dropChars line 4)).isSome && !p.announced then child
      else child.feed (dropChars line 4)
    { p with child? := some child, announced := false }

  private partial def indented (p : Parser) (line indent : String) : Parser := Id.run do
    if let some child := p.child? then
      if line.startsWith "    " then
        let child := child.feed (dropChars line 4)
        let p := { p with child? := some child }
        return match child.bailout? with
          | some reason =>
            let (p, _) := p.closeChild
            { p with bailout? := some reason, ok := false }
          | none => p
    let mut p := p
    if let some (yamlIndent, lines) := p.yaml? then
      if line.startsWith yamlIndent then
        if line == yamlIndent ++ "..." then
          let diagnostic := "\n".intercalate lines.toList
          return { p with yaml? := none
                          current? := p.current?.map ({ · with diagnostic? := some diagnostic }) }
        return { p with yaml? := some (yamlIndent, lines.push (dropChars line yamlIndent.length)) }
      p := p.yamlGarbage
    if p.current?.isSome && p.yaml?.isNone && line == indent ++ "---" then
      return { p with yaml? := some (indent, #[]) }
    if line.startsWith "    " then
      if p.announced || (subtestOf? (dropChars line 4)).isSome then
        return p.openChild line
      if let some content := stripRepeated "    " line then
        if !content.startsWith " " then
          if isComment content then return p
          if (pointOf? content 0).isSome || (pragmaOf? content).isSome ||
              (bailoutOf? content).isSome || (versionOf? content).isSome ||
              (planOf? content).isSome || (subtestOf? content).isSome then
            return p.openChild line
    if isComment line then return p
    return p.nonTap line

  /-- Reads one line, without its line break. -/
  private partial def feed (p : Parser) (line : String) : Parser := Id.run do
    if p.bailout?.isSome then return p
    -- A line of only whitespace is blank: part of an open subtest or YAML block, else ignored.
    let line := if line.all Char.isWhitespace then "" else line
    if line.isEmpty then
      if let some child := p.child? then return { p with child? := some (child.feed "") }
      if let some (indent, lines) := p.yaml? then
        return { p with yaml? := some (indent, lines.push "") }
      return p
    if p.nested && (versionOf? line).isSome && p.yaml?.isNone then return p
    let indent := String.ofList (line.toList.takeWhile fun c => c == ' ' || c == '\t')
    if !indent.isEmpty then return p.indented line indent
    let isPoint := (pointOf? line 0).isSome
    let isOther := (pragmaOf? line).isSome || (bailoutOf? line).isSome ||
      (versionOf? line).isSome || (planOf? line).isSome
    if !isPoint && !isOther then
      if (subtestOf? line).isSome then
        let p := p.yamlGarbage
        return if p.closed then p.nonTap line else { p with announced := true }
      if isComment line then return p
      return p.nonTap line
    let p := { p.yamlGarbage with announced := false }
    if p.closed then return p.nonTap line
    if let some reason := bailoutOf? line then return p.bail reason
    if let some (on, key) := pragmaOf? line then
      if p.child?.isSome then return p.nonTap line
      let p := p.settle
      return if key == "strict" then { p with strict := on } else p
    if let some version := versionOf? line then
      if version >= 13 && p.plan?.isNone && p.points.isEmpty && p.current?.isNone then
        return { p with version? := some version }
      return p.nonTap line
    if let some plan := planOf? line then return p.plan plan line
    match pointOf? line (p.points.size + if p.current?.isSome then 1 else 0) with
    | some point => return p.point point
    | none => return p

  /-- The document, after the last line. -/
  private partial def finish (p : Parser) : Document := Id.run do
    let mut p := p.yamlGarbage.settle
    if p.bailout?.isNone then
      match p.plan? with
      | none => p := p.error "no plan"
      | some plan =>
        if plan.skipsAll && !p.points.isEmpty then
          p := p.error "plan of 1..0, but test points encountered"
        else if p.points.size != plan.count then
          p := p.error s!"planned {plan.count} test points, but found {p.points.size}"
    return { version? := p.version?, plan? := p.plan?, points := p.points, bailout? := p.bailout?
             errors := p.errors, ok := p.ok }
end

end Parser

/-- Parses a whole TAP stream. `\r\n` and `\r` count as line breaks. -/
def parse (stream : String) : Document :=
  let lines := ((stream.replace "\r\n" "\n").replace "\r" "\n").splitOn "\n"
  -- The break after the last line does not start another one.
  let lines := if lines.getLast? == some "" then lines.dropLast else lines
  (lines.foldl Parser.feed {}).finish

end Alaya.Tap
