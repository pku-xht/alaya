import Test.Framework
import Test.Scripted
import Alaya

/-! Routines: how an agent is structured. A workflow, a sub-agent with a tool of its own, and
the steps the workflow runs are each a routine, entered by a call alone, so the log of a run of
the agent is the nesting of what it did. -/

namespace RoutinesTests

open Testing Alaya Alaya.Base Alaya.Core Alaya.LLM Alaya.Runtime Alaya.App Scripted
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
def lookup : Routine.Typed Agent Word String := routine "lookup" fun asked => do
  return (← exec s!"grep {asked.word} notes.txt").output.output

/-- `lookup`, as the planner offers it to its model. -/
def lookupDefinition : Chat.ToolDefinition := {
  name := lookup.name
  description := "What the notes say of a word"
  parameters := .object #[("word", .string (description? := some "The word to look up"))] }

/-- A sub-agent: a conversation of its own, which offers its model `lookup` alone and ends when
the model answers without a call. Its answer, a command a line, is the plan. -/
def planner : Routine.Typed Agent Task Plan := routine "planner" fun task => do
  let opening : Array Chat.Message := #[.system "You plan.", .user task.goal]
  let answer ← iter (fun (messages : Array Chat.Message) => do
    let response ← sample testModelSpec { messages, tools := #[lookupDefinition] }
    if response.toolCalls.isEmpty then return Sum.inr (response.content?.getD "")
    let mut messages := messages.push response.message
    for asked in response.toolCalls do
      -- The model's call is a call of the routine it names, with the arguments it gave.
      let result ← try Alaya.Core.call asked.name asked.arguments catch error => pure (.str s!"error: {error}")
      messages := messages.push (.tool asked.id result)
    return Sum.inl messages) opening
  return { steps := ((answer.splitOn "\n").filter (!·.isEmpty)).toArray }

/-- A step of the workflow: one command, and how it ended. -/
def step : Routine.Typed Agent String Nat := routine "step" fun command => do
  return (← exec command).output.exitCode?.map (·.toNat) |>.getD 1

/-- The workflow: a plan from the planner, then each of its steps, and how many failed. -/
def workflow : Routine.Typed Agent Task String := routine "workflow" fun task => do
  let plan ← planner.call task
  let mut failed := 0
  for command in plan.steps do
    if (← step.call command) != 0 then failed := failed + 1
  return s!"{plan.steps.size} steps, {failed} failed"

/-- The routines above, defined together: each calls the others by name. -/
def scope : Scope Agent :=
  Scope.fix fun scope => #[lookup.within scope, planner.within scope, step.within scope, workflow.within scope]

/-- The agent's configuration: what a person calls it with. -/
structure Config where
  task : String
  deriving ToJson, FromJson

/-- The agent: a routine, the workflow on the task of its configuration, that calls the routines
of `scope`. -/
def agent : Routine Agent :=
  (routine "agent" fun (config : Config) => workflow.call { goal := config.task }).within scope

/-- The run: the run's routine, whose scope has the agent, so that a person's call of it finds it. -/
def run : Scope Agent := Scope.of #[Catalog.session (Scope.of #[agent])]

/-- Runs `k` with the run of `make`'s computation for the task, in the scope above. -/
private def withRun (make : String → Computation Agent Json) (k : Scope Agent → TestM Unit) : TestM Unit :=
  k (runOf make scope)

/-- The openings of a log: the frame each call runs in, and the routine it names. -/
private def openings (log : Log Agent) : Array (Frame × String) :=
  log.filterMap fun | .opened frame opened => some (frame, opened.name) | _ => none

private def executed (output : String := "ok") : Stored :=
  .execution { output := { output, exitCode? := some 0 }, workspace := default }

def suite : Suite := Testing.suite "routines" #[
  test "a workflow, its sub-agent and their tools are calls in frames of their own, nested in the log" do
    do
      let executor : Executor := { exec := fun _ _ argv _ => do
        let command := argv[0]?.getD ""
        pure { output := if command.startsWith "grep" then "build: make" else "ok"
               exitCode? := some (if command == "make test" then 1 else 0) } }
      let model ← scriptedModel #[
        responseWith #[{ id := "l", name := "lookup", arguments := .mkObj [("word", "build")] }],
        { content? := some "make\nmake test" }]
      let (rt, last, stop) ← drive run executor model "ship it"
      check (isIdle stop) "the agent is over"
      let log ← logAt rt last
      assertEqual "the agent's result" ((agentResult log).bind (·.toOption) |>.map (·.compress)) (some "\"2 steps, 1 failed\"")
      assertEqual "the calls, each in its caller's next frame" (openings log)
        #[(⟪"session"⟫, "session"), (⟪"session", "agent"⟫, "agent"), (⟪"session", "agent", "workflow"⟫, "workflow"), (⟪"session", "agent", "workflow", "planner"⟫, "planner"),
          (⟪"session", "agent", "workflow", "planner", "lookup"⟫, "lookup"), (⟪"session", "agent", "workflow", "step"⟫, "step"),
          (⟪"session", "agent", "workflow", "step#1"⟫, "step")]
      -- A call's opening holds its arguments, and its end its result: both data, in the log.
      check (log.any fun | .opened ⟪"session", "agent", "workflow"⟫ { name := "workflow", arguments, .. } => arguments.compress == "{\"goal\":\"ship it\"}" | _ => false)
        "the workflow's arguments"
      check (log.any fun | .returned ⟪"session", "agent", "workflow", "planner"⟫ value => value.compress == "{\"steps\":[\"make\",\"make test\"]}" | _ => false)
        "the planner's plan"
      check (log.any fun | .returned ⟪"session", "agent", "workflow", "step#1"⟫ value => value.compress == "1" | _ => false) "the failed step's status"
      -- What a routine asks the world for is asked from its own frame.
      let asked := log.filterMap fun
        | .answered frame (.sample ..) _ => some (frame, "sample")
        | .answered frame (.exec command _) _ => some (frame, command)
        | _ => none
      assertEqual "who asked for what" asked
        #[(⟪"session", "agent", "workflow", "planner"⟫, "sample"), (⟪"session", "agent", "workflow", "planner", "lookup"⟫, "grep build notes.txt"),
          (⟪"session", "agent", "workflow", "planner"⟫, "sample"), (⟪"session", "agent", "workflow", "step"⟫, "make"),
          (⟪"session", "agent", "workflow", "step#1"⟫, "make test")]
      -- The sub-agent's conversation is its own: its second request holds the tool's result.
      let requests := samplesOf run log
      assertEqual "two samples, both the planner's" requests.size 2
      check (requests[1]!.1.messages.any fun | .tool "l" (.str "build: make") => true | _ => false)
        "the planner's model was shown what its tool gave",

  test "a routine is entered by a call alone, and what crosses the call must be what it takes" do
    -- Called with arguments it cannot read, a routine fails; its caller may catch that.
    withRun (fun _ => try Alaya.Core.call "step" (.mkObj [("command", "make")]) catch error => pure (.str error)) fun run => do
      let log := settle run opening
      check (log.any fun | .failed ⟪"session", "agent", "step"⟫ error => contains error "step: its arguments cannot be read" | _ => false)
        "the routine failed, in its own frame"
      check ((next run log) matches .waits ⟪"session"⟫ _) "and the agent went on, to its end"
    -- A handle that expects another result than the routine gives fails where the result is read.
    let mistaken : Routine.Typed Agent String String := routine "step" fun _ => pure ""
    withRun (fun _ => toJson <$> mistaken.call "make") fun run => do
      let log := answer run (settle run opening) (executed)
      check (log.any fun | .returned ⟪"session", "agent", "step"⟫ value => value.compress == "0" | _ => false) "the routine returned its status"
      check (log.any fun | .failed ⟪"session", "agent"⟫ error => contains error "step: its result cannot be read" | _ => false)
        "the caller could not read it"
    -- The grader is a program a person calls, no routine: nothing an agent calls reaches it.
    withRun (fun _ => Alaya.Core.call "grader" (.mkObj [("command", "true")])) fun run => do
      let log := settle run opening
      check (log.any fun | .failed ⟪"session", "agent", "grader"⟫ "no routine named grader" => true | _ => false) "there is no such routine",

  test "a program brings its scope: an agent's tools and itself, fixed where it is defined" do
    match Catalog.scope.find "mini-swe" with
    | none => fail "mini-swe is a program"
    | some swe =>
      assertEqual "what a call inside MiniSwe can name"
        (#["bash", "submit", "ask_user", "time_budget", "mini-swe", "mini-vero", "grader"].filter
          fun name => (swe.scope.find name).isSome) #["bash", "ask_user", "time_budget", "mini-swe"]
      -- The scope holds MiniSwe itself, with the same scope: what lets it call itself.
      check ((swe.scope.find "mini-swe").any fun inner => (inner.scope.find "bash").isSome)
        "MiniSwe in its own scope has the same scope"
    check (Catalog.scope.find "nothing").isNone "no program of that name"
]

end RoutinesTests
