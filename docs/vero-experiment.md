# Paired same-model answer pilot

`example/vero_experiment.py` runs an independent baseline, selects its latest
completed nonterminal state, elicits one question, and forks that question into
no-answer and same-model simulated-answer continuations. It uses `primepy`
codeproof, `xmcp:closeai/gpt-5.4-mini`, temperature zero, and a 1800-second ceiling.
Setup, pinned toolchains, credentials, and isolated grading are documented in
[vero-smoke.md](vero-smoke.md).

```sh
python example/vero_experiment.py baseline --output /private/NEW_RUN --vero VERO --alaya ALAYA
python example/vero_experiment.py ask      --output /private/NEW_RUN --vero VERO --alaya ALAYA
python example/vero_experiment.py simulate --output /private/NEW_RUN --vero VERO --alaya ALAYA
python example/vero_experiment.py compare  --output /private/NEW_RUN --vero VERO --alaya ALAYA
python example/verify_vero_experiment.py /private/NEW_RUN
```

`NEW_RUN` must not exist at baseline creation. It gets an empty cache and copied
binaries. The runner delivers the complete task instruction in the first request
and saves its exact text/hash. This changes delivery, not the Vero specification.

The baseline uses `mini-swe`. Question elicitation and both continuations use
`mini-ask`, which adds standalone `ask_user({"question":"..."})`. The CLI records
a question node and exits with status 3. `alaya reply QUESTION ANSWER` creates a
reply child, after which `step` or `resume` continues. The parser rejects mixed
question/action turns and empty or malformed questions. Further questions during
the two continuations receive the existing fixed no-further-help reply.

The checkpoint selection rule is fixed: choose the latest nonterminal baseline
turn, falling back to the latest before half-budget when fewer than 120 seconds
remain. The elicitation message contains the existing approximate remaining-time
notice; this change does not add time feedback. The model's early `submit` remains
terminal and is reported as an outcome, not overridden by the runner.

The simulated answer uses the same model, no tools, current visible task/source,
and the latest three turns of tool feedback. It sees neither reference solutions
nor grader results. Keep its response verbatim and label it simulated data, not
a human participant or expert answer. Provider latency is not human thinking time.

Both branches start from the same question workspace. Their equal continuation
budget is 1800 seconds minus shared-prefix, question, and simulated-answer time.
The no-answer branch is charged the same simulated wait. Branches run sequentially
because the CLI shares `DATA/work`. Grading occurs separately and does not enter
either continuation's budget or context.

The verifier checks CAS hashes, ancestry, equal budgets, unchanged question/reply
workspaces, cache responses, unedited answers, and grading leaves. It exports local
transcripts, source snapshots, official reports, and an HTML overview. Actual
transport bodies are separate optional recorder evidence; an HTML context view is
a reconstruction of a possible next request, not a saved historical request.

One question and one continuation per arm is exploratory. Different old/new
baselines can elicit different questions; this cannot identify a causal answer
effect or a separate effect of each implementation change. Report failures and
costs honestly, including unavailable provider cost fields. See the
[fresh implementation comparison](output-recovery-experiment.md).
