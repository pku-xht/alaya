# Alaya

A Lean 4 library for typed chat models and recorded agent runs. An agent's run is a tree of
immutable states, each a file named by the hash of its content, with their workspaces in a
restic repository beside them: every model turn, every tool result, and every workspace snapshot
is kept exactly as it happened, so a run can be replayed, branched at any point, evaluated
against hidden tests, and interrupted by a person.

The library is organised in four layers, each documented on its own page.

```sh
lake build              # the alaya executable, in .lake/build/bin/
lake exe tests          # the test suite; pass a substring to run a subset
```

Besides the Lean toolchain named in `lean-toolchain`, `alaya` calls these programs:

| Program | Used for |
| --- | --- |
| `curl` | every request to a model provider |
| `docker` | running every command an agent or a grader runs, in a pinned container image |
| `restic` (0.17 or later) | snapshotting a workspace, writing one back out, and diffing two ([restic.net](https://restic.net)) |
| `chmod` | making a directory replaceable |

Nothing an agent or a grader asks for runs on the host: every trajectory is created with
`--image`, its commands run in that image, and its graders in that image or one of their own,
so a running docker daemon is required, for the tests too. `restic` is a single binary, and `chmod` is on any Unix host.

A first run needs an image, a project directory, a task, and a model (`docs/llm-api.md` lists
the providers). `ghcr.io/astral-sh/uv:python3.12-bookworm-slim` — Debian, Python 3.12, and `uv` —
is a good default image; `alaya` records it by digest:

```sh
root=$(alaya root --task "Add a hello.py that prints hello" ./project \
  --agent agents/mini-swe-default.json --image ghcr.io/astral-sh/uv:python3.12-bookworm-slim)
alaya resume "$root" --model PROVIDER:MODEL
alaya tree
```

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
repository, the model cache entry, and every `alaya` command.

[`docs/miniswe.md`](docs/miniswe.md) — the MiniSwe design. `Alaya.Agent.MiniSwe` is the port of
mini-SWE-agent as one agent: the original's prompts, cut from its `mini.yaml`, its `bash` tool, and protocol for reading a
response and answering a malformed one, realized through the agent API with Lean-native
rendering, and commands run in a container.

## Example

[`example/bija/`](example/bija/README.md) is a benchmark for alaya: Bija, a small language to be
implemented from its specification, with a skeleton to start from, an image to run in, and a
grader that scores an attempt against 232 programs the agent never sees.
