/-- A verdict, read off what a grader prints: how many of its checks passed, of how many, in the
Test Anything Protocol's lines `ok` and `not ok`. -/
def verdict (stdout : String) : String :=
  let lines := stdout.splitOn "\n"
  let passed := (lines.filter (·.startsWith "ok ")).length
  let failed := (lines.filter (·.startsWith "not ok ")).length
  s!"{if failed == 0 then "pass" else "fail"} {passed}/{passed + failed}"

/-- A grader is a tool that no conversation offers its model, and needs nothing of its own: it
is an external program and a reading of what it prints. This one runs tests the agent never
sees: in an image of its own, on a checkout of the workspace as the agent left it, with the
tests mounted to read. The operation holds all of that, so the log does. -/
def hiddenTests : Tool where
  name := "hidden_tests"
  run _ := do
    let ran ← perform (.external "pytest /grader" "grader@sha256:9f2c" (some "hidden") 900)
    return verdict ran.stdout

/-- What follows the agent in a run: the graders. They are given what the agent returned, or
the error when it failed or was stopped, and what they return is the result of the run. The
agent is over when they start, so whatever they do, the agent cannot see it. To grade a state
a run went through is no other thing: the log is forked there and stopped, and the graders
follow. -/
def grading (_ : Except String Json) : Program Agent Json := call "hidden_tests" ""

/-- A run of the agent with its graders. The agent is called with its configuration, which
the log so holds from the start. The graders are among the tools of the run, and no
conversation offers them to a model. -/
def graded (config : Config) : Run Agent :=
  { tools := table
      [agent config, bash, timeBudget, askUser, delegate config.model, commit, hiddenTests]
    call := ⟨"agent", config.json⟩
    after := grading }

/-- The positions at which the workspace is at a version for the first time. Graders that look
at the workspace alone give one grade for a version, so these are all the states there is to
grade: a result kept by what it was computed from, as Mokhov, Mitchell and Peyton Jones (2018)
keep the results of a build. -/
def versions (log : List (Event Agent)) : List Nat :=
  let reached := fun position => workspace (log.take position)
  (List.range (log.length + 1)).filter fun position =>
    position > 0 && reached position != reached (position - 1)
