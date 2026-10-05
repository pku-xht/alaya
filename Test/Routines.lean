import Test.Framework
import Test.Scripted
import Alaya

/-! Routines: how an agent is structured. A workflow, a sub-agent with a tool of its own, and
the steps the workflow runs are each a routine, entered by a call alone, so the log of a run of
the agent is the nesting of what it did. -/

namespace RoutinesTests

open Testing Alaya Scripted
open Lean (Json ToJson FromJson toJson)

structure Task where
  goal : String
  deriving ToJson, FromJson

structure Plan where
  steps : Array String
  deriving ToJson, FromJson

structure Word where
  word : String
  deriving ToJson, FromJson

/-- A tool of the planner's: what the notes say of a word, by a command. -/
def lookup : Routine Agent Word String := routine "lookup" fun asked => do
  return (← exec s!"grep {asked.word} notes.txt").output.output

/-- `lookup`, as the planner offers it to its model. -/
def lookupDefinition : Chat.ToolDefinition := {
  name := lookup.name
  description := "What the notes say of a word"
  parameters := .object #[("word", .string (description? := some "The word to look up"))] }

/-- A sub-agent: a conversation of its own, which offers its model `lookup` alone and ends when
the model answers without a call. Its answer, a command a line, is the plan. -/
def planner : Routine Agent Task Plan := routine "planner" fun task => do
  let opening : Array Chat.Message := #[.system "You plan.", .user task.goal]
  let answer ← iter (fun (messages : Array Chat.Message) => do
    let response ← sample { messages, tools := #[lookupDefinition] }
    if response.toolCalls.isEmpty then return Sum.inr (response.content?.getD "")
    let mut messages := messages.push response.message
    for asked in response.toolCalls do
      -- The model's call is a call of the routine it names, with the arguments it gave.
      let result ← try Alaya.call asked.name asked.arguments catch error => pure (.str s!"error: {error}")
      messages := messages.push (.tool asked.id result)
    return Sum.inl messages) opening
  return { steps := ((answer.splitOn "\n").filter (!·.isEmpty)).toArray }

/-- A step of the workflow: one command, and how it ended. -/
def step : Routine Agent String Nat := routine "step" fun command => do
  return (← exec command).output.exitCode?.map (·.toNat) |>.getD 1

/-- The workflow: a plan from the planner, then each of its steps, and how many failed. -/
def workflow : Routine Agent Task String := routine "workflow" fun task => do
  let plan ← planner.call task
  let mut failed := 0
  for command in plan.steps do
    if (← step.call command) != 0 then failed := failed + 1
  return s!"{plan.steps.size} steps, {failed} failed"

/-- The agent: it waits for its task, and runs the workflow on it. -/
def agent : Program Agent Json := do
  let notices ← await fun _ notice => notice matches .said _
  let goal := match notices with
    | .said goal :: _ => goal
    | _ => ""
  return toJson (← workflow.call { goal })

def routines : Array (Routine.Entry Agent) := #[lookup.entry, planner.entry, step.entry, workflow.entry]

/-- Runs `k` with the run of `program`, with the routines above. -/
private def withRun (program : Program Agent Json) (k : Run Agent → TestM Unit) : TestM Unit :=
  match Run.ofAgent (testConfig testAgent).toJson program routines with
  | .ok run => k run
  | .error problem => fail problem

/-- The openings of a log: the frame each call runs in, and the routine it names. -/
private def openings (log : Log Agent) : Array (Frame × String) :=
  log.filterMap fun | .opened frame opened => some (frame, opened.name) | _ => none

private def executed (output : String := "ok") : Stored :=
  .execution { output := { output, exitCode? := some 0 }, workspace := default }

def suite : Suite := Testing.suite "routines" #[
  test "a workflow, its sub-agent and their tools are calls in frames of their own, nested in the log" do
    withRun agent fun run => do
      let executor : Executor := { uname := pure testUname, exec := fun _ _ argv _ => do
        let command := argv[0]?.getD ""
        pure { output := if command.startsWith "grep" then "build: make" else "ok"
               exitCode? := some (if command == "make test" then 1 else 0) } }
      let model ← scriptedModel #[
        responseWith #[{ id := "l", name := "lookup", arguments := .mkObj [("word", "build")] }],
        { content? := some "make\nmake test" }]
      let (rt, last, stop) ← drive run executor model "ship it"
      match stop with
      | .over (.returned value) none => assertEqual "the agent's result" value.compress "\"2 steps, 1 failed\""
      | _ => fail "the agent is over"
      let log ← logAt rt last
      assertEqual "the calls, each in its caller's next frame" (openings log)
        #[(#[0], "agent"), (#[0, 0], "workflow"), (#[0, 0, 0], "planner"), (#[0, 0, 0, 0], "lookup"),
          (#[0, 0, 1], "step"), (#[0, 0, 2], "step")]
      -- A call's opening holds its arguments, and its end its result: both data, in the log.
      check (log.any fun | .opened #[0, 0] ⟨"workflow", arguments⟩ => arguments.compress == "{\"goal\":\"ship it\"}" | _ => false)
        "the workflow's arguments"
      check (log.any fun | .returned #[0, 0, 0] value => value.compress == "{\"steps\":[\"make\",\"make test\"]}" | _ => false)
        "the planner's plan"
      check (log.any fun | .returned #[0, 0, 2] value => value.compress == "1" | _ => false) "the failed step's status"
      -- What a routine asks the world for is asked from its own frame.
      let asked := log.filterMap fun
        | .answered frame (.sample _) _ => some (frame, "sample")
        | .answered frame (.exec command _) _ => some (frame, command)
        | _ => none
      assertEqual "who asked for what" asked
        #[(#[0, 0, 0], "sample"), (#[0, 0, 0, 0], "grep build notes.txt"), (#[0, 0, 0], "sample"),
          (#[0, 0, 1], "make"), (#[0, 0, 2], "make test")]
      -- The sub-agent's conversation is its own: its second request holds the tool's result.
      let requests := samplesOf run log
      assertEqual "two samples, both the planner's" requests.size 2
      check (requests[1]!.1.messages.any fun | .tool "l" (.str "build: make") => true | _ => false)
        "the planner's model was shown what its tool gave",

  test "a routine is entered by a call alone, and what crosses the call must be what it takes" do
    -- Called with arguments it cannot read, a routine fails; its caller may catch that.
    withRun (try Alaya.call "step" (.mkObj [("command", "make")]) catch error => pure (.str error)) fun run => do
      let log := settle run #[.arrived (.changed default "p")]
      check (log.any fun | .failed #[0, 0] error => contains error "step: its arguments cannot be read" | _ => false)
        "the routine failed, in its own frame"
      check ((next run log) matches .waits #[]) "and the agent went on, to its end"
    -- A handle that expects another result than the routine gives fails where the result is read.
    let mistaken : Routine Agent String String := routine "step" fun _ => pure ""
    withRun (toJson <$> mistaken.call "make") fun run => do
      let log := answer run (settle run #[.arrived (.changed default "p")]) (executed)
      check (log.any fun | .returned #[0, 0] value => value.compress == "0" | _ => false) "the routine returned its status"
      check (log.any fun | .failed #[0] error => contains error "step: its result cannot be read" | _ => false)
        "the caller could not read it"
    -- The grader is no routine: nothing an agent calls reaches it.
    withRun (Alaya.call "grade" (Grader.toJson { command := "true", image := "image" })) fun run => do
      let log := settle run #[.arrived (.changed default "p")]
      check (log.any fun | .failed #[0, 0] "no routine named grade" => true | _ => false) "there is no such routine",

  test "the routines of a run are declared once each, and none under the agent's own name" do
    let build (entries : Array (Routine.Entry Agent)) : Option String :=
      match Run.ofAgent .null agent entries with
      | .ok _ => none
      | .error problem => some problem
    assertEqual "the routines above" (build routines) none
    check ((build (routines.push step.entry)).any (contains · "two routines are named step")) "a name twice"
    check ((build #[(agentRoutine, fun _ => pure .null)]).any (contains · "cannot be named agent")) "the agent's name"
    -- The agents the command line can name declare the tools they offer, and nothing else.
    match miniRun { tools := #["bash", "submit", "ask_user"] } with
    | .error problem => fail problem
    | .ok run =>
      assertEqual "what a run of MiniSwe has" (#["agent", "bash", "submit", "ask_user", "time_budget", "grade"].filter
        fun name => (run.routines name).isSome) #["agent", "bash", "submit", "ask_user"]
]

end RoutinesTests
