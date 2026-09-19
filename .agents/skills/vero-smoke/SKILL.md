---
name: vero-smoke
description: Run and inspect fresh Alaya smoke tests or paired ask_user pilots on the real Vero primepy benchmark, with isolated Lean execution and official grading.
---

Read [the verified setup and result](../../../docs/vero-smoke.md) before running this path. Use `example/vero_smoke.py` and `example/Dockerfile.vero`; keep setup details and commands in that document.

For task delivery or tool-output recovery changes, read [the recovery contract](../../../docs/output-recovery.md). New runs include the full specification in the opening request; verify the recorded request rather than assuming a later file read delivered it. When comparing with an isolated older implementation, label an instruction-deficient control and keep the existing model, budgets, time feedback, submission, and answer policies matched.

Choose this flow when the user wants a small real model run or to verify the Vero connection. A six-turn smoke test is not a complete solve attempt or an estimate of human-answer usefulness. Keep model sampling, compilation, specification scores, and human-intervention evidence distinct.

For a time-bounded baseline and same-question answer comparison, read [the experiment procedure](../../../docs/vero-experiment.md) and use `example/vero_experiment.py`, followed by `example/verify_vero_experiment.py`. Keep the two arms' budgets and solver policy matched; record early submissions as outcomes. Label researcher-elicited questions and same-model simulated answers explicitly. Preserve answers verbatim, keep reference/grading data out of answer context, and never treat simulated API latency as human thinking time. One continuation per arm is a pilot, not evidence of statistical significance.

Keep the upstream Vero reference repository outside the agent container. Start a new output directory and cache for a new sample; evaluate a separate copy and preserve evaluation states as leaves. Report the actual model route, turns, elapsed time, usage, stop reason, and grader result. Use the installed provider's current model list rather than inferring its routing prefix from the model's marketing name.
