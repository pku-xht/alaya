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
| Report experimental effects separately | The [joint report](https://github.com/msv-lab/alaya/pull/7) is independent documentation, not sampling or causal evidence for this standalone feature. |

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

1. `MiniSwe.lean` and `OutputRead.lean`: optional recovery, preview metadata, pagination, and errors.
2. `Agent.lean` and `Trajectory.lean`: provide the selected log to tool execution.
3. `Test/OutputRead.lean`, `Test/Docker.lean`, `Test/Mini.lean`, and the test worker:
   direct coverage of the new behavior and its cache, persistence, and isolation boundaries.
4. API/contract documentation and the current validation metadata.

## Independent changes

The CAS fixture repair is [PR #6](https://github.com/msv-lab/alaya/pull/6), the historical
cache-only runner is [a separate replay change](https://github.com/msv-lab/alaya/pull/8), and the frozen joint
Vero report is [PR #7](https://github.com/msv-lab/alaya/pull/7). None is implemented by or required to use recovery.
The old archive needs its original request format for cache hits; this PR documents that
boundary rather than including a second replay implementation.

## Current validation

After extraction, `lake build` and all **12 output-recovery tests passed**. The complete
Linux suite reported **125 passed, 1 failed, zero skipped** (126 total). Its only failure
was the unchanged upstream CAS fixture `an unchanged capture re-hashes nothing`
(expected zero cache misses, got five). All Docker tests, including container recreation,
passed. The independent CAS test fix is not folded back into this PR to make the suite green.

[Validation metadata](output-recovery-validation.json) binds this result to the 40-file
source manifest and executable. Earlier 127/129-test all-pass results included other changes
and are not this source's validation. The moved replay example and joint experiment carry
their own evidence. No new model sampling was performed during this extraction.
