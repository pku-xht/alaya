# Git snapshot storage

Alaya snapshots a workspace as a native Git **commit** and restores it by checking out that
commit. `Alaya.Cas.Store` remains the API name, but Git owns the working index, objects,
commit parents, and checkout behavior. A snapshot is a version of a Git project, not a backup
of every filesystem entry or of the project's `.git` directory.

```lean
let store ← Cas.Store.create storeDirectory
let snapshot ← store.snapshot projectDirectory
store.setRef "checkpoint" snapshot
store.restore snapshot checkoutDirectory
```

The trajectory layer records the commit ID as `workspace` and pins the commits it needs.
A separately used snapshot must also be pinned while it must survive store collection.

## Creating a snapshot

For a directory without its own `.git`, Alaya initializes a repository. An existing normal
repository with a `.git` directory is used directly. Capture runs `git add -A` against its
real working index and records the resulting tree in a snapshot commit whose parent is the
current HEAD. If the tree already matches HEAD, capture reuses that commit.

This has visible effects in the source directory: new eligible files are staged, deletions
and modifications are staged, and any previous partial staging selection is replaced by the
whole working-tree selection. When a new snapshot commit is created, source HEAD becomes
detached at it. Existing branch refs are not advanced or rewritten; existing commits and their
parent history remain available. Capture is a write operation on the project's index and HEAD,
not a read-only inspection of its files.

Git decides what belongs in the tree. `.gitignore` applies to untracked files; tracked files
remain tracked even if an ignore rule matches them. Empty directories are not represented.
Built-in `text`, `eol`, and `working-tree-encoding` attributes follow Git semantics rather
than a separate raw-byte backup contract. Regular file contents, executable flags, and symlinks
are represented as Git represents them. Timestamps, ownership, ACLs, and arbitrary permission
bits are not snapshot data.

A linked worktree or other repository whose `.git` is a file is currently rejected. Submodules
and embedded repositories are represented only as Git links; Alaya does not recursively
snapshot or restore their working directories. Do not assume that a gitlink records dirty
files inside a submodule.

### Git configuration on the host

Snapshot operations run Git on the host even when model tools run in Docker. Alaya starts
these subprocesses with a restricted environment, ignores global and system Git configuration,
and permits only the local `file` transport. Workspace commands disable hooks, fsmonitor,
commit signing, and recursive submodule operations.

Before staging or checkout, Alaya inspects the effective repository configuration, including
local includes. Nonempty external `filter.*.clean`, `filter.*.smudge`, `filter.*.process`,
`remote.*.uploadpack`, `remote.*.vcs`, `core.alternateRefsCommand`, and
`uploadpack.packObjectsHook` settings are rejected. Configuration that would redirect a fetch
from the snapshot store's local path is also rejected. The error identifies the setting's key,
without printing its value. External filters are therefore unsupported through this storage
path; the built-in attributes above remain available.

## Restoring a snapshot

Restore fetches the requested commit and its reachable history from the store into a normal
workspace repository, then runs `git checkout --detach --force` and `git clean -fd`. The
workspace has its own `.git` directory, so Git can run inside a Docker container without
following an absolute `.git` pointer into the host filesystem. Restore does not unpack an
older copy of `.git` over the repository or erase existing commit history.

Tracked files and the index are reset to the requested version. Nonignored untracked files
are cleaned according to Git's rules; ignored build caches normally remain. Conflicts with
tracked paths are resolved by the forced checkout, and Git's protections for nested
repositories still apply. This is intentionally not an exact filesystem-directory replacement.
For a completely empty grading environment, use a separate fresh checkout rather than relying
on a switch of versions to remove ignored data.

Capture and restore reject overlap with the storage directory. Git errors are reported to
the caller. Checkout is not a crash-atomic transaction: a failure can leave a partially updated
index or workspace. Alaya does not retain a complete old-directory backup or promise rollback
of every file on failure. Serialize writes to each store and workspace, including collection;
there is no Alaya transaction spanning concurrent Git operations.

Checkout changes the repository in place rather than replacing the workspace directory inode.
A Docker container already bound to that directory can continue to use it after a version
switch, including repeated `stepOnce` or `resume` calls on the same runtime.

## Object format and history

New stores default to a bare SHA-1 Git repository, matching ordinary existing Git projects.
A bare SHA-256 Git store is also supported, but the source and destination workspace
repositories must use its object format. A mismatch is rejected explicitly; Alaya
does not rewrite an existing project's history to convert between SHA-1 and SHA-256. Object
IDs are consequently 40 or 64 hexadecimal characters according to the repository format.

State JSON is stored as a Git blob. Workspace and evaluation-evidence snapshots refer to Git
commits, which in turn reference their tree and parents. Trajectory parentage and Git commit
parentage serve different purposes: trajectory parents order model/tool events, while Git
parents retain file-version history.

Named refs keep recorded states and required workspace commits reachable. Git collection
follows commit parents as well as trees, so removing a trajectory branch does not remove a
commit that remains an ancestor of a surviving snapshot. Git may pack refs and objects; use
Git commands to enumerate them instead of relying on loose files.

Restoring a state selects its tracked files and model log; it does not hide Git history already
present in the workspace repository. After reusing `D/work` for a sibling and returning to an
older state, `git log --all` can still expose that sibling's commits. Ignored files can also
remain. A fork in a reused workspace therefore does not provide knowledge isolation. Experiment
arms that require it must use independent workspace repositories and data directories, without
copying sibling history into them.

This design delegates change detection to the native index. Git may conservatively reread
files when timestamps are ambiguous. It does not promise zero rereads on an unchanged capture,
or a particular performance improvement. Measure capture and checkout separately, recording
file counts, total bytes, cache state, and the changed-file set.

## Explicit legacy import

The earlier raw-SHA-256 store and JSON directory trees are not transparently migrated during
ordinary snapshot, read, or checkout operations. Unpack a copy of an archive into a new data
directory, preserving the original, then run the explicit importer:

```sh
alaya import-legacy --data EXTRACTED_DATA
```

No agent or model is required. The command validates the legacy objects and creates new Git
workspace commits and state blobs in the extracted data directory. It remaps trajectory
parents and workspace/evidence references, preserving recorded events. `legacy-import.json`
records the old-to-new state mapping. Original raw blobs, legacy refs, and model cache files
are retained unchanged; repeated import is stable. These new identities must not be presented
as the original archive's hashes or substituted into a historical report.

Legacy trees containing `.git` are rejected explicitly: the importer does not invent commit
history from a filesystem copy of Git metadata. Import support is not a promise to preserve
filesystem details that native Git does not track. Previously imported workspace objects are
reused through their retained mapping; this is not a repeated integrity audit of every raw
source object. Reading an original raw object through the legacy reader verifies its SHA-256.

The intermediate Git-tree snapshot format used by earlier revisions of this change is a
separate compatibility case. It is not the raw archive format accepted by `import-legacy`.
Current checkout requires a commit, so those tree-valued workspace states are not migrated
automatically. Inspect existing intermediate-format scratch runs with their original binary;
start new native-commit runs in a fresh data directory. Opening an existing SHA-256 Git store
only establishes object-format support, not compatibility with every state previously stored
in it.

When unpacking the bundled macOS-created `example/trajectory.tar.gz` on Linux, exclude
AppleDouble `._*` entries and `__MACOSX` metadata. These are archive metadata, not Alaya objects
or refs. Do not rewrite the archive or cached model responses to obtain a successful import
or replay.

The model cache in `cache/v1` remains separate from snapshot storage. Storage alone does not
change the model, task specification, tool schema, or response-cache format. Recorded tool
output may expose Git state and thereby change a later model request; cache-only callers must
stop on a cache miss rather than sample a provider. Keep archive inspection, cached responses,
actual tool execution, new model sampling, and grading distinct.

## Validation

Use the pinned Lean toolchain and Git on a Linux filesystem. Windows-mounted filesystems are
not the reference environment for executable-bit and symlink tests.

```sh
lake build
lake exe tests cas
lake exe tests
```

Check native commit identity, parent preservation, reuse of an unchanged HEAD, detached HEAD
and unchanged branch refs, ordinary ignore/attribute behavior, and reopening the store. Verify
that a restored repository has self-contained Git metadata and that checkout restores tracked
content while handling untracked and ignored files according to the documented Git commands.
Cover object-format mismatch, unsupported linked worktrees, submodule boundaries, explicit
legacy import, rejected external configuration, ref collection with commit ancestry, and
same-runtime Docker continuations. Check tracked-file restoration separately from visibility
of retained Git history.

The Docker case that runs Git inside the container requires an explicitly supplied local image
containing Git, for example:

```sh
ALAYA_TEST_GIT_IMAGE=node:22-bookworm lake exe tests
```

That case skips when the variable is unset or the local image is unavailable or lacks Git.
It does not build or pull an image to install Git.

Run Docker suites serially because cleanup tests share image names. Validation reports must
name their source revision and actual commands, distinguish simulated models from real API
sampling, and report failures and skipped environment-dependent checks. The commands above
are a procedure, not a claim that every environment or benchmark passed.
