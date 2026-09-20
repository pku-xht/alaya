# Alaya project notes

- Use the Lean version in `lean-toolchain`. Build with `lake build`; run tests with `lake exe tests` (an optional substring selects a subset).
- The CLI and snapshot backend require Unix tools. On Windows, run them in WSL/Linux; run filesystem tests on a Linux filesystem so executable bits and symlinks have their intended meaning.
- `Alaya/Cas/Store.lean` owns Git objects and legacy reads; `Alaya/Cas/Workspace.lean` owns snapshot capture and restore. The contract and compatibility limits are in `docs/git-store.md`; use `.agents/skills/git-store/SKILL.md` when changing this backend.
- Keep the snapshot repository independent of the captured project's Git metadata. Preserve file bytes, symlinks, executable bits, and explicit empty directories; do not apply project filters or ignore files by default.
- Preserve `example/trajectory.tar.gz`. Unpack compatibility tests into ignored scratch space such as `tmp/`; never rewrite archived states or model cache entries to obtain a passing replay.
- Keep model sampling, cached responses, actual tool execution, and grading separate. A storage change alone does not authorize fresh API sampling. Evaluation checkouts remain separate from resumable workspaces.
- Validate at the affected scope and report actual results. Storage tests and archive reads do not establish real-model benchmark performance.
