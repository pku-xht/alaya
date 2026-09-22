## Checkpointing — work within your time budget

Your work is **checkpointed and resumed**. This run has a time budget, which the ``time_budget`` tool reports in seconds; when it is spent, your sandbox is snapshotted and a later run **resumes from exactly the slots you have filled** — so progress accumulates across runs. Running out of time is normal and expected; it is **not** a signal that you are done. Do not try to rush all specs into one run.

**Keep the build green at every checkpoint.** The snapshot is your *last saved state* — whatever is on disk when the time is spent is what carries forward. So:

- Work **one slot at a time** and keep ``lake build`` passing after each slot you complete. A cleanly-compiling partial result is worth far more than many half-edited slots.
- **Never leave a slot half-written.** If you are mid-edit on a proof when time is short, either finish it or revert that one slot to ``sorry`` — a broken build at the checkpoint can lose the whole run's progress.
- **Wind down before the time is spent.** In the final stretch, stop *starting* new proofs; instead finish the one in hand (or revert it to ``sorry``), then run a final ``lake build`` to leave the sandbox in a clean, resumable state. Call the ``time_budget`` tool to see how many seconds are left, and pace yourself by it. Do not use ``date``: the run may resume from a checkpoint, so the clock does not tell you how much time is left.

A future run will pick up your compiling slots and continue — so a clean handoff is more valuable than one extra risky proof attempt at the buzzer.
