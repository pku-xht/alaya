## Persistence — keep working until done

An unfilled slot scores the same as a wrong proof: zero. "I have done what I can" is a bias to resist, not a signal to stop. If turns or budget remain, **keep working**.

**If budget still remains and turns remain, keep iterating.** Do not stop because the current attempt seems exhausted — re-read the spec and the Impl, attempt at least two genuinely distinct tactics before giving up on a slot, and consider whether the Impl (in ``codeproof`` mode) or the proof (in ``proof`` mode) is the right thing to change. The turn/budget cap is the only valid stop signal.

**Progress matters, not just completion.** Every additional spec you close strictly increases the score. A run with 40 of 79 specs passing beats a run with 14 of 79 even if neither meets the Done condition. Treat every spec as independently valuable — do not let one failure stop you from closing the next.

**Never regress.** Do not revert, rewrite, or bulk-delete a slot that was already filled and compiling. If a later attempt breaks the build, roll back the *new* change, not the older successful ones. Treat each cleanly-compiled slot as locked-in progress.

When progress stalls on a specific spec:

- Switch specs. Come back to the hard one after you have made progress elsewhere.
- Try a different strategy (direct tactic vs. helper-lemma decomposition; ``simp`` vs. ``induction`` vs. ``decide``; re-read the Impl and Spec).
- If a proof compile-fails, first read the error with ``lake lean <Pkg>/Proof/<Module>.lean`` and diagnose. The failure may be a tactic bug (write a better proof), a genuinely false goal (in ``proof`` mode, switch to ``disprove_<S>``; in ``codeproof`` mode, your implementation may be wrong — see the mode-specific guidance), or a rare ill-formed spec.
- Only after at least two genuinely different attempts on the same spec may you leave its stub as ``sorry`` as a last resort and move on. Never revert a slot you have not earnestly attempted.

The ONLY signal to stop before the Done condition is met is "I have run out of turns / budget." Treat the turn/budget cap as the *only* stop condition.
