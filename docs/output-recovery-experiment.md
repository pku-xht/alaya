# Fresh Vero comparison: complete instructions and recoverable output

The frozen joint implementation fixed the delivery defect, but this exploratory rerun did
**not** improve the Vero score: all eight evaluated outcomes scored **0/9**. Both new runs transmitted
the complete instruction in their first real solver request. Neither old run ever
transmitted the middle `Done condition` in a solver request. The new model did not
call `read_output`; recovery correctness is established by behavioral tests, not
by claiming that this sample exercised the new tool spontaneously.

Task delivery and output recovery are now proposed independently. This report retains the
original joint experiment at `b60f044`; it is not fresh model sampling of either split PR.
The standalone task-delivery change is on
[PR #5](https://github.com/msv-lab/alaya/pull/5).
No effect in the tables below can be attributed to either individual feature.

## Settings and evidence

These are fresh old/new samples and fresh official grades from 2026-09-20, not a
comparison against archived results. Both used `xmcp:closeai/gpt-5.4-mini` through
`https://llm.xmcp.ltd/chat/completions`, temperature 0, Vero `primepy` codeproof,
and Vero commit `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09`. The isolated image was
`sha256:89a18a67a744e17f2cbf2304cdcaa3a57daa3c3bfe3d6cad3a0cf2654a1df7c0`,
with Lean 4.29.1. Alaya used Lean 4.31.0.

The unchanged instruction contains 13,265 Unicode scalar values / 13,390 UTF-8
bytes, SHA-256 `0f9705968bc0b9dbb91615f1764c44fb8ba7e2a29fa3ed29087e738291a07ba0`.
Its completion conditions lie between the old 5,000-character head and tail.
The isolated pre-change implementation was preserved before editing. Public
support commit `9727039` has identical executable Lean sources, old smoke/pilot
runners, and toolchain files to that control; its documentation/history excludes
private prior runs.

| Binary | SHA-256 |
|---|---|
| Old | `6f2e4769896ab3b3837b141c24369c5c64fb5fa50ae4e2353dea4fb09756b05e` |
| New | `4108ae7ea384f83eb0d14d088a144b648930bdc1a17e278503a1489b227ac45a` |

The new frozen experiment binary is byte-identical to the build of experimental
commit `b60f044badb448765d4e0d7ecfd9843452c65a34`. Its 42 Lean/build source files
match the original validated Linux tree. This evidence belongs to that frozen
experiment revision, not to every later revision. See
[frozen validation metadata](https://github.com/pku-xht/alaya/blob/b60f044badb448765d4e0d7ecfd9843452c65a34/docs/output-recovery-validation.json) and the
[machine-readable comparison](https://github.com/pku-xht/alaya/blob/b60f044badb448765d4e0d7ecfd9843452c65a34/docs/output-recovery-experiment-result.json).

The subsequent scope review made the recovery notice explicitly optional, added
direct sibling-isolation and process-restart tests, and removed MiniAsk/Vero
product and harness additions from the main PR. The complete experiment revision
is retained on the fork's
[`codex/output-recovery-experiment` branch](https://github.com/pku-xht/alaya/tree/b60f044badb448765d4e0d7ecfd9843452c65a34).
The standalone output-recovery patch has separate validation; this report does not claim
a fresh model rerun of that patch or its revised notice. See [the review map](output-recovery-review.md).

A minimal real API/execution smoke succeeded first: HTTP 200, returned model
`closeai/gpt-5.4-mini`, 164 reported tokens, 3.041 seconds. These preflight tokens
are separate from the tables below. Every experiment used a fresh private cache.
Actual transport bodies were recorded without credentials or headers; successful
solver request bodies were checked against their cache requests: old smoke/pilot
6/25 and new smoke/pilot 6/20. Simulation requests and responses were saved
separately by the existing simulation runner.

## Outcomes

Seconds and tokens below belong to each segment. They do not repeatedly charge
the common prefix to both continuation rows. `Long outputs` counts new raw output
events over 10,000 characters; actual sent-preview counts are given below.

| Implementation / segment | Vero | Seconds | Tokens | Turns | Stop | Long outputs | Rereads |
|---|---:|---:|---:|---:|---|---:|---:|
| Old smoke | 0/9 | 62.075 | 59,090 | 6 | step limit | 2 | 0 |
| New smoke | 0/9 | 81.074 | 82,380 | 6 | step limit | 3 | 0 |
| Old independent baseline | 0/9 | 642.380 | 218,644 | 14 | Submitted | 3 | 0 |
| New independent baseline | 0/9 | 48.102 | 164,157 | 9 | Submitted | 3 | 0 |
| Old no-answer continuation | 0/9 | 19.243 | 113,447 | 4 | Submitted | 1 | 0 |
| New no-answer continuation | 0/9 | 23.465 | 128,726 | 4 | Submitted | 0 | 0 |
| Old simulated-answer continuation | 0/9 | 29.926 | 177,855 | 6 | Submitted | 0 | 0 |
| New simulated-answer continuation | 0/9 | 33.756 | 200,581 | 6 | Submitted | 0 | 0 |

All six pilot segments submitted early. None was forced to continue. Every final
artifact had seven nonempty code slots and zero filled proof slots; the proof
files remained unchanged. The new no-answer artifact compiled under the official
grader but still proved no specifications. The other seven artifacts failed the
grader's build. The recorded solver compile commands failed 2/2, 4/4, 5/5, 4/4,
1/1, 2/2, 2/2, and 4/4 in the table's order; this detector recognizes `lake build`
and `lake lean`, not every possible compiler invocation. Official final grading
is the authoritative build/score result.

Actual requests carried six distinct truncated results per implementation:
old smoke/pilot 2/4, new smoke/pilot 3/3. No continuation used `read_output`, so
there are no real-model page results to present as a successful recovery. Tests
separately recover the exact omitted middle, concatenate Unicode/long-line pages
to EOF, and recover after forks, reopening CAS, GC, resume, and container recreation.

| Totals, including smoke, baseline, question, simulation and both continuations | Old | New |
|---|---:|---:|
| Generation/tool seconds | 762.052 | 196.759 |
| Successful final grading seconds | 13.208 | 12.826 |
| Known tokens, including simulated answer | 609,651 | 617,614 |
| Exchanges with unknown usage | 1 | 0 |

Known captured provider usage matches the committed-response totals. The old
pilot had one **565.077-second curl 28 transport failure**, with unknown delivery,
tokens, and cost; the existing retry policy retried it. No missing usage is counted
as zero. None of the provider responses supplied numeric cost fields, so a monetary
total is unavailable. The timing gap cannot be attributed to this code change.

## Budgets and interpretation

Both smoke runs retained six turns and a 1,800-second generation ceiling. Both
independent baselines retained the existing 1,800-second ceiling with no turn cap.
Each paired branch has the same 1,800-second total ceiling after charging its
shared prefix, question, and simulated wait. Within the old pilot both continuation
budgets were 1,152.285 seconds; within the new pilot both were 1,744.628 seconds.
The remaining durations differ across implementations because their actual shared
prefix durations differ. No time-feedback, submit, model, specification, or
`ask_user` policy was changed.

Answers are same-model **simulated data**, not human participants or expert labels.
The baseline and the two branches are distinct experimental roles. Old/new pilots
elicited different questions; there is only one continuation per answer condition.
The old implementation is an instruction-delivery defect control, not a fair
model-capability baseline. Delivery and recoverability were changed together;
this sample identifies neither their separate effects nor a causal answer effect,
statistical significance, or an efficiency improvement.

Infrastructure failures were preserved. An initial old-smoke attempt stopped
before any paid request because WSL could not resolve a Windows worktree's Git
pointer; a provenance-only adapter fixed that lookup for a fresh zero-cache run.
Initial grading CLI calls for old smoke and the new simulated-answer terminal
returned exit 1 without creating evaluation leaves. Their original helper did
not retain stderr, so the specific cause is unknown. The same unchanged terminal
states were then graded successfully in separate grading workspaces, without
model resampling or `--force`. Future helper failures now retain redacted stderr.

## Reproduction and privacy

Use the frozen harness's
[smoke instructions](https://github.com/pku-xht/alaya/blob/b60f044badb448765d4e0d7ecfd9843452c65a34/docs/vero-smoke.md),
[paired-pilot instructions](https://github.com/pku-xht/alaya/blob/b60f044badb448765d4e0d7ecfd9843452c65a34/docs/vero-experiment.md), and
`example/compare_vero_runs.py --help` in that checkout. Build old support commit
`9727039` and new experimental commit `b60f044`
in separate checkouts, use the same pinned environment and per-run private
recording directories, and run branches within each pilot sequentially. The
comparison checks model/task/image/instruction equality, ancestry, budgets,
raw-output page matches, actual transport requests, and official score artifacts.

Private evidence retains all real requests/responses, CAS/cache, transcripts,
simulated-answer context, code/proof snapshots and diffs, failure records, and
grading leaves. The current PR contains the standalone output-recovery change, reviewed
reports, validation metadata, and the archived replay example. The aggregate metrics and Vero
reproduction harness are linked from the frozen experiment branch. The HTML context view remains a
prospective reconstruction; the saved actual request bodies establish transmission.

Validation of the frozen experiment revision: `lake build`; **130 Lean tests passed with no skips** on a Linux
filesystem, including real Docker recovery; **13 Python tests passed** without
API calls. An existing stat-cache test was made deterministic without relaxing
production invalidation; a same-timestamp same-size edit test protects that guard.
Validation of the later scoped patch is recorded separately in the review map and metadata.
