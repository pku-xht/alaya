# Alaya project notes

- This repository is a Lean 4 library and CLI. Use the version in `lean-toolchain`.
- Build with `lake build`; run tests with `lake exe tests` (an optional substring selects a subset).
- The CLI's host executor requires Unix tools. On Windows, run the CLI in WSL/Linux.
- Run the full CAS/filesystem test suite on a Linux filesystem, not a Windows-mounted checkout; executable bits and filesystem timestamps are part of its contract.
- Core interfaces live in `Alaya/Agent.lean`, recorded runs in `Alaya/Trajectory.lean`, and the CLI in `Main.lean`. Their contracts are documented in `docs/`.
- Complete task delivery and recoverable tool previews are specified in `docs/output-recovery.md`. Use `root --instruction-file` for file-based task specifications; keep recovery based on recorded observations, including across forks and container restarts.
- `example/trajectory.tar.gz` is a recorded Bija run and model cache. Preserve the archive; unpack experiments into ignored scratch space such as `tmp/`.
- A fresh real-model Vero smoke run is documented in `docs/vero-smoke.md` and routed by `.agents/skills/vero-smoke/SKILL.md`; it uses Vero's pinned Lean toolchain separately from Alaya's.
- The `mini-ask` agent and paired same-model answer pilot are documented in `docs/vero-experiment.md`. Keep equal continuation budgets, preserve early-stop outcomes, and distinguish simulated answers from human data.
- Distinguish archived results, cached model replay with freshly executed tools, fresh model sampling, and fresh grading. Bija test counts are not Vero specification counts.
- A cache-only replay must fail on a cache miss; it must not silently send a request to a provider.
- Keep grading checkouts separate from resumable agent workspaces. Evaluation states are terminal leaves; hidden tests must not enter an agent continuation.
- Validate changes at the relevant scope: build Lean changes, run targeted behavioral tests, and inspect generated reports. Do not present an unrun example as a verified result.
