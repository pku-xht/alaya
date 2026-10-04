import Alaya.Render
import Alaya.Workspaces
import Alaya.Agents.MiniSwe

/-!
A standalone HTML report of a forest of logs, for reading only: the data as JSON in a `<script>`
tag, with the page that renders it, so a report can be mailed or archived. Nothing on the page
runs anything: it shows what the logs hold, and what replay says of them.

The page shows the forest as the logs are. On the left, two lists of the same rows: the
branches of each run, by how each departs and how its log ends, and the log of the chosen
branch, one entry a row, indented by the frame of the call it is in, so a tool's events nest
under its opening, with a switch on every entry that has siblings, to the other branches that
fork there. On the right, the page of the chosen entry, the same for every kind: what it is and
the calls it happened in; a few facts — its time, a response's tokens and how full the model's
context was, a command's exit status; what it holds, as labelled blocks — a response's
reasoning and calls, a command and its output, a verdict's failed checks; then the request a
sample answered, what replay asks for there, and the files the entry changed; and, last, how
the run stands there: its time and tokens so far, and its workspace.

Requests are carried as what each adds to the one before it in the same frame, the way a
conversation grows, and whole only when an agent rewrote earlier messages, so a report is linear
in its logs. Workspace changes carry the text of the files they touch when that is cheap (small,
textual, and not obviously machine-generated), so the page can show a line diff.
-/

namespace Alaya.Html

open Lean (Json)
open Alaya.Workspaces (Change ChangeKind)

/-- Paths under these are listed but never carried, and never diffed line by line. -/
private def uninteresting : Array String :=
  #[".venv/", "__pycache__/", ".pytest_cache/", ".git/", "node_modules/", ".mypy_cache/"]

private def isUninteresting (path : String) : Bool :=
  uninteresting.any fun prefix' => (path.splitOn prefix').length > 1

/-- Largest file whose content is carried into the report, in bytes. -/
private def contentLimit : Nat := 60000

/-- Most changed paths listed for one entry. -/
private def changeLimit : Nat := 300

/-- Whether `path` lies under one of the folded prefixes, and which. -/
private def foldedUnder? (hidden : Array String) (path : String) : Option String :=
  hidden.find? fun prefix' => path == prefix' || path.startsWith (prefix' ++ "/")

private def jsonText? (bytes? : Option ByteArray) : Option String :=
  match bytes? with
  | none => none
  | some bytes =>
    if bytes.size > contentLimit then none
    else match String.fromUTF8? bytes with
      | some text => if text.any (· == '\x00') then none else some text
      | none => none

/-- The text of `paths` in a snapshot, read in one request. -/
private def readTexts (workspaces : Workspaces) (root : Snapshot) (paths : Array String) :
    Result (Std.HashMap String String) := do
  if paths.isEmpty then return {}
  let contents ← workspaces.readFiles root paths
  pure <| (paths.zip contents).foldl (init := {}) fun texts (path, bytes?) =>
    match jsonText? bytes? with
    | some text => texts.insert path text
    | none => texts

/-- What changed from `before` to `after`: each change with the before and after text when both
are cheap to carry, directories under `hidden` counted rather than listed, and at most
`changeLimit` paths. -/
private def changesJson (workspaces : Workspaces) (hidden : Array String) (before after : Snapshot) :
    Result Json := do
  let changes ← workspaces.diff before after
  let mut folds : Std.HashMap String (Nat × Nat × Nat) := {}
  let mut listed : Array Change := #[]
  for change in changes do
    match foldedUnder? hidden change.path with
    | none => listed := listed.push change
    | some prefix' =>
      let (a, r, m) := folds.getD prefix' (0, 0, 0)
      folds := folds.insert prefix' <| match change.kind with
        | .added => (a + 1, r, m) | .removed => (a, r + 1, m) | .modified => (a, r, m + 1)
  let shown := listed.extract 0 changeLimit
  let carried := shown.filter fun change => !isUninteresting change.path && !change.directory
  let pathsWhere (keep : Change → Bool) := (carried.filter keep).map (·.path)
  let old ← readTexts workspaces before (pathsWhere (·.kind != .added))
  let new ← readTexts workspaces after (pathsWhere (·.kind != .removed))
  let rows := shown.map fun change =>
    let kind := match change.kind with
      | .added => "added" | .removed => "removed" | .modified => "modified"
    let text (texts : Std.HashMap String String) (absent : ChangeKind) : Json :=
      if change.directory || change.kind == absent then .null
      else texts.get? change.path |>.map Json.str |>.getD .null
    Json.mkObj [("path", change.path), ("kind", kind), ("old", text old .added), ("new", text new .removed)]
  let folded := hidden.filterMap fun prefix' => folds.get? prefix' |>.map fun (a, r, m) =>
    Json.mkObj [("prefix", prefix'), ("added", a), ("removed", r), ("modified", m)]
  pure <| .mkObj [("count", changes.size), ("listed", listed.size), ("changes", .arr rows),
    ("folded", .arr folded)]

/-! ## Entries as the page reads them -/

private def orNull (value? : Option α) (write : α → Json) : Json := value?.map write |>.getD .null

private def callJson (call : Chat.ToolCall) : Json :=
  .mkObj [("id", call.id), ("name", call.name),
    ("arguments", call.invalidArguments?.map Json.str |>.getD call.arguments),
    ("summary", Render.argumentsSummary call.arguments)]

private def usageJson (usage : Chat.TokenUsage) : Json :=
  .mkObj [("input", orNull usage.input? (fun n => (n : Json))),
    ("output", orNull usage.output? (fun n => (n : Json))),
    ("cached", orNull usage.cached? (fun n => (n : Json))),
    ("reasoning", orNull usage.reasoning? (fun n => (n : Json)))]

/-- An event by what a reader needs of it, under `k`, its kind. -/
def eventJson : Event Agent → Json
  | .arrived (.said message) => .mkObj [("k", "said"), ("text", message)]
  | .arrived (.changed workspace summary) =>
    .mkObj [("k", "changed"), ("workspace", workspace.hex), ("text", summary)]
  | .arrived (.replied to reply) =>
    .mkObj [("k", "replied"), ("to", to.toJson), ("text", reply.toJson.compress)]
  | .arrived (.assigned grader) =>
    .mkObj [("k", "assigned"), ("grader", grader), ("summary", Render.argumentsSummary grader)]
  | .heard _ notices => .mkObj [("k", "heard"), ("notices", .arr (notices.map fun (n : Nat) => (n : Json)))]
  | .answered _ key (.error error) =>
    let op := match key with
      | .sample _ => "sample" | .exec .. => "exec" | .time => "time" | .external .. => "external"
    .mkObj [("k", op), ("error", error)]
  | .answered _ _ (.ok (.response r)) =>
    .mkObj [("k", "sample"), ("content", orNull r.content? .str), ("reasoning", orNull r.reasoning? .str),
      ("encrypted", r.reasoningItems.size), ("finish", orNull r.finishReason? .str),
      ("calls", .arr (r.toolCalls.map callJson)), ("usage", orNull r.usage? usageJson)]
  | .answered _ key (.ok (.execution e)) =>
    let (command, timeout) := match key with
      | .exec command config => (command, config.timeoutSeconds)
      | _ => ("", 0)
    .mkObj [("k", "exec"), ("command", command), ("timeout", timeout), ("output", e.output.output),
      ("exit", orNull e.output.exitCode? fun c => (c.toNat : Json)), ("failure", orNull e.output.error? .str),
      ("workspace", e.workspace.hex), ("file", orNull e.file? .str)]
  | .answered _ _ (.ok (.timing t)) =>
    .mkObj [("k", "time"), ("spent", t.spentMs), ("budget", orNull t.budgetMs? fun n => (n : Json))]
  | .answered _ key (.ok (.external e)) =>
    let (command, image, input?) := match key with
      | .external command image input? _ => (command, image, input?)
      | _ => ("", "", none)
    .mkObj [("k", "external"), ("command", command), ("image", image), ("input", orNull input? (Json.str ·.hex)),
      ("exit", orNull e.exitCode? fun c => (c : Json)), ("stdout", e.stdout), ("stderr", e.stderr),
      ("checkout", e.checkout.hex), ("elapsed", e.elapsedMs), ("failure", orNull e.error? .str)]
  | .opened _ call =>
    .mkObj [("k", "open"), ("routine", call.name), ("arguments", call.arguments),
      ("summary", Render.argumentsSummary call.arguments)]
  | .returned _ value => .mkObj [("k", "return"), ("value", value), ("summary", Render.valueSummary value)]
  | .failed _ error => .mkObj [("k", "fail"), ("error", error)]
  | .stopped reason => .mkObj [("k", "stop"), ("text", reason)]
  | .commented _ text => .mkObj [("k", "comment"), ("text", text)]

/-- What the walk keeps of the forest for the page. -/
private structure Acc where
  rows : Array Json := #[]
  index : Std.HashMap Hash Nat := {}
  /-- Per entry, the request a sample answered, as replay asks for it. -/
  requests : Array (Option Chat.Request) := #[]
  /-- Per entry, its parent's index and its frame. -/
  parents : Array (Option Nat) := #[]
  frames : Array (Option Frame) := #[]
  /-- The entries that change the files a reader sees, with the versions before and after. -/
  diffs : Array (Nat × Snapshot × Snapshot) := #[]
  /-- The context size of the model of the run of each entry, when known. -/
  contextSizes : Array (Option Nat) := #[]

private def wireOf (dialogue : Array Chat.Message) : Array String := dialogue.map (·.toJson.compress)

/-- A request minus its messages: the tools, the tool choice, and the response format, exactly
as `Chat.Request.toJson` lays them out. -/
private def envelope (request : Chat.Request) : Json :=
  ({ request with messages := #[] } : Chat.Request).toJson

/-- Everything the page renders, as one JSON document. -/
def dataJson (store : Store) (workspaces : Workspaces) (forest : Forest) (title : String)
    (hidden : Array String := #[]) : Result Json := do
  let hidden := hidden.map fun prefix' =>
    if prefix'.endsWith "/" then (prefix'.dropEnd 1).toString else prefix'
  let acc ← walk store forest ({} : Acc) fun acc visit => do
    let i := acc.rows.size
    let parent? := visit.entry.parent?.bind acc.index.get?
    let event := visit.entry.event
    let leaf := (forest.childrenOf visit.hash).isEmpty
    let next? : Option String := if leaf then
        some ((visit.next?.map (Render.nextSummary visit.question? visit.agent?)).getD "the run cannot be read")
      else none
    -- A run whose agent is over, graded or waiting for a grader, stands as its agent ended.
    let over := match visit.next? with
      | some (.done _) | some (.raised _) | some (.waits #[]) => true
      | _ => false
    let state : Option String := if !leaf then none else match visit.next?, visit.agent? with
      | some (.mismatch _), _ | some (.unguarded _), _ | none, _ => some "broken"
      | some _, some (.returned _) => if over then some "done" else some "paused"
      | some _, some (.failed _) => if over then some "failed" else some "paused"
      | some _, some (.stopped _) => if over then some "stopped" else some "paused"
      | some (.done _), none => some "done" | some (.raised _), none => some "failed"
      | some (.waits _), none => some (if visit.question?.isSome then "question" else "waits")
      | _, none => some "paused"
    -- On an entry that ends a graded log: the verdict, in a line.
    let graded : Option String := if !leaf then none else match visit.next? with
      | some (.done verdict) => some (Render.valueSummary verdict)
      | some (.raised error) => some s!"error: {Render.flatten error 40}"
      | _ => none
    let config := match visit.config?, event with
      | some config, .opened #[0] _ => config.toJson
      | _, _ => .null
    let row := Json.mkObj [
      ("h", visit.hash.hex), ("p", orNull parent? fun n => (n : Json)), ("pos", visit.position),
      ("f", orNull event.frame? Frame.toJson), ("e", eventJson event),
      ("t", visit.entry.elapsedMs), ("run", visit.spentMs), ("usage", usageJson visit.usage),
      ("ws", orNull visit.workspace? (Json.str ·.hex)), ("next", orNull next? .str),
      ("state", orNull state .str), ("graded", orNull graded .str), ("config", config),
      ("question", orNull visit.question? fun q => .mkObj [("text", q.text), ("form", q.form.name),
        ("options", .arr (q.form.options.map Json.str))])]
    let request? := match visit.asked? with
      | some { op := .sample request, .. } => some request
      | _ => none
    let diff? : Option (Snapshot × Snapshot) := match event, visit.before?, visit.workspace? with
      | .answered _ _ (.ok (.external ran)), _, some workspace => some (workspace, ran.checkout)
      | _, some before, some after => some (before, after)
      | _, _, _ => none
    let contextSize? := visit.config?.bind (Models.read ·.model |>.toOption) |>.bind (·.contextTokens?)
    pure { acc with
      rows := acc.rows.push row, index := acc.index.insert visit.hash i
      requests := acc.requests.push request?, parents := acc.parents.push parent?
      frames := acc.frames.push event.frame?
      diffs := match diff? with
        | some (before, after) => acc.diffs.push (i, before, after)
        | none => acc.diffs
      contextSizes := acc.contextSizes.push contextSize? }
  -- A sample's request, as what it adds to the request of the nearest sample above it in the
  -- same frame — the same conversation — or whole when it rewrote earlier messages.
  let mut envelopes : Array Json := #[]
  let mut requests : Array Json := #[]
  for i in [:acc.rows.size] do
    let some request := acc.requests[i]! | requests := requests.push .null
    let frame := acc.frames[i]!
    let mut above : Option Nat := acc.parents[i]!
    while true do
      match above with
      | none => break
      | some j =>
        if acc.requests[j]!.isSome && acc.frames[j]! == frame then break
        above := acc.parents[j]!
    let base? : Option (Nat × Chat.Request) := above.bind fun j => acc.requests[j]!.map (j, ·)
    let full := request.messages
    let (from?, added) := match base? with
      | some (j, base) =>
        let before := base.messages
        if before.size <= full.size && wireOf (full.extract 0 before.size) == wireOf before
        then (some j, full.extract before.size full.size) else (none, full)
      | none => (none, full)
    let shape := envelope request
    let e := (envelopes.findIdx? (·.compress == shape.compress)).getD envelopes.size
    if e == envelopes.size then envelopes := envelopes.push shape
    -- What the request held: the provider's count, or an estimate when it gave none.
    let reported? := match acc.rows[i]!.getObjVal? "e" >>= (·.getObjVal? "usage") >>=
        (·.getObjVal? "input") >>= Json.getNat? with
      | .ok n => some n
      | .error _ => none
    let tokens := reported?.getD (Agents.MiniSwe.estimateTokens full)
    requests := requests.push <| .mkObj [
      ("base", orNull from? fun n => (n : Json)), ("added", .arr (added.map (·.toJson))),
      ("size", full.size), ("envelope", e), ("tokens", tokens), ("estimated", reported?.isNone),
      ("window", orNull acc.contextSizes[i]! fun n => (n : Json))]
  -- A few diffs at a time: each costs the snapshot store a diff and two reads, which for restic
  -- are processes that mostly wait.
  let mut changes : Std.HashMap Nat Json := {}
  let mut rest := acc.diffs
  while !rest.isEmpty do
    let tasks ← (rest.extract 0 8).mapM fun (i, before, after) => Result.fromIO Error.storage <|
      IO.asTask (prio := .dedicated) ((fun json => (i, json)) <$> changesJson workspaces hidden before after).toBaseIO
    for task in tasks do
      match task.get with
      | .ok (.ok (i, json)) => changes := changes.insert i json
      | .ok (.error error) => throw error
      | .error error => throw <| .storage (toString error)
    rest := rest.extract 8 rest.size
  let rows := acc.rows.mapIdx fun i row =>
    let row := row.setObjVal! "request" requests[i]!
    row.setObjVal! "changes" (changes.getD i .null)
  pure <| .mkObj [("title", title), ("entries", .arr rows), ("envelopes", .arr envelopes)]

def styles : String := include_str "Html/page.css"
def script : String := include_str "Html/page.js"

/-- The page around `data`: the styles, the data, and the script that renders it. -/
def page (title : String) (data : Json) : String :=
  -- `</` cannot appear inside a script element; the JSON parser does not mind the escape.
  let safe := data.compress.replace "</" "<\\/"
  let title := ((title.replace "&" "&amp;").replace "<" "&lt;").replace ">" "&gt;"
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" ++
  "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n" ++
  "<title>" ++ title ++ "</title>\n<style>\n" ++ styles ++ "\n</style></head>\n<body>\n" ++
  "<div id=\"layout\">" ++
  "<div id=\"side\"><div id=\"tools\">" ++
  "<input id=\"find\" placeholder=\"find in this log (enter for next)\" spellcheck=\"false\">" ++
  "<span id=\"found\"></span></div>" ++
  "<div id=\"branches\"></div><div id=\"log\"></div></div>" ++
  "<div id=\"detail\"></div></div>\n" ++
  "<script id=\"data\" type=\"application/json\">" ++ safe ++ "</script>\n" ++
  "<script>\n" ++ script ++ "\n</script>\n</body></html>\n"

/-- Renders every log of the forest as one standalone page. Paths under `hidden` are counted
rather than listed, so a directory that changes constantly and means nothing — a virtual
environment, a bytecode cache — is reported without burying the rest. -/
def report (store : Store) (workspaces : Workspaces) (forest : Forest) (title : String)
    (hidden : Array String := #[]) : Result String := do
  pure (page title (← dataJson store workspaces forest title hidden))

end Alaya.Html
