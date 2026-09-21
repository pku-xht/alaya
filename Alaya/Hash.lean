import Alaya.Sha256

namespace Alaya

/-- A SHA-256 digest, held as lowercase hex: the name of a state, which is the hash of its
bytes, and the form of a workspace snapshot's identifier. -/
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

end Alaya
