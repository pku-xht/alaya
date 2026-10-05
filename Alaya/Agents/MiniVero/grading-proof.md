## Grading (``proof`` mode)

A spec is **passed** iff exactly one of ``{prove_<S>, disprove_<S>}`` is filled, the file compiles, and ``#print axioms`` reports only the standard trio (``Classical.choice``, ``propext``, ``Quot.sound``) or none.

Per-spec failure statuses: ``unfilled``, ``overfilled``, ``sorry_leaked``, ``axiom_leaked``, ``slot_body_tainted``, ``build_error``.

Do not hide ``sorry`` via ``Classical.arbitrary`` or contradictory hypotheses. The grader reads axioms, not tactics.
