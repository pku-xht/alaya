# Alaya

Alaya is a framework for experimenting with coding agents, built on three principles:

**Agents as programs over a log.** Agent runs are random and depend on their environment, which
makes them hard to analyse and experiment with. In Alaya, an agent is a program that only asks:
for a model's response, a command's output, the time, a person's reply. A run is the log of
those answers and of everything that arrived from outside, and replaying the program against
the log tells what it does next. Alaya carries out each request and appends its answer,
filesystem snapshots included. Every run is therefore complete data that can be analysed without
running it again, the calls of its tools, workflows and sub-agents nested in the log as they
were made, and any point of a run can start a controlled experiment: vary a single factor, such
as a message, a file, or the model, or resample the continuation, and compare the outcomes.

**Agent-native operation.** Experiments with agents produce more data than a person can process
by hand, and research itself is increasingly automated by AI. Alaya is designed to be operated
entirely by an external agent, such as Claude Code or Codex, through a strict, self-describing
command line. An external agent can therefore carry out research on its own, from proposing
ideas to evaluating them in experiments.

**Reliable runs on realistic benchmarks.** Runs on realistic benchmarks are long and expensive,
need non-trivial environments, and are graded in ways that differ from benchmark to benchmark.
Alaya appends to a run's log as it goes and caches model responses, so an interrupted run
continues where it stopped; runs every command in an isolated container of the benchmark's image;
and grades any point of any run through one interface, a grader assigned to it once its agent is
over, with an adapter for each benchmark. Alaya includes
MiniSwe, a port of mini-SWE-agent for SWE-bench, and MiniVero, for the Vero benchmark of
verified Lean code.

## Getting started

```sh
lake build              # the alaya executable, in .lake/build/bin/
lake exe tests          # the test suite, which runs that executable too; pass a substring to run a subset
```

Besides the Lean toolchain named in `lean-toolchain`, `alaya` calls `curl` for every request to
a model provider, `docker` for every command an agent or a grader runs, and
[`restic`](https://restic.net) 0.17 or later for workspace snapshots. A running Docker daemon is
required, for the tests too.

A typical session, on the [Bija example benchmark](example/bija/README.md): implement a small
language from its specification, graded against programs the agent never sees.

```sh
docker build -t alaya-bija example/bija
export ALAYA_DATA=$PWD/runs    # the data directory; `new` creates it
last() { tail -n 1 | cut -d' ' -f1; }

# A run: the project, the agent's configuration, and the task.
tip=$(alaya new --task-file example/bija/TASK.txt example/bija/skeleton --agent mini-swe \
  --model gpt-6-luna --set model.params.reasoning_effort=high --image alaya-bija | last)
end=$(alaya run "$tip" --provider apiyi | last)   # an entry a line; `alaya config` lists models, providers

# Grade it: a grader is a command that prints TAP, run on a checkout of the workspace.
grader=(--grader 'python3 /grader/grade.py' --grader-input example/bija)
alaya grade "$end" "${grader[@]}"

# Find where it went wrong, and see what the model was sent there.
alaya tree
alaya log "$end"
alaya show "$end:140" --request

# Grade that point too: a fork stopped there, graded the same way.
alaya grade "$end:140" "${grader[@]}"

# Correct the workspace at that point by hand, and let the agent go on from the correction.
alaya checkout "$end:140" fix              # its files, to edit by hand in fix/
fixed=$(alaya commit "$end:140" fix --message "I corrected the parser by hand; go on from here." | last)
fixed_end=$(alaya run "$fixed" --provider apiyi | last)
alaya grade "$fixed_end" "${grader[@]}"
```

`ENTRY:N` names the entry at position `N` of a log, and every command that appends prints each
entry it adds; `alaya tree` shows the whole forest. The first branch is untouched, so the
verdicts compare the same run with and without the correction, and with the agent stopped early.

`alaya html report.html` writes all runs as one page, for reading: each branch's log, an entry a
row, nested by the calls it happened in, with switches where branches fork, and an entry in full
— its reasoning, its calls and output, the request the model was sent, its time and tokens, and
the workspace changes. Below is the page for a gpt-6-luna run on [Bija](example/bija/README.md), graded 362 of 464,
with a second branch that starts mid-run, where a person sent the agent a note on how the suite
checks diagnostics, graded 410 of 464, and a third that grades the point where the note went in
as it stood, 362 of 464; the page shows a turn of the second.

![The HTML report of a gpt-6-luna run on Bija](example/bija/report.png)

## Documentation

[`docs/architecture.md`](docs/architecture.md) — how the parts fit: programs, which only ask;
the log, flat and append-only, kept as a forest of entries named by their content; replay, which
reads a log with its program to find what comes next; and the driver, which carries that out and
appends the answer. Every shared data structure, with diagrams.

[`docs/agent-api.md`](docs/agent-api.md) — the agent API. A program over Alaya's operations —
sample, run a command, time the run, run a grader — with failures, reads of the inbox, loops,
and calls of routines by name, each in a frame of its own: how an agent of tools, workflows and
sub-agents is structured. Tools, agents, runs, questions and replies.

[`docs/log-schema.md`](docs/log-schema.md) — the log and cache schema: the entry and the event as
stored, how runs grow and fork, draws, what a person appends, grading a point of a run by
stopping a fork there, the data directory, the workspace snapshots kept in a restic repository,
and the model cache entry.

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API. `Alaya.Chat` is the typed data of the
chat-completions protocol: messages, tools, tool calls, structured output, requests, and
responses. `Alaya.Model` is one interface for anything that answers a request, built by wrapping
a provider transport in layers — retry, batching, sampling independence, a persistent response
cache — each configured separately.

[`docs/cli.md`](docs/cli.md) — the `alaya` command line, for scripts, UIs and agents: every
command, how a command line is read, the data directory, text and JSON output, and one exit
status per class of failure.

[`docs/miniswe.md`](docs/miniswe.md) — the MiniSwe design. `Alaya.Agents.MiniSwe` is the port of
mini-SWE-agent as a program: the original's prompts, cut from its `mini.yaml`, its `bash` tool,
and protocol for reading a response and answering a malformed one, realized as a loop over the
conversation, with Lean-native rendering, and commands run in a container.

[`docs/minivero.md`](docs/minivero.md) — MiniVero, the agent for Vero's Lean implementation and
proof tasks: MiniSwe with its own prompts, a `proof` or `codeproof` mode, and a `time_budget`
tool to pace a run by, graded by the Vero benchmark in `benchmarks/vero/`.

[`docs/ask-user.md`](docs/ask-user.md) — `ask_user`, the tool with which MiniSwe and MiniVero
ask a person a question and wait: yes/no, single-choice and open-ended forms, answering with
`alaya reply`, and a local page that serves the waiting questions.

The design follows the sketch in `functional_agents/`, whose own test
`Test/Prototype.lean` runs against Alaya's interpreter.
