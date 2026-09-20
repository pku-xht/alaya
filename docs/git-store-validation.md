# Native Git snapshot validation

Validated on 2026-09-20 using production code at `79b2f304d6d0be4f9c82be18325f45e7b086a3ad`.
The subsequent report-only commit does not change that code. Lean was 4.31.0 and Git was
2.43.0, running on a WSL Linux filesystem. The binary SHA-256 was
`adcf2925b0b3572522b9765f61344f2b56116cbd429951d024816b26bc36dae7`.
See [the storage contract](git-store.md) for behavior and supported configurations.

## Build and behavior

`lake build` passed. `ALAYA_TEST_GIT_IMAGE=node:22-bookworm lake exe tests` passed all
128 tests with no skips, including 53 CAS cases. The Git-enabled Docker image was already
present locally; the test did not pull or build an image.

Coverage includes native index reuse, changes/deletions/renames, ignores and built-in
attributes, commit ancestry, branch refs, independent checkouts, SHA-1/SHA-256 format checks,
symlinks/executable modes/gitlinks, garbage collection, explicit legacy import, and continued
use of a Docker runtime after checkout. Regression cases reject configured host filter
commands and internal-fetch redirects, and verify that fsmonitor commands do not execute.

The bundled archive was extracted into a fresh directory, excluding AppleDouble metadata,
then imported twice with `alaya import-legacy --data D`. Both imports produced the same
mapping. All 20 states, 10 distinct workspace snapshots and two evidence snapshots were
checked. State fields and events matched except for remapped addresses; snapshot file bytes
and modes matched the original raw objects. Actual checkouts of the root and both terminal
branches matched 38, 577 and 558 files respectively. All 586 original blobs, 32 refs and
16 cache files retained their SHA-256 digests. The archive itself was unchanged:
`2314b17de05bbeec058b5c092981cc372b0b804c202dc9f531ec7df76a8c75a8`.
This was conversion and checkout verification, not cached model replay or fresh grading.

## Local filesystem comparison

All three backends were run afresh on independent, identical fixtures: 100 and 1,000 ordinary
1 KiB files under `src/` and `build/`, with no ignore rules or synthetic `.git` contents.
Each timed operation was a complete CLI `root` or `checkout` invocation. After the first
operation, three unchanged repetitions were measured. A middle file was then modified,
captured and restored; the old snapshot was also restored. All 42 file-content inventory
checks passed. Native repository metadata was excluded from file-content comparison.

| Backend | 1,000-file unchanged capture median | Unchanged checkout median |
| --- | ---: | ---: |
| Original CAS, production code matching upstream `8f0d08b` | 0.088040 s | 0.084467 s |
| Earlier Git-object implementation `deff1ec` | 6.634932 s | 7.055351 s |
| Native Git implementation `79b2f30` | 0.126800 s | 0.134975 s |

The native path made 18 top-level Git invocations per capture and 13 per checkout at both
fixture sizes; the earlier Git implementation made 2,030 and 2,029 at 1,000 files. A separate
PATH wrapper counted invocations; its time was not included. Git's internal subprocesses are
not included in these counts. Native capture/checkout were about 52 times faster than the
earlier Git implementation, but remained 1.44/1.60 times slower than the original CAS here.

These are small local measurements on shared hardware, not throughput or benchmark-score
claims. Initial files had timestamps in 2000 to exercise the old CAS's steady-state cache;
the modified file used its actual new timestamp. Controls were retained unchanged while the
final native binary was rerun on fresh identical fixtures after the configuration guard was
added. Differences in ignored files, metadata and history are intentional semantic changes,
not evidence that the backends provide identical backup guarantees.

## Fresh model smoke and fresh control

Both `79b2f30` and isolated `deff1ec` received a new six-turn run using
`xmcp:closeai/gpt-5.6-luna`, temperature 0, the configured XMCP chat-completions API, Vero
`primepy` in `codeproof` mode at `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09`, Lean 4.29.1,
and the same pinned execution image. Each generation budget was 1,800 seconds. Both used
fresh caches and the existing positional `root TASK` interface containing the complete task;
actual first wire requests verified identical delivered-task SHA-256:
`ec7979aa791000dac4c5cf8c9ff78e64dbe1f6ecde6621ae8317007fdc179e63`.
Neither control was instruction-deficient in this comparison.

| Measure | Earlier implementation, fresh control | Native Git, fresh run |
| --- | ---: | ---: |
| Generation time | 55.886 s | 56.564 s |
| Grading time | 3.169 s | 4.628 s |
| Input / output tokens | 77,521 / 3,359 | 78,862 / 3,956 |
| Total tokens | 80,880 | 82,818 |
| Tool observations | 8 | 9 |
| Outputs reaching the existing 10,000-character preview limit | 2 | 2 |
| Official specification score | 0/9 | 0/9 |
| Implementation harness build | Passed | Failed |
| Proof result | 9 build errors | 9 unfilled |
| Stop | Six-turn limit | Six-turn limit |

The control changed implementation and proof files; the native run changed only the
implementation file. Neither submitted early or was forced to continue. The provider did
not report usable cost data. A separate 15-token API preflight is excluded from these totals.
This PR does not add `read_output`; no such recovery calls were available or made. Existing
preview behavior, task specification, time feedback and ask-user policy were unchanged.

Fresh CLI processes reopened both runs and verified initial/terminal checkouts, including
content and modes. The official grader used separate terminal evaluation checkouts. No
simulated human answers were used. Actual requests, responses, tool traces, generated code,
proofs and interactive reports were retained locally and were not published with this PR.

The new implementation did not improve the score in this pair, and its implementation failed
to compile. Runs partly overlapped on shared hardware; with one sample per implementation,
these results establish integration behavior, not a statistical or causal conclusion about
model quality or latency.
