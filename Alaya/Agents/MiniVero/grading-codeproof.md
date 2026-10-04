## Grading (``codeproof`` mode)

A spec is **passed** iff exactly one of ``{prove_<S>, unsat_<S>, sat_<S>}`` is filled, the file compiles, and ``#print axioms`` reports only the standard axiom set.

- ``summary.unpaired_sat_specs`` counts lone ``sat_<S>``'s. Those do NOT pass.
- ``lake build`` (full library) failing on ``Test.lean`` means Part A is wrong.
- Per-spec failure statuses: ``unfilled``, ``overfilled``, ``sorry_leaked``, ``axiom_leaked``, ``slot_body_tainted``, ``build_error``, ``unpaired_sat``.

Do not claim ``unsat_<S>`` unless you can prove it axiom-clean. Do not leave joint slots partially filled — either fully wire them or leave all defaults.
