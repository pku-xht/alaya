import Alaya.Base.Sha256

namespace Alaya.Base

/-- A SHA-256 digest, held as lowercase hex: the name of an entry of a log, which is the hash
of its event and of the entry before it, and the form of a workspace snapshot's identifier. -/
structure Hash where
  hex : String
  deriving BEq, Hashable, Repr, Inhabited

namespace Hash

/-- A well-formed lowercase SHA-256 digest. Anything else must be rejected before it is joined
onto a directory, where a hostile "digest" like `../../x` would leave it. -/
def valid (hex : String) : Bool :=
  hex.length == 64 && hex.all fun c => c.isDigit || (97 <= c.toNat && c.toNat <= 102)

def ofBytes (bytes : ByteArray) : Hash := ⟨Sha256.sumHex bytes⟩

end Hash

/-- The identifier of a workspace snapshot (`Alaya.Runtime.Workspaces`): a digest like any other, named
apart so that a signature says it is a workspace it speaks of. -/
abbrev Snapshot := Hash

end Alaya.Base
