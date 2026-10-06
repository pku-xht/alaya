# MiniSwe

`Alaya.Agents.MiniSwe` is a port of
[mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent)'s default tool-calling agent. It
keeps what defines that agent: its prompts, its `bash` tool, its way of reading a response and
answering a malformed one, and its limits. It is written as a program (`docs/agent-api.md` §8):
a loop over a conversation that opens with its task.

## 1. Options

Set at `call` with `--set FIELD=VALUE`; `alaya config --program mini-swe` prints the defaults.
A field left out is its default, and a misspelt one is an error.

| Field | Default | Meaning |
| --- | --- | --- |
| `model` | none | the model it samples: its spec (`docs/llm-api.md`), a name alone being that model's defaults; required |
| `task` | none | the task, verbatim; required. `--set-file task=FILE` reads it from a file |
| `max_consecutive_format_errors` | 3 | malformed responses in a row before `RepeatedFormatError`; 0 is no limit |
| `executor.timeout_seconds` | 30 | the time a command may take |
| `executor.env` | mini's | environment overrides for every command: `PAGER=cat` and the like |
| `tools` | `["bash", "submit"]` | the tools offered, in order. `bash` and `submit` are required; `ask_user`, `time_budget` and `subagent` may be added. The list replaces the default one |
| `question_types` | `[]` | the kinds of question `ask_user` lets the model ask: any of `yes_no`, `single_choice`, `open_ended`. Required, and not empty, when `ask_user` is offered |
| `recover_output` | false | name the file that holds the whole of a cut output (§4) |
| `context_reserve` | 8000 | tokens kept free for the next response (§3) |
| `mask_observations` | null | `{keep_turns, block}`: leave old outputs out of the view (§4) |

## 2. What the model is sent

**The opening** is mini's two messages, rendered from its `mini.yaml`: the system message, and
the task with a line naming the machine: the system and the architecture, as the `uname`
routine reads them in the call's container. Each offered tool's instruction is appended to the task message.

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
| `RepeatedFormatError` | `max_consecutive_format_errors` malformed responses in a row |
| `ContextExceeded` | the next request would not fit the model's context, or the provider refused it as too long; then `reason` holds the provider's words |

A tool that fails does not end the agent: the model is shown the error as the call's result.

**A full context ends the agent.** When the model's `context_tokens` is known, the agent ends
with `ContextExceeded` before a request that would not fit: one whose size reaches the context
less `context_reserve`, or less the model's `output_tokens` when that is smaller. The size is
taken from the last response's reported usage, plus four characters a token for what was added
since.

## 4. Commands and their output

A command runs through `/bin/sh` in the run's container, at its workdir, with stderr merged into
stdout and no standard input. A command that fails or runs out of time still gets an answer,
which the model sees.

A long output would flood the context, so the model sees only the first and last 5 000
characters of an output of 10 000 or more (§2). With `recover_output`, the warning also names a
file that holds the whole output, which the model can read with `bash`:

```
[output truncated; full output: /alaya/outputs/3f9a1c2b7d4e.txt]
```

The file is named by a hash of the output, so the same output has the same name in every run.

Over a long run, old outputs fill the context too. With
`mask_observations: {keep_turns: K, block: B}`, the outputs of turns older than the last `K` are
replaced by a note that names their file:

```json
{"output": "[output omitted; full output: /alaya/outputs/8b21e0c47a19.txt]", "exit_code": 0}
```

The boundary moves `B` turns at a time, so between its moves the conversation only grows at its
end, and the provider's prompt cache stays valid.

## 5. Differences from mini-SWE-agent

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
- **The environment is a snapshot of the workspace**, not a persistent machine: what a command
  installs outside the workspace lasts only until a later `resume` starts a new container.
- **A full context ends the agent** (§3), where mini sends the request.
- **No cost accounting or step limit**: mini's `cost_limit` and `step_limit` are not enforced,
  and the agent never ends with `LimitsExceeded`. `alaya resume --samples N` pauses a run after `N`
  responses instead, and a later `resume` goes on from there (`docs/cli.md`).
- **A person can speak to it**: what a person says or changes reaches the model at the start of
  its next round, and with `ask_user` among its tools it can ask, in the kinds of question its
  configuration allows (`docs/agent-api.md` §7).
