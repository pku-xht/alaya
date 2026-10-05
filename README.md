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

## Getting started

```sh
lake build        # the alaya executable, in .lake/build/bin/
lake exe tests    # the test suite
```

Alaya also needs `curl`, a running Docker daemon, and [`restic`](https://restic.net) 0.17 or later.

A session on the [Bija benchmark](benchmarks/bija/README.md): an agent is given a project with
the specification of a small language and a few sample programs, implements the language, and is
graded on programs it never sees.

```sh
last() { tail -n 1 | cut -d' ' -f1; }   # a command prints each entry it appends; keep the last

# Create a run of MiniSwe on that project, and run it until the agent is over.
tip=$(alaya new benchmarks/bija/skeleton --task-file benchmarks/bija/TASK.txt --agent mini-swe \
  --model gpt-6-luna --image ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd | last)
end=$(alaya run "$tip" --provider apiyi | last)

# Grade the run's end against the reference programs.
grader=(--grader 'python3 /opt/alaya-bija/grade.py --tests /grader'
        --grader-image ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd
        --grader-input benchmarks/bija/reference/tests --grader-timeout 1800)
alaya grade "$end" "${grader[@]}"

# Read the log, fork it at position 140 with a hint, run the fork, and grade it.
alaya log "$end"
hint=$(alaya tell "$end:140" 'Check the diagnostics against SPEC.md.' | last)
alaya grade "$(alaya run "$hint" --provider apiyi | last)" "${grader[@]}"
```

`alaya html report.html` writes the forest as one page for reading, here for a Bija run and a
fork of it:

![The HTML report of a gpt-6-luna run on Bija](docs/figures/bija-report.png)

## Documentation

[`docs/agent-api.md`](docs/agent-api.md) — the agent API: a program, the log of events it
writes, and what each construct writes there (an operation, a read of the inbox, a call, a
failure, a loop, a comment); then replay, routines, tools, `ask_user`, an agent, a run, and the
driver.

[`docs/log-schema.md`](docs/log-schema.md) — the log schema: an entry, the events as JSON, the
forest of logs and its forks, the grader's protocol and its verdict, the data directory with its
workspace snapshots, and the model cache entry.

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API: requests and responses as typed values,
structured output, a model as the draws of a request, the layers a model is built from (retry,
batching, sharing of draws, a persistent cache), and the providers that serve models.

[`docs/cli.md`](docs/cli.md) — the `alaya` command line: how a command line is read, text and
JSON output, the exit statuses, and what each command does to the forest.

[`docs/miniswe.md`](docs/miniswe.md) — MiniSwe, the port of mini-SWE-agent: its options, what
the model is sent, how it ends, how a command runs, long outputs and a full context, and how it
differs from the original.

[`docs/minivero.md`](docs/minivero.md) — MiniVero, MiniSwe with Vero's instructions for Lean
implementation and proof tasks: its options, what the model is sent, how that differs from
Vero's own instructions, and the `time_budget` tool a run is paced by.

[`docs/style_guide.md`](docs/style_guide.md) — how Alaya looks: the colours, type, parts, icons
and wording of the HTML report, and how the website and the diagrams take them up.
