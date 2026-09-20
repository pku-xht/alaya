import Alaya.Cas.Core
import Alaya.Cas.Sha256
import Alaya.Cas.Store
import Alaya.Cas.Workspace

/-!
A thin Git-backed store for recorded states and workspace commits.

- `Cas.Store.create` opens a bare Git store; new stores use SHA-1, while existing SHA-256
  Git stores retain their format. Project and store formats must match.
- `Store.snapshot` stages a workspace through its own real Git index and returns a native
  commit ID. New snapshot commits retain HEAD as parent and detach HEAD without advancing
  the original branch. Ignore rules, supported attributes, and empty directories follow Git semantics.
- `Store.materialize`/`restore` fetch and check out a commit in a normal repository. Git
  metadata and history are retained, and ignored caches normally remain in the workspace.
- `Store.setRef` pins objects by name; `Store.gc` delegates reachability to Git, including
  surviving commit ancestry. Legacy raw stores require a separate explicit import.

See `docs/git-store.md` for the storage contract and migration limits.
-/
