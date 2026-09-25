import TinyTrivial.Harness

/-!
# TinyTrivial.Spec.Core — DO NOT MODIFY.

The only specification says that the bundled API is the identity function on natural numbers.
-/

def spec_idNat (impl : RepoImpl) : Prop :=
  ∀ n : Nat, impl.tiny.idNat n = n
