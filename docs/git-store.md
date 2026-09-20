# Git snapshot storage

Alaya creates a directory snapshot and restores one by its hash. `Alaya.Cas.Store` keeps that
API, but new objects live in a separate bare Git repository using SHA-256 object IDs. A
snapshot is a native Git **tree**, not a commit or a branch in the captured project.

```lean
let store ← Cas.Store.create storeDirectory
let snapshot ← store.snapshot projectDirectory
store.setRef "checkpoint" snapshot
store.restore snapshot checkoutDirectory
```

Pin a hash with `setRef` while it must survive `gc`. The trajectory layer pins recorded states
and their workspace/evidence trees itself. Neither operation runs Git against the captured
project's repository. If a snapshot includes `.git`, restoring it reproduces those files too,
just as it restores the rest of the destination.

## Capturing and restoring files

The backend writes file contents with `git hash-object --no-filters` and directory entries
with `git mktree`. It reads object bytes and reconstructs the destination directly, without
using `git checkout`, the project's index, hooks, clean/smudge filters, or line-ending
conversion. Its repository is under the Alaya data store, outside the captured directory.

Default capture includes all directory entries, including `.git`, files matched by
`.gitignore`, and explicit empty directories. `CaptureConfig.ignore` can opt out selected
paths. Regular files preserve their bytes, executable files preserve the executable bit, and
symbolic links preserve the link target instead of reading through it. `symlinks := .reject`
rejects links; `execBits := false` disables executable-bit capture. Snapshots do not preserve
timestamps, ownership, ACLs, hard-link identity, or all POSIX permission bits.
Capture assumes that no other process changes the source while it is being walked; it is not
an atomic filesystem snapshot of concurrent writes.

Restoring first reads the requested tree into a staging directory, then replaces the
destination contents, including removing paths left by another branch. A missing or unreadable
object fails before replacing the original destination. `MaterializeConfig.onExisting := .error`
refuses a nonempty destination. Capture and restore reject paths overlapping the store, so the store cannot
capture its own writes or be overwritten by a restore. A failed Git operation or unreadable
object is reported as a storage error. Do not concurrently mutate the destination during
restore; its replacement is a directory operation, not a transaction for other readers/writers.
An interrupted process can leave staging directories behind; restore is not crash-atomic.

The old stat cache, parallel hashing configuration, checkout bookkeeping, incremental restore,
copy-on-write clone mode, and their metrics are removed. Files are read when captured and
checkouts are rebuilt when restored. This favors the two required operations over retaining a
second implementation of Git's change-detection machinery. Unchanged content still deduplicates
in Git's object database; this is not a claim that unchanged files avoid being read, or that
large-workspace performance improves.
This implementation invokes Git for individual files and trees; process startup and complete
checkout reconstruction can cost more than the removed cache or incremental restore.

`diff`, `readPath`, `writePath`, `removePath`, and `listPaths` remain thin tree operations for
trajectory notices and reports. They use the same objects and do not mutate existing snapshots.
Callers using removed `CaptureConfig`/`MaterializeConfig` fields or metric/clone APIs need to
update their source; `snapshot` and `restore` keep their core interface.

## Existing archives and object identity

Old stores address raw bytes by SHA-256 and represent trees as JSON. New stores use Git's
SHA-256 object format, whose hash includes the object type and length. An identical file or
state JSON therefore generally has a different ID when newly stored by Git.

Legacy `blobs/` and named refs remain readable. Existing state JSON is not rewritten, its hash
does not change, and its old workspace hash still restores through the compatibility reader.
When a new tree needs a legacy object, the backend imports it into Git as needed. New snapshots
and continuation states use Git IDs; an old replay's final state hash is not expected to remain
identical merely because its files and messages match the archive.

When unpacking the bundled macOS-created `example/trajectory.tar.gz` on Linux, exclude
AppleDouble `._*` entries and `__MACOSX` metadata. These are archive metadata, not Alaya objects
or refs; extracting them into the store would make strict legacy-ref validation reject them.

The model cache in `cache/v1` is separate and unchanged. Storage IDs do not participate in its
request key. A backend migration does not change the model, prompts, tool schema, or cached
response format. A replay can still miss if the actual tool output changes the next request;
cache-only callers must stop at that miss rather than sample a provider.

Collection applies to the new Git object database. Legacy raw objects are deliberately left
in place so old references remain usable; removing a trajectory may therefore leave legacy
disk usage behind. Keep the original archive as the compatibility source rather than treating
collection as an archive conversion tool.
Serialize updates to the same named reference, and run collection only while no writer is
using the same store. Concurrent writers to mutable aliases are not supported.

Native refs live at `store/git/refs/alaya/<UTF8-name-as-hex>/<logical-hash>` and point to the
native Git object ID. The logical hash component preserves an old state's identity when its
bytes are imported into Git. Legacy `store/refs/<name>` files are enumerated too; a successful
`setRef` installs the Git ref before removing that name's old file. Before collection, live
legacy refs are pinned in Git. Fresh stores need no custom ref files, stat cache, or checkout
records. See [the trajectory layout](trajectory-schema.md#5-on-disk) for the relationship
between state refs and workspace refs.
These ref paths are a Git namespace; Git may pack them into `packed-refs`. Enumerate them with
`git for-each-ref` rather than relying on loose ref files.

## Validation

Use the pinned Lean toolchain on a Linux filesystem and Git with SHA-256 repository support.
Windows-mounted filesystems are not the reference environment for executable-bit and symlink
tests.

```sh
lake build
lake exe tests cas
lake exe tests
```

The relevant checks cover native Git object identity, raw binary round trips, executable bits,
links and empty directories, project Git isolation, reopening, sibling restores, legacy reads,
refs and collection, and failures on invalid or missing objects. The full suite also checks
trajectory behavior and the separate model cache. Run Docker suites serially: existing cleanup
tests share image names. These commands describe the validation procedure; execution results
belong in the PR evidence, not in a permanent claim that every environment passed.
