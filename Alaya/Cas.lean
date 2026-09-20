import Alaya.Cas.Core
import Alaya.Cas.Sha256
import Alaya.Cas.Store
import Alaya.Cas.Workspace

/-!
A Git-backed content-addressed store with a compatibility reader for legacy objects.

- `Cas.Store.create` opens a separate bare SHA-256 Git repository; `putBytes`/`getBytes`
  store and read raw blobs without applying the captured project's Git filters.
- `Store.snapshot` captures a directory as a native Git tree and returns its hash.
  `Store.materialize`/`restore` rebuild its contents, including symlinks, executable
  bits, and empty directories. Capture does not use the project's index or ignore rules.
- `Store.readPath`/`writePath`/`removePath`/`listPaths` edit snapshots purely — cheap
  branching without touching the working directory.
- `Store.setRef` pins objects by name; `Store.gc` collects unpinned Git objects.
  Legacy raw objects remain readable at their original hashes and are not collected.

See `docs/git-store.md` for the storage contract and migration limits.
-/
