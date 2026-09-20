# Alaya project notes

- Use the Lean version in `lean-toolchain`. Build with `lake build`; run tests with `lake exe tests` (an optional substring selects a subset).
- The CLI and snapshot backend require Unix tools. On Windows, run them in WSL/Linux; run filesystem tests on a Linux filesystem so executable bits and symlinks have their intended meaning.
- New model sampling uses `xmcp:closeai/gpt-5.6-luna` with the configured XMCP API. Keep historical reports, recorded model identities, and cache-only replay tied to their original model; start a fresh run when changing models.
- `Alaya/Cas/Store.lean` owns Git objects and refs; `Alaya/Cas/Workspace.lean` owns snapshot commits and checkout. The contract and compatibility limits are in `docs/git-store.md`; use `.agents/skills/git-store/SKILL.md` when changing this backend.
- Snapshots use native Git commits and the workspace's actual index. Capture may initialize a repository and detach HEAD; preserve existing branch refs and commit ancestry. Ignore rules, supported attributes, empty directories, and submodules follow the documented Git semantics rather than a whole-directory backup contract.
- Keep a self-contained workspace repository usable inside Docker. Reject unsupported linked worktrees and object-format mismatches explicitly; do not silently convert project history or overwrite `.git` from a snapshot.
- Preserve `example/trajectory.tar.gz`. Legacy import is explicit and separate from normal storage operations. Use an isolated destination and never rewrite archived states or model cache entries to obtain a passing import or replay.
- Keep model sampling, cached responses, actual tool execution, and grading separate. A storage change alone does not authorize fresh API sampling. Evaluation checkouts remain separate from resumable workspaces.
- Validate at the affected scope and report actual results. Storage tests and archive reads do not establish real-model benchmark performance.
