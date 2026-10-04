import Alaya.Walk

/-! Rendering logs as text, for the command line: an event in a line, what a run does next, and
the forest as a tree of branches. -/

namespace Alaya.Render

open Lean (Json)

def short (hash : Hash) : String := (hash.hex.take 12).toString

/-- `s` on one line, cut to `limit` characters. -/
def flatten (s : String) (limit : Nat := 80) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then (flat.take (limit - 3)).toString ++ "..." else flat

/-- Arguments as one string: the value of the one string field, or of a string `command` field
beside others — the shapes a command tool takes — otherwise the compact JSON. -/
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
      | _, _ => arguments.compress
  | other => other.compress

/-- A model's tool call, `name  arguments`, on one line. -/
def callSummary (call : Chat.ToolCall) : String :=
  call.name ++ " " ++ flatten (call.invalidArguments?.getD (argumentsSummary call.arguments)) 60

/-- A value a call gave, on one line: a verdict by its status and score, an agent's outcome by
its status and submission, a command's result by its status and first line, anything else as
compact JSON. -/
partial def valueSummary (value : Json) : String :=
  match value with
  | .str s => flatten s
  | .arr values => ", ".intercalate (values.map valueSummary).toList
  | .obj _ =>
    let field (name : String) := value.getObjVal? name |>.toOption
    match field "status", field "passed", field "total", field "submission", field "output" with
    | some (.str status), some passed, some total, _, _ => s!"{status} {passed.compress}/{total.compress}"
    | some (.str status), _, _, some (.str submission), _ =>
      if submission.isEmpty then status else s!"{status}: {flatten submission 60}"
    | some (.str status), _, _, _, _ => status
    | _, _, _, _, some (.str output) =>
      let status := match field "exit_code" with
        | some (.num code) => s!"exit {code}"
        | _ => "no status"
      let first := (output.splitOn "\n").find? (!·.trimAscii.isEmpty) |>.getD ""
      s!"{status}: {flatten first 60}"
    | _, _, _, _, _ => flatten value.compress
  | _ => flatten value.compress

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
  | .replied to reply => s!"replied to {to.render}: {flatten reply.toJson.compress 60}"
  | .assigned grader => s!"assigned grader {(flatten (argumentsSummary grader) 60).quote}"

/-- An event in a line. -/
def eventSummary : Event Agent → String
  | .arrived notice => noticeSummary notice
  | .heard _ notices =>
    if notices.isEmpty then "inbox: nothing" else s!"inbox: takes {notices.toList}"
  | .answered _ _ (.error error) => s!"failed: {flatten error}"
  | .answered _ (.sample _) (.ok (.response response)) =>
    if response.toolCalls.isEmpty then s!"sample → says {(flatten (response.content?.getD "") 60).quote}"
    else s!"sample → " ++ "; ".intercalate (response.toolCalls.map callSummary).toList
  | .answered _ (.exec command _) (.ok (.execution e)) =>
    let status := match e.output.exitCode?, e.output.error? with
      | some code, _ => s!"exit {code}"
      | none, some error => flatten error 40
      | none, none => "no status"
    s!"exec {flatten command 60} → {status}, {short e.workspace}"
  | .answered _ .time (.ok (.timing t)) =>
    s!"time {seconds t.spentMs}" ++ (t.budgetMs?.map (s!" of {seconds ·}") |>.getD "")
  | .answered _ (.external command image ..) (.ok (.external e)) =>
    let status := match e.exitCode?, e.error? with
      | some code, _ => s!"exit {code}"
      | none, some error => flatten error 40
      | none, none => "no status"
    s!"external {flatten command 50} in {flatten image 30} → {status}"
  | .answered .. => "answered"
  | .opened _ tool =>
    if tool.name == agentTool then
      let name (field : String) := (tool.arguments.getObjVal? field >>= (·.getObjVal? "name") >>=
        Json.getStr?).toOption.getD "?"
      s!"open agent: {name "agent"}, {name "model"}"
    else s!"open {tool.name} {(flatten (argumentsSummary tool.arguments) 60).quote}"
  | .returned _ value => s!"return {valueSummary value}"
  | .failed _ error => s!"fail: {flatten error}"
  | .stopped reason => s!"stopped: {flatten reason}"

/-- How a run whose agent is over stands, in a line: how the agent ended, and the verdict once
the run is graded — `done: fail 352/464`, `stopped: pass 2/2` — or what the agent gave, or why
it ended, while it is not. -/
def endingSummary (agent : AgentEnd) (verdict? : Option Json) : String :=
  let graded := verdict?.map valueSummary
  match agent with
  | .returned value => s!"done: {graded.getD (valueSummary value)}"
  | .failed error => s!"failed: {graded.getD (flatten error)}"
  | .stopped reason => s!"stopped: {graded.getD (flatten reason)}"

/-- What a run does next, in a line: how it is over, what it waits for, or what it asks. `agent?`
is how the agent ended, once it has. -/
def nextSummary (question? : Option Question) (agent? : Option AgentEnd) : Next Agent → String
  | .done value =>
    match agent? with
    | some agent => endingSummary agent (some value)
    | none => s!"done: {valueSummary value}"
  | .raised error => s!"failed: {flatten error}"
  | .waits frame =>
    match question?, agent? with
    | some question, _ => s!"waits for a reply: {flatten question.text 70}"
    | none, some agent => if frame.isEmpty then endingSummary agent none else s!"waits for a notice in {frame.render}"
    | none, none => if frame.isEmpty then "waits for a workspace" else s!"waits for a notice in {frame.render}"
  | .ask call => s!"next: {call.op.describe}"
  | .hears frame _ => s!"next: a read of the inbox in {frame.render}"
  | .opens _ tool => s!"next: open {tool.name}"
  | .returns frame _ => s!"next: the return of {frame.render}"
  | .fails frame _ => s!"next: the failure of {frame.render}"
  | .mismatch position => s!"broken: the event at {position} is no trace of the program"
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
  /-- On a root: the agent, the model, and the task, once the log has them. -/
  title? : Option String := none
  deriving Inhabited

/-- Every entry of the forest, as the tree shows it: what each log does next at its end, and on
each root the agent and the model of its run. -/
def rows (store : Store) (forest : Forest) : Result (Array Row) := do
  let rows ← walk store forest (#[] : Array Row) fun rows visit => do
    let isLeaf := (forest.childrenOf visit.hash).isEmpty
    let status? := if !isLeaf then none else match visit.next? with
      | some next => some (nextSummary visit.question? visit.agent? next)
      | none => some "the run cannot be read"
    pure (rows.push { hash := visit.hash, parent? := visit.entry.parent?, position := visit.position
                      summary := eventSummary visit.entry.event, status?
                      title? := if visit.position == 1 then visit.config?.map fun config =>
                        let name (json : Json) := (json.getObjVal? "name" >>= Json.getStr?).toOption.getD "?"
                        s!"{name config.agent}, {name config.model}" else none })
  -- A run's title is its root's.
  let titles : Std.HashMap Hash String := rows.foldl (init := {}) fun titles row =>
    match row.title?, row.parent? with
    | some title, some root => titles.insert root title
    | _, _ => titles
  pure <| rows.map fun row =>
    if row.parent?.isNone then { row with title? := titles.get? row.hash } else { row with title? := none }

/-- The forest as a tree of branches: a root and its run, then every stretch of entries with no
fork in it as one line — where it starts and ends, how many entries, the last event, and, at
the end of a log, what the run does next — and the stretches that fork from its end indented
under it. -/
partial def treeLines (rows : Array Row) : Array String := Id.run do
  let byHash : Std.HashMap Hash Row := rows.foldl (init := {}) fun m row => m.insert row.hash row
  let children : Std.HashMap Hash (Array Hash) := rows.foldl (init := {}) fun m row =>
    match row.parent? with
    | some parent => m.insert parent ((m.getD parent #[]).push row.hash)
    | none => m
  let kids (hash : Hash) := children.getD hash #[]
  -- The stretch from `hash` on, until a fork or an end.
  let rec stretch (hash : Hash) (length : Nat) : Hash × Nat :=
    match (kids hash).toList with
    | [only] => stretch only (length + 1)
    | _ => (hash, length)
  let rec lines (hash : Hash) (indent : String) : Array String :=
    let (last, length) := stretch hash 1
    let first := byHash.getD hash default
    let end' := byHash.getD last default
    let status := end'.status?.map (s!"  [{·}]") |>.getD ""
    let span := if length == 1 then short hash else s!"{short hash}..{short last}"
    let line := s!"{indent}{span}  {first.position}-{end'.position}  {end'.summary}{status}"
    (kids last).foldl (init := #[line]) fun out child => out ++ lines child (indent ++ "  ")
  let mut out := #[]
  for row in rows do
    if row.parent?.isNone then
      out := out.push s!"{short row.hash}  root  {row.title?.getD row.summary}"
      for child in kids row.hash do
        out := out ++ lines child "  "
  return out

end Alaya.Render
