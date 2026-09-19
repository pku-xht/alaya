# Reliability scope and review map

Acceptance criteria for this patch are delivery and recovery reliability. A higher Vero score,
spontaneous use of recovery, and reading every page are not acceptance criteria.

## Contract and evidence

| Requirement | Implementation and direct evidence |
| --- | --- |
| Deliver the complete task in the initial request | `--instruction-file` appends the exact UTF-8 text before root creation. `Test/Cli.lean` checks the complete file, including middle completion conditions and its trailing newline, in the first serialized request. The frozen experiment separately verifies actual transmitted requests. |
| Bounded preview with exact recovery | `MiniSwe.observation` limits only the displayed executor text; the original observation is unchanged. `read_output` provides a content hash, Unicode scalar ranges, and pages. `Test/OutputRead.lean` checks omitted-middle recovery, a maximum-size page through the view, long single-line/Unicode reconstruction to EOF, and explicit failure paths. |
| Recovery is optional | The notice offers chosen ranges when needed, with no instruction to read to EOF. A behavioral test accepts both `long output -> submit` and `long output -> bash -> submit` without any injected recovery or continuation. |
| Persistence and branch isolation | Forks can read ancestor observations. A sibling cannot read another branch's private output even when it knows the reference. A separate OS process reopens CAS and records a recovered page after removal of the old execution directory. The Docker test closes one container and starts another before recovery. |
| Report experimental effects separately | The frozen experiment reports eight 0/9 grades and zero recovery calls. The timeout, unknown fees, simulated answers, early submissions, and small-sample limits remain explicit. Neither a score gain nor a timing gain is claimed. |

The recovery suite also covers failed state persistence, missing/corrupt states,
unknown references, invalid ranges, short/exact-limit output, and read-only cache
isolation. The scope audit added direct evidence for optional use, sibling denial,
and process restart; the older fork test alone did not establish those properties.

Recovery preserves the executor's decoded string, not arbitrary original binary
stdout. Keeping the trajectory store is required. Output lookup scans ancestor
observations; this change does not bound executor memory or total model context.

## Review the production change independently

Only six production files change: `Alaya/Agent.lean`,
`Alaya/Agent/MiniSwe.lean`, `Alaya/Agent/OutputRead.lean`, `Alaya/Cli.lean`,
`Alaya/Trajectory.lean`, and `Main.lean`. The CLI continues to register only the
upstream `mini-swe` agent. No `MiniAsk` implementation, `ask_user` prompt, experiment
time-feedback prompt, model choice, or forced continuation is added by this PR.

The commits are arranged for review in this order:

1. Stabilize the existing CAS stat-cache test fixture, retaining a guard for
   same-size/same-timestamp edits. Production CAS invalidation is unchanged.
2. Add complete instruction delivery and optional output recovery, with direct
   behavioral tests and API/CLI documentation.
3. Keep an explicit historical view/tool schema in the archived replay example.
   Read-only cache misses still fail without a provider transport.
4. Record this scope audit, independent candidate validation, and the separate
   experiment report.

## Frozen experiments and current validation

The complete Vero/MiniAsk harness and its original source are preserved on the
fork's [`codex/output-recovery-experiment` branch](https://github.com/pku-xht/alaya/tree/b60f044badb448765d4e0d7ecfd9843452c65a34).
Old control commit `9727039` and new experimental commit `b60f044` remain available
for reproducing the comparison. They are optional experiment support, not
dependencies that upstream must adopt to review the production fix.

The [experiment report](output-recovery-experiment.md) describes those frozen
runs. In particular, its 130 Lean tests, 13 Python tests, 42-file manifest, and
experiment binary hash are historical evidence for `b60f044`; they are not reused
as the final scoped candidate's test count or binary identity. The optional
notice was clarified after those runs and was not sampled again in this audit.

The scoped candidate is built and tested separately on a Linux filesystem. Its
source manifest, binary hash, test counts, and relationship to the frozen
experiment are recorded in [validation metadata](output-recovery-validation.json).
`lake build` and all **129 Lean tests** passed with no skips, including the 12-case
recovery suite and real Docker recreation. Relative to the frozen 130-test suite,
the scoped suite omits four MiniAsk tests with that separate feature and adds
three direct reliability cases. The 40 compiled source/build files match the
committed candidate; the archived replay example also compiles.
The original private request/response evidence stays outside the public patch.
