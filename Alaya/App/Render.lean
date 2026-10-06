import Alaya.Runtime.Walk

/-! Rendering logs as text, for the command line: an event in a line, what a run does next, and
the forest as a tree of branches. -/

namespace Alaya.App.Render

open Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime

open Lean (Json)

def short (hash : Hash) : String := (hash.hex.take 12).toString

/-- `s` on one line, cut to `limit` characters. -/
def flatten (s : String) (limit : Nat := 80) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then (flat.take (limit - 3)).toString ++ "..." else flat

/-- The fields of an object in a line, `name: value, …`: a text as it is, anything else as
compact JSON. -/
private def fieldsLine (value : Json) : String :=
  match value with
  | .obj fields =>
    ", ".intercalate <| (fields.foldl (fun (acc : Array String) name field =>
      acc.push s!"{name}: {match field with | .str text => text | other => other.compress}") #[]).toList
  | other => other.compress

/-- Arguments as one string: the value of the one string field, or of a string `command` or
`question` field beside others — what a call is about — otherwise the fields in a line. -/
def argumentsSummary (arguments : Json) : String :=
  match arguments with
  | .str value => value
  | .obj fields =>
    match fields.foldl (fun (acc : Array (String × Json)) k v => acc.push (k, v)) #[] with
    | #[(_, .str value)] => value
    | _ =>
      match arguments.getObjVal? "command", arguments.getObjVal? "question" with
      | .ok (.str command), _ => command
      | _, .ok (.str question) => question
      | _, _ => fieldsLine arguments
  | other => other.compress

/-- A model's tool call, `name  arguments`, on one line. -/
def callSummary (call : Chat.ToolCall) : String :=
  call.name ++ " " ++ flatten (call.invalidArguments?.getD (argumentsSummary call.arguments)) 60

/-- A value a call gave, on one line: a verdict by its status and score, an agent's outcome by
its status and submission, a command's result by how it ended and its first line; a value of no
such kind as what it holds — a text, the fields of an object, the elements of a list. -/
partial def valueSummary (value : Json) : String :=
  let field (name : String) := value.getObjVal? name |>.toOption
  let text (name : String) := (field name >>= (·.getStr?.toOption)).getD ""
  match valueKind? value, value with
  | some .verdict, _ =>
    s!"{text "status"} {((field "passed").getD .null).compress}/{((field "total").getD .null).compress}"
  | some .outcome, _ =>
    if (text "submission").isEmpty then text "status" else s!"{text "status"}: {flatten (text "submission") 60}"
  | some .command, _ =>
    let status := match field "exit_code", field "error" with
      | some (.num code), _ => s!"exit {code}"
      | _, some (.str error) => flatten error 40
      | _, _ => "no status"
    let first := ((text "output").splitOn "\n").find? (!·.trimAscii.isEmpty) |>.getD ""
    s!"{status}: {flatten first 60}"
  | none, .str s => flatten s
  | none, .arr values => ", ".intercalate (values.map valueSummary).toList
  | none, .obj _ => flatten (fieldsLine value)
  | none, other => flatten other.compress

/-- `label rest`, or `label` alone when there is nothing to add. -/
private def labelled (label rest : String) : String :=
  if rest.isEmpty then label else s!"{label} {rest}"

private def count (n : Nat) : String :=
  if n < 1000 then toString n
  else if n < 1000000 then s!"{n / 1000}.{(n % 1000) / 100}k"
  else s!"{n / 1000000}.{(n % 1000000) / 100000}M"

/-- `in 48.2k, 41.9k cached; out 1.1k, 800 reasoning`, with what was not reported left out. -/
def tokens (usage : Chat.TokenUsage) : String :=
  let side (name : String) (n? : Option Nat) (part? : Option Nat) (partName : String) : List String :=
    match n? with
    | some n => [s!"{name} {count n}" ++ (part?.map (s!", {count ·} {partName}") |>.getD "")]
    | none => []
  "; ".intercalate (side "in" usage.input? usage.cached? "cached" ++
    side "out" usage.output? usage.reasoning? "reasoning")

/-- Milliseconds as seconds with one decimal: `12.3 s`. -/
def seconds (ms : Nat) : String := s!"{ms / 1000}.{(ms % 1000) / 100} s"

def noticeSummary : Notice → String
  | .said message => s!"said {(flatten message 70).quote}"
  | .changed workspace summary => s!"changed → {short workspace}: {flatten summary 60}"
  | .replied to reply => s!"replied to {to.render}: {flatten reply.line 60}"
  | .called call => s!"call {callTitle call}"

/-- An event in a line. -/
def eventSummary : Event Agent → String
  | .arrived notice => noticeSummary notice
  | .heard _ notices =>
    if notices.isEmpty then "inbox: nothing" else s!"inbox: takes {notices.toList}"
  | .asked _ question => s!"ask {(flatten question.text 70).quote}"
  | .answered _ _ (.error error) => s!"failed: {flatten error}"
  | .answered _ (.sample ..) (.ok (.response response)) =>
    if response.toolCalls.isEmpty then s!"sample → says {(flatten (response.content?.getD "") 60).quote}"
    else s!"sample → " ++ "; ".intercalate (response.toolCalls.map callSummary).toList
  | .answered _ (.exec command _) (.ok (.execution e)) =>
    let status := match e.output.exitCode?, e.output.failure? with
      | some code, _ => s!"exit {code}"
      | none, some error => flatten error 40
      | none, none => "no status"
    s!"exec {flatten command 60} → {status}, {short e.workspace}"
  | .answered _ .time (.ok (.timing t)) =>
    s!"time {seconds t.spentMs}" ++ (t.budgetMs?.map (s!" of {seconds ·}") |>.getD "")
  | .answered .. => "answered"
  | .opened _ call =>
    -- An agent's call is told by its routine and its model, not by its whole configuration.
    match agentTitle? call with
    | some title => s!"open {title}"
    | none =>
      let arguments := argumentsSummary call.arguments
      labelled s!"open {call.name}" (if arguments.isEmpty then "" else (flatten arguments 60).quote)
  | .returned _ value => labelled "return" (valueSummary value)
  | .failed _ error => s!"fail: {flatten error}"
  | .broke frame reason => s!"stopped {frame.render}: {flatten reason}"
  | .commented text => s!"# {flatten text}"

/-- How a call ended, in a line: what it gave — `done: pass 48/48`, `done: Submitted` — or why it
ended. -/
def endingSummary : CallEnd → String
  | .returned value => s!"done: {valueSummary value}"
  | .failed error => s!"failed: {flatten error}"
  | .stopped reason => s!"stopped: {flatten reason}"

/-- What a run does next, in a line: what it waits for, or what it asks. `ended?` is how its last
call ended, once it has: a run that calls nothing stands as that call ended. -/
def nextSummary (question? : Option Question) (ended? : Option CallEnd) : Next Agent → String
  | .ended (.ok value) => s!"done: {valueSummary value}"
  | .ended (.error error) => s!"failed: {flatten error}"
  | .waits frame _ =>
    match question?, ended? with
    | some question, _ => s!"waits for a reply: {flatten question.text 70}"
    | none, some ended => if frame.size ≤ 1 then endingSummary ended else s!"waits for a notice in {frame.render}"
    | none, none => if frame.size ≤ 1 then "waits for a call" else s!"waits for a notice in {frame.render}"
  | .ask call => s!"next: {call.op.describe}"
  -- A mark to come reads as it will in the log.
  | .mark event => s!"next: {eventSummary event}"
  | .mismatch position => s!"broken: the event at {position} is no trace of the run"
  | .unguarded frame => s!"broken: a loop in {frame.render} reads no event"

/-- An entry as the commands that append print it: its full name, its position, its frame, and
its event. -/
def entryLine (hash : Hash) (position : Nat) (event : Event Agent) : String :=
  let frame := (event.frame?.map Frame.render).getD "-"
  s!"{hash.hex}  {position}  {frame}  {eventSummary event}"

/-- One entry of the forest, as the tree shows it. -/
structure Row where
  hash : Hash
  parent? : Option Hash
  position : Nat
  summary : String
  /-- What the run does next, on an entry that ends a log. -/
  status? : Option String := none
  /-- On a root: the program its first call names, and the model, once the log has them. -/
  title? : Option String := none
  /-- Whether the entry is a comment. -/
  comment : Bool := false
  deriving Inhabited

/-- Every entry of the forest, as the tree shows it: what each log does next at its end, and on
each root the program and the model of its first call. -/
def rows (store : Store) (forest : Forest) (scope : Scope Agent) : Result (Array Row) := do
  let rows ← walk (scope := scope) store forest (#[] : Array Row) fun rows visit => do
    let isLeaf := (forest.childrenOf visit.hash).isEmpty
    let status? := if !isLeaf then none else match visit.next? with
      | some next => some (nextSummary visit.question? (visit.last?.bind (·.2)) next)
      | none => some "the run cannot be read"
    pure (rows.push { hash := visit.hash, parent? := visit.entry.parent?, position := visit.position
                      summary := eventSummary visit.entry.event, status?
                      comment := visit.entry.event matches .commented ..
                      title? := match visit.entry.event with
                        | .opened #[_, _] call => some (callTitle call)
                        | _ => none })
  -- A run's title is its first call's, on its root.
  let titles : Std.HashMap Hash String := rows.foldl (init := {}) fun titles row =>
    match row.title?, (forest.path row.hash)[0]? with
    | some title, some root => if titles.contains root then titles else titles.insert root title
    | _, _ => titles
  pure <| rows.map fun row =>
    if row.parent?.isNone then { row with title? := titles.get? row.hash } else { row with title? := none }

/-- The forest as a tree of branches: a root and its run, then every stretch of entries with no
fork in it as one line — where it starts and ends, how many entries, the last event, and, at
the end of a log, what the run does next — and the stretches that fork from its end indented
under it. A comment that nothing follows, beside another continuation of its entry, is no
branch: it is a line under the stretch its entry is in. -/
partial def treeLines (rows : Array Row) : Array String := Id.run do
  let byHash : Std.HashMap Hash Row := rows.foldl (init := {}) fun m row => m.insert row.hash row
  let children : Std.HashMap Hash (Array Hash) := rows.foldl (init := {}) fun m row =>
    match row.parent? with
    | some parent => m.insert parent ((m.getD parent #[]).push row.hash)
    | none => m
  let all (hash : Hash) := children.getD hash #[]
  let lone (hash : Hash) := (byHash.getD hash default).comment && (all hash).isEmpty
  let annotation (hash : Hash) : Bool :=
    lone hash && match (byHash.getD hash default).parent? with
      | some parent => (all parent).any (!lone ·)
      | none => false
  let kids (hash : Hash) := (all hash).filter (!annotation ·)
  let noted (indent : String) (hash : Hash) : Array String := (all hash).filter annotation |>.map fun note =>
    let row := byHash.getD note default
    s!"{indent}  {short note}  {row.position}  {row.summary}"
  -- The stretch from `hash` on, until a fork or an end, and the annotations of its entries.
  let rec stretch (indent : String) (hash : Hash) (length : Nat) (notes : Array String) :
      Hash × Nat × Array String :=
    let notes := notes ++ noted indent hash
    match (kids hash).toList with
    | [only] => stretch indent only (length + 1) notes
    | _ => (hash, length, notes)
  let rec lines (hash : Hash) (indent : String) : Array String :=
    let (last, length, notes) := stretch indent hash 1 #[]
    let first := byHash.getD hash default
    let end' := byHash.getD last default
    let status := end'.status?.map (s!"  [{·}]") |>.getD ""
    let span := if length == 1 then short hash else s!"{short hash}..{short last}"
    let line := s!"{indent}{span}  {first.position}-{end'.position}  {end'.summary}{status}"
    (kids last).foldl (init := #[line] ++ notes) fun out child => out ++ lines child (indent ++ "  ")
  let mut out := #[]
  for row in rows do
    if row.parent?.isNone then
      out := out.push s!"{short row.hash}  root  {row.title?.getD row.summary}"
      out := out ++ noted "" row.hash
      for child in kids row.hash do
        out := out ++ lines child "  "
  return out

end Alaya.App.Render
