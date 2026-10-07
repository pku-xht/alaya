# The language

Agent runs must survive crashes and remain available for analysis, so Alaya separates deciding
from acting, in three parts. The **computation** is a value that says what to ask the world for
next. The **log** is the flat, append-only list of what happened in a
run. The **driver** replays the computation against the log to find what it asks next, carries that
out, and appends the answer.

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontFamily": "BlinkMacSystemFont, Segoe UI, Helvetica, Arial", "fontSize": "13px", "primaryColor": "#f6f7f9", "primaryTextColor": "#1c1e21", "primaryBorderColor": "#d3d9e0", "lineColor": "#a3abb5", "textColor": "#6f7985", "edgeLabelBackground": "#ffffff", "clusterBkg": "#fafbfc", "clusterBorder": "#e3e6ea"}}}%%
flowchart LR
  classDef notice stroke:#7556a3

  computation("<b>computation</b><br/>decides: asks,<br/>does not act")
  log("<b>log</b><br/>remembers: flat,<br/>append-only")
  replay("<b>replay</b><br/>next run log")
  driver("<b>driver</b><br/>acts")
  world("<b>the world</b><br/>model · executor<br/>clock · container")
  person("<b>a person</b>"):::notice

  computation --> replay
  log -- "read from its root" --> replay
  replay -- "what the run<br/>does next" --> driver
  driver -- "carries out<br/>an operation" --> world
  world -- "its answer" --> driver
  driver -- "appends the answer,<br/>or a mark" --> log
  person -- "appends a notice<br/>or a break" --> log
  linkStyle default stroke-width:1px
```

| § | What | Where |
| --- | --- | --- |
| 1 | a **computation**: a tree of what it asks for | `Alaya.Core.Computation` |
| 2 | the **log** and its **events** | `Alaya.Core.Computation` |
| 3 | what each construct of a computation writes in the log | `Alaya.Core.Replay`, `Alaya.Runtime.Agent` |
| 4 | **replay**: from the log back to the computation | `Alaya.Core.Replay` |
| 5 | **routines** and **scopes**: how a computation is structured | `Alaya.Core.Computation` |

How a run is driven, and the data directory, are `docs/runtime.md`; the tools and the agents built in
this language, `docs/agents.md`. `docs/log-schema.md` specifies how a log is stored; `docs/cli.md`
is the command line.

## 1. A computation

```lean
inductive Computation (σ : Signature) : Type → Type 1 where              -- Alaya.Core.Computation
  | pure    : α → Computation σ α                                          -- a leaf: a value
  | fail    : Failure → Computation σ α                                    -- a leaf: a failure
  | perform : (op : σ.Op) → (Except String (σ.Answer op) → Computation σ α) →
              Computation σ α
  -- the other constructors (inbox, ask, call, iter, comment) are omitted here; see §3

abbrev Agent : Signature            -- Alaya.Runtime.Agent: its operations are sample, exec, time
```

A computation of Alaya has the type `Computation Agent α`: it asks for operations of the signature
`Agent`, and ends with an `α`. It is represented as a tree whose leaves are values or failures,
and whose inner nodes are requests, with a subtree for each possible answer. This representation
is known as the free monad (Hancock and Setzer 2000; Kiselyov and Ishii 2015).

```lean
def fix : Computation Agent String := do
  let response ← sample model request
  match response.content? with
  | none => return "nothing to do"
  | some command =>
    let ran ← exec command
    if ran.output.exitCode? == some 0 then
      return "fixed"
    else
      throw (.refused "the command failed")
```

*The computation `fix` as a tree: an operation is a node, and each answer leads to the rest of the
computation.*

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontFamily": "BlinkMacSystemFont, Segoe UI, Helvetica, Arial", "fontSize": "13px", "primaryColor": "#f6f7f9", "primaryTextColor": "#1c1e21", "primaryBorderColor": "#d3d9e0", "lineColor": "#a3abb5", "textColor": "#6f7985", "edgeLabelBackground": "#ffffff", "clusterBkg": "#fafbfc", "clusterBorder": "#e3e6ea"}}}%%
flowchart TD
  classDef sample stroke:#3567a0
  classDef exec stroke:#2b6f6f
  classDef ok fill:#dcf1e2,stroke:#2a7a4b,color:#1c5c33
  classDef bad fill:#f8dfdd,stroke:#b3261e,color:#8a2a25

  asked("perform (sample request)"):::sample
  asked -- "a response with no text" --> nothing("pure “nothing to do”"):::ok
  asked -- "a response that says make" --> ran("perform (exec “make”)"):::exec
  asked -- "an error" --> errored("fail error"):::bad
  ran -- "exit 0" --> fixed("pure “fixed”"):::ok
  ran -- "exit 2" --> broken("fail (refused “the command failed”)"):::bad
  linkStyle default stroke-width:1px
```

A computation is written in `do` notation, from eight constructs:

| Written | Asks for | Goes on with |
| --- | --- | --- |
| `return a` | nothing: it ends with `a` | |
| `throw failure` | nothing: it gives up | |
| `sample`, `exec`, `time` | an operation of the world | its answer |
| `inbox`, `await` | the notices that arrived from outside | those it takes |
| `ask question` | a person's answer to a question | the reply |
| `call name arguments` | a routine, by its name | the routine's result |
| `iter step state` | a loop from `state` | the result of its last round |
| `comment text` | a line in the log, for a reader | nothing |

`try … catch` catches a failure, but a defect (§3.4), and `retry n c` tries a computation `c`
again while it fails.

## 2. The log

```lean
inductive Event (σ : Signature) where
  | arrived   (notice : Notice)                              -- from outside
  | heard     (frame : Frame) (notices : Array Nat)          -- a read of the inbox
  | asked     (frame : Frame) (question : Question)          -- a question for a person
  | answered  (frame : Frame) (key : σ.Key) (answer : Except String σ.Stored)
  | opened    (frame : Frame) (call : RoutineCall)           -- a call begins
  | returned  (frame : Frame) (value : Json)                 -- … and ends with its value
  | failed    (frame : Frame) (failure : Failure)            -- … or with its failure
  | broke     (frame : Frame) (reason : String)              -- from outside: the call open in `frame` ends
  | commented (text : String)                                -- for a reader only

abbrev Log (σ : Signature) := Array (Event σ)
```

A log is an array of events, and an event's **position** is its index. There are four kinds of
event:

| Kind | Events | Appended |
| --- | --- | --- |
| from outside | `arrived`, `broke` | by a person, at any time; it is in no frame |
| answer | `answered` | by the driver, after it carried out an operation |
| mark | `heard`, `asked`, `opened`, `returned`, `failed` | by the driver, where the computation did something that needs no world |
| comment | `commented` | by the driver, for the computation, or by a person; it has no frame |

Marks make the log readable without the computation: who read which notice, where each call began
and how it ended.

A **notice** is what arrives from outside:

```lean
inductive Notice where
  | said     (message : String)                       -- a person's message
  | changed  (workspace : Snapshot) (summary : String)   -- the workspace, changed from outside
  | replied  (to : Frame) (reply : Reply)             -- an answer to the question asked in frame `to`
  | called   (call : RoutineCall)                     -- a call asked for from outside
```

A **frame** says which call of a routine (`call name arguments`, §3.3) an event happened in. It
lists, from the outermost call inward, each call by the routine's name and by how many calls of
that name its caller made before it. A run is itself a call, made from outside
(`docs/runtime.md` §1): in a run of MiniSwe, `mini-swe` is the agent's call, and
`mini-swe/bash#2` its third call of `bash`. `#[]` is the outside, where nothing of the run runs;
it is written `-`.

A frame keeps its identity when a program changes around it: a call of one routine does not
move the calls of another. An agent that comes to call `ask_user` first still has its first
`bash` in `mini-swe/bash`.

*The log of the agent below.*

![The log of a small agent, beside its computation](figures/agent-api/log.svg)

```lean
def agent (task : String) : Computation Agent Json := do
  let _ ← inbox                                             -- 4: read what a person said
  let response ← sample model (request task …)              -- 5
  let ran ← exec "make"                                     -- 6
  return "fixed"                                            -- 7
```

Every log begins the same way. Position 0 is the **root**, `arrived (changed …)`: the
**workspace**, the filesystem directory the agent works in, as the run starts. Position 1 is the
run's call, here of the agent, a notice; position 2 the outside's read of it, and position 3 the
opening of the call (`docs/runtime.md` §1).

## 3. What each construct writes

As the driver runs a computation, it appends to the log what happened at each construct it reaches:
the answer the world gave to an operation, or a mark of what the computation did there.

### 3.1 Operations

```lean
sample   : Models.Spec → Chat.Request → Computation Agent Chat.Response
exec     : String → Executor.Config → Computation Agent Execution  -- the config defaults to {}
time     : Computation Agent Timing
```

1. The computation reaches an operation. It stops there: it has asked.
2. The driver carries the operation out.
3. The driver appends `answered frame key answer`: the frame that asked, the operation's key,
   and what the world gave.
4. The computation goes on with the answer. On every later replay the answer is read from the log:
   an operation whose answer is logged is not carried out again.

![Three operations, each answered by its part of the world](figures/agent-api/perform.svg)

| Operation | Carried out by | Answer |
| --- | --- | --- |
| `sample model request` | the model it names, by its spec | `Chat.Response` |
| `exec command config` | the executor: `command` in the container of the call it is made in, on the workspace, with `config`'s timeout and environment, and its stderr merged into its stdout unless `config.merge` is off | `Execution`: the output, the version of the workspace it left, and with `config.outputs` the file that holds the whole output |
| `time` | the driver: the run's time summed along its log | `Timing`: the time spent, and the budget of this invocation |

A command that exits with an error, or runs out of time, is still an answer: its status is in
the output. Only an answer the world could not give is a failure (§3.4).

The log records every version of the workspace, by the name of its snapshot. A command runs on
the version of the workspace the log has reached, and its answer names the version it left. A
person's change is a notice that names a version too, which no read takes (§3.2). So the workspace at any point of a run is
the last version a command or a change left before it, and that point can be checked out,
compared, or continued.

![The versions of the workspace along a log](figures/agent-api/workspace.svg)

### 3.2 Notices: `inbox` and `await`

`inbox` and `await` receive notices from outside: `inbox` takes whatever has arrived, possibly
nothing, and `await` waits until the notices it is for arrive.

```lean
inbox : Computation σ (List Notice)                                    -- take what has arrived
await : (Frame → Notice → Bool) → (one := false) → Computation σ (List Notice)  -- wait for them
```

1. A person appends a notice: `arrived notice`. No one has read it yet.
2. `inbox` takes every message not yet read: what a person said. The driver marks the read,
   `heard frame positions`, with the positions of what it took, which may be none.
3. `await accepts` takes the unread notices that `accepts frame notice` holds for; with `one`,
   only the first of them, as a wait for a call takes one call. When none has arrived, the read
   is not made: the run **waits**, and the driver stops. Once one arrives, the read is made and
   marked like any other.
4. A `replied` and a `called` notice are **addressed**: to the call that asked, and to whatever
   waits for a call. Only an `await` for them takes them; a plain `inbox` leaves them.
5. A `changed` notice is for no reader. What it says may be out of date by the time a read would
   take it; it changes the files the next command runs on, which a computation sees by looking.
   A person who wants the agent told says so in a message, as `alaya commit` does.

![Notices arrive from outside, and reads take them](figures/agent-api/inbox.svg)

A notice is read once, by one read, and the mark says by which.

### 3.3 Calls

`call` runs a routine, a named computation (§5), in a frame of its own, and gives back its result.

```lean
call : (name : String) → (arguments : Json) → (environment? : Option Json := none) → Computation σ Json
```

1. The computation calls a routine by its name. The driver marks the call,
   `opened child ⟨name, arguments⟩`. The **child frame** is the caller's frame and a step for
   the call: the routine's name, and how many calls of it the caller made before, as in
   `mini-swe/bash`, then `mini-swe/bash#1`.
2. The routine the caller's scope has under that name (§5) runs in the child frame: its
   operations are performed there, and its own calls open frames nested in it.
3. Its commands run in the environment the call names, when it names one: an image, and where
   the workspace is mounted. Otherwise they run where its caller's do. What a call can reach is
   fixed where its routine is defined (§5); where it runs is its caller's to say.
3. The routine ends, and the driver marks how: `returned child value`, or `failed child failure`.
4. The caller goes on with the value. A failure is the caller's too, unless it catches it.

![Two calls of a routine, each a bracket in the log](figures/agent-api/call.svg)

Because a call names its routine instead of holding its body, the log records it in full. Every
routine is entered through a call, so a call and the calls nested in it occupy one contiguous
stretch of the log, between its opening and its end, apart from notices that arrive meanwhile.
This flat encoding of nested scopes follows scoped operations (Wu, Schrijvers and Hinze 2014;
Piróg et al. 2018). A call of a name with no routine fails in its new frame, with the defect
`no routine named …`.

### 3.4 Failures

A failure is of one of three kinds, each with its reason:

| Kind | What it says | Caught by `try … catch` |
| --- | --- | --- |
| `refused` | what the computation was given cannot be used: wrong data, a question that cannot be asked, a request the world refused | yes |
| `defect` | a bug a correct program does not have: a routine its scope lacks, settings it cannot read, a result that cannot be read back | no: it fails every call it is in, up to one whose continuation takes any failure, as the session's does |
| `broken` | the call was broken from outside (§3.7) | yes, by its caller |

- `throw failure` gives up, up to the nearest `try … catch` in the same frame, or to the end of
  the frame.
- An operation whose answer is an error is refused where it was performed. Currently, the only such
  answer is a model's refusal of a request as too long for its context. Any other trouble with
  the world — a provider that cannot be reached, a container that cannot be started, a full disk
  — is not an answer: the driver stops, nothing is logged, and the next `alaya resume` asks again.
- A failure that reaches the end of its frame is marked, `failed frame failure`, and becomes the
  failure of the call, of the same kind.
- `try … catch` leaves no mark. Nothing is rolled back: what a failed routine did stays in the
  log.

![A failed sample ends its routine, and the caller catches the failure](figures/agent-api/failure.svg)

`retry n c` tries `c` again while it fails, `n` times more; every try is in the log.

### 3.5 Loops

```lean
iter : (S → Computation σ (S ⊕ α)) → S → Computation σ α
```

1. `iter step state` runs `step state`: one **round**.
2. A round that gives `.inl state'` is followed by a round from `state'`; one that gives
   `.inr result` ends the loop with `result`.
3. The loop writes nothing of its own. The log holds the events of its rounds, one after
   another.

![A loop of three rounds: the log holds their events, flat](figures/agent-api/loop.svg)

A loop carries its state as an ordinary value, such as the conversation so far or a turn
counter, from which each round computes its request and checks limits on turns or context size.

Every round must read an event: an operation, a read of the inbox, or a call. A loop that goes
round without one is `unguarded`, a broken run. This is what makes replay of a finite log end.
A loop as a constructor whose every round performs is from Hancock and Setzer (2000); `iter`
itself is the loop of interaction trees (Xia et al. 2020).

### 3.6 Comments

```lean
comment : String → Computation σ Unit
```

A comment is a line for whoever reads the log, `commented text`, shown as `# text` by `alaya log`
and the report. A computation writes one with `comment`, and a person with `alaya comment`; the two
are the same event.

Replay passes over every comment: those in the log, and those the computation makes. A comment of
the computation matters only at the end of the log, where the driver writes it before the next event
it appends. So comments can be added to an agent, reworded or removed, and every existing log is
still a log of that agent. `alaya rebase` writes an agent's new comments into a copy of an
existing log. A comment does not guard a loop.

### 3.7 Breaks

A break is not a construct of a computation. It comes from outside, `broke frame reason`,
appended where a call is open in `frame`; `alaya stop` appends one.

1. The call open in `frame` ends there, and every call inside it, whatever the nesting, with no
   marks.
2. Nothing inside the call can catch it.
3. Its caller goes on with `broken reason` as the call's failure, and may catch it. A break of
   the run's own call ends the run.

![A break ends the call open in its frame, and its caller goes on](figures/agent-api/stop.svg)

### 3.8 Questions: `ask`

```lean
ask : Question → Computation σ Reply

structure Question where
  text : String
  form : Question.Form := .openEnded

inductive Question.Form where
  | yesNo
  | openEnded
  | singleChoice (options : Array String)     -- exactly one of the candidates, or none of them

inductive Reply where
  | yes
  | no
  | choice (number : Nat)                     -- the candidate chosen, numbered from 1
  | noneOfAbove
  | text (text : String)                      -- an answer in the person's own words
  | unavailable                               -- the person cannot answer
```

1. The computation reaches `ask question`. A question that cannot be asked — a blank one, or a
   choice with fewer than two distinct candidates — fails there.
2. The driver marks it, `asked frame question`. So the question is in the log, whoever asks it.
3. The run waits for a reply to that frame that fits the question, and the driver stops.
4. A person replies: `arrived (replied frame reply)`. A reply where no question waits, or one
   that does not fit, is refused before it is appended.
5. The read is marked like any other, and the computation goes on with the reply.

There are three kinds of question and six kinds of reply:

| Kind of question | A reply that fits |
| --- | --- |
| `yes_no` | `yes`, `no` |
| `single_choice` | `choice n`, with `n` from 1; `noneOfAbove`: no candidate is right |
| `open_ended` | `text`, not blank, kept verbatim |
| any | `unavailable`: the person cannot answer |

Any computation may ask: a tool a model calls (`docs/agents.md` §2), or a step of a workflow that wants a person's
word before it goes on.

```lean
def deploy : Routine.Typed Agent String Bool := routine "deploy" fun target => do
  let reply ← ask { text := s!"Deploy to {target}?", form := .yesNo }
  if reply != .yes then return false
  return (← exec s!"make deploy TARGET={target}").output.exitCode? == some 0
```

```lean
questionOf? : Next Agent → Option (Frame × Question)        -- the question a run waits on
replyTo     : Next Agent → Reply → Except String (Event Agent)   -- the reply as an event, or why not
```

## 4. Replay: from the log back to the computation

```lean
next : Routine σ → Log σ → Next σ      -- what a run of the routine does after a log
```

The driver keeps nothing of a computation between two events. It calls `next`, which
**replays** the run's routine against the log from its root. Running a computation again from
the start with its recorded answers, in place of saving where it had got to, is how durable
workflows survive a crash (Koppel, Scherer and Solar-Lezama 2018; Burckhardt et al. 2021):

- an `answered` event is given to the computation as the answer of the operation it asks for there;
- a mark is checked against the mark the computation makes there;
- an `arrived` notice is set aside until a read takes it.

At the end of the log, replay reaches a construct the log does not yet record. `next` returns
it, and the driver acts on it as follows:

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontFamily": "BlinkMacSystemFont, Segoe UI, Helvetica, Arial", "fontSize": "13px", "primaryColor": "#f6f7f9", "primaryTextColor": "#1c1e21", "primaryBorderColor": "#d3d9e0", "lineColor": "#a3abb5", "textColor": "#6f7985", "edgeLabelBackground": "#ffffff", "clusterBkg": "#fafbfc", "clusterBorder": "#e3e6ea"}}}%%
flowchart TD
  classDef notice stroke:#7556a3
  classDef ok fill:#dcf1e2,stroke:#2a7a4b,color:#1c5c33
  classDef bad fill:#f8dfdd,stroke:#b3261e,color:#8a2a25
  classDef wait fill:#fbe9cf,stroke:#a8690f,color:#7a4a08

  person("a person"):::notice -- "appends a notice" --> next("next run log")
  next -- "waits" --> waits("stop: wait for a person<br/>a call, a reply, a message"):::wait
  next -- "ended" --> over("the run is over"):::ok
  next -- "mismatch ·<br/>unguarded" --> refuse("refuse: the log<br/>is not a trace<br/>of the computation"):::bad
  next -- "mark" --> mark("append<br/>the mark")
  mark --> next
  next -- "ask" --> act("carry out<br/>the operation") --> answered("append answered")
  answered --> next
  linkStyle default stroke-width:1px
```

| `Next` | What the log says |
| --- | --- |
| `ask request` | it ends where the computation asks for an operation, which the world answers |
| `mark event` | it ends where the computation makes a mark: `heard`, `asked`, `opened`, `returned` or `failed`, which is appended as it is |
| `waits frame question?` | it ends where a read waits, and nothing the read is for has arrived; with the question, when it waits for a reply |
| `ended result` | it is complete: the run is over, with its value or its failure |
| `mismatch position` | its event at `position` is not what the computation does |
| `unguarded frame` | the computation went round a loop without reading an event |

Three rules make a computation one that can be replayed:

- **It is a function of its answers.** What it asks next is computed from what came back
  before: earlier answers, notices, and the run's configuration, all of which are in the log. It
  reads no clock and no file of its own.
- **Every round of a loop reads an event** (§3.5).
- **What comes from outside comes through the inbox** (§3.2).

A log is matched by position, so a computation changed after a log was written reads that log only
up to its first changed operation; after it the log is a `mismatch`, which the driver refuses
to go on from. Comments are the exception (§3.6). `alaya rebase` copies the prefix that holds
into a data directory of its own, as the changed computation makes it (`docs/cli.md`).

## 5. Routines and scopes

A **routine** is a computation from its arguments to its result, both JSON, under a name, with
a scope: the routines it can call. It is the one way to structure an agent: a tool, a step
of a workflow, a sub-agent and the agent itself are routines, and each runs in a frame of its
own (§3.3). A **scope** is a set of routines, by name. The run itself is a call of a routine,
made from outside (`docs/runtime.md` §1).

```lean
structure Routine σ where
  name  : String
  body  : Json → Computation σ Json            -- from the arguments to the result
  scope : Scope σ                              -- the routines it can call

structure Scope σ where
  find : String → Option (Routine σ)

Scope.of  : Array (Routine σ) → Scope σ                    -- these routines
Scope.fix : (Scope σ → Array (Routine σ)) → Scope σ        -- routines that see each other

structure Routine.Typed σ α β where            -- a routine as Lean code calls it
  name : String
  body : Json → Computation σ Json
  call : α → Computation σ β                   -- the call, typed

routine : String → (α → Computation σ β) → Routine.Typed σ α β   -- α and β to and from JSON
Routine.Typed.within : Routine.Typed σ α β → Scope σ → Routine σ
```

1. **Declare it** with `routine name body`. The body takes a typed argument and gives a typed
   result.
2. **Give it its scope** with `within`. Routines defined together take theirs from `Scope.fix`.
3. **Call it** with `r.call argument`, from a routine of that scope. A routine a model names is
   called by that name: `call name arguments` (`docs/agents.md` §1).

**How a call finds its routine.** Every frame runs the body of one routine: the run's own frame
runs the run's routine, and every other frame runs the routine whose call opened it. When a body
performs `call name arguments`, the name is looked up in the scope of the routine whose body
that is. The routine found runs in a new frame. The calls its body makes are looked up in the
found routine's own scope, not in the caller's.

So the routines a call can reach depend only on the routine the call is written in. They do not
depend on who called that routine, or from where. This is lexical scoping: a routine carries
its scope as a closure carries its environment. In Alaya's own agents:

| Routine | Its scope: the routines it can call |
| --- | --- |
| `basic` | `bash`, `ask_user` |
| `mini-swe` | `bash` |
| `mini-vero` | `bash`, `ask_user`, `time_budget`, `subagent`, and `mini-vero` itself |
| `subagent`, within `mini-vero` | the same as `mini-vero`'s |
| `bash`, `ask_user`, `time_budget` | none |
| `grader` | none |

A call of `bash` made by `mini-swe` finds `bash` in `mini-swe`'s scope. The same call made by the
run finds nothing, since the catalog has no `bash`, and fails with `no routine named bash`. A
call of `grader` made by `mini-swe` fails the same way, so an agent cannot reach the grader.

A scope is fixed when its routines are defined, so it holds no per-call data. What varies from
call to call, such as an agent's configuration or a command's timeout, is in the call's
arguments, and so is in the log.

**Building a scope.** `Scope.of routines` is a scope of routines that already have their own
scopes; the catalog is built this way. Routines that call each other need more. Each must have,
as its own scope, the scope that contains all of them, and that scope exists only once they do.
`Scope.fix make` resolves the circle, as `letrec` does. `make` receives the scope being built and
returns the routines, each given that scope; the result contains them all. This is how
`mini-vero`'s scope contains `mini-vero` itself, so that `subagent` can call it, and how the steps
of a workflow call one another.

The argument and the result cross the call as JSON, because that is how the log holds them: the
argument on the opening, the result on the end. Each side reads what it is given, and fails in
its own frame when it cannot.

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontFamily": "BlinkMacSystemFont, Segoe UI, Helvetica, Arial", "fontSize": "13px", "primaryColor": "#f6f7f9", "primaryTextColor": "#1c1e21", "primaryBorderColor": "#d3d9e0", "lineColor": "#a3abb5", "textColor": "#6f7985", "edgeLabelBackground": "#ffffff", "clusterBkg": "#fafbfc", "clusterBorder": "#e3e6ea"}}}%%
flowchart TD
  classDef bad fill:#f8dfdd,stroke:#b3261e,color:#8a2a25

  asks("caller · 0.0<br/>planner.call task")
  opened("the log<br/>opened 0.0.0 planner {goal: ship it}")
  body("routine planner · 0.0.0<br/>body task")
  returned("the log<br/>returned 0.0.0 {steps: […]}")
  plan("caller · 0.0<br/>plan : Plan")
  failed("the log<br/>failed 0.0.0 planner: its arguments cannot be read"):::bad
  unread("caller · 0.0<br/>the caller fails: its result cannot be read"):::bad

  asks -- "toJson" --> opened
  opened -- "fromJson" --> body
  opened -- "cannot be read" --> failed
  body -- "toJson" --> returned
  returned -- "fromJson" --> plan
  returned -- "cannot be read" --> unread
  linkStyle default stroke-width:1px
```

An agent of several parts is routines calling routines:

```lean
structure Task where
  goal : String
  deriving ToJson, FromJson

structure Plan where
  steps : Array String
  deriving ToJson, FromJson

/-- The model the planner samples. -/
def model : Models.Spec := …

/-- One round of the planner's conversation: a sample, then the tools the model called. -/
def planRound (messages : Array Chat.Message) :
    Computation Agent (Array Chat.Message ⊕ String) := do
  let response ← sample model { messages, tools := #[lookupDefinition] }
  if response.toolCalls.isEmpty then
    return .inr (response.content?.getD "")
  let mut messages := messages.push response.message
  for asked in response.toolCalls do
    -- the model's tool call is a call of a routine
    let result ←
      try call asked.name asked.arguments
      catch error => pure (.str s!"error: {error.reason}")
    messages := messages.push (.tool asked.id result)
  return .inl messages

/-- A sub-agent: a conversation of its own, with the tool it offers its model. -/
def planner : Routine.Typed Agent Task Plan := routine "planner" fun task => do
  let opening := #[.system "You plan.", .user task.goal]
  let answer ← iter planRound opening
  return { steps := (answer.splitOn "\n").toArray }

/-- A step of the workflow: one command, and its exit status. -/
def step : Routine.Typed Agent String Nat := routine "step" fun command => do
  let ran ← exec command
  return (ran.output.exitCode?.map (·.toNat)).getD 1

/-- The workflow: a plan from the planner, then each of its steps. -/
def workflow : Routine.Typed Agent Task String := routine "workflow" fun task => do
  let plan ← planner.call task
  let mut failed := 0
  for command in plan.steps do
    if (← step.call command) != 0 then
      failed := failed + 1
  return s!"{plan.steps.size} steps, {failed} failed"

/-- The routines the agent calls, defined together: each calls the others by name. -/
def scope := Scope.fix fun scope =>
  #[lookup.within scope, planner.within scope, step.within scope, workflow.within scope]

/-- The agent's configuration: what a person calls it with. -/
structure Config where
  task : String
  deriving ToJson, FromJson

/-- The agent: a routine, the workflow on the task of its configuration, that calls the
routines of `scope`. -/
def agent : Routine Agent :=
  (routine "agent" fun (config : Config) => workflow.call { goal := config.task }).within scope
```

A run of this agent is a call of `agent`, made from outside, with its configuration as its
arguments.

*The calls made when this agent runs, as a tree of frames.*

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontFamily": "BlinkMacSystemFont, Segoe UI, Helvetica, Arial", "fontSize": "13px", "primaryColor": "#f6f7f9", "primaryTextColor": "#1c1e21", "primaryBorderColor": "#d3d9e0", "lineColor": "#a3abb5", "textColor": "#6f7985", "edgeLabelBackground": "#ffffff", "clusterBkg": "#fafbfc", "clusterBorder": "#e3e6ea"}}}%%
flowchart TD
  agent("agent") --> workflow("agent/workflow")
  workflow --> planner("agent/workflow/planner")
  workflow --> make("step “make” · agent/workflow/step")
  workflow --> test("step “make test” · agent/workflow/step#1")
  planner --> lookup("agent/workflow/planner/lookup")
  linkStyle default stroke-width:1px
```

*Its log (`Test/Runtime/Routines.lean`): the same tree, flat. Each frame is one stretch of rows, from
its opening to its return.*

![The log of the workflow, its sub-agent and their tools](figures/agent-api/routines.svg)

Every sample names its model; an agent takes it from its configuration. A helper that is not a
routine, such as `planRound`, runs in its caller's frame and leaves no call in the log.

## References

- S. Burckhardt et al. Durable Functions: semantics for stateful serverless. OOPSLA 2021.
- P. Hancock, A. Setzer. Interactive programs in dependent type theory. CSL 2000.
- O. Kiselyov, H. Ishii. Freer monads, more extensible effects. Haskell 2015.
- J. Koppel, G. Scherer, A. Solar-Lezama. Capturing the future by replaying the past. ICFP 2018.
- M. Piróg, T. Schrijvers, N. Wu, M. Jaskelioff. Syntax and semantics for operations with
  scopes. LICS 2018.
- N. Wu, T. Schrijvers, R. Hinze. Effect handlers in scope. Haskell 2014.
- L. Xia et al. Interaction trees: representing recursive and impure programs in Coq. POPL 2020.
