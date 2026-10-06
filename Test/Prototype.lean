import Alaya.Replay
import Test.Framework
import Test.Frames

/-! The sketch the design began as, run on Alaya's interpreter: its signature, its programs,
its scripted world and its driver, transliterated, must print what the sketch printed
(`Test/Prototype/expected.txt`). Every way a log can
be read — a fork that is stopped, a question that waits, a failure that is caught, a log that is
no trace of the program — is checked against the sketch, line for line.

One line departs from the sketch on purpose. The sketch could stop its agent alone; in Alaya a
stop ends whichever call of the run is running, so a stop while the sketch's run grades ends the
grading, and the run's routine fails with it. -/

namespace PrototypeTests

open Alaya
open Lean (Json)

/-! ## The sketch's stubs -/

def txt : Json → String
  | .str s => s
  | json => json.compress

inductive Message where
  | system (text : String) | user (text : String)
  | assistant (text : String) (calls : List RoutineCall) | tool (result : String)
  deriving BEq
abbrev Dialogue := List Message
structure ModelConfig where
  name : String
  maxTokens : Nat
  deriving BEq
structure AgentConfig where
  tools : List String
  retries : Nat
structure Config where
  system : String
  agent : AgentConfig
  model : ModelConfig
def Config.json (config : Config) : Json :=
  .str (s!"system: \"{config.system}\", " ++
    s!"agent: tools {config.agent.tools}, retries {config.agent.retries}, " ++
    s!"model: {config.model.name}, max tokens {config.model.maxTokens}")
structure Request where
  model : ModelConfig
  messages : Dialogue
  tools : List String
  deriving BEq
inductive Form where
  | yesNo | choice (options : List String) | openEnded
structure Question where
  text : String
  form : Form
def Question.parse (arguments : String) : Except String Question :=
  if arguments.startsWith "yes_no: " then pure ⟨(arguments.drop 8).toString, .yesNo⟩
  else if arguments.startsWith "choice: " then
    match (arguments.drop 8).toString.splitOn " | " with
    | text :: first :: second :: more => pure ⟨text, .choice (first :: second :: more)⟩
    | _ => throw "a choice needs at least two options"
  else pure ⟨arguments, .openEnded⟩
def Question.accepts (question : Question) : Reply → Bool
  | .unavailable => true
  | .yes | .no => (question.form matches .yesNo)
  | .noneOfAbove => (question.form matches .choice _)
  | .choice number =>
    match question.form with
    | .choice options => 1 ≤ number && number ≤ options.length
    | _ => false
  | .text answer => (question.form matches .openEnded) && !answer.isEmpty
def render : Reply → String
  | .yes => "yes" | .no => "no" | .choice number => toString number
  | .noneOfAbove => "none_of_above" | .text answer => answer | .unavailable => "unavailable"
structure Response where
  text : String
  toolCalls : List RoutineCall := []
structure Output where
  text : String
  workspace : Snapshot
  exit : Nat := 0
structure ExternalOutput where
  exit : Nat
  stdout : String
  checkout : Snapshot
  elapsedMs : Nat

/-! ## The sketch's signature -/

inductive Op where
  | sample (request : Request)
  | exec (command : String)
  | time
  | external (command image : String) (input : Option Snapshot) (timeout : Nat)
  deriving BEq

def Op.Answer : Op → Type
  | .sample _ => Response
  | .exec _ => Output
  | .time => Nat × Option Nat
  | .external .. => ExternalOutput

inductive Stored where
  | response (r : Response) | output (o : Output) | time (t : Nat × Option Nat)
  | external (e : ExternalOutput)

def store : (op : Op) → op.Answer → Stored
  | .sample _, r => .response r
  | .exec _, o => .output o
  | .time, t => .time t
  | .external .., e => .external e

def read : (op : Op) → Stored → Option op.Answer
  | .sample _, .response r => some r
  | .exec _, .output o => some o
  | .time, .time t => some t
  | .external .., .external e => some e
  | _, _ => none

abbrev Agent : Signature :=
  { Op, Answer := Op.Answer, Key := Op, key := id, sameKey := (· == ·), Stored, store, read }

def perform (op : Op) : Computation Agent op.Answer := Alaya.perform (σ := Agent) op

/-! ## The sketch's programs -/

structure Tool where
  name : String
  run : Json → Computation Agent Json

def bash : Tool where
  name := "bash"
  run command := do
    let output ← perform (.exec (txt command))
    if output.exit != 0 then throw s!"exit {output.exit}: {output.text}"
    return .str output.text

def timeBudget : Tool where
  name := "time_budget"
  run _ := do
    let (spent, budget?) ← perform .time
    return .str <| match budget? with
      | some budget => s!"{(budget - spent) / 1000} s left"
      | none => "no limit"

def noticeText : Notice → String
  | .said message => message
  | .changed _ summary => s!"The workspace was changed: {summary}"
  | .replied _ reply => render reply
  | .called call => s!"{call.name} was called"

def askUser : Tool where
  name := "ask_user"
  run arguments := do
    let question ← match Question.parse (txt arguments) with
      | .ok question => pure question
      | .error problem => throw problem
    let replies ← await fun frame notice =>
      match notice with
      | .replied to reply => to == frame && question.accepts reply
      | _ => false
    return .str ("\n".intercalate (replies.map noticeText))

def round (agent : AgentConfig) (model : ModelConfig) (listen : Bool) (dialogue : Dialogue) :
    Computation Agent (Dialogue ⊕ String) := do
  let request := { model, messages := dialogue, tools := agent.tools }
  let response ← retry agent.retries (perform (.sample request))
  if response.toolCalls.isEmpty then return .inr response.text
  let mut results := []
  for asked in response.toolCalls do
    let result ←
      if agent.tools.contains asked.name then
        -- The sketch calls a routine a tool, and its interpreter says so of one that is missing.
        try (txt <$> call asked.name asked.arguments)
        catch error => pure s!"error: {error.replace "no routine named" "no tool named"}"
      else pure s!"error: {asked.name} is not a tool of this conversation"
    results := results ++ [Message.tool result]
  let heard ← if listen then inbox else pure []
  return .inl (dialogue ++ [.assistant response.text response.toolCalls] ++ results
    ++ heard.map (.user <| noticeText ·))

def converse (agent : AgentConfig) (model : ModelConfig) (dialogue : Dialogue)
    (listen := false) : Computation Agent String :=
  iter (round agent model listen) dialogue

def delegate (model : ModelConfig) : Tool where
  name := "delegate"
  run task := .str <$> converse { tools := ["bash", "time_budget"], retries := 2 } model
    [.system "You are a sub-agent.", .user (txt task)]

def commit : Tool where
  name := "commit"
  run message := do
    let report ← call "delegate" (.str "run the tests")
    let _ ← call "bash" (.str "git add")
    let _ ← call "bash" (.str s!"git commit -m {txt message}")
    return report

def agent (config : Config) : Tool where
  name := "agent"
  run _ := do
    let task ← await fun _ notice => notice matches .said _
    .str <$> converse config.agent config.model ([.system config.system] ++ task.map (.user <| noticeText ·))
      (listen := true)

/-- The sketch's tools as routines defined together, each calling the others by name. -/
def scopeOf (tools : List Tool) : Scope Agent :=
  Scope.fix fun scope => tools.toArray.map fun tool => { name := tool.name, body := tool.run, scope }

def verdict (stdout : String) : String :=
  let lines := stdout.splitOn "\n"
  let passed := (lines.filter (·.startsWith "ok ")).length
  let failed := (lines.filter (·.startsWith "not ok ")).length
  s!"{if failed == 0 then "pass" else "fail"} {passed}/{passed + failed}"

def hiddenTests : Tool where
  name := "hidden_tests"
  run _ := do
    let ran ← perform (.external "pytest /grader" "grader@sha256:9f2c" (some ⟨"hidden"⟩) 900)
    return .str (verdict ran.stdout)

def grading (_ : Except String Json) : Computation Agent Json := call "hidden_tests" (.str "")

def graded (config : Config) (after : Except String Json → Computation Agent Json := grading) : Routine Agent :=
  { name := "run"
    body := fun _ => .call ⟨"agent", config.json⟩ after
    scope := scopeOf [agent config, bash, timeBudget, askUser, delegate config.model, commit, hiddenTests] }

/-! ## The sketch's world and driver -/

abbrev Log' := Array (Event Agent)

def workspace (log : Log') : Snapshot :=
  log.foldl (init := ⟨""⟩) fun version event =>
    match event with
    | .answered _ (.exec _) (.ok (.output output)) => output.workspace
    | .arrived (.changed workspace _) => workspace
    | _ => version

def reply (log : Log') (answer : Reply) : Except String (Event Agent) := do
  let bracket := log.reverse.find? fun
    | .opened .. | .returned .. | .failed .. | .stopped _ => true
    | _ => false
  match bracket with
  | some (.opened frame ⟨"ask_user", arguments⟩) =>
    if (← Question.parse (txt arguments)).accepts answer then pure (.arrived (.replied frame answer))
    else throw "the reply is not of the form the question asks for"
  | _ => throw "no question waits for a reply"

structure World where
  model : Log' → Request → Except String Response
  execute : Snapshot → String → Output
  external : Snapshot → String → String → ExternalOutput
  clock : Nat × Option Nat
  arrivals : Log' → List Notice

def World.answer (world : World) (log : Log') : (op : Op) → Except String op.Answer
  | .sample request => world.model log request
  | .exec command => .ok (world.execute (workspace log) command)
  | .time => .ok world.clock
  | .external command image _ _ => .ok (world.external (workspace log) image command)

partial def drive (world : World) (run : Routine Agent) (log : Log') : Log' × Next Agent :=
  let log := log ++ ((world.arrivals log).map Event.arrived).toArray
  match next run log with
  | .ask call =>
    let answer := (world.answer log call.op).map (store call.op)
    drive world run (log.push (.answered call.frame call.op answer))
  | .hears frame notices => drive world run (log.push (.heard frame notices))
  | .opens frame tool => drive world run (log.push (.opened frame tool))
  | .returns frame value => drive world run (log.push (.returned frame value))
  | .fails frame error => drive world run (log.push (.failed frame error))
  | result => (log, result)

def versions (log : Log') : List Nat :=
  let reached := fun position => workspace (log.extract 0 position)
  (List.range (log.size + 1)).filter fun position =>
    position > 0 && reached position != reached (position - 1)

/-! ## The sketch's test -/

def Request.last (request : Request) : String :=
  match request.messages.getLast? with
  | some (.system text) | some (.user text) | some (.assistant text _) | some (.tool text) => text
  | none => ""

def calls (pairs : List (String × String)) : Response :=
  { text := "", toolCalls := pairs.map fun (name, arguments) => ⟨name, .str arguments⟩ }

def script (request : Request) : Response :=
  match request.last with
  | "the task" => calls [("ask_user", "Which target?")]
  | "the default one" => calls [("bash", "make")]
  | "output of make" => calls [("commit", "fix")]
  | "run the tests" => calls [("time_budget", ""), ("bash", "pytest")]
  | "output of pytest" => { text := "48 tests pass" }
  | "error: exit 1: nothing to commit" => calls [("commit", "fix")]
  | "The workspace was changed: a person edited README" => calls [("bash", "git diff")]
  | _ => { text := "done" }

def asked (log : Log') : Bool :=
  let last := log.reverse.find? fun
    | .arrived (.said _) | .arrived (.changed ..) => false
    | _ => true
  match last with
  | some (.opened _ ⟨"ask_user", _⟩) => true
  | _ => false

def version (n : Nat) : Snapshot := ⟨s!"w{n}"⟩
def versionNumber (snapshot : Snapshot) : Nat := (snapshot.hex.drop 1).toString.toNat!

def world : World where
  model _ request := .ok (script request)
  execute v command :=
    { text := s!"output of {command}"
      workspace := if command == "git diff" then v else version (versionNumber v + 1) }
  external v _ _ :=
    let made := versionNumber v
    let passing := if made == 0 then 0 else if made < 5 then 1 else 4
    let line := fun (check, name) =>
      s!"{if check < passing then "ok" else "not ok"} {check + 1} - {name}"
    { exit := if passing == 4 then 0 else 1
      stdout := "\n".intercalate (["builds", "parses", "evaluates", "reports errors"].zipIdx.map
        fun (name, check) => line (check, name))
      checkout := ⟨s!"{v.hex}, graded"⟩
      elapsedMs := 1200 }
  clock := (412000, some 3600000)
  arrivals log :=
    if log.isEmpty then [.changed (version 0) "the repository"]
    else if log.size == 2 then [.said "the task"]
    else if log.size == 22 then [.changed (version 2) "a person edited README"]
    else if !asked log then []
    else match reply log (.text "the default one") with
      | .ok (.arrived notice) => [notice]
      | _ => []

def failsOnce (log : Log') (request : Request) : Except String Response :=
  let failedBefore := log.any fun | .answered _ _ (.error _) => true | _ => false
  if request.last == "run the tests" && !failedBefore then .error "overloaded"
  else .ok (script request)

def upTo (length : Nat) (log : Log') : List Notice :=
  if log.size ≤ length then world.arrivals log else []

def overreaches (_ : Log') (request : Request) : Except String Response :=
  if request.last == "the task" then .ok (calls [("hidden_tests", "")])
  else .ok (script request)

def keepsFailing (_ : Log') (request : Request) : Except String Response :=
  if request.last == "run the tests" then .error "overloaded" else .ok (script request)

def Op.describe : Op → String
  | .sample request => s!"sample after \"{request.last}\""
  | .exec command => s!"exec {command}"
  | .time => "time"
  | .external command image input _ =>
    s!"external {command}, in {image}, with {(input.map (·.hex)).getD "nothing"}"

/-- The sketch's frames: each call's ordinal among the calls of its caller, read off the openings
of `log`, as the sketch numbered its frames. A frame the log has not opened yet, as one that
opens next, is the next ordinal of its caller. -/
partial def ordinals (log : Log') (frame : Frame) : List Nat :=
  let (known, counts) := log.foldl (init := (({} : Std.HashMap Frame (List Nat)), ({} : Std.HashMap Frame Nat)))
    fun (known, counts) event => match event with
      | .opened opened _ =>
        let parent := opened.pop
        let n := counts.getD parent 0
        (known.insert opened (ordinalOf known counts parent ++ [n]), counts.insert parent (n + 1))
      | _ => (known, counts)
  ordinalOf known counts frame
where
  ordinalOf (known : Std.HashMap Frame (List Nat)) (counts : Std.HashMap Frame Nat) (frame : Frame) : List Nat :=
    match known.get? frame with
    | some ordinal => ordinal
    | none => if frame.isEmpty then [] else ordinalOf known counts frame.pop ++ [counts.getD frame.pop 0]

def describe (o : Frame → List Nat) : Event Agent → String
  | .arrived (.said message) => s!"-  arrived: said {message}"
  | .arrived (.changed workspace _) => s!"-  arrived: changed → {workspace.hex}"
  | .arrived (.replied to answer) => s!"-  arrived: replied to {o to}: {render answer}"
  | .arrived (.called call) => s!"-  arrived: called {call.name}"
  | .commented text => s!"-  commented: {text}"
  | .answered frame (.external command image ..) (.ok (.external ran)) =>
    s!"{o frame}  answered: external {command}, in {image} → exit {ran.exit}, {ran.checkout.hex}"
  | .answered frame (.exec command) (.ok (.output output)) =>
    s!"{o frame}  answered: exec {command} → {output.workspace.hex}"
  | .answered frame op (.ok _) => s!"{o frame}  answered: {op.describe}"
  | .answered frame op (.error error) =>
    s!"{o frame}  answered: {op.describe}: failed: {error}"
  | .opened frame tool => s!"{o frame}  opened: {tool.name} \"{txt tool.arguments}\""
  | .returned frame value => s!"{o frame}  returned: {txt value}"
  | .failed frame error =>
    s!"{o frame}  failed: {error.replace "no routine named" "no tool named"}"
  | .stopped reason => s!"-  stopped: {reason}"
  | .heard frame notices => s!"{o frame}  heard {notices.toList}"
  | .asked frame question => s!"{o frame}  asked: {question.text}"

def describeNext (o : Frame → List Nat) : Next Agent → String
  | .done value => s!"done: {txt value}"
  | .ask call => s!"ask {o call.frame} {call.op.describe}"
  | .opens frame tool => s!"log the opening of {o frame}: {tool.name}"
  | .returns frame value => s!"log the return of {o frame}: {txt value}"
  | .fails frame error => s!"log the failure of {o frame}: {error}"
  | .raised error => s!"failed: {error}"
  | .hears frame notices => s!"mark the read of {o frame}, of {notices.toList}"
  | .questions frame question => s!"log the question of {o frame}: {question.text}"
  | .waits frame _ =>
    if frame.isEmpty then "wait: there is no workspace to start on"
    else s!"wait: {o frame} reads the inbox once something arrives"
  | .mismatch position => s!"mismatch at {position}"
  | .unguarded frame => s!"unguarded loop in {o frame}"

def withAgent (run : Routine Agent) (computation : Computation Agent Json) : Routine Agent :=
  { run with scope := ⟨fun name =>
      if name == "agent" then
        let scope := ((run.scope.find name).map (·.scope)).getD .empty
        some { name, body := fun _ => computation, scope }
      else run.scope.find name⟩ }

/-- The run without the routine `name`, wherever its routines would call it. -/
def without (run : Routine Agent) (name : String) : Routine Agent :=
  { run with scope := run.scope.without name }

def faithful (run : Routine Agent) (log : Log') : Bool :=
  (List.range (log.size + 1)).all fun i =>
    match log[i]?, next run (log.extract 0 i) with
    | some (.arrived _), _ => true
    | some (.answered frame op _), .ask call => frame == call.frame && op == call.op
    | some (.heard frame notices), .hears reader taken => frame == reader && notices == taken
    | some (.opened frame tool), .opens entered called => frame == entered && tool == called
    | some (.returned frame value), .returns ended given => frame == ended && value == given
    | some (.failed frame error), .fails ended given => frame == ended && error == given
    | none, .done _ => true
    | _, _ => false

def drop (log : Log') (start : Nat) : Log' := log.extract start log.size

/-- Everything the sketch's test prints, in its order. -/
def transcript : Array String := Id.run do
  let mut out : Array String := #[]
  let config : Config :=
    { system := "You are a coding agent."
      agent := { tools := ["bash", "time_budget", "commit", "ask_user"], retries := 2 }
      model := { name := "a-model", maxTokens := 4096 } }
  let run := graded config
  let replay := fun log => describeNext (ordinals log) (next run log)
  let same := fun (one other : Log') => one.map (describe (ordinals one)) == other.map (describe (ordinals other))
  let (log, result) := drive world run #[]
  for (event, i) in log.zipIdx do out := out.push s!"{i}  {describe (ordinals log) event}"
  out := out.push (describeNext (ordinals log) result)
  out := out.push s!"workspace {(workspace log).hex}"
  out := out.push s!"replay agrees with the run wherever the driver asked: {faithful run log}"
  let stoppedAt := fun position => (log.extract 0 position).push (.stopped "to grade this state")
  out := out.push "the states of the run, where the workspace is at a new version, forked and stopped:"
  for position in (versions log).filter (· < 42) do
    let (fork, grade) := drive world run (stoppedAt position)
    let v := workspace (log.extract 0 position)
    let more := fork.size - position
    out := out.push s!"  at {position}, workspace {v.hex}: {describeNext (ordinals fork) grade}, in {more} more events"
  out := out.push "the fork stopped at 24:"
  let stopped := (drive world run (stoppedAt 24)).1
  for (event, i) in stopped.zipIdx do
    if i ≥ 23 then out := out.push s!"  {i}  {describe (ordinals stopped) event}"
  out := out.push s!"the run itself is as it was: {same (drive world run log).1 log}"
  out := out.push s!"the agent cannot go on after a stop: {replay (stoppedAt 24 ++ drop log 24)}"
  out := out.push s!"a stop once the agent is over: {replay ((log.extract 0 44).push (.stopped "x"))}"
  out := out.push s!"a reply when no question waits: {(reply log .yes).toOption.isSome}"
  let asking := log.extract 0 6
  out := out.push s!"a reply of another form than asked: {(reply asking .yes).toOption.isSome}"
  out := out.push s!"that the person cannot answer: {(reply asking .unavailable).toOption.isSome}"
  let wrong := asking.push (.arrived (.replied ⟪"agent", "ask_user"⟫ .yes))
  out := out.push s!"a reply of another form, put in the log: {replay wrong}"
  let (waiting, pending) := drive { world with arrivals := upTo 2 } run #[]
  out := out.push s!"while the person has not replied: {describeNext (ordinals waiting) pending}"
  out := out.push s!"  and the log ends with: {(waiting.back?.map (describe (ordinals waiting))).getD ""}"
  out := out.push s!"resumed to the same log: {same (drive world run waiting).1 log}"
  let (interrupted, pending) := drive { world with arrivals := fun log =>
    if log.size == 6 then [.changed (version 1) "a person edited README"] else upTo 2 log } run #[]
  out := out.push s!"with another notice while a question waits: {describeNext (ordinals interrupted) pending}"
  out := out.push s!"  and the log ends with: {(interrupted.back?.map (describe (ordinals interrupted))).getD ""}"
  let (later, _) := drive world run interrupted
  for (event, i) in later.zipIdx do
    if 6 ≤ i ∧ i ≤ 10 then out := out.push s!"  {i}  {describe (ordinals later) event}"
  let flaky := { world with
    arrivals := fun log => if log.size == 22 then [] else world.arrivals log
    execute := fun v command =>
      if command.startsWith "git commit" ∧ v == version 3 then
        { text := "nothing to commit", workspace := version 4, exit := 1 }
      else world.execute v command }
  let (failing, ended) := drive flaky run #[]
  out := out.push "with a commit that fails the first time:"
  for (event, i) in failing.zipIdx do
    if 30 ≤ i ∧ i ≤ 36 then out := out.push s!"  {i}  {describe (ordinals failing) event}"
  out := out.push s!"  and the run ends, after {failing.size} events: {describeNext (ordinals failing) ended}"
  let (once, ended) := drive { world with model := failsOnce } run #[]
  out := out.push "with a model that fails to answer once:"
  for (event, i) in once.zipIdx do
    if 17 ≤ i ∧ i ≤ 19 then out := out.push s!"  {i}  {describe (ordinals once) event}"
  out := out.push s!"  and the run ends, after {once.size} events: {describeNext (ordinals once) ended}"
  let (thrice, ended) := drive { world with model := keepsFailing } run #[]
  out := out.push "with a model that keeps failing a sub-agent:"
  for (event, i) in thrice.zipIdx do
    if 17 ≤ i ∧ i ≤ 25 then out := out.push s!"  {i}  {describe (ordinals thrice) event}"
  out := out.push s!"  and the run ends, after {thrice.size} events: {describeNext (ordinals thrice) ended}"
  let (missing, _) := drive world (without run "bash") #[]
  out := out.push "with a tool that the run does not have:"
  for (event, i) in missing.zipIdx do
    if 10 ≤ i ∧ i ≤ 14 then out := out.push s!"  {i}  {describe (ordinals missing) event}"
  let (refused, _) := drive { world with model := overreaches } run #[]
  out := out.push "with a model that asks for a tool it was not offered:"
  for (event, i) in refused.zipIdx do
    if 4 ≤ i ∧ i ≤ 6 then out := out.push s!"  {i}  {describe (ordinals refused) event}"
  let (broken, ended) := drive world (withAgent run (throw "no model")) #[]
  out := out.push "with an agent that fails:"
  for (event, i) in broken.zipIdx do
    if i ≥ 3 then out := out.push s!"  {i}  {describe (ordinals broken) event}"
  out := out.push s!"  {describeNext (ordinals broken) ended}"
  let (graders, ended) := drive world (graded config (after := fun _ => throw "no grader")) #[]
  out := out.push s!"with graders that fail, the run ends: {describeNext (ordinals graders) ended}"
  let (empty, pending) := drive { world with arrivals := fun _ => [] } run #[]
  out := out.push s!"with no workspace yet: {describeNext (ordinals empty) pending}, after {empty.size} events"
  let (idle, pending) := drive { world with arrivals := upTo 0 } run #[]
  out := out.push s!"with no task yet: {describeNext (ordinals idle) pending}, after {idle.size} events"
  out := out.push s!"resumed to the same log: {same (drive world run idle).1 log}"
  let crashed := log.extract 0 24
  out := out.push s!"after a crash at 24: {replay crashed}"
  out := out.push s!"resumed to the same log: {same (drive world run crashed).1 log}"
  let removed := log.extract 0 18 ++ drop log 19
  out := out.push s!"an answer removed: {replay removed}"
  out := out.push s!"  where the program would {replay (removed.extract 0 18)}"
  out := out.push s!"an answer left over: {replay (log ++ drop log 45)}"
  out := out.push s!"an opening removed: {replay (log.extract 0 5 ++ drop log 6)}"
  out := out.push s!"a reply removed: {replay (log.extract 0 6 ++ drop log 7)}"
  out := out.push s!"a return removed: {replay (log.extract 0 8 ++ drop log 9)}"
  out := out.push s!"a read not marked: {replay (log.extract 0 35 ++ drop log 36)}"
  let unseen := (log.extract 0 35).push (.arrived (.said "stop")) ++ drop log 35
  out := out.push s!"a log with no root: {replay (drop log 1)}"
  out := out.push s!"a notice put in before a read: {replay unseen}"
  let spin : Computation Agent Json := iter (fun (n : Nat) => pure (.inl (n + 1))) 0
  out := out.push s!"a loop that reads nothing: {describeNext (ordinals log) (next (withAgent run spin) log)}"
  return out

def suite : Testing.Suite := Testing.suite "prototype" #[
  Testing.iotest "the interpreter reads every log as the sketch does, line for line" do
    let expected := (← IO.FS.readFile ("Test" / "Prototype" / "expected.txt")).splitOn "\n"
    let expected := if expected.getLast? == some "" then expected.dropLast else expected
    let actual := transcript.toList
    for (line, i) in (actual.zip expected).zipIdx do
      if line.1 != line.2 then
        throw <| IO.userError s!"line {i + 1}:\n  ours:   {line.1}\n  sketch: {line.2}"
    if actual.length != expected.length then
      throw <| IO.userError s!"{actual.length} lines where the sketch prints {expected.length}"
]

end PrototypeTests
