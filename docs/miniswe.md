# MiniSwe

`Alaya.Agents.MiniSwe` is a port of
[mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent)'s default tool-calling agent. It
keeps what defines that agent: its prompts, its `bash` tool, its way of reading a response and
answering a malformed one, and its limits. It is written as a program (`docs/agent-api.md` §8):
a wait for the task, then a loop over the conversation.

## 1. Options

Set at `new` with `--set agent.FIELD=VALUE`; `alaya config --agent mini-swe` prints the
defaults. A field left out is its default, and a misspelt one is an error.

| Field | Default | Meaning |
| --- | --- | --- |
| `step_limit` | 0 | responses before the agent ends with `LimitsExceeded`; 0 is no limit |
| `max_consecutive_format_errors` | 3 | malformed responses in a row before `RepeatedFormatError`; 0 is no limit |
| `executor.timeout_seconds` | 30 | the time a command may take |
| `executor.env` | mini's | environment overrides for every command: `PAGER=cat` and the like |
| `tools` | `["bash", "submit"]` | the tools offered, in order. `bash` and `submit` are required; `ask_user` and `time_budget` may be added. The list replaces the default one |
| `recover_output` | false | name the file that holds the whole of a cut output (§5) |
| `context_reserve` | 8000 | tokens kept free for the next response (§5) |
| `mask_observations` | null | `{keep_turns, block}`: leave old outputs out of the view (§5) |

## 2. What the model is sent

**The opening** is mini's two messages, rendered from its `mini.yaml`: the system message, and
the task with a line naming the machine: the system and the architecture of the run's image. Each offered tool's instruction is appended to the task message.

**The view** is what each later request holds of the conversation:

- A person's message or change to the workspace is told as an `<intervention>`.
- A turn is the model's message and a tool message for each call. A `bash` result is JSON with
  `output`, `exit_code` and `error`. An output of 10 000 characters or more is shown as its
  first and last 5 000, with the count of what was left out; the log keeps all of it.
- A malformed response is not shown. In its place the model sees a user message with the
  format error, so it does not try to continue its own broken output. This is mini's protocol.

**A format error** is the whole turn's answer when its first problem is one of these:

| The response | Format error |
| --- | --- |
| has no tool call | "No tool calls found in the response…" |
| has a call whose arguments are not JSON | "Error parsing tool call arguments: …" |
| calls a tool that is not offered | "Unknown tool '…'." |
| has a call its tool refuses: a `bash` call with no `command`, a malformed question | what is wrong with it |
| calls `ask_user` beside another tool | "ask_user must be called alone." |

The message wraps the problem in mini's guidance on calling the tool. When the provider cut the
response off (`finish_reason` is `length`, or `tool_calls` with no call), it says so and asks for
a shorter response instead.

## 3. How it ends

The agent returns `{status, submission}`:

| Status | When |
| --- | --- |
| `Submitted` | the model called `submit`; its message is the submission. Calls after it in the same response do not run |
| `LimitsExceeded` | `step_limit` responses were sampled |
| `RepeatedFormatError` | `max_consecutive_format_errors` malformed responses in a row |
| `ContextExceeded` | the next request would not fit the model's context, or the provider refused it as too long; then `reason` holds the provider's words |

A tool that fails does not end the agent: the model is shown the error as the call's result.

## 4. How a command runs

- **One container for a run**, started from the run's image at the first command, with the
  workspace mounted at the run's workdir. Each command is a `docker exec` in it. Nothing runs
  on the host.
- **Through `/bin/sh`, with stderr merged into stdout**, so the model sees output in the order
  a terminal would.
- **A command that times out or cannot be run is an answer**, with no exit code and an
  `error`. A run does not die on a failed command. Of a command that could not be run, the
  model is told only that: what docker said, with its paths and container, is kept in the log
  as the answer's `detail`.
- **Only the workspace is kept.** What a command installs elsewhere in the container lasts
  until a later `run` starts a new container.

## 5. Long outputs and a full context

**Reading a cut output back** (`recover_output`). The warning on a cut output names a file that
holds the whole of it, which the agent reads with `bash`:

```
[output truncated; full output: /alaya/outputs/3f9a1c2b7d4e.txt]
```

The driver writes each command's whole output to a file named by a hash of its content, and
mounts the files of the log's earlier commands read-only at `/alaya/outputs`. The name is shown
to the model, so it holds nothing of the log: the same output has the same name in every run,
whatever comments or messages came before it. A fork sees its own log's files; no snapshot and
no grader sees them.

**A full context ends the agent.** When the model's `context_tokens` is known, the agent ends
with `ContextExceeded` before a request that would not fit: one whose size reaches the context
less `context_reserve`, or less the model's `output_tokens` when that is smaller. The size is
taken from the last response's reported usage, plus four characters a token for what was added
since.

**Masking** (`mask_observations: {keep_turns: K, block: B}`) leaves the outputs of the oldest
turns out of the view. An omitted output keeps its exit code and names its file:

```json
{"output": "[output omitted; full output: /alaya/outputs/8b21e0c47a19.txt]", "exit_code": 0}
```

The boundary keeps the last `K` turns whole and moves `B` turns at a time. Between its moves
the context only grows at its end, so the provider's prompt cache holds. Only command outputs
are omitted, and the choice depends on turn positions alone, never on the model.

## 6. Differences from mini-SWE-agent

- **A run ends with the `submit` tool**, not with a sentinel line in a command's output. The
  two prompt sentences and the last line of the format-error message say so.
- **A response must hold a tool call, not a `bash` call.** Mini's three sentences that say
  `bash` say a tool, so that a tool added later is not contradicted.
- **The machine line is the image's system and architecture**, such as `Linux x86_64`. Mini
  gives the whole `uname`; in a container its kernel release and version are the host's, so
  they would put the machine a run was created on into the prompt.
- **Observations are Lean's JSON**: the fields are `output`, `exit_code` and `error`, where
  mini has `returncode` and `exception_info`, and non-ASCII text is not escaped.
- **A format error names one problem**, where mini concatenates every problem found. A
  `command` that is not a string is a format error, where Python would run a list.
- **Error texts are plain**, not Python's exception messages, and invalid UTF-8 in output is
  replaced byte by byte.
- **The environment is a snapshot of the workspace**, not a persistent machine (§4).
- **A full context ends the agent** (§5), where mini sends the request.
- **No cost accounting**: mini's `cost_limit` is not enforced.
- **A person can speak to it**: what a person says or changes reaches the model at the start of
  its next round, and with `ask_user` among its tools it can ask (`docs/agent-api.md` §7).
