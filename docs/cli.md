# The `alaya` command line

`alaya` drives runs from a shell, a script, a UI, or an agent such as Claude Code. Each command
is a thin layer over one operation of the driver (`Alaya.Driver`), of what a person appends
(`Alaya.Notices`), or of a reader of the forest (`Alaya.Render`, `Alaya.Html`); how they fit is
`docs/architecture.md`, and what they write is `docs/log-schema.md`. This page is the command
line itself: the commands, how a command line is read, what a command prints, and how it fails.

There are no states. A run is a log, a point of a run is an **entry** — one event and the entry
before it — and every command takes the entry it acts at. Acting at an entry that already goes
on is a fork.

## 1. Commands

```
alaya new [PROJECT] (--task TEXT | --task-file FILE) --agent NAME --model NAME --image IMAGE [--workdir PATH]
          [--set PATH=VALUE …]                 create a run
alaya config [--agent NAME] [--model NAME] [--set PATH=VALUE …]   the agents, models and providers, or what new would record
alaya run ENTRY [--provider NAME [--url URL] [--port N]] [--samples N] [--time-budget S]
          [--container-user UID:GID] [--network NAME]   drive a run on
alaya tell ENTRY TEXT                          append a person's message
alaya commit ENTRY DIR [--message TEXT]        append a change to the workspace: DIR's files, and what changed
alaya reply ENTRY (TEXT | --unavailable)       answer the question the log waits on
alaya grade ENTRY --grader CMD [--grader-input DIR] [--grader-image IMAGE] [--grader-timeout S]
                                               grade the run at ENTRY: stop the agent there, ask for the grader, run it
alaya stop ENTRY [--reason TEXT]               stop the agent there
alaya waiting                                  every log that waits for a reply, with its question
alaya tree                                     the forest: runs, their stretches of entries, their forks
alaya log ENTRY                                the log that ends at ENTRY, an event a line, and what comes next
alaya show ENTRY [--request]                   one entry in full, and the request a sample answered
alaya ls ENTRY [PATH]                          list a directory of the workspace at ENTRY
alaya cat ENTRY PATH                           print a file of the workspace at ENTRY, or preview it
alaya checkout ENTRY DIR                       write the workspace at ENTRY into DIR
alaya diff A B                                 the workspace changes between two entries
alaya html FILE [--hide DIR]                   write the forest as one self-contained page, for reading
alaya rm ENTRY                                 delete ENTRY, everything after it, and the snapshots only they named
alaya help [COMMAND]                           what a command takes; `help --json` for all of them
```

An `ENTRY` is an entry's name, or any prefix of it no other name has, or `PREFIX:N`, the entry at
position `N` of that entry's log, counted from 0, where the root is: `alaya grade 4f2c8b:120
--grader …` grades a fork of the log as it stood after the event at position 120. Every command but `config`, which reads no
run, takes `--data DIR`, and every command takes `--json` and `--help`.

A typical session:

```sh
# Create a run: its workspace, the agent's call with the run's configuration, and the task.
tip=$(alaya new --task-file TASK.txt ./project --agent mini-swe --model gpt-6-luna \
  --image my-task:1 | tail -n 1 | cut -d' ' -f1)
# Drive it until its agent is over; one line per entry.
end=$(alaya run "$tip" --provider apiyi | tail -n 1 | cut -d' ' -f1)
# Grade its end; the command exits with the verdict.
alaya grade "$end" --grader 'python3 /grader/grade.py' --grader-input ./hidden
# Grade the point where it went wrong: a fork stopped there, graded the same way, or by another grader.
alaya grade "$end:140" --grader 'python3 /grader/grade.py' --grader-input ./hidden
# Go on from that point with a message to the agent, as a new branch.
alaya tell "$tip:140" 'The parser is fine; look at the evaluator.'
```

## 2. Reading a command line

Every command declares what it takes (`Alaya.Cli`), and the command comes first. A command
refuses an option it does not take, naming the nearest one it does; a switch never takes the
next token; a valued option takes the next token, or its value after `=` (`--task=--literal`),
and may be given once; after `--` everything is an argument, which is how an answer that begins
with `-` is given. Every problem is reported at once. `alaya help`, `alaya help COMMAND` and
`alaya COMMAND --help` print what a command accepts, and `alaya help --json` describes every
command as data.

**The data directory.** Every command names it with `--data DIR`, or reads `ALAYA_DATA`; there
is no default, so a command run from the wrong place cannot quietly begin a new one. `new`
creates it, and every other command refuses a path that holds none. What it holds is
`docs/log-schema.md` §5.

## 3. Output

A command prints text for a reader by default, and JSON with `--json`. Every command that appends
— `new`, `run`, `grade`, `tell`, `commit`, `reply`, `stop` — prints each entry it appends on a line of its
own: its full 64-hex name, its position in its log, its frame, and its event in a few words.

```
d176eb02…5235  2  -    said "Create hello.txt"
b064afdd…73b  3  0    inbox: takes [2]
7a40c19e…d02  4  0    inbox: nothing
1cd9bd3f…4e6  5  0    sample → bash ls -la && cat README.md
310195fb…959  6  0.0  open bash "ls -la && cat README.md"
```

The last line is the entry the log now ends at, so a script takes it with `tail -n 1 | cut -d' '
-f1`. `run` and `grade` say how they stopped on stderr — `done: pass 48/48`, `stopped: fail
12/48`, `waits for a reply to: …`, `paused: …` — or, with `--json`, as a last object.

With `--json`, a command prints one JSON object per line:

| Command | Object |
| --- | --- |
| `new`, `run`, `grade`, `tell`, `commit`, `reply`, `stop` | each entry it appends: `{entry, parent, position, frame, summary, event, elapsed_ms}` |
| `run`, `grade` | then how it stopped: `{entry, status, …}`. Once the agent is over, `status` is how it ended — `done` with its `value`, `failed` with its `error`, `stopped` with the stop's `reason` — and `verdict` is the grader's verdict, or `null` while the log is not graded. Otherwise `waits` with `frame` and `question`, the one it waits on as `{text, form: {type, options}}`, or `null` when it waits for a task; or `paused` with `reason` |
| `config` | with no flags, a line for each agent, model and provider: `{agent}`, `{model}`, `{provider: {name, base_url, base_url_var, key_var, any_model, routes}}`; with `--agent` or `--model`, the one object `{agent, model}` that `new` would record |
| `tree` | every entry: `{entry, parent, position, summary, status}`, `status` how its log goes on, on an entry that ends one |
| `waiting` | every log that waits for a reply: `{entry, frame, question, question_type, options}`, the question's text and form side by side |
| `log` | every entry of the log: `{entry, position, frame, event, elapsed_ms}`, then `{next}` |
| `show` | `{entry, parent, position, event, elapsed_ms, run_time_ms, run_usage, workspace, calls, next, request}` |
| `ls` | `{entry, snapshot, path, entries}`, each entry `{name, path, kind, size}` |
| `cat` | a preview, `{entry, snapshot, path, kind, content, size}` (§5) |
| `diff` | `{changes}` |
| `checkout` | `{entry, snapshot, directory}` |
| `html` | `{file, bytes}` |
| `rm` | `{removed}` |

A failure is one JSON object on stderr (§4).

## 4. Failures and exit status

An outcome is 0 to 4. A failure has one of six statuses above them, the same for every command:
64 for a command line that does not parse, and one for each of the five classes a failure of a
command itself can have:

| Status | Meaning | What to do |
| --- | --- | --- |
| 0 | the command succeeded; `run`: the agent is over, returned or stopped; `grade`: the verdict is a pass | — |
| 1 | `run`: the agent failed; `grade`: the verdict is a fail | look at the log |
| 2 | `grade`: the verdict is an error — the grader did not finish, or printed no complete TAP | look at the grader's answer |
| 3 | `run`: the run waits for a person — a reply, or a task | `reply` or `tell`, then `run` from the new entry |
| 4 | `run`: `--samples` or `--time-budget` paused it | `run` from the entry it printed last |
| 64 | `usage`: the command line does not parse | fix the command line |
| 65 | `input`: it names something not there, in the wrong condition, or malformed — a log that is no trace of its run included | fix the request |
| 69 | `environment`: the machine lacks docker, an image, restic or an API key | fix the machine |
| 74 | `storage`: the data directory could not be read or written | look at the data directory |
| 75 | `transient`: another command is writing the data directory, or the provider was unreachable, throttled or failing after alaya's own retries | try again later |
| 76 | `model`: the provider rejected the request, or answered it wrongly | fix the model's settings, or the key |

The five from `input` on are `Error.Class`, which sorts the constructors of `Alaya.Error` by what
the caller does about them (`docs/llm-api.md` §4). A failure prints `error: MESSAGE` on stderr, or
with `--json` one object: `{"error": CLASS, "message": ...}`, with `status` and `retry_after_ms`
for an HTTP failure, and `problems` and `usage` for `usage`. One failure of the provider is no
failure of `run`: its refusal of a request as too long for the model's context is the answer the
agent's sample gets, in the log, and MiniSwe ends with `ContextExceeded` (`docs/architecture.md`
§6). Any other — a key it rejects, a request it rejects for another reason, a response it
garbles — stops `run` with its status, and nothing is logged for it.

A failed `run` keeps every entry it appended; the operation it was carrying out is asked for
again by the next `run` from the entry it printed last.

**One writer at a time.** A command that writes the data directory — `new`, `run`, `grade`,
`tell`, `commit`, `reply`, `stop`, `rm` — holds its lock (`DATA/lock`, `Alaya.Lock`) from start to end. A
second writer is refused at once, with status 75 and the holder's pid, rather than left waiting
for as long as a `run` drives; the operating system drops the lock when its holder exits, however
it exits, so none is ever left behind. Commands that only read — `tree`, `log`, `show`, `ls`, `cat`, `diff`, `waiting`, `html`, `checkout` — take no lock and run beside a
writer, so a run can be watched while it grows; one that reads while an `rm` deletes can fail
with `storage`.

One writer is what keeps a data directory consistent: the model cache is extended by one
process, two continuations of an entry never take the same draw, and `rm` never drops a snapshot
that an entry about to be written refers to. Work in parallel goes to several data directories,
one per worker or per arm of an experiment, each its own forest with its own cache. A command
killed outright leaves its scratch under `DATA/tmp/` behind.

## 5. Commands in detail

### `new`

`new` takes the task as `--task TEXT` or `--task-file FILE`, one of the two. The file is read by
`alaya`, relative to the current directory, not from the image, as it is, not trimmed or
rewritten, and must be UTF-8; a missing or unreadable file is an error before anything is
created. Stdin is the file `/dev/stdin`. The task is the notice the agent waits for, the third
event of the log, so the first request carries all of it.

**The agent and the model.** Both are configured the same way, with defaults in code and
overrides on the command line; there are no configuration files, and an experiment's arms are
named in the script that runs it.

- `--agent NAME` names an agent — `mini-swe` (`docs/miniswe.md`) or `mini-vero`
  (`docs/minivero.md`). `--model NAME` names a model by its ID as its creator publishes it, with
  no provider prefix — `gpt-oss-120b`, `gpt-6-luna`, `deepseek-v4.1-flash` — whose defaults are a
  row of the model table: its context and output sizes when known, default `params`, and whether
  its earlier reasoning is sent back (`echo_reasoning`; `docs/llm-api.md` §3).
- `--set PATH=VALUE`, repeatable and applied in order, overrides one field. PATH starts with
  `agent.` or `model.` and continues into that object (`agent.mode`,
  `agent.executor.timeout_seconds`, `agent.tools=["bash","submit","ask_user"]`,
  `model.params.reasoning_effort`, `model.context_tokens`), and VALUE is read as JSON when it
  parses and as a string otherwise. Each `--set` replaces exactly one key, with no deep merging;
  an unknown field, or a value of the wrong type, is an input error naming it.

`alaya config`, which takes no `--data`, lists every agent and model with its complete defaults,
and every provider with the names it serves models under; `alaya config --agent NAME --model NAME --set …` prints exactly
the configuration `new` would record, creating nothing. Both are recorded complete in the opening
of the agent's call, which `show` prints, and every later command builds them from there.

**The image and the workdir.** `new` requires `--image`, resolves it to a digest and records it:
every command of the run runs in it. A recorded image that is missing is pulled by its digest;
one recorded as a local build's ID cannot be, and has to be rebuilt or `docker load`ed. The
workspace is mounted at `--workdir`, `/workspace` unless given. Without a `PROJECT`, `new` copies
the image's own `--workdir` out as the workspace the run starts on: task images that install
their project in place, such as SWE-bench's at `/testbed`, work as they are. A workdir is an
absolute, clean path other than `/`, and not `/grader`, which a grader mounts, nor in or around
`/alaya/outputs`, where a command reads the whole output of an earlier one (`docs/miniswe.md`
§9). `new` reads the image's `uname`, which the agent tells its model.

`new` takes no grader: a grader is no part of a run, and is given to `grade` when a point of the
run is graded.

### `run`

`run` replays the log that ends at `ENTRY` and drives it on, until its agent is over, it waits
for a person, or it reaches a limit. A log that is no trace of its run's program — one edited by
hand, or written by another version of the agent — is refused (65).

`--provider NAME` — and for `dgx`, `--url`/`--port` — names who serves the run's model, for this
invocation alone; a run may be driven through any provider that serves its model, and one that
cannot meet what the run recorded is refused before any request (`docs/llm-api.md`). It is needed
only when the run samples. The model
cache keys on the model alone, so a response is reused whichever provider sent it.
`--container-user` and `--network` say how this invocation's containers run; a container runs
with **no network** unless `--network` names one.

**Limits.** `--samples N` (default 0, no limit) pauses before the agent samples its `N+1`th
response, or reads its inbox after the `N`th; `--time-budget SECONDS` (default 0, no limit)
pauses before anything the agent does once the run's time, summed along its log, is spent.
Neither is recorded
except where the agent times the run (`time_budget` reports the budget). A paused run is driven
on by a later `run` from its last entry — with a larger budget, or none — and a person may append
there first: what they add is heard before the next sample. A paused run is graded as it stands
with `grade`, which stops it there.

**Exit.** 0 when the agent is over, returned or stopped, with how it ended on stderr, and the
verdict of a log that was graded; 1 when the agent failed; 3 when the run waits for a reply or a
task; 4 when it paused. A `run` from an entry where a `grade` was interrupted runs the grader
that was assigned.

### `grade`

`grade ENTRY --grader CMD` grades the run as it stood at `ENTRY` (`docs/log-schema.md` §4). If
the agent is still running there, it appends a stop, on a fork when the log already goes on; it
assigns the grader, a notice; and it drives the run to its end, the grader's verdict. It needs
no provider: the agent does not go on.

`--grader CMD` is the grader's command, which prints TAP; `--grader-input DIR`, its trusted
files, snapshotted now and mounted read-only at `/grader`; `--grader-image IMAGE`, the image it
runs in, pinned now, by default the run's; and `--grader-timeout S`, 900 unless given, 0 for
none. `--container-user` says whom the grader's container runs as, as for `run`; it never has a
network.

```sh
alaya grade 4f2c8b --grader 'python3 /grader/grade.py' --grader-input ./hidden      # the end of a run
alaya grade 4f2c8b:140 --grader 'python3 /grader/grade.py' --grader-input ./hidden  # an earlier point
alaya grade 4f2c8b --grader 'sh /grader/strict.sh' --grader-input ./hidden          # the end again, by another
```

A log has one grader. Where the log at `ENTRY` has one already, `grade` assigns the new one on
a fork, from the entry before the first was assigned, so a point is graded again beside its
first verdict, and `tree` shows both.

**Exit.** With the grader's verdict: 0 a pass, 1 a fail, 2 an error.

### `tell`, `commit`, `reply` and `stop`

Each appends one event after `ENTRY` and prints the new entry. `tell` appends what a person says;
`commit` snapshots `DIR`, lists what changed from the workspace the log has reached — `M path`,
`+ path`, `- path` — and appends the change with `--message` after the list, refusing a directory
with no change; `checkout` writes the files to edit. `reply` answers the question the log waits
on, read against its form (`docs/ask-user.md`), or with `--unavailable` that the person cannot,
and is refused where no question waits. `stop` ends every frame of the agent there, with
`--reason`: the run is over at that point, as `grade` makes it before it assigns its grader.
None of them appends once the agent is over, where there is nothing to stop and no one to read
it. A message or a change is taken
by the agent at its next read of its inbox, which MiniSwe makes at the start of every round. A
reply is taken by the `ask_user` call that waits for it, and by nothing else. A stop is not read
at all: it ends the agent where it is.

### `tree`, `log` and `show`

`tree` shows each run — its agent and model — and then every stretch of entries with no fork in
it as one line: where it starts and ends, its positions, its last event, and, at the end of a
log, how the log goes on: `done: pass 48/48` or `stopped: fail 12/48` for a run that is over
and graded, how its agent ended and its verdict; `done: Submitted: …` for one not graded, what
its agent gave; `waits for a reply: …`; `next: …`. Stretches that
fork from an entry are indented under it. `log` prints a log an event a line with the run's time
so far, and what the run does next. `show` prints one entry in full — its event, its time and the
run's, the run's tokens so far, the calls open there, what comes after it — and with `--request`
the request a sample answered, as replay makes it.

### `ls`, `cat`, `checkout` and `diff`

They read the workspace at an entry: the version its log has reached, or, on the answer of a
grader's program, the checkout as the grader left it, which is how a report a grader wrote is
read. They read a snapshot directly, without restoring it. A path is clean and relative to the
workspace's root (no `..`, no leading `/`); a symbolic link is listed, but never followed, and
`cat` prints only regular files, byte for byte. `ls` prints each entry's size and path, by name,
with `/` after a directory and `@` after a link. `cat --json` previews any entry instead: a
regular UTF-8 file of up to 1 MiB is `text` with its `content`, and anything else says only what
it is — `binary`, `too_large`, `symlink`, `directory` or `other` — so a page can show a snapshot
without reading what it should not.

### `html`

`html FILE` writes every log of the forest as one page that only shows: it runs nothing, sends
nothing, and needs nothing beside it. Its title is `alaya` and the data directory as it was
given, so a page to be passed on is best written from a relative path.

On the left are two lists of the same rows. The first is the branches of each run, by how each
departs and how its log ends; the second is the log of the chosen branch, an entry a row,
indented by the frame of the call it is in, with a switch on every entry where branches fork.
The box above them finds text in the chosen log, and Enter goes to the next match.

On the right is the page of the chosen entry, laid out the same for every kind: what it is and
the calls it happened in; a few facts, such as a response's tokens and how full the model's
context was, or a command's exit status; what it holds — a response's reasoning and calls, a
command and its output, a grader's verdict with its failed checks first; the request a sample
answered; the files it changed, with line diffs; and how the run stands there, its time and
tokens so far.

`--hide DIR`, repeatable or comma-separated, counts the changes under a directory rather than
listing them.
