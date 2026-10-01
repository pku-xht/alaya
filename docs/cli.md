# The `alaya` command line

`alaya` drives the trajectory from a shell, a script, a UI, or an agent such as Claude Code. Each
command is a thin layer over one operation of `Alaya.Trajectory`, whose model — states, draws,
people in the tree, evaluation, what is on disk — is `docs/trajectory-schema.md`. This page is
the command line itself: the commands, how a command line is read, what a command prints, and
how it fails.

## 1. Commands

```
alaya root --task TEXT PROJECT --agent FILE --image IMAGE [--workdir PATH]   create a root from a project directory
alaya root --task TEXT --agent FILE --image IMAGE --workdir PATH   …or from the image's own PATH
alaya resume HASH --model P:M [--turns N] [--time-budget S]   grow one continuation until it ends, asks, or reaches a limit
alaya eval   HASH --grader CMD [--input DIR] [--grader-image IMAGE] [--timeout S]   grade a state
alaya commit HASH DIR [--note NOTE]              record a hand-edited workspace as a child, telling the agent
alaya tell   HASH TEXT                           send the agent a message, as a child
alaya reply  HASH (TEXT | --unavailable)         answer the question a state is waiting on, or say the person cannot
alaya waiting                                    list every unanswered question
alaya ls HASH [PATH]                             list a directory of a state's workspace snapshot
alaya cat HASH PATH                              print a file from a state's workspace snapshot, or preview it
alaya checkout HASH DIR                          materialize a state's workspace into DIR
alaya tree                                       show the whole forest
alaya show HASH [--view]                         metadata, the log, and optionally the view
alaya diff A B                                   workspace changes between two states
alaya html FILE [--hide DIR]                     write the forest as one self-contained page
alaya rm HASH                                    delete a subtree and the snapshots only it used
alaya help [COMMAND]                             what a command takes; `help --json` for all of them
```

A `HASH` is a state's hash, or any unambiguous prefix of it. Every command also takes
`--data DIR`, `--json` and `--help`.

## 2. Reading a command line

Every command declares what it takes (`Alaya.Cli`), and the command comes first. A command
refuses an option it does not take, naming the nearest one it does; a switch never takes the
next token; a valued option takes the next token, or its value after `=` (`--task=--literal`),
and may be given once; after `--` everything is an argument, which is how an answer that begins
with `-` is given. Every problem is reported at once. `alaya help`, `alaya help COMMAND` and
`alaya COMMAND --help` print what a command accepts, and `alaya help --json` describes every
command as data.

**The data directory.** Every command names it with `--data DIR`, or reads `ALAYA_DATA`; there
is no default, so a command run from the wrong place cannot quietly begin a new one. `root`
creates it, and every other command refuses a path that holds none. What it holds is
`docs/trajectory-schema.md` §5.

## 3. Output

A command prints text for a reader by default, and JSON with `--json`. In the text, every state
a command creates — by `root`, `resume`, `commit`, `tell`, `reply` and `eval` — is printed on a line of
its own that begins with its full 64-hex hash, so a script that only needs the new state can
take it from there.

With `--json`, a command prints one JSON object per line:

| Command | Object |
| --- | --- |
| `root`, `resume`, `commit`, `tell`, `reply` | each state it creates: `{state, parent, kind, note, outcome, question, question_type, options}` |
| `resume`, stopped at a limit | then `{state, turns_spent, turns}` or `{state, time_budget_spent, run_time_ms}` |
| `eval` | `{state, status, passed, total, reason}` |
| `tree` | every state, as `root` prints one |
| `waiting` | every open question: `{state, question, question_type, options}` |
| `show` | the state object (`docs/trajectory-schema.md` §6) with its `state` hash, the run's `run_time_ms`, its `history` — one `{state, kind, events}` per state from the root, whose events concatenate to the log — and, with `--view`, the `view` |
| `ls` | `{state, workspace, path, entries}`, each entry `{name, path, kind, size}` |
| `cat` | a preview, `{state, workspace, path, kind, content, size}` (§5) |
| `diff` | `{a, b, changes}` |
| `checkout` | `{state, workspace, directory}` |
| `html` | `{file, bytes}` |
| `rm` | `{removed}` |

A failure is one JSON object on stderr (§4).

## 4. Failures and exit status

An outcome is 0 to 4, and a failure is one of six classes above them, each with one status, the
same for every command:

| Status | Meaning | What to do |
| --- | --- | --- |
| 0 | done: the command succeeded, a run ended, a verdict passed | — |
| 1, 2 | `eval`: the verdict is fail, or error | — |
| 3 | `resume`: the run waits for an answer | `reply`, then resume from the reply |
| 4 | `resume`: `--turns` or `--time-budget` stopped it | resume from the last state |
| 64 | `usage`: the command line does not parse | fix the command line |
| 65 | `input`: it names something not there, in the wrong condition, or malformed | fix the request |
| 69 | `environment`: the machine lacks docker, an image, restic or an API key | fix the machine |
| 74 | `storage`: the data directory could not be read or written | look at the data directory |
| 75 | `transient`: another command is writing the data directory, or the provider was unreachable, throttled or failing after alaya's own retries | try again later |
| 76 | `model`: the provider refused the request or answered it wrongly | fix the model's settings |

The classes are `Error.Class`, one per constructor of `Alaya.Error` (`docs/llm-api.md` §4). A
failure prints `error: MESSAGE` on stderr, or with `--json` one object: `{"error": CLASS,
"message": ...}`, where CLASS is the class's name above, with `status` and `retry_after_ms` for
an HTTP failure, and `problems` and `usage` for `usage`.

A failed `resume` leaves the states it wrote: to continue after one, resume from the last state
it printed, since resuming the state it started from again begins a new branch beside the
first (`docs/trajectory-schema.md` §2).

**One writer at a time.** A command that writes the data directory — `root`, `resume`, `eval`,
`commit`, `tell`, `reply`, `rm` — holds its lock (`DATA/lock`, `Alaya.Lock`) from start to end.
A second writer is refused at once, with status 75 and the holder's pid, rather than left
waiting for as long as a `resume` runs; the operating system drops the lock when its holder
exits, however it exits, so none is ever left behind. Commands that only read — `tree`, `show`,
`ls`, `cat`, `diff`, `waiting`, `html`, `checkout` — take no lock and run beside a writer, so a
run can be watched while it grows; one that reads while an `rm` deletes can fail with `storage`.

One writer is what keeps a data directory consistent: the model cache is extended by one
process, two continuations of a state never take the same draw, and `rm` never drops a snapshot
that a state about to be written refers to. Work in parallel goes to several data directories,
one per worker or per arm of an experiment, each its own forest with its own cache. A command
killed outright leaves its scratch under `DATA/tmp/` behind.

## 5. Commands in detail

### `root`

`root` takes the task as `--task TEXT` or `--task-file FILE`, one of the two. The file is read by
`alaya`, relative to the current directory, not from the image, as it is, not trimmed or
rewritten, and must be UTF-8; a missing or unreadable file is an error before anything is
created, not an empty task. Stdin is the file `/dev/stdin`. Either way the task is saved in the
opening log and the root's note, so the first request carries all of it without a tool read: a
task specification too long for a command's output preview reaches the model whole, its middle
included.

**The agent.** An agent is a *family* — `mini-swe` (`docs/miniswe.md`) or `mini-vero`
(`docs/minivero.md`) — and a *configuration*: a JSON object with a `family` field and the
family's own fields, every one of which may be left out for its default, and none of which may
be misspelt. A configuration is a file: `root --agent FILE` names it, and that is the one way to
configure an agent. `agents/` in the repository holds the families' defaults,
`mini-swe-default.json` and `mini-vero-default.json`, complete, which is the documentation of
the fields; a variant for an experiment is a copy with a field changed, named for what it
changes. The complete configuration is recorded in the root (`docs/trajectory-schema.md` §6,
`agent`), shown by `show` and, by family, by `tree`, and every later command — `resume`, `html`,
`show --view` — builds the agent from it, so a run is continued by the agent that started it;
none of them takes `--agent`.

**The image.** `root` requires `--image`. The image is resolved to a digest and recorded, and
every later command runs in it: `resume` takes no `--image`. A recorded image that is missing is
pulled by its digest; one recorded as a local build's ID cannot be, and has to be rebuilt or
`docker load`ed.

**The workdir.** The workspace is mounted in the container at the root's `--workdir`, which is
`/workspace` unless given, and commands run there. It is recorded on the root and inherited,
like the image, so every later command and every grader sees the workspace at the same path.
Without a `PROJECT`, `root` copies the image's own `--workdir` out as the initial workspace: task
images that install their project in place, such as SWE-bench's at `/testbed`, work as they are,
compiled extensions and `.git` included. A workdir is an absolute, clean path other than `/`, and
not `/grader` or `/out`, which the grader mounts.

### `resume`

`resume` takes the model — `--model PROVIDER:NAME`, `--temperature`, `--echo-reasoning`, and the
DGX flags `--url`/`--port` (`docs/llm-api.md`) — and `--container-user` and `--network` for the
run's commands. A container runs with **no network** unless `--network` names one
(`--network bridge` is Docker's default network): an agent with network access can go looking
for its own reference solution, so an image should carry what a task legitimately needs.

**Limits.** Every model step records its wall-clock time on its state (`elapsed_ms`), and a
run's time is the sum along its path from the root: `show` prints both, `tree` each step's.
`--time-budget SECONDS` (default 0, no limit) is this invocation's alone and recorded nowhere.
Before each step `resume` checks the run's time against the budget; once spent, it writes
nothing, says so, and exits with status 4, and a later `resume` — with a larger budget, or
none — continues from the same state. The budget never cuts a step short, so a run can overrun
it by one step. `--turns N` (default 0, no limit) stops the same way after this invocation's
`N`th turn when the run has not ended: `--turns 1` is one step. An agent that paces itself reads
the time left from its session (`docs/agent-api.md` §3), as MiniVero's `time_budget` tool does
(`docs/minivero.md`).

### `eval`

`eval` takes `--grader CMD`, `--input DIR`, `--grader-image IMAGE`, `--timeout` (default
900 s, 0 for none) and `--container-user` for the grader, which always runs without network.
How a grader runs and what its verdict means is `docs/trajectory-schema.md` §4. `eval` exits
with the verdict, and with a failure's status when it records none.

### `ls` and `cat`

`ls` and `cat` read a state's snapshot directly, without restoring its workspace, which is how
a report an evaluation left in its workspace is read. A path is clean and relative to the
workspace's root (no `..`, no leading `/`); a symbolic link is listed, but never followed, and
`cat` prints only regular files, byte for byte. `ls` prints each entry's size and path, by name,
with `/` after a directory and `@` after a link. `cat --json` previews any entry instead: a
regular UTF-8 file of up to 1 MiB is `text` with its `content`, and anything else says only what
it is — `binary`, `too_large`, `symlink`, `directory` or `other` — so a page can show a snapshot
without reading what it should not.
