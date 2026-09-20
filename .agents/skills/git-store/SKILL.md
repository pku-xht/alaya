---
name: git-store
description: Implement or validate Alaya's native Git snapshot commits, checkout semantics, explicit legacy import, and trajectory integration.
---

Read [the storage contract](../../../docs/git-store.md) before changing `Alaya/Cas` or its trajectory integration. Keep storage semantics there rather than duplicating them here.

Use the environment, commands, and behavioral checks in the document's Validation section. Check the caller-facing Git semantics and host configuration restrictions as well as object integrity: a successful `git fsck` alone does not establish correct staging, detached HEAD, branch preservation, checkout behavior, or experiment isolation.

Use disposable workspace repositories when testing capture because the real index and HEAD change. Verify that ignored caches and empty directories follow Git behavior rather than asserting raw-directory equality. Keep object-format conversion and linked-worktree support outside the current contract.

For compatibility, unpack `example/trajectory.tar.gz` into a new ignored scratch data directory and run the explicit importer there. Keep original hashes distinct from the recorded import mapping and preserve the source archive, raw objects, refs, and model cache verbatim. Do not turn a cache miss into a provider call or alter stored responses to make a replay pass.

Record commands, source revision, results, and skipped environment-dependent checks. Re-run only the checks affected by subsequent changes or unresolved failures. Keep private run data out of public test fixtures.
