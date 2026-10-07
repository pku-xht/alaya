# The runtime

The language (`docs/language.md`) says what a computation asks for and what its log holds. The
runtime carries it out: a run is a call made from outside on a workspace, and the driver replays
its log to find what it asks next, does it, and appends the answer. A data directory keeps the
runs, their workspaces and the model cache, and every command of `alaya` is a function over it.

| § | What | Where |
| --- | --- | --- |
| 1 | a **run**: a workspace, and a call made from outside; the session | `Alaya.Runtime.Calls`, `Alaya.App.Session` |
| 2 | **driving** a run: the driver's own API, and the data directory | `Alaya.Runtime.Driver`, `Alaya.Runtime.Commands` |

## 1. A run

A run is a workspace and a call made from outside, of a routine of the scope the run is
replayed in. Outside, in `#[]`, the run waits for its call, takes it, and makes it in a frame of
its own; the run is over when that call is. The core knows nothing more of it.

The command line starts every run as a call of `session`, a routine of the app
(`Alaya.App.Session`). It is a loop: it waits for a call, calls the program the call names in a
frame of its own, and waits again. Its scope is the catalog. What a person may do at a point of
a run — call a program, say something, stop a call — is the session's to say: the runtime takes
anything the log can take.

```lean
Session.of    : Scope Agent → Routine Agent        -- wait for a call, make it, wait again
Session.scope : Scope Agent                        -- what a run's call may name: the session, a program

structure Environment where                         -- where a call's commands run, as the driver
  image   : String                                  --   reads a call's environment?, which the
  workdir : String                                  --   core holds as data

RoutineCall.event : RoutineCall → Event Agent      -- a person's call: arrived (called call)
environmentOf : Log Agent → Frame → Result (Frame × Environment)  -- where a frame's commands run
lastCall?      : Log Agent → Option (RoutineCall × Option CallEnd)   -- the run's last call, and how it ended
```

1. **The root.** A person provides the workspace: `arrived (changed …)`, at position 0.
2. **The run's call.** `alaya new` appends the call of `session`; the outside reads it, `heard -
   [1]`, and opens it, `opened session`. The session waits for a call.
3. **A person calls a program**: `alaya call` appends `arrived (called call)`, a call like any
   other: the program's name, its configuration as its arguments, and the environment its
   commands run in, which a person's call always names.
4. **The session reads it, and opens the call** as it is: `heard session [4]`, then `opened
   session/mini-swe call`, so every later command builds the same program from the log alone.
5. **The call runs**, in frame `session/mini-swe`, until it returns, fails, or is broken. It calls
   the routines of the program's scope, and its commands run in a container of the image its call
   named. A call inside it that names no environment, a sub-agent's or a tool's, runs in the
   same container; one that names its own runs in a container of that image.
6. **The session waits for the next call.** A grader is called the same way, in frame
   `session/grader`, and its value is its verdict.

![A whole run: the agent, then a grader, each in a frame of its own](figures/agent-api/run.svg)

## 2. Driving a run

The driver is the one part that touches the world. Lean code that uses Alaya as a library drives
a run with two functions:

```lean
drive  : Runtime → Scope Agent → (tip : Hash) → Limits → OnEntry → Result (Hash × Stop)
append : Store → Scope Agent → (tip : Hash) → Event Agent → Result (Hash × Entry)
settle : Store → Scope Agent → (tip : Hash) → Result (Array (Hash × Entry))   -- the marks, with no world

structure Runtime where          -- what a run is driven with
  store ; workspaces ; workDir ; outputsDir
  executor : Environment → Result Executor   -- a container of a call's image, for its commands
  model : Models.Spec → Result Model         -- a call's model; fails when no provider was named

structure Limits where           -- what one invocation allows; nothing of it is recorded
  samples? : Option Nat          -- responses this invocation may sample
  budgetMs? : Option Nat         -- the run's time, summed along its log, after which nothing starts

inductive Stop where             -- why the driver stopped
  | ended (result : Except String Json)                  -- the run's call is over
  | waits (frame : Frame) (question? : Option Question)  -- a read waits for a notice
  | paused (reason : String)                             -- a limit was reached
```

A point of a run is an **entry**: one event and the entry before it, named by a hash
(`docs/log-schema.md`). The log of an entry is the path to it from its root.

`drive` goes on from the entry `tip`:

1. It reads the log that ends at `tip`, and replays it.
2. It asks what the run does next, and does it (the diagram of `docs/language.md` §4): it carries out an
   operation and appends the answer, or appends a mark, after the comments the computation made
   since its last event. Each event is a new entry after the last, and `OnEntry` is called with
   it.
3. It stops when the run is over, when a read waits for a notice, or at a limit. It gives the
   last entry, and why it stopped. The session waiting for a call is a wait like any other.

`settle` appends the marks alone, with no world: a run whose call was just appended is at its
first wait, so a person's next call finds it waiting.

`append` is how something from outside enters a log: a notice, or a break, after `tip`. It
replays the log first, and refuses what the log cannot take:

| Event | Taken only |
| --- | --- |
| a break | where a call is open in its frame |
| a notice | while the run is not over |

What a person may append beyond that is the front end's to say. The command line takes a message,
a change or a reply only while a call of the session runs, and a call only where the session
waits for one (`Session.admitsNotice`, `Session.admitsCall`).

Appending at an entry that already goes on is a fork: the entry has two continuations, and
each is a log.

- **Draws.** A sample from an entry that has `n` sampled continuations takes draw `n` of its
  request. So the first sample from an entry takes draw 0, which is the response the cache
  kept if the run crashed after its model answered; and driving a point again takes a new draw.
- **Time.** Each entry records how long its event took, and a run's time is the sum along its
  log. A response counts for the time its draw took, also when the cache gives it.
- **Limits** are checked before an operation and before a read of the inbox, so a paused run
  stops where a message a person appends is heard at once. A read that takes calls alone is not
  held: it starts no work of its own. A limit writes nothing, and holds every call, a grader's
  too.
- **Failures.** A failure that is not an answer (`docs/language.md` §3.4) stops `drive` with an error, and nothing is
  logged for the operation; the next `drive` asks for it again. So a command happens at least
  once: what it does beyond the workspace may happen twice.

### 2.1 The data directory

A data directory holds a forest of runs, their workspaces, and the model cache
(`docs/log-schema.md` §4). `Alaya.Runtime.Data` and `Alaya.Runtime.Commands` give every command
of `alaya` as a function over it. Each returns a typed value, and a front end only parses and
prints. Each takes the scope the run's call is made in, so the runtime knows no catalog of
programs, and a front end says with `admit` what a person may append beyond what the log takes.

```lean
Data.with   : FilePath → (Data → Result α) → (write create : Bool) → Result α   -- holds the lock to write
Data.create : FilePath → Source → Scope Agent → RoutineCall → Result (Array Appended)  -- a new run
Data.call / tell / stop / commit / reply / comment : … → Result Appended         -- what a person appends
Data.withRuntime : Data → RunOptions → Option Provider → … → (Runtime → Result α) → Result α
Data.resume : Data → Routine Agent → String → Runtime → Limits → … → Result (Hash × Stop × Log Agent)
Data.rebase : Data → Array Entry → Rebased Agent → (target : FilePath) → String → Result (Array Appended)
Data.visitsAt / visitAt / waiting / changes                                     -- what a run did
```

