# Complete task instructions

`alaya root --instruction-file FILE` includes a UTF-8 file in the opening task message.
This is useful when a task specification is too long to read through a bounded `bash`
observation: completion conditions in the middle of the file must reach the model too.

```sh
root=$(alaya root "Complete the task below." ./project \
  --agent mini-swe --instruction-file ./project/INSTRUCTION.md --data ./run)

# Inspect the recorded opening log and the dialogue built from it before sampling.
alaya show "$root" --view --agent mini-swe --data ./run > ./initial-log-and-view.txt

alaya resume "$root" --agent mini-swe --model P:M --data ./run
```

## Delivery and persistence

The CLI reads `FILE` on the host, relative to its current working directory, even when the
agent's workspace runs in a container. An image-internal path supplied with `--path` does
not change where `--instruction-file` is read; provide a host-accessible copy of the file.

The task passed to the agent is exactly `TASK + "\n\n" + file contents`. The file must be
valid UTF-8. Its contents are not trimmed, summarized, or otherwise rewritten, including
any trailing newline. Without the flag, the original task is passed through unchanged;
Alaya does not automatically search for `INSTRUCTION.md`.

MiniSwe places that combined task in its opening user message, before its existing workflow
instructions. Opening messages pass through its view unchanged, so the first model request
contains the whole file without a preliminary tool call. This option adds no model tool.

`root` records the opening log and the combined task in the root's note; it does not call a
model. The first request is constructed when `step` or `resume` samples from that root. The
saved log carries the contents through later continuations, so changing or removing the
original host file does not change that root. The flag applies only when creating a new
root; it does not repair the opening message of an existing run.

The `show --view` command above prints the saved log and its MiniSwe dialogue in full. It
lets a reviewer check the initial message without a provider call. It is a reconstruction
from the recorded root, not evidence that a provider has received a request.

## Errors and limits

A missing flag value, an unreadable file, or invalid UTF-8 is a configuration error and
aborts `root` before a root state is created. Alaya does not silently fall back to an
incomplete task. There is no file-size limit or automatic paging here: the combined prompt
must still fit the selected provider's context limit, and loading it requires memory.

## Verification

The `cli.args` tests check that a file with long Unicode sections on both sides of its
middle completion condition appears intact and exactly once in the first serialized
MiniSwe request, including its final newline. They also cover the unchanged default and
the explicit errors above.

```sh
lake build
lake exe tests cli.args
```

These are local construction and serialization checks, not a real-model benchmark. Earlier
experiments that combined this change with tool-output recovery cannot isolate this option's
effect on model scores.

On 2026-09-20, this standalone source passed `lake build` and all **116 Lean tests with
zero skips** on a Linux filesystem. Both split PRs reuse the existing `fef7df7` CAS
test-fixture support commit: the initial run reproduced the upstream timestamp race;
the shared fixture makes that check deterministic without changing production CAS code.
The full suites were run serially because an existing Docker cleanup check enumerates
every container using its test image.

Validation identity (38 Lean/build source files):

- Source-manifest SHA-256: `6fb29449f3471dea4a90e121bde7f25c7c54569488cea91ba31a4e207232c753`.
- Executable SHA-256: `152675bd3d6c72abf5baa6e66b8de110de7e34b060eeb5318fb8fe4be1f99bb1`.
- Full-test log SHA-256: `9cedcec47d51a964bb37fea627050f07befbc88e92ba70f1e64be36d3930116c`.
