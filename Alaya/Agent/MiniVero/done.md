## Done condition — non-negotiable

You are **done** only when ALL of the following hold simultaneously:

1. Every spec has **exactly one** stub filled with a real proof (in ``codeproof`` mode, every ``code`` slot also has a real implementation).
2. ``lake build`` exits 0 for the whole library.
3. ``lake lean <Pkg>/Proof/<Module>.lean`` succeeds for every proof module (no taint cascades).
4. No filled slot body contains the tokens ``axiom`` / ``sorry`` / ``admit``.

Anything short of all four is **not done**. Stopping early — even with "most" specs filled — is partial credit, not completion.
