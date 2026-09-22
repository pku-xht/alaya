# Questions: `ask_user`

MiniSwe and MiniVero can ask a question and wait for an answer. Set
`"ask_user": true` in the agent's JSON configuration to offer the tool. It is off by default.
The root records the setting explicitly as `true` or `false`, so later commands
rebuild the same agent. As with other configuration fields, omitting it on input
uses the default.

For example, save this as `mini-vero-questions.json`:

```json
{"family": "mini-vero", "mode": "codeproof", "ask_user": true}
```

## Question forms

One tool supports three forms, selected by the required `question_type` field:

| `question_type` | `options` | Requested reply |
| --- | --- | --- |
| `yes_no` | `[]` | `yes` or `no` |
| `multiple_choice` | At least two distinct, nonempty candidates | A JSON array of distinct option numbers, from 1; zero through all options may be selected |
| `open_ended` | `[]` | Free text |

The model calls the tool alone and includes the relevant context in `question`.
All three fields are required. Yes/no and open-ended questions require an empty
`options` array; multiple-choice questions never append an automatic custom option.

```json
{
  "question_type": "yes_no",
  "question": "Should the function preserve duplicate elements? The prose does not specify this.",
  "options": []
}
```

```json
{
  "question_type": "multiple_choice",
  "question": "Which approaches apply? The implementation compiles, but the recursive list proof remains unresolved.",
  "options": [
    "Prove a helper lemma about the recursive step.",
    "Look for a library theorem matching the current goal.",
    "Reconsider the implementation's recursive structure."
  ]
}
```

For this multiple-choice question, `[]` means none of the listed options apply;
`[1, 3]` selects two options and `[1, 2, 3]` selects all of them. An explicit `[]`
is an answer, distinct from leaving the question unanswered. It does not provide
an alternative answer or explain why the options are unsuitable; use an
open-ended question when that information is needed.

```json
{
  "question_type": "open_ended",
  "question": "What invariant should the helper lemma express? The induction step splits the list at its head.",
  "options": []
}
```

Validation checks the tool arguments, blank text and duplicate choices (ignoring
surrounding whitespace). It does not check whether a candidate is correct. The
original arguments, including `question_type`, remain in the trajectory so
studies can distinguish the question forms.

## Waiting and replying

`ask_user` produces `Directive.ask`, which uses the existing question state and
`reply` command. It runs no workspace command. A turn combining it with another
tool is a format error before any tool runs. Ordinary turn and format-error limits
still apply. Both the model context and HTML report retain the question and reply.
If the question used the last allowed model turn, continuing its reply records
`LimitsExceeded` without another model call.

```bash
alaya root --task-file /path/to/source/MINIVERO_TASK.md /path/to/source \
  --agent mini-vero-questions.json --data /path/to/run
alaya resume ROOT --model PROVIDER:MODEL --data /path/to/run --json
# A question stops resume/step with exit code 3. Use its state hash below.
alaya waiting --data /path/to/run
# For a multiple-choice question when none of the listed options apply:
alaya reply QUESTION '[]' --data /path/to/run
alaya resume REPLY --model PROVIDER:MODEL --data /path/to/run --json
```

The reply formats above guide answer collection. The generic `reply` command
records text unchanged; it does not validate, rewrite or judge the answer.
Callers collecting structured answers must enforce their form if required by
their study. Different replies to one question form separate branches with the
same workspace. Receiving an answer does not change the task's rules or imply
that the answer is correct. If no answer is available, the caller may record
that as a reply so the agent can continue independently; it should not use `[]`
as a substitute for a missing answer.

This tool supplies the interaction. Answer collection, simulation, budgets and
comparative grading remain the caller's policy.
