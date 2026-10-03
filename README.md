# Alaya

Alaya is a framework for experimenting with coding agents, built on three principles:

**Agents as pure functions.** Agent runs are random and depend on their environment, which makes
them hard to analyse and experiment with. In Alaya, a run is a log of events, such as model
responses, command outputs and messages from a person, and an agent is a pure function from this
log to its next effect, such as a model request or a command. Alaya carries out each effect and
records its result, filesystem snapshots included. Every run is therefore complete data that can
be analysed without running it again, and any point in a run can start a controlled experiment:
vary a single factor, such as a message, a file, or the model, or resample the continuation, and
compare the outcomes.

**Agent-native operation.** Experiments with agents produce more data than a person can process
by hand, and research itself is increasingly automated by AI. Alaya is designed to be operated
entirely by an external agent, such as Claude Code or Codex, through a strict, self-describing
command line. An external agent can therefore carry out research on its own, from proposing
ideas to evaluating them in experiments.

**Reliable runs on realistic benchmarks.** Runs on realistic benchmarks are long and expensive,
need non-trivial environments, and are graded in ways that differ from benchmark to benchmark.
Alaya saves a run after every step and caches model responses, so an interrupted run continues
where it stopped; runs every command in an isolated container of the benchmark's image; and
grades every outcome through one interface, with an adapter for each benchmark. Alaya includes
MiniSwe, a port of mini-SWE-agent for SWE-bench, and MiniVero, for the Vero benchmark of
verified Lean code.

## Getting started

```sh
lake build              # the alaya executable, in .lake/build/bin/
lake exe tests          # the test suite; pass a substring to run a subset
```

Besides the Lean toolchain named in `lean-toolchain`, `alaya` calls `curl` for every request to
a model provider, `docker` for every command an agent or a grader runs, and
[`restic`](https://restic.net) 0.17 or later for workspace snapshots. A running Docker daemon is
required, for the tests too.

A typical session, on the [Bija example benchmark](example/bija/README.md): implement a small
language from its specification, graded against programs the agent never sees.

```sh
docker build -t alaya-bija example/bija
export ALAYA_DATA=$PWD/runs    # the data directory; `root` creates it

# Run the agent until it submits, then grade where it ended.
root=$(alaya root --task-file example/bija/TASK.txt example/bija/skeleton \
  --agent mini-swe --model gpt-6-luna --set model.params.reasoning_effort=high --image alaya-bija)
alaya resume "$root" --provider apiyi    # one line per new state; `alaya config` lists models, providers
alaya eval END --input example/bija --grader /grader/grade.py --timeout 1800

# Find the step where it went wrong, and see what the model was sent there.
alaya tree
alaya show STEP --request

# Correct the workspace at that step by hand, let the agent go on from the correction, and grade
# the new branch.
alaya checkout STEP fix    # its files, to edit by hand in fix/
fixed=$(alaya commit STEP fix --message "I corrected the parser by hand; go on from here.")
alaya resume "$fixed" --provider apiyi
alaya eval END2 --input example/bija --grader /grader/grade.py --timeout 1800
```

`END`, `STEP` and `END2` stand for state hashes, or any unambiguous prefix of one: `resume`
prints each state it adds, and `tree` the whole forest. The first branch is untouched, so the two
verdicts compare the same run with and without the correction.

`alaya html report.html` writes all runs as one page. Below is the page for a
gpt-6-luna run on [Bija](example/bija/README.md), with a second branch that starts mid-run where
a person sent the agent a message.

![The HTML report of a gpt-6-luna run on Bija](example/bija/report.png)

## Documentation

[`docs/architecture.md`](docs/architecture.md) — how the parts fit: the agent, a pure function
from the log of a run to its next effect, or its outcome; the trajectory, a tree of immutable
states that partition the log; and the driver, whose handler carries effects out and whose loop
records their answers.
Every shared data structure — events, call references, the index of model turns, steps and
branches — with diagrams of how a log is referenced and partitioned.

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API. `Alaya.Chat` is the typed data of the
chat-completions protocol: messages, tools, tool calls, structured output, requests, and
responses. `Alaya.Model` is one interface for anything that answers a request, built by wrapping
a provider transport in layers — retry, batching, sampling independence, a persistent response
cache — each configured separately.

[`docs/agent-api.md`](docs/agent-api.md) — the agent API. A run is a log of events — what the
world placed in it, and its answer to each of the agent's effects — and an agent is a pure
`next` from the log to an effect — sample this request, run this command in the workspace,
time the run, record a result, ask a person — or to the run's outcome. Each effect has a type
of answer. An agent carries out no effect itself, so its decisions can be recomputed
and composed with combinators.

[`docs/trajectory-schema.md`](docs/trajectory-schema.md) — the trajectory and cache schema.
`Alaya.Trajectory` records a run as a tree of content-addressed states, each holding its
parent, the events it appends, and a snapshot of the workspace, so a run can be replayed,
forked, evaluated against hidden tests, and continued after a person intervenes. The page
specifies the state object, the store layout, the workspace snapshots kept in a restic
repository, and the model cache entry.

[`docs/cli.md`](docs/cli.md) — the `alaya` command line, for scripts, UIs and agents: every
command, how a command line is read, the data directory, text and JSON output, and one exit
status per class of failure.

[`docs/miniswe.md`](docs/miniswe.md) — the MiniSwe design. `Alaya.Agent.MiniSwe` is the port of
mini-SWE-agent as one agent: the original's prompts, cut from its `mini.yaml`, its `bash` tool, and protocol for reading a
response and answering a malformed one, realized through the agent API with Lean-native
rendering, and commands run in a container.

[`docs/minivero.md`](docs/minivero.md) — MiniVero, the agent for Vero's Lean implementation and
proof tasks: MiniSwe with its own prompts, a `proof` or `codeproof` mode, and a `time_budget`
tool to pace a run by, graded by the Vero benchmark in `benchmarks/vero/`.

[`docs/ask-user.md`](docs/ask-user.md) — `ask_user`, the tool with which MiniSwe and MiniVero
ask a person a question and wait: yes/no, single-choice and open-ended forms, answering with
`alaya reply`, and a local page that serves the waiting questions.
