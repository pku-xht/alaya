---
name: git-store
description: Implement or validate Alaya's Git snapshot backend, including exact restore, legacy archive reads, and trajectory persistence.
---

Read [the storage contract](../../../docs/git-store.md) before changing `Alaya/Cas` or its trajectory integration. Keep storage semantics there rather than duplicating them here.

Use the environment, commands, and behavioral checks in the document's Validation section. Check the caller-facing contract as well as Git object identity; a successful `git fsck` alone does not prove exact workspace restoration.

For compatibility, unpack `example/trajectory.tar.gz` into a new ignored scratch directory. Inspect old states and restore their old workspace hashes before creating new snapshots. Keep original archive hashes distinct from new Git object IDs, and preserve the model cache verbatim. Do not turn a cache miss into a provider call or alter stored responses to make a replay pass.

Record commands, source revision, results, and skipped environment-dependent checks. Re-run only the checks affected by subsequent changes or unresolved failures. Keep private run data out of public test fixtures.
