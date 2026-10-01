# Alaya

Alaya is a framework for experimenting with coding agents that focuses on:

**Agents as pure functions.** Agent runs are stochastic, depend on their environment, and take
long, so they are hard to reproduce and compare. In Alaya, an agent is a pure function of its
run's log, and everything impure — model responses, tool results, workspaces — is recorded as a
tree of immutable states. Any run can be continued, branched, or replayed from any state.

**Agent-native operation.** Research is increasingly automated by AI. Alaya is designed to be
operated entirely by an external agent, such as Claude Code, through a strict, self-describing
command line with JSON output and exit codes that say what happened.

**Long-horizon tasks, benchmarks, and human interaction.** Runs can be paused and resumed across
invocations, execute in a benchmark's own container images, and are graded separately against
hidden tests. A person can answer the agent's questions or step into a run at any point. Alaya
includes MiniSwe, a port of mini-SWE-agent for SWE-bench, and MiniVero, for the Vero benchmark of
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
  --agent agents/mini-swe-default.json --image alaya-bija)
alaya resume "$root" --model PROVIDER:MODEL    # one line per new state; providers: docs/llm-api.md
alaya eval END --input example/bija --grader /grader/grade.py --timeout 1800

# Find the turn where it went wrong, and see what the model was sent there.
alaya tree
alaya show TURN --view

# Correct the workspace at that turn by hand, let the agent go on from the correction, and grade
# the new branch.
alaya checkout TURN fix    # its files, to edit by hand in fix/
fixed=$(alaya commit TURN fix --note "corrected by hand")
alaya resume "$fixed" --model PROVIDER:MODEL
alaya eval END2 --input example/bija --grader /grader/grade.py --timeout 1800
```

`END`, `TURN` and `END2` stand for state hashes, or any unambiguous prefix of one: `resume`
prints each state it adds, and `tree` the whole forest. The first branch is untouched, so the two
verdicts compare the same run with and without the correction.

## Documentation

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API. `Alaya.Chat` is the typed data of the
chat-completions protocol: messages, tools, tool calls, structured output, requests, and
responses. `Alaya.Model` is one interface for anything that answers a request, built by wrapping
a provider transport in layers — retry, batching, sampling independence, a persistent response
cache — each configured separately.

[`docs/agent-api.md`](docs/agent-api.md) — the agent API. An agent records a log of events —
messages, model responses, tool observations — and is defined by a pure view that turns the log
into the dialogue the model is sent, a pure `next` that decides whether to sample, act, ask a
person, or stop, an `act` that runs a tool call in a workspace, and the tools it offers.

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
