# Agent API

An agent of Alaya is a **program** over the signature `Agent` (`Alaya.Program`, `Alaya.Agent`):
a tree of the operations it asks the world for, each continued with its answer. It carries out
nothing. The driver replays it against the log of its run to find what it asks for next, carries
that out, and appends the answer (`docs/architecture.md`). What follows from this:

- **Every decision can be recomputed.** What an agent asks at any point is replay of the log up
  to there; nothing it decides depends on what the log does not hold — not the wall clock, not
  the invocation that drove it.
- **The structure of a run is in its log.** Every tool runs in a frame of its own, bracketed by
  its opening and its end, so a reader sees which call each event happened in, sub-agents and
  tools that call tools included, without the program.
- **Samples are draws.** A model's response is a draw of its request, which the model cache
  keeps, so running a point again is a new draw, and a crash takes the draw the cache kept.
- **The workspace is in the log.** Every command's answer names the version of the workspace it
  left, so any point of a run can be checked out, compared, graded, or gone on from.

## 1. Programs

```lean
inductive Program (σ : Signature) : Type → Type 1 where
  | pure | fail | perform | inbox | call | iter          -- docs/architecture.md §2

instance : Monad (Program σ)
instance : MonadExcept String (Program σ)               -- throw, try … catch

perform : (op : σ.Op) → Program σ (σ.Answer op)         -- fails where the world could not answer
inbox   : Program σ (List Notice)                       -- every notice not yet read and addressed to no one
await   : (Frame → Notice → Bool) → Program σ (List Notice)   -- wait for the notices it is for
call    : (name : String) → Json → Program σ Json       -- a tool, by name; its failure is ours
iter    : (S → Program σ (S ⊕ α)) → S → Program σ α     -- a loop whose state is data
retry   : Nat → Program σ α → Program σ α               -- try again while it fails
```

A program is written in `do` notation like any monadic code. Three rules make it one the driver
can replay:

- **It is a function of its answers.** What it asks next is decided from what came back before:
  a request, a command, a question are computed from earlier answers and notices, and from the
  run's configuration, which is in the log.
- **Every round of a loop reads an event.** A loop that goes round without asking for an
  operation, reading the inbox, or calling a tool is `unguarded`, a broken run. MiniSwe's loop
  samples every round.
- **What comes from outside comes through the inbox.** A person's messages and changes are
  notices; a program sees them by reading its inbox, and the read is marked in the log with the
  positions of what it took. A read that waits — `await` — is how a program stops for a person.

`try`/`catch` catch a failure inside a frame and leave no mark. A call catches its tool's failure
and marks it (`failed`), so the caller sees the error and the log shows which call failed.

## 2. Alaya's operations

```lean
inductive Op where
  | sample (request : Chat.Request)                            -- answered by Chat.Response
  | exec (command : String) (config : Executor.Config)         -- answered by Execution
  | time                                                       -- answered by Timing
  | external (command image : String) (input? : Option Snapshot) (timeoutSeconds : Nat)
                                                               -- answered by External

structure Execution where output : Output ; workspace : Snapshot ; file? : Option String
structure Timing where spentMs : Nat ; budgetMs? : Option Nat
structure External where
  exitCode? : Option Int ; stdout : String ; stderr : String
  checkout : Snapshot ; elapsedMs : Nat ; error? : Option String

sample   : Chat.Request → Program Agent Chat.Response
exec     : String → Executor.Config → Program Agent Execution
time     : Program Agent Timing
external : String → String → Option Snapshot → Nat → Program Agent External
```

| Operation | What it is | The answer |
| --- | --- | --- |
| `sample` | a response of the run's model to a request | the response, or, when the provider refuses the request as too long for the model's context, its words as an error; no other failure of a provider is an answer |
| `exec` | a command in the workspace, at the version the log has reached, with `config`'s timeout and environment | its output, the version it left, and with `config.outputs` the file a later command finds the whole output in |
| `time` | the run's time along its log | the time, and the invocation's budget |
| `external` | a program in a fresh container of `image`, with no network, on a checkout of the workspace, `input?` at `/grader` | how it ended, its stdout and stderr, and the checkout as it left it; the run's workspace stays where it is |

The log keeps an operation by its **key** (`Op.key`): all of it, except that a sample is kept by
the digest of its request (`Model.requestDigest`), so the log does not hold the dialogue again
with every response. The request itself is what replay asks for at that point, which is how
`alaya show --request` and the HTML report show it.

## 3. Tools

```lean
structure Tool where
  definition : Chat.ToolDefinition                -- its schema for a model
  alone : Bool := false                           -- must be the only call of its turn
  instruction? : Option String := none            -- appended to the prompt
  check : Json → Except String Unit               -- what is wrong with a call's arguments
  run : Json → Program Agent Json                 -- the program that answers a call
```

A tool is a program from a call's arguments to its result, under a name. Programs call a tool by
its name alone, so it always runs in a frame of its own, and a tool may call tools — a sub-agent
is a tool whose program is a conversation of its own. The tools of a run are its agent's tools
and `grade`, which no agent offers its model: the run calls it with the grader assigned. The
agent's call is a tool too, `agent`, called with the run's configuration.

| Tool | Program |
| --- | --- |
| `bash` | `exec` of its `command`, with the agent's executor settings; gives the whole output, its status, and its file |
| `submit` | not run: an agent that offers it ends with its message |
| `ask_user` | `await` a reply to its own frame, of the form the question asks for (`docs/ask-user.md`) |
| `time_budget` | `time`, and the seconds left of the budget, or that there is none |
| `grade` | `external` of the grader its arguments describe, the one assigned to the run, and the verdict of the TAP it printed |

`Agents.Tools.all` lists the tools an agent's configuration can name. A tool knows nothing of the
agent that offers it: the agent decides what its model is offered, how a malformed call is
worded, and how a result is shown.

## 4. An agent

An agent is the program of the `agent` tool, built from its configuration (`Agents.Catalog`):

```lean
structure Built where
  config : Json                                       -- the complete configuration
  tools : Array Tool                                  -- the tools it offers, which the run has
  program : Models.Spec → Uname → Program Agent Json  -- for a run of a model on a machine

structure Definition where
  name : String
  make : Json → Except String Built
```

MiniSwe (`docs/miniswe.md`) is the pattern:

```lean
def converse (config : Config) (opening : String → Array Chat.Message) : Program Agent Json := do
  let notices ← await fun _ notice => notice matches .said _   -- wait for the task
  iter (round config) { items := (opening task).map .told, … } -- go round until it ends

def round (config : Config) (history : History) : Program Agent (History ⊕ Json) := do
  let history ← listen history                                 -- what a person said or changed
  if limits are reached then return .inr (outcome …)
  let response ← sample (request config history)               -- the view of the conversation
  match parseActions response config with
  | .formatError message => return .inl (history with the format error)
  | .calls calls => for each call: submit ends the agent; any other is `call name arguments`,
                    its failure given to the model as its result
```

The state of the loop is the conversation as data — what was told, each turn with its calls'
results, each malformed response — so the request of every round is a function of it, and limits
that count turns or measure the context read it too.

## 5. A run

```lean
structure RunConfig where
  agent : Json                       -- the agent's complete configuration
  model : Json                       -- the model's complete spec
  environment : Environment          -- the pinned image, the workdir, the machine's uname

RunConfig.run : RunConfig → Models.Spec → Except String (Run Agent)
configOf : Log Agent → Result RunConfig                 -- the arguments of the agent's call
assignment : Grader → Event Agent                       -- the notice that assigns a grader
agentEnd? : Log Agent → Option AgentEnd                 -- how the agent ended, once it has
```

The run calls the agent with the configuration. What follows the agent, `grading`, is three
steps: it waits for an `assigned` notice, calls `grade` with the grader the notice names, in the
frame after the agent's, and returns the verdict, which is the result of the run. A grader is
assigned only once the agent is over, and only where the log has none (`Driver.append`), which
is what `alaya grade` does after stopping the agent where it still runs; a point is graded again
on a fork.

Programs live in `Type 1`, since a continuation is a function, so a `Run` is built by pure
functions and passed to the driver; it is never returned through `IO`.

## 6. Questions and replies

```lean
questionOf? : Log Agent → Next Agent → Option (Frame × Question)   -- the question a log waits on
replyTo : Log Agent → Next Agent → Reply → Except String (Event Agent)
```

A log waits on a question when replay waits in the frame of an `ask_user` call: the question is
read off the call's opening. A reply is the notice `replied frame reply`, refused when no question
waits or when it is not of the form the question asks for, so a log never holds a reply that its
program cannot take. Its wait takes it at the next read, and the tool gives it to the model.
