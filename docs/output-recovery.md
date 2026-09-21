# Complete task delivery and recoverable tool output

MiniSwe keeps a bounded preview of long command output in the model context and lets the model
read any omitted part from the recorded observation. The trajectory already stores the complete
executor output, so recovery reuses that content rather than creating another spill directory
or workspace snapshot.

`root --instruction-file FILE` puts a task file directly into the opening user message, so
completion conditions do not depend on the model reading a long file through a tool preview.
The file is appended verbatim to the positional task, and the combined text is recorded in
the root before any model request. Without the option, task construction is unchanged.
See [complete task instructions](task-instructions.md) for host-path handling, errors, and
how to inspect the saved opening message.

MiniVero shares MiniSwe's tools, view, and execution loop, so it also offers `read_output`.
Its Vero mode, prompt sections, limits, and submission behavior are unchanged.

## Preview and page contract

`Alaya.Agent.MiniSwe.observation` changes only the model-facing rendering of an executor
`Output`. The recorded JSON observation and values consumed by other code stay complete.
Output of at most 10 000 Unicode scalar values remains in the ordinary `output` field.
Longer output is rendered with:

| Field | Meaning |
| --- | --- |
| `output_head`, `output_tail` | First and last 5 000 characters |
| `elided_chars`, `total_chars` | Omitted and total character counts |
| `truncated` | `true` |
| `displayed_ranges` | Two zero-based half-open character ranges `[start, end)` |
| `output_ref` | `sha256:` followed by the SHA-256 of the complete decoded output's UTF-8 bytes |
| `read_output` | Ready-to-use arguments beginning at the first omitted character |
| `warning` | Explains the reference, offset convention, and optional recovery procedure |

`exit_code` and any executor `error` remain visible. The preview's 10 000-character bound is
for the text itself; JSON metadata and guidance add context. This is not a token limit or a
bound on total conversation length.

For example, after receiving an `output_ref`, the model can request:

```json
{"ref": "sha256:<digest from output_ref>", "offset": 5000, "limit": 10000}
```

`read_output` requires a string `ref`, a nonnegative integer `offset`, and an integer `limit`
from 1 through 10 000. Its result has this shape:

```json
{
  "output_ref": "sha256:<same digest>",
  "content": "the requested original characters",
  "offset": 5000,
  "end_offset": 15000,
  "total_chars": 25000,
  "next_offset": 15000,
  "eof": false
}
```

Recovery is entirely on demand. `bash` remains the default for commands and file work. If the
preview is sufficient for the next decision, continue without recovery. If omitted content is
needed, choose an `offset` and `limit` for that section; `read_output` may be the only tool call
in the response. There is no obligation to reach EOF. The agent can continue with `bash` or
call `submit` separately after reading only the needed part. For another page, use `next_offset` when
useful. If the entire remaining output is needed, following it reaches `eof: true` with
`next_offset: null`.
`offset == total_chars` returns an empty final page; an offset beyond the end returns an error.
The unit is a Unicode scalar value, not a UTF-8 byte, UTF-16 code unit, line, or grapheme cluster.
Pages do not split a scalar value. They can split a multi-scalar displayed glyph, but concatenating
the pages restores the exact original string. Newline placement has no effect: a very long
single line can be read from start to end or at a chosen middle offset.

Page text uses `content`, not executor `output`, so the generic executor-output preview does not
truncate it again. Invalid arguments are rejected by action parsing; an unknown reference or
out-of-range offset produces an explicit error observation. Recovery never reports success
when it found no corresponding output.

## Persistence, forks, and failure behavior

The reference identifies text, not a host path or an independently stored object. `read_output`
searches only executor-output observations in the current full `Workspace.log`, matching their
content digest. Identical text can share a reference. Both `Agent.run` and the trajectory driver
supply the current log before each act, including earlier observations from the same turn.
Direct library callers must provide the relevant log themselves.

The trajectory serializes original observations inside ordinary version-1 state objects.
`logOf` reconstructs them from the root to the selected state. Consequently, a fork retains
access to its ancestors' output, a resumed process reopens the same recorded content, and a
fresh execution container does not need a copy of a spill file. Sibling branch observations
are not searched. Grading checkouts remain separate and evaluation nodes remain terminal leaves.

There is no second full-output save step or output-specific retention mechanism. The ordinary
state files keep the observations alive. A failure to read or persist a trajectory state is a storage error;
the driver does not acknowledge a durable child state when its write failed. A reference missing
from the supplied log returns `Full output unavailable` rather than a fabricated page. The
store must be preserved along with the trajectory; deleting it cannot be repaired from a
preview or the model response cache. The store-free `Agent.run` supports recovery only for the
log supplied to that process and does not itself promise durability.

The executor already decodes command output as UTF-8 and replaces invalid byte sequences.
Recovery preserves that entire decoded string; it does not introduce raw binary capture.
The current implementation also scans and hashes recorded outputs during lookup, so very large
logs can make recovery expensive. This change bounds the model's preview and page size, not
executor memory, state-file size, or the accumulated context.

## Compatibility and scope

No observation schema migration is needed. Short outputs below the former threshold keep their
existing rendering; output exactly 10 000 characters now stays in `output` instead of displaying
a zero-omission preview. Longer output receives the recovery metadata above. The added
`read_output` tool and changed long-output rendering intentionally change model-cache keys.
Historical cache hits require the original view, tool list, and model identity. The existing
cache mechanism is unchanged: ordinary CLI runs may call the provider on a miss; library
callers using read-only cache access receive an error instead. No archive-specific replay
runner is included.

This change does not add historical-output pruning or conversation summaries, alter time
feedback, force continuation after submission, change the model or task specification, or
change `ask_user` policy. Real requests, tool execution, cached replay, and fresh grading must
be reported separately.

Recovery reliability and Vero task performance are separate claims. Tests of exact page
contents, EOF, persistence, and failure handling establish the recovery contract; they do not
establish an improvement in benchmark scores. Vero runs provide exploratory evidence of model
behavior under the recorded settings, including whether the model chose to recover any output.
The included [joint Vero report](output-recovery-experiment.md) sampled the frozen `b60f044`
implementation with both task delivery and output recovery. It cannot establish either
feature's independent effect, and it is not new sampling of this restic-based revision.

## Design references

The following source versions were inspected for the bounded-preview, full-content, and
explicit-retrieval pattern. Their retention and filesystem choices are not Alaya's contract.

- **Pi**, commit `7d5eb0ee3b16ee3e5733e235107ee3f382cfca04`:
  [shell result](https://github.com/badlogic/pi-mono/blob/7d5eb0ee3b16ee3e5733e235107ee3f382cfca04/packages/coding-agent/src/core/tools/bash.ts#L311-L337),
  [output accumulator](https://github.com/badlogic/pi-mono/blob/7d5eb0ee3b16ee3e5733e235107ee3f382cfca04/packages/coding-agent/src/core/tools/output-accumulator.ts),
  and [file pagination](https://github.com/badlogic/pi-mono/blob/7d5eb0ee3b16ee3e5733e235107ee3f382cfca04/packages/coding-agent/src/core/tools/read.ts#L149-L175).
  It keeps a 2 000-line / 50 KiB tail and stores complete shell output in a temporary file,
  reporting the shown range and a path. A read page names its next line offset; an oversized
  single line needs a shell fallback.
- **DeepSeek Harness**, commit `fb2c4b9e698e30edb738bca4cf0618587db7d203`:
  [spill policy](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/spill/spill-policy/src/index.ts),
  [local store](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/spill/spill-local/src/index.ts),
  and [filesystem limitation](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/spill/spill-local/README.md#L122-L140).
  It separates program values from model presentation, reserves notice space within the preview
  budget, exempts reads to prevent repeated spilling, and keeps the original inline result if
  storage fails. Its local backend requires the reader to share the saved file's filesystem.
- **OpenCode**, commit `fee476bb90043a1012abda156dd9af9e5c71b19d`:
  [truncation](https://github.com/anomalyco/opencode/blob/fee476bb90043a1012abda156dd9af9e5c71b19d/packages/opencode/src/tool/truncate.ts)
  and [read tool](https://github.com/anomalyco/opencode/blob/fee476bb90043a1012abda156dd9af9e5c71b19d/packages/opencode/src/tool/read.ts#L137-L179).
  It writes full text before returning the path and Grep/Read guidance, with configurable
  previews defaulting to 2 000 lines / 50 KiB and a seven-day cleanup policy. Its line reader
  clips individual lines, which motivates character pagination for Alaya's long-line case.

Alaya adopts explicit ranges, actionable recovery, and the separation of recorded data from
model presentation. Looking up the existing observation avoids duplicate storage and host-path
dependencies; character pagination avoids the gaps left by line-only readers.
