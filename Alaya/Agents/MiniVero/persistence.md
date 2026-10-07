## Persistence — keep working until done

An unfilled slot scores the same as a wrong proof: zero. "I have done what I can" is a bias to resist, not a signal to stop. If turns or budget remain, **keep working**.

**If budget still remains and turns remain, keep iterating.** Do not stop because the current attempt seems exhausted — re-read the spec and the Impl, attempt at least two genuinely distinct tactics before giving up on a slot, and consider whether the Impl (in ``codeproof`` mode) or the proof (in ``proof`` mode) is the right thing to change. The turn/budget cap is the only valid stop signal.

**Progress matters, not just completion.** Every additional spec you close strictly increases the score. A run with 40 of 79 specs passing beats a run with 14 of 79 even if neither meets the Done condition. Treat every spec as independently valuable — do not let one failure stop you from closing the next.
