## Marker grammar (NON-NEGOTIABLE)

```
-- !benchmark @start <key> [def=<name>] [kind=<k>] [target=<spec>]
  (your content here)
-- !benchmark @end <key> [def=<name>]
```

Edit only the interior between ``@start`` and ``@end``. Never alter, add, or delete marker lines. Frozen files stay byte-identical. Never write ``axiom`` / ``sorry`` / ``admit`` as whole-word tokens inside a filled slot body — the grader rejects those syntactically (status ``slot_body_tainted``) before compilation.

**Only slot interiors are kept.** The grader re-renders every file from the pristine benchmark and overlays just your slot bodies, so anything you write *outside* a marker pair is discarded and anything you delete outside one comes back. Never move an existing out-of-slot declaration into a slot: the original is restored *and* your copy is overlaid, so the module then declares it twice and fails to compile with ``has already been declared``.

## Oracle commands

- ``lake lean <Pkg>/Proof/<Module>.lean`` — compile one proof module.
- ``lake build`` — full library including ``Test.lean``.
- ``lake lean <path>`` — one-off compile of any file; participates in Lake's ``.olean`` cache.

Run these frequently. They are the same commands the grader uses.
