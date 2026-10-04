/-- The last message of a request: what the model was shown last. -/
def Request.last (request : Request) : String :=
  match request.messages.getLast? with
  | some (.system text) | some (.user text) | some (.assistant text _) | some (.tool text) => text
  | none => ""

/-- A scripted model: it answers by the last message it is shown. -/
def script (request : Request) : Response :=
  match request.last with
  | "the task" => { text := "", toolCalls := [⟨"ask_user", "Which target?"⟩] }
  | "the default one" => { text := "", toolCalls := [⟨"bash", "make"⟩] }
  | "output of make" => { text := "", toolCalls := [⟨"commit", "fix"⟩] }
  | "run the tests" => { text := "", toolCalls := [⟨"time_budget", ""⟩, ⟨"bash", "pytest"⟩] }
  | "output of pytest" => { text := "48 tests pass" }
  | "error: exit 1: nothing to commit" => { text := "", toolCalls := [⟨"commit", "fix"⟩] }
  | "The workspace was changed: a person edited README" =>
    { text := "", toolCalls := [⟨"bash", "git diff"⟩] }
  | _ => { text := "done" }

/-- Whether a question waits for a reply that has not arrived: the last event, notices that are
no replies apart, is the opening of `ask_user`. -/
def asked (log : List (Event Agent)) : Bool :=
  let last := log.reverse.find? fun
    | .arrived (.said _) | .arrived (.changed ..) => false
    | _ => true
  last matches some (.opened _ ⟨"ask_user", _⟩)

/-- A scripted world. A person provides the workspace, which is the root of the run, gives the
task, replies when asked, and later edits a file in the workspace while the sub-agent is at
work. A command leaves a new version of the workspace, except `git diff`, which leaves it as
it was. The hidden tests, which only a grader runs, are four checks: one passes once the build
is made, and all once the fix is committed. -/
def world : World where
  model _ request := .ok (script request)
  execute version command :=
    { text := s!"output of {command}"
      workspace := if command == "git diff" then version
        else s!"w{(version.drop 1).toNat! + 1}" }
  external version _ _ :=
    let made := (version.drop 1).toNat!
    let passing := if made == 0 then 0 else if made < 5 then 1 else 4
    let line := fun (check, name) => s!"{if check < passing then "ok" else "not ok"} {check + 1} - {name}"
    { exit := if passing == 4 then 0 else 1
      stdout := "\n".intercalate (["builds", "parses", "evaluates", "reports errors"].zipIdx.map
        fun (name, check) => line (check, name))
      checkout := s!"{version}, graded"
      elapsedMs := 1200 }
  clock := (412000, some 3600000)
  arrivals log :=
    if log.isEmpty then [.changed "w0" "the repository"]
    else if log.length == 2 then [.said "the task"]
    else if log.length == 22 then [.changed "w2" "a person edited README"]
    else if !asked log then []
    else match reply log (.text "the default one") with
      | .ok (.arrived notice) => [notice]
      | _ => []

/-- A model that fails to answer the sub-agent's first request, the first time it is asked. -/
def failsOnce (log : List (Event Agent)) (request : Request) : Except String Response :=
  let failedBefore := log.any (· matches .answered _ (.error _))
  if request.last == "run the tests" && !failedBefore then .error "overloaded"
  else .ok (script request)

/-- What arrives in the scripted world while the log is no longer than `length`, and nothing
after that. -/
def upTo (length : Nat) (log : List (Event Agent)) : List Notice :=
  if log.length ≤ length then world.arrivals log else []

/-- A model that asks for a grader, which the run has and its conversation does not offer. -/
def overreaches (_ : List (Event Agent)) (request : Request) : Except String Response :=
  if request.last == "the task" then .ok { text := "", toolCalls := [⟨"hidden_tests", ""⟩] }
  else .ok (script request)

/-- A model that fails to answer that request every time. -/
def keepsFailing (_ : List (Event Agent)) (request : Request) : Except String Response :=
  if request.last == "run the tests" then .error "overloaded" else .ok (script request)

def Op.describe : Op → String
  | .sample request => s!"sample after \"{request.last}\""
  | .exec command => s!"exec {command}"
  | .time => "time"
  | .external command image input _ =>
    s!"external {command}, in {image}, with {input.getD "nothing"}"

def describe : Event Agent → String
  | .arrived (.said message) => s!"-  arrived: said {message}"
  | .arrived (.changed workspace _) => s!"-  arrived: changed → {workspace}"
  | .arrived (.replied to answer) => s!"-  arrived: replied to {to.toList}: {answer.render}"
  | .answered ⟨frame, .external command image ..⟩ (.ok ran) =>
    s!"{frame.toList}  answered: external {command}, in {image} → exit {ran.exit}, {ran.checkout}"
  | .answered ⟨frame, .exec command⟩ (.ok output) =>
    s!"{frame.toList}  answered: exec {command} → {output.workspace}"
  | .answered call (.ok _) => s!"{call.frame.toList}  answered: {call.op.describe}"
  | .answered call (.error error) =>
    s!"{call.frame.toList}  answered: {call.op.describe}: failed: {error}"
  | .opened frame tool => s!"{frame.toList}  opened: {tool.name} \"{tool.arguments}\""
  | .returned frame value => s!"{frame.toList}  returned: {value}"
  | .failed frame error => s!"{frame.toList}  failed: {error}"
  | .stopped reason => s!"-  stopped: {reason}"
  | .heard frame notices => s!"{frame.toList}  heard {notices}"

def describeNext : Next Agent Json → String
  | .done value => s!"done: {value}"
  | .ask call => s!"ask {call.frame.toList} {call.op.describe}"
  | .opens frame tool => s!"log the opening of {frame.toList}: {tool.name}"
  | .returns frame value => s!"log the return of {frame.toList}: {value}"
  | .fails frame error => s!"log the failure of {frame.toList}: {error}"
  | .raised error _ => s!"failed: {error}"
  | .hears frame notices => s!"mark the read of {frame.toList}, of {notices}"
  | .waits frame =>
    if frame.isEmpty then "wait: there is no workspace to start on"
    else s!"wait: {frame.toList} reads the inbox once something arrives"
  | .stopped _ => "stopped"
  | .mismatch position => s!"mismatch at {position}"
  | .unguarded frame => s!"unguarded loop in {frame.toList}"

/-- A run with another program for its agent. -/
def withAgent (run : Run Agent) (program : Program Agent Json) : Run Agent :=
  { run with tools := fun name =>
      if name == "agent" then some fun _ => program else run.tools name }

/-- Replay agrees with the run: wherever the driver asked, `next` of the log up to there is
the call that the log goes on to answer, or the mark it goes on to hold. -/
def faithful (run : Run Agent) (log : List (Event Agent)) : Bool :=
  (List.range (log.length + 1)).all fun i =>
    match log.drop i, next run (log.take i) with
    | .arrived _ :: _, _ => true
    | .answered call _ :: _, .ask asked => call.frame = asked.frame ∧ call.op = asked.op
    | .heard frame notices :: _, .hears reader taken => frame = reader ∧ notices = taken
    | .opened frame tool :: _, .opens entered called => frame = entered ∧ tool = called
    | .returned frame value :: _, .returns ended given => frame = ended ∧ value = given
    | .failed frame error :: _, .fails ended given => frame = ended ∧ error = given
    | [], .done _ => true
    | _, _ => false

#eval show IO Unit from do
  let run := graded
    { system := "You are a coding agent."
      agent := { tools := ["bash", "time_budget", "commit", "ask_user"], retries := 2 }
      model := { name := "a-model", maxTokens := 4096 } }
  let replay := fun log => describeNext (next run log)
  let same := fun (one other : List (Event Agent)) => one.map describe == other.map describe
  let (log, result) := drive world run []
  for (event, i) in log.zipIdx do IO.println s!"{i}  {describe event}"
  IO.println (describeNext result)
  IO.println s!"workspace {workspace log}"
  IO.println s!"replay agrees with the run wherever the driver asked: {faithful run log}"
  -- a state the run went through is graded by forking: the log up to there, stopped, and the
  -- graders follow as they follow any run
  let stoppedAt := fun position => log.take position ++ [.stopped "to grade this state"]
  IO.println "the states of the run, where the workspace is at a new version, forked and stopped:"
  for position in (versions log).filter (· < 42) do
    let (fork, grade) := drive world run (stoppedAt position)
    let version := workspace (log.take position)
    let more := fork.length - position
    IO.println s!"  at {position}, workspace {version}: {describeNext grade}, in {more} more events"
  IO.println "the fork stopped at 24:"
  for (event, i) in (drive world run (stoppedAt 24)).1.zipIdx do
    if i ≥ 23 then IO.println s!"  {i}  {describe event}"
  IO.println s!"the run itself is as it was: {same (drive world run log).1 log}"
  IO.println s!"the agent cannot go on after a stop: {replay (stoppedAt 24 ++ log.drop 24)}"
  IO.println s!"a stop once the agent is over: {replay (log.take 44 ++ [.stopped "x"])}"
  -- a question and its reply: the reply is of the form asked, and names the call that asked
  IO.println s!"a reply when no question waits: {repr ((reply log .yes).toOption.isSome)}"
  let asking := log.take 6
  IO.println s!"a reply of another form than asked: {repr ((reply asking .yes).toOption.isSome)}"
  IO.println s!"that the person cannot answer: {repr ((reply asking .unavailable).toOption.isSome)}"
  let wrong := asking ++ [.arrived (.replied #[0, 0] .yes)]
  IO.println s!"a reply of another form, put in the log: {replay wrong}"
  -- a question the person has not answered: the run stops, and goes on when the reply is there
  let (waiting, pending) := drive { world with arrivals := upTo 2 } run []
  IO.println s!"while the person has not replied: {describeNext pending}"
  IO.println s!"  and the log ends with: {(waiting.getLast?.map describe).getD ""}"
  IO.println s!"resumed to the same log: {same (drive world run waiting).1 log}"
  -- another notice while a question waits: it does not end the wait, and is not the answer
  let (interrupted, pending) := drive { world with arrivals := fun log =>
    if log.length == 6 then [.changed "w1" "a person edited README"] else upTo 2 log } run []
  IO.println s!"with another notice while a question waits: {describeNext pending}"
  IO.println s!"  and the log ends with: {(interrupted.getLast?.map describe).getD ""}"
  let (later, _) := drive world run interrupted
  for (event, i) in later.zipIdx do
    if 6 ≤ i ∧ i ≤ 10 then IO.println s!"  {i}  {describe event}"
  -- a command that fails: the failure passes through the frames of `bash` and `commit`, each
  -- marked in the log, to the conversation, which tells the model; the model calls `commit` again
  let flaky := { world with
    arrivals := fun log => if log.length == 22 then [] else world.arrivals log
    execute := fun version command =>
      if command.startsWith "git commit" ∧ version == "w3" then
        { text := "nothing to commit", workspace := "w4", exit := 1 }
      else world.execute version command }
  let (failing, ended) := drive flaky run []
  IO.println "with a commit that fails the first time:"
  for (event, i) in failing.zipIdx do
    if 30 ≤ i ∧ i ≤ 36 then IO.println s!"  {i}  {describe event}"
  IO.println s!"  and the run ends, after {failing.length} events: {describeNext ended}"
  -- a model that fails to answer: the answer logged is the error, and the conversation asks again
  let (once, ended) := drive { world with model := failsOnce } run []
  IO.println "with a model that fails to answer once:"
  for (event, i) in once.zipIdx do
    if 17 ≤ i ∧ i ≤ 19 then IO.println s!"  {i}  {describe event}"
  IO.println s!"  and the run ends, after {once.length} events: {describeNext ended}"
  -- a model that keeps failing: the sub-agent gives up, and its caller's model is told
  let (thrice, ended) := drive { world with model := keepsFailing } run []
  IO.println "with a model that keeps failing a sub-agent:"
  for (event, i) in thrice.zipIdx do
    if 17 ≤ i ∧ i ≤ 25 then IO.println s!"  {i}  {describe event}"
  IO.println s!"  and the run ends, after {thrice.length} events: {describeNext ended}"
  -- a tool the run does not have: its call fails, and the model that asked for it is told
  let (missing, _) := drive world { run with tools := fun name =>
    if name == "bash" then none else run.tools name } []
  IO.println "with a tool that the run does not have:"
  for (event, i) in missing.zipIdx do
    if 10 ≤ i ∧ i ≤ 14 then IO.println s!"  {i}  {describe event}"
  -- a tool the run has but the conversation did not offer: it is not called at all
  let (refused, _) := drive { world with model := overreaches } run []
  IO.println "with a model that asks for a tool it was not offered:"
  for (event, i) in refused.zipIdx do
    if 4 ≤ i ∧ i ≤ 6 then IO.println s!"  {i}  {describe event}"
  -- a failure that nothing catches ends the agent, and the run goes on to the graders
  let (broken, ended) := drive world (withAgent run (throw "no model")) []
  IO.println "with an agent that fails:"
  for (event, i) in broken.zipIdx do
    if i ≥ 3 then IO.println s!"  {i}  {describe event}"
  IO.println s!"  {describeNext ended}"
  let (_, ended) := drive world { run with after := fun _ => throw "no grader" } []
  IO.println s!"with graders that fail, the run ends: {describeNext ended}"
  -- with no workspace there is no run; with no task the agent does not start: it is opened,
  -- and waits
  let (empty, pending) := drive { world with arrivals := fun _ => [] } run []
  IO.println s!"with no workspace yet: {describeNext pending}, after {empty.length} events"
  let (idle, pending) := drive { world with arrivals := upTo 0 } run []
  IO.println s!"with no task yet: {describeNext pending}, after {idle.length} events"
  IO.println s!"resumed to the same log: {same (drive world run idle).1 log}"
  -- a crash while `pytest` ran: the call is asked for again, and the driver finishes the same run
  let crashed := log.take 24
  IO.println s!"after a crash at 24: {replay crashed}"
  IO.println s!"resumed to the same log: {same (drive world run crashed).1 log}"
  -- a log that is no trace of the program; what was expected is `next` of the log up to there
  let removed := log.take 18 ++ log.drop 19
  IO.println s!"an answer removed: {replay removed}"
  IO.println s!"  where the program would {replay (removed.take 18)}"
  IO.println s!"an answer left over: {replay (log ++ log.drop 45)}"
  IO.println s!"an opening removed: {replay (log.take 5 ++ log.drop 6)}"
  IO.println s!"a reply removed: {replay (log.take 6 ++ log.drop 7)}"
  IO.println s!"a return removed: {replay (log.take 8 ++ log.drop 9)}"
  IO.println s!"a read not marked: {replay (log.take 35 ++ log.drop 36)}"
  let unseen := log.take 35 ++ [.arrived (.said "stop")] ++ log.drop 35
  IO.println s!"a log with no root: {replay (log.drop 1)}"
  IO.println s!"a notice put in before a read: {replay unseen}"
  let spin : Program Agent Json := iter (fun (n : Nat) => pure (.inl (n + 1))) 0
  IO.println s!"a loop that reads nothing: {describeNext (next (withAgent run spin) log)}"
