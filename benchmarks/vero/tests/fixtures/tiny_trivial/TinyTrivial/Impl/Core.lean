-- !benchmark @start imports
-- !benchmark @end imports

/-!
# TinyTrivial.Impl.Core

One identity API. The pipeline replaces the marked body with `sorry` in codeproof mode.
-/

namespace TT

abbrev IdNatSig := Nat → Nat

end TT

-- !benchmark @start global_aux
-- !benchmark @end global_aux

-- !benchmark @start code_aux def=idNat
-- !benchmark @end code_aux def=idNat

def TT.idNat : TT.IdNatSig :=
-- !benchmark @start code def=idNat
  fun n => n
-- !benchmark @end code def=idNat
