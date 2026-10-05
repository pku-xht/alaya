# Alaya: LLM Agents as Effectful Programs with Durable Execution

Alaya is a framework for experimenting with coding agents, built on three principles:

**Agents as durable effectful programs.** Agent runs are hard to study: model responses are
random and the agent modifies files as it works, so a run cannot be reproduced, or rerun with a
single change to see what that change does. Alaya represents an agent as an effectful program in
free-monad form and runs it by durable execution: replay against an append-only log of events.
The logs form a forest, so any point of a run, with its workspace, can be forked and resampled.
A run is therefore complete data, which can be analysed without running anything again, and a
controlled experiment is a fork: change a message, a file or the model, or sample again, and
compare the outcomes.

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

A typical session, on the [Bija benchmark](benchmarks/bija/README.md): implement a small
language from its specification, graded against programs the agent never sees.

```sh
docker pull ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd
docker pull ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd
export ALAYA_DATA=$PWD/runs    # the data directory; `new` creates it
last() { tail -n 1 | cut -d' ' -f1; }

# A run: the project, the agent's configuration, and the task.
tip=$(alaya new --task-file benchmarks/bija/TASK.txt benchmarks/bija/skeleton --agent mini-swe \
  --model gpt-6-luna --set model.params.reasoning_effort=high \
  --image ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd | last)
end=$(alaya run "$tip" --provider apiyi | last)   # an entry a line; `alaya config` lists models, providers

# Grade it: a grader is a command that prints TAP, run on a checkout of the workspace.
grader=(--grader 'python3 /opt/alaya-bija/grade.py --tests /grader'
        --grader-image ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd
        --grader-input benchmarks/bija/reference/tests --grader-timeout 1800)
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
the workspace changes. Below is the page for a gpt-6-luna run on [Bija](benchmarks/bija/README.md), graded 362 of 464,
with a second branch that starts mid-run, where a person sent the agent a note on how the suite
checks diagnostics, graded 410 of 464, and a third that grades the point where the note went in
as it stood, 362 of 464; the page shows a turn of the second.

![The HTML report of a gpt-6-luna run on Bija](docs/figures/bija-report.png)

## Documentation

[`docs/agent-api.md`](docs/agent-api.md) — the agent API, step by step: a program, the log and
its events, and what each construct of a program writes in the log — an operation, a read of
the inbox, a call, a failure, a loop, a comment — each with a figure. Then replay, routines,
tools, `ask_user`, an agent, a run, and the driver that drives it.

[`docs/log-schema.md`](docs/log-schema.md) — the log schema: an entry, the events as JSON, the
forest of logs and its forks, the grader's protocol and its verdict, the data directory with its
workspace snapshots, and the model cache entry.

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API, step by step: a request and a response as
typed values, structured output, a model as the draws of a request, the layers a model is built
from — retry, batching, sharing of draws, a persistent cache — and models and the providers
that serve them.

[`docs/cli.md`](docs/cli.md) — the `alaya` command line, for scripts, UIs and agents: how a
command line is read, text and JSON output, one exit status per class of failure, and every
command with an example and a figure of what it does to the forest.

[`docs/miniswe.md`](docs/miniswe.md) — MiniSwe, the port of mini-SWE-agent: its options, what
the model is sent, how it ends, how a command runs, long outputs and a full context, and how it
differs from the original.

[`docs/minivero.md`](docs/minivero.md) — MiniVero, MiniSwe with Vero's instructions for Lean
implementation and proof tasks: its options, what the model is sent, how that differs from
Vero's own instructions, and the `time_budget` tool a run is paced by.

[`docs/style_guide.md`](docs/style_guide.md) — how Alaya looks: the colours, type, parts, icons
and wording of the HTML report, and how the website and the diagrams take them up.
