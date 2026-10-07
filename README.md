# Alaya: LLM Agents as Effectful Programs with Durable Execution

Alaya is an agentic framework built on three principles:

**Agents as durable effectful programs.** Agent runs are hard to study and reproduce. Alaya
represents an agent as an effectful program in free-monad form and runs it by durable execution:
replay against an append-only log of events. A run is therefore complete data, which can be
analysed without re-execution. The logs form a forest, so the impact of an
intervention, such as changing a message, a file or the agent's workflow, is studied by forking a
run at the point of the change.

**Agent-native operation.** Experiments with agents produce more data than a person can process
by hand, and research itself is increasingly automated by AI. Alaya is designed to be operated
entirely by an external agent, such as Claude Code or Codex, through a strict, self-describing
command line. An external agent can therefore carry out research on its own, from proposing
ideas to evaluating them in experiments.

**Reliable runs on realistic benchmarks.** Runs on realistic benchmarks are long and expensive,
need non-trivial environments, and are graded in ways that differ from benchmark to benchmark.
Alaya continues an interrupted run from its log, runs every command in an isolated container of
the benchmark's image, and grades any point of any run through one interface, with an adapter for
each benchmark. Alaya includes MiniSwe, a port of mini-SWE-agent for SWE-bench, and MiniVero, for
the Vero benchmark of verified Lean code.

## Features

- **Durable runs.** A run that crashed or was interrupted resumes from its log. Every model draw
  is cached, so resuming sends no request twice.
- **A complete view of runs.** `alaya html` writes the whole forest as one page: every branch,
  every call in its frame, each request as it was sent, each response with its reasoning, and how
  each command changed the files.
- **Forks.** Any entry of any run can be continued differently, and the original stays as it was.
  The logs of a data directory form a forest that shares their common entries.
- **Interventions at any point.** A person can send a message (`tell`), change the workspace
  (`commit`), answer an agent's question (`reply`), or stop any call by its frame (`stop`).
- **Grading at any point.** A grader is a program called on the log, in an image of its own. It
  reads TAP from the benchmark's tests and gives a verdict: pass, fail or error, with a score.
- **Rebase.** After an agent changes, `rebase` copies a run into a new data directory as the new
  version makes it, keeping every entry that still holds.
- **Isolated execution.** Every command runs in a container of its call's image, pinned by
  digest, with no network by default. The workspace is versioned after every command, so any
  point of a run can be listed, read, compared or checked out.
- **Provider-independent runs.** A run records the model it used, not who served it. Another
  provider may resume it only if it sends the model the same requests, and is refused otherwise.
- **Agents.** MiniSwe and MiniVero are included, with the tools `bash`, `submit`, `ask_user`,
  `time_budget` and `subagent`. An agent is a Lean program, built from routines with lexical
  scopes, and its log shows every call it made.
- **An agent-native command line.** Every command takes `--json`, every failure has a typed exit
  status, and `alaya help --json` describes every command as data.

## Getting started

```sh
lake build                 # the alaya executable, in .lake/build/bin/
lake exe tests             # the test suite
lake exe tests core/ llm/  # the suites of two layers; --list names the cases
```

Alaya also needs `curl`, a running Docker daemon, and [`restic`](https://restic.net) 0.17 or later.
The tests are arranged by the library's layers, `Test/Base` to `Test/App`. A suite that needs
docker, restic, node or the built binary is skipped where they are missing, and the run then fails.

A session on the [Bija benchmark](benchmarks/bija/README.md): an agent is given a project with
the specification of a small language and a few sample programs, implements the language, and is
graded on programs it never sees.

```sh
last() { tail -n 1 | cut -d' ' -f1; }   # a command prints each entry it appends; keep the last

# Create a run on that project, call MiniSwe on its task, and drive it until the agent is over.
root=$(alaya new benchmarks/bija/skeleton | last)
called=$(alaya call "$root" mini-swe --set model=gpt-6-luna --set-file task=benchmarks/bija/TASK.txt \
  --image ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd | last)
end=$(alaya resume "$called" --provider apiyi | last)

# Grade a point: call the grader there, whose image holds the reference programs, and resume.
grade() { alaya resume "$(alaya call "$1" grader --image alaya-bija-grader \
  --set command='python3 /opt/alaya-bija/grade.py --tests /grader' | last)"; }
grade "$end"

# Read the log, fork it at position 140 with a hint, drive the fork, and grade it.
alaya log "$end"
hint=$(alaya tell "$end:140" 'Check the diagnostics against SPEC.md.' | last)
grade "$(alaya resume "$hint" --provider apiyi | last)"
```

`alaya html report.html` writes the forest as one page for reading, here for a Bija run and a
fork of it:

![The HTML report of a gpt-6-luna run on Bija](docs/figures/bija-report.png)

## Documentation

[`docs/language.md`](docs/language.md) — the language agents are written in: a computation, the
log of events it writes, what each construct writes there (an operation, a read of the inbox, a
call, a failure, a loop, a comment, a break, a question), replay, and routines and scopes.

[`docs/runtime.md`](docs/runtime.md) — how a run is carried out: a run as a call made from
outside, the session, the driver, and the data directory with every command as a function.

[`docs/agents.md`](docs/agents.md) — the tools agents offer, `ask_user`, how an agent is made and
offered as a program, and the two agents included: MiniSwe, the port of mini-SWE-agent, and
MiniVero, MiniSwe with Vero's instructions for Lean implementation and proof tasks.

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API: requests and responses as typed values,
structured output, a model as the draws of a request, the layers a model is built from (retry,
batching, sharing of draws, a persistent cache), and the providers that serve models.

[`docs/cli.md`](docs/cli.md) — the `alaya` command line: its commands for creating, running,
grading, inspecting and rebasing runs, their text and JSON output, and their exit statuses.

[`docs/log-schema.md`](docs/log-schema.md) — the log schema: an entry, the events as JSON, the
forest of logs and its forks, the grader's protocol and its verdict, the data directory with its
workspace snapshots, and the model cache entry.

[`docs/style_guide.md`](docs/style_guide.md) — how Alaya looks: the colours, type, parts, icons
and wording of the HTML report, and how the website and the diagrams take them up. It is a
reference for AI agents that write Alaya's pages and figures, not reading for users.
