import Alaya.Trajectory

/-! Rendering a trajectory as text for `show`, `tree` and `diff`, and its token counts. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Effect CallRef Question Reply)

/-! ## Rendering: generic over tools — a call by name and arguments, an observation by its
content. -/

private def take (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

private def short (h : Hash) : String := take h.hex 12

private def flatten (s : String) (limit : Nat := 60) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then take flat (limit - 3) ++ "..." else flat

/-- The arguments of a call as one string: the value of the one string field, or of a string
`command` field beside others — the shapes a command tool takes — otherwise the compact JSON, or
the raw text when it did not parse. -/
def argumentsSummary (call : Chat.ToolCall) : String :=
  match call.invalidArguments? with
  | some raw => raw
  | none =>
    match call.arguments with
    | .obj fields =>
      match fields.foldl (fun (acc : Array (String × Lean.Json)) k v => acc.push (k, v)) #[] with
      | #[(_, Lean.Json.str value)] => value
      | _ =>
        match call.arguments.getObjVal? "command" with
        | .ok (Lean.Json.str command) => command
        | _ => call.arguments.compress
    | other => other.compress

/-- `name  arguments`, flattened to one line. -/
def callSummary (call : Chat.ToolCall) : String :=
  call.name ++ "  " ++ flatten (argumentsSummary call)

private def observationText : Lean.Json -> String
  | .str s => s
  | other => other.pretty

private def label (state : State) : String :=
  match state.kind with
  | .root root =>
    let nameOf (json : Lean.Json) := (json.getObjVal? "name" >>= Lean.Json.getStr?).toOption
    let run := match nameOf root.agent, nameOf root.model with
      | some agent, some model => s!"[{agent}, {model}]  "
      | _, _ => ""
    "root  " ++ run ++ flatten (root.task?.getD "")
  | .step .. =>
    let calls := state.calls
    let first := match calls[0]? with
      | some call => callSummary call
      -- A step that sampled nothing says why: the provider's refusal, in its outcome.
      | none => match state.outcome?.bind (·.reason?), state.appended.isEmpty with
        | some reason, true => "step  " ++ flatten reason
        | _, _ => "step  (no tool call)"
    let more := if calls.size > 1 then s!"  (+{calls.size - 1})" else ""
    first ++ more
  | .intervention { changed := #[], message } => "tell  " ++ flatten message
  -- A commit is labelled by what the person said of it, or by what it changed.
  | .intervention { changed, message } =>
    let changes := (changed[0]?.getD "") ++ (if changed.size > 1 then s!"  (+{changed.size - 1})" else "")
    "commit  " ++ (if message.isEmpty then changes else flatten message)
  | .reply =>
    let text := match state.appended[0]? with
      | some (Event.recorded _ (Lean.Json.str s)) => s
      | some (Event.recorded _ other) => other.compress
      | _ => ""
    "reply  " ++ flatten text
  | .evaluation e => s!"eval  [{e.verdict}]  " ++ flatten e.command

private def outcomeSuffix (state : State) : String :=
  match state.outcome? with
  | some o => s!"  [{o.status}]"
  | none => ""

/-! ## Tokens -/

private def addCounts (a b : Option Nat) : Option Nat :=
  match a, b with
  | some a, some b => some (a + b)
  | some n, none | none, some n => some n
  | none, none => none

/-- Two usages added; a count stays unknown only where neither reported it. -/
def addUsage (a b : Chat.TokenUsage) : Chat.TokenUsage :=
  { input? := addCounts a.input? b.input?, output? := addCounts a.output? b.output?
    total? := addCounts a.total? b.total?, reasoning? := addCounts a.reasoning? b.reasoning?
    cached? := addCounts a.cached? b.cached? }

/-- What a state's responses cost, as the provider reported when it first produced them; `none`
for a state with no response. -/
def State.usage? (state : State) : Option Chat.TokenUsage :=
  state.appended.foldl (init := none) fun acc event =>
    match event with
    | .sampled _ _ r => some (addUsage (acc.getD {}) (r.usage?.getD {}))
    | _ => acc

/-- What the run's responses cost from the root to `hash`. A response alaya's own cache replayed
cost nothing again, but carries what it cost when it was first sampled. -/
def runUsage (store : Store) (hash : Hash) : Result Chat.TokenUsage := do
  pure ((← ancestors store hash).foldl (fun acc (_, state) => addUsage acc (state.usage?.getD {})) {})

private def count (n : Nat) : String :=
  if n < 1000 then toString n
  else if n < 1000000 then s!"{n / 1000}.{(n % 1000) / 100}k"
  else s!"{n / 1000000}.{(n % 1000000) / 100000}M"

/-- `in 48.2k, 41.9k cached; out 1.1k, 0.8k reasoning`, with what was not reported left out. -/
def tokens (usage : Chat.TokenUsage) : String :=
  let side (name : String) (n? : Option Nat) (part? : Option Nat) (partName : String) : List String :=
    match n? with
    | some n => [s!"{name} {count n}" ++ (part?.map (s!", {count ·} {partName}") |>.getD "")]
    | none => []
  "; ".intercalate (side "in" usage.input? usage.cached? "cached" ++
    side "out" usage.output? usage.reasoning? "reasoning")

/-- Milliseconds as seconds with one decimal: `12.3 s`. -/
def seconds (ms : Nat) : String := s!"{ms / 1000}.{(ms % 1000) / 100} s"

/-- Renders the whole forest as indented lines, each `<short-hash> <label> [outcome]`. -/
partial def treeLines (store : Store) : Result (Array String) := do
  let states ← allStates store
  let mut roots := #[]
  for h in states do
    if (← getState store h).parent? == none then roots := roots.push h
  let rec render (hash : Hash) (depth : Nat) : Result (Array String) := do
    let state ← getState store hash
    let kids ← children store hash
    let indent := String.join (List.replicate depth "  ")
    -- A question is waiting until some child answers it.
    let mut waitingMark := ""
    if state.question?.isSome then
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind matches .reply)
      if !answered then waitingMark := "  [Waiting]"
    let measures := (state.elapsedMs?.map seconds).toList ++
      (state.usage?.map tokens |>.filter (!·.isEmpty)).toList
    let time := if measures.isEmpty then "" else s!"  ({"; ".intercalate measures})"
    let line := s!"{indent}{short hash}  {label state}{outcomeSuffix state}{waitingMark}{time}"
    let mut lines := #[line]
    for kid in kids do
      lines := lines ++ (← render kid (depth + 1))
    pure lines
  let mut lines := #[]
  for root in roots do
    lines := lines ++ (← render root 0)
  pure lines

/-- A response's reasoning as `show` gives it: the text, and of encrypted items only their size. -/
private def reasoningLines (r : Chat.Response) : Array String :=
  let text := match r.reasoning? with
    | some text => if text.isEmpty then #[] else #["[reasoning] " ++ text]
    | none => #[]
  let size := r.reasoningItems.foldl (fun n item => n + item.compress.length) 0
  if r.reasoningItems.isEmpty then text
  else text.push s!"[reasoning items] {r.reasoningItems.size}, {size} characters, encrypted"

/-- One event as lines: who, then what. A call is shown by its id, which `index`, of the log the
event is in, gives. -/
private def eventLines (index : Agent.Index) : Event -> Array String
  | .told m =>
    match m with
    | .system c => #["[system]", c]
    | .user c => #["[user]", c]
    | .assistant c? calls _ _ =>
      #["[assistant]", c?.getD ""] ++ calls.map fun call => "[call] " ++ callSummary call
    | .tool id content => #[s!"[tool {id}]", observationText content]
  | .placed snapshot => #[s!"[placed] {snapshot.hex}"]
  | .sampled _ purpose r =>
    #[if purpose == Agent.Purpose.turn then "[sampled]" else s!"[sampled: {purpose}]"] ++
      reasoningLines r ++ #[r.content?.getD ""] ++
      r.toolCalls.map fun call => "[call] " ++ callSummary call
  | .executed call _ _ output snapshot =>
    #[s!"[executed {(index.callId? call).getD (toString call)}] workspace {snapshot.hex}",
      observationText output.toJson]
  | .recorded call content =>
    #[s!"[recorded {(index.callId? call).getD (toString call)}]", observationText content]
  | .timed runTimeMs budgetMs? =>
    #[s!"[timed] the run at {seconds runTimeMs}" ++ (budgetMs?.map (s!" of {seconds ·}") |>.getD "")]

/-- The request the step at `hash` was sampled from, as `agent` makes it
(`Agent.requestAt?`): `none` when the state sampled nothing, or the agent no longer makes the
request its response records. -/
def stepRequest? (store : Store) (agent : Agent) (hash : Hash) : Result (Option Chat.Request) := do
  let branch ← branchOf store hash
  let (_, tip) := branch.tip
  let log := branch.log
  -- A step that sampled did so first: its response is where its events begin in the log.
  pure <| if tip.sampled then agent.requestAt? log (log.size - tip.appended.size) else none

/-- Renders a state for `show`: metadata, then the full reconstructed log — what happened — and,
given `request?`, the request its step was sampled from (`stepRequest?`), `none` within it when
it sampled nothing. -/
def showLines (store : Store) (hash : Hash) (request? : Option (Option Chat.Request) := none) :
    Result (Array String) := do
  let state ← getState store hash
  let log ← logOf store hash
  let mut lines := #[
    s!"state    {hash.hex}",
    s!"kind     {state.kind.toString}",
    s!"parent   {state.parent?.map (·.hex) |>.getD "(root)"}",
    s!"workspace {state.workspace.hex}"]
  let run ← runOf store hash
  if let some root := state.root? then
    if let some task := root.task? then lines := lines.push s!"task     {task}"
  lines := lines.push s!"image    {run.image}"
  lines := lines.push s!"workdir  {run.workdir}"
  if let some root := state.root? then
    lines := lines.push s!"agent    {root.agent.compress}"
    lines := lines.push s!"model    {root.model.compress}"
  if let some ms := state.elapsedMs? then lines := lines.push s!"elapsed  {seconds ms}"
  let total ← elapsedMs store hash
  if total > 0 then lines := lines.push s!"run time {seconds total}, from the root"
  if let some usage := state.usage? then lines := lines.push s!"tokens   {tokens usage}"
  let run := tokens (← runUsage store hash)
  if !run.isEmpty then lines := lines.push s!"run tokens {run}, from the root"
  if let some e := state.evaluation? then
    lines := lines.push s!"grader   {e.command}"
    lines := lines.push s!"grader image {e.graderImage}"
    lines := lines.push s!"checkout {e.checkout.hex}"
    if let some input := e.input? then lines := lines.push s!"input    {input.hex}"
    let exit := e.returncode?.map (s!"exit {·}") |>.getD "no exit status"
    lines := lines.push s!"verdict  {e.verdict} ({exit}, {e.elapsedMs} ms)"
    if !e.reason.isEmpty then lines := lines.push s!"reason   {e.reason}"
    if !e.checks.isEmpty then
      lines := lines.push "--- checks ---"
      for c in e.checks do
        let directive := if c.directive.isEmpty then "" else s!"  # {c.directive}"
        lines := lines.push s!"{if c.ok then "ok    " else "not ok"}  {c.name}{directive}"
    lines := lines.push "--- grader stdout ---"
    lines := lines.push e.stdout
    if !e.stderr.isEmpty then
      lines := lines.push "--- grader stderr ---"
      lines := lines.push e.stderr
  if let some o := state.outcome? then
    lines := lines.push s!"outcome  {o.status}"
    if let some reason := o.reason? then lines := lines.push s!"reason   {reason}"
    if o.submission != "" then lines := lines.push s!"submission:\n{o.submission}"
  if let some q := state.question? then lines := lines.push s!"question {q.render}"
  if let some i := state.intervention? then lines := lines.push s!"message  {i.message}"
  lines := lines.push "--- log ---"
  let index := log.index
  for event in log do
    lines := lines ++ eventLines index event
  match request? with
  | none => pure ()
  | some none => lines := lines.push "--- request: none; this state sampled nothing ---"
  | some (some request) =>
    lines := lines.push "--- request: what this step was sampled from ---"
    for message in request.messages do
      lines := lines ++ eventLines index (.told message)
  pure lines

/-- The changes from `a`'s files to `b`'s (`State.snapshot`). -/
def diffLines (store : Store) (workspaces : Workspaces) (a b : Hash) : Result (Array String) := do
  let sa ← getState store a
  let sb ← getState store b
  changedLines workspaces sa.snapshot sb.snapshot

end Alaya.Trajectory
