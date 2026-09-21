# Alaya project notes

- Use the Lean version in `lean-toolchain`. Build with `lake build`; run tests with
  `lake exe tests` or pass a substring to select related cases.
- Run CLI and filesystem tests on Linux, including WSL on a Linux filesystem.
  Workspace tests need restic 0.17 or later; Docker tests require a working daemon.
  Check for skipped tests before reporting container recovery as verified.
- Agent contracts are in `docs/agent-api.md`; state storage and workspace snapshots
  are in `docs/trajectory-schema.md`.
- Complete task delivery and optional tool-output recovery are specified in
  `docs/task-instructions.md` and `docs/output-recovery.md`. Preserve raw observations
  and branch-local recovery when changing the model-facing view or run drivers.
- Keep `example/trajectory.tar.gz` intact. Unpack experiments into ignored `tmp/`
  directories, and keep grading checkouts separate from resumable workspaces.
- Distinguish local behavioral tests, cached model replay, fresh model sampling, and
  fresh grading. Historical reports retain their original source and model identities.
  New model sampling for this project uses `xmcp:closeai/gpt-5.6-luna`.
