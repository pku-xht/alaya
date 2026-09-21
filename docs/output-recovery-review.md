# Task delivery and output recovery: review map

This change delivers file-based task instructions directly in the opening request and makes
long tool output recoverable on demand. Acceptance is based on delivery and recovery
reliability. A higher Vero score, spontaneous use of recovery, and reading every page are not
acceptance criteria.

## Contract and evidence

| Requirement | Implementation and direct coverage |
| --- | --- |
| Complete initial instructions | `root --instruction-file` appends the host file verbatim before creating the opening log. `Test/Cli.lean` checks that a long instruction's middle completion condition and trailing newline appear intact and exactly once in the serialized first request, plus the unchanged default and explicit read/UTF-8 errors. |
| Bounded preview with exact recovery | `MiniSwe.observation` limits only the displayed executor text; the original observation is unchanged. `read_output` provides a content hash, Unicode scalar ranges, and pages. `Test/OutputRead.lean` covers omitted-middle recovery, a maximum-size page through the view, long single-line/Unicode reconstruction to EOF, and errors. |
| Recovery is optional | The notice offers chosen ranges when needed, with no instruction to read to EOF. Behavioral tests accept both `long output -> submit` and `long output -> bash -> submit` without injected recovery or continuation. |
| Persistence and branch isolation | Forks can read ancestor observations. A sibling cannot read another branch's private output even when it knows the reference. A separate OS process reopens the state store and records a recovered page after removal of the old execution directory. The Docker test closes one container and starts another before recovery. |
| MiniVero compatibility | MiniVero inherits the same tools and view. Tests cover recovery in both modes and unchanged immediate submission; its mode-specific prompts and limits remain covered by `Test/MiniVero.lean`. |
| Experimental effects reported separately | The [joint Vero report](output-recovery-experiment.md) preserves the frozen `b60f044` experiment. It is not a real-model rerun of the current restic-based source and cannot isolate either feature's effect. |

The recovery suite also covers failed state persistence, missing/corrupt states, unknown
references, invalid ranges, short/exact-limit output, and read-only cache isolation.
Recovery preserves the executor's decoded string, not arbitrary binary stdout. Keeping the
trajectory state files is required. Output lookup scans ancestor observations; this change
does not bound executor memory or total model context.

## Review by responsibility

1. `Alaya/Cli.lean` and `Main.lean`: read the optional instruction file before root creation;
   preserve existing workspace-overlap checks and agent/mode dispatch.
2. `Alaya/Agent/MiniSwe.lean` and `Alaya/Agent/OutputRead.lean`: optional recovery, preview
   metadata, pagination, and errors.
3. `Alaya/Agent.lean` and `Alaya/Trajectory.lean`: provide the selected log to tool execution,
   using the existing state store and workspace backend.
4. `Test/Cli.lean`, `Test/OutputRead.lean`, `Test/Docker.lean`, `Test/Mini.lean`, and the test
   worker: behavioral coverage of delivery, cache, persistence, and isolation boundaries.
5. Contract documentation, current validation metadata, and the separately identified frozen
   experiment report.

There is no archive-specific replay runner, historical-output pruning, conversation summary,
time-feedback change, new model selection, changed task specification, or `ask_user` policy
change. Submission remains terminal. Existing model caching is reused; historical cache hits
still require the original request format and model identity.

## Validation

`lake build` passed on a Linux filesystem with Lean 4.31.0 and restic 0.19.1. All **126 cases
were verified**: the full run executed 114 and skipped 12 while Docker Desktop was unavailable;
after recovery, all 12 Docker cases passed with no skips. Targeted checks passed: output
recovery **13/13**, CLI **13/13**, and MiniVero **11/11**. Eight additional real CLI checks
verified saved instruction text for MiniSwe and both MiniVero modes, failure before data-directory
creation, the unchanged default, and workspace-overlap protection. No model requests were sent.

The [validation metadata](output-recovery-validation.json) records each run, the 51-file build
input manifest, and the executable hash. Earlier standalone test counts and CAS fixture failures
belong to older sources, not this combined revision.

The [experiment validation metadata](output-recovery-experiment-validation.json) belongs only
to frozen commit `b60f044`; its 130-test result and real Vero runs must not be reported as
validation of the current source.
