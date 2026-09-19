# Reliability scope and review map

Acceptance for this patch is based on output recovery reliability. A higher Vero score,
spontaneous use of recovery, and reading every page are not acceptance criteria.

Complete task delivery through `--instruction-file` is proposed separately on
[PR #5](https://github.com/msv-lab/alaya/pull/5).
Both changes target upstream `main` independently. This PR leaves `Alaya/Cli.lean`, `Main.lean`,
and `Test/Cli.lean` identical to the upstream base; it neither implements nor requires that flag.

## Contract and evidence

| Requirement | Implementation and direct evidence |
| --- | --- |
| Bounded preview with exact recovery | `MiniSwe.observation` limits only the displayed executor text; the original observation is unchanged. `read_output` provides a content hash, Unicode scalar ranges, and pages. `Test/OutputRead.lean` checks omitted-middle recovery, a maximum-size page through the view, long single-line/Unicode reconstruction to EOF, and explicit failure paths. |
| Recovery is optional | The notice offers chosen ranges when needed, with no instruction to read to EOF. A behavioral test accepts both `long output -> submit` and `long output -> bash -> submit` without any injected recovery or continuation. |
| Persistence and branch isolation | Forks can read ancestor observations. A sibling cannot read another branch's private output even when it knows the reference. A separate OS process reopens CAS and records a recovered page after removal of the old execution directory. The Docker test closes one container and starts another before recovery. |
| Report experimental effects separately | The frozen joint experiment reports eight 0/9 grades and zero recovery calls. It changed both task delivery and output recovery, so it does not measure this standalone PR's effect. The timeout, unknown fees, simulated answers, early submissions, and small-sample limits remain explicit. Neither a score gain nor a timing gain is claimed. |

The recovery suite also covers failed state persistence, missing/corrupt states,
unknown references, invalid ranges, short/exact-limit output, and read-only cache
isolation. The scope audit added direct evidence for optional use, sibling denial,
and process restart; the older fork test alone did not establish those properties.

Recovery preserves the executor's decoded string, not arbitrary original binary
stdout. Keeping the trajectory store is required. Output lookup scans ancestor
observations; this change does not bound executor memory or total model context.

## Review the production change independently

Only four production files change: `Alaya/Agent.lean`,
`Alaya/Agent/MiniSwe.lean`, `Alaya/Agent/OutputRead.lean`, and
`Alaya/Trajectory.lean`. The CLI continues to register only the
upstream `mini-swe` agent. No `MiniAsk` implementation, `ask_user` prompt, experiment
time-feedback prompt, model choice, or forced continuation is added by this PR.

Review the final diff by responsibility:

1. `Alaya/Agent/MiniSwe.lean` and `Alaya/Agent/OutputRead.lean`: preview metadata,
   optional `read_output`, Unicode character pagination, and explicit errors.
2. `Alaya/Agent.lean` and `Alaya/Trajectory.lean`: provide the full current log at
   tool execution. `Test/OutputRead.lean` and `Test/Docker.lean` cover recovery,
   branch isolation, persistence, process restart, and container recreation.
3. `Test/Cas.lean`: stabilize the existing stat-cache fixture while retaining a
   same-size/same-timestamp edit guard. Production CAS invalidation is unchanged.
4. `example/ReplayCached.lean` and `example/prepare_replay.py`: retain the archived
   view/tool schema. Read-only cache misses still fail without a provider transport.
5. API and recovery documentation, this map, independent candidate validation,
   and the separately identified joint experiment report.

## Frozen experiments and current validation

The complete Vero/MiniAsk harness and its original source are preserved on the
fork's [`codex/output-recovery-experiment` branch](https://github.com/pku-xht/alaya/tree/b60f044badb448765d4e0d7ecfd9843452c65a34).
Old control commit `9727039` and new experimental commit `b60f044` remain available
for reproducing the comparison. They are optional experiment support, not
dependencies that upstream must adopt to review the production fix.

The [experiment report](output-recovery-experiment.md) describes those frozen
runs. In particular, its 130 Lean tests, 13 Python tests, 42-file manifest, and
experiment binary hash are historical evidence for `b60f044`; they are not reused
as the standalone output-recovery candidate's test count or binary identity. The optional
notice was clarified after those runs. Neither split PR has been sampled again; these runs
changed delivery and recovery together and cannot attribute outcomes to either feature.

The standalone candidate passed `lake build` and all **127 Lean tests with zero skips**
on a Linux filesystem, including the 12 recovery tests and real Docker recreation.
The archived replay example compiled; its full replay was not rerun. The
[validation metadata](output-recovery-validation.json) binds these results to the source
manifest and binary. It covers 40 Lean/build inputs plus the replay example. The earlier
combined candidate's 129-test result is not reused for this split source.

An initial parallel test run exposed the existing Docker cleanup test's global image-based
container enumeration. Running the two full suites serially passed without changing the
recovery source. Both PRs share the existing `fef7df7` CAS test-fixture support commit;
production CAS behavior is unchanged. Initial failure records and the original private
request/response evidence remain outside the public patch.
