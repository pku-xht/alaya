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

| `question_type` | `options` | Answer control and accepted reply |
| --- | --- | --- |
| `yes_no` | `[]` | Two radio buttons; exactly `yes` or `no` |
| `multiple_choice` | At least two distinct, nonempty candidates | Independent checkboxes; a JSON array of distinct option numbers, from 1; zero through all options may be selected |
| `open_ended` | `[]` | A text area; free text |

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
studies can distinguish the question forms. The waiting state also records the
original question text, its type and its options as separate fields. Answer
collectors do not need to parse options out of formatted text.

## Answer in the browser

From a Linux/WSL checkout, start the local answer page with Python 3.10+ (standard
library only) and a built Alaya CLI:

```bash
lake build
python3 example/answer_questions.py --alaya .lake/build/bin/alaya --data /path/to/run
```

Open the printed `http://127.0.0.1:PORT` address. The page shows the questions
waiting in that data directory:

- For yes/no, select one of the two buttons before submitting.
- For multiple choice, check any number of options. Leaving every checkbox
  unchecked and clicking **Submit answer** records `[]`; it does not leave the
  question unanswered.
- For open-ended questions, type a nonblank answer in the text area.

Selections are not recorded until **Submit answer** is clicked. A successful
submission saves a reply in the existing trajectory and removes the question
from the waiting list. **Refresh** loads newly waiting questions. An error keeps
the current selection so it can be corrected or retried. A stale page cannot
accidentally submit a second answer to a question that is no longer waiting.

The server listens only on the local loopback address and does not start a model
run. Continue from the recorded reply with the normal `resume` command. The CLI
remains available for scripted answer collection and deliberate reply branches.

## Waiting and replying

`ask_user` produces `Directive.ask`, which uses the existing question state and
`reply` command. It runs no workspace command. A turn combining it with another
tool is a format error before any tool runs. Ordinary turn and format-error limits
still apply. Both the model context and HTML report retain the question and reply.
If the question used the last allowed model turn, continuing its reply records
`LimitsExceeded` without another model call.

With `--time-budget`, the recorded model-step time carries through a reply.
Time spent waiting for a person is not a model step and does not consume that
budget. Pass the intended total budget again when resuming; if it is already
spent, Alaya stops without another model call.

```bash
alaya root --task-file /path/to/source/MINIVERO_TASK.md /path/to/source \
  --agent mini-vero-questions.json --data /path/to/run
alaya resume ROOT --model PROVIDER:MODEL --data /path/to/run --json
# A question stops resume/step with exit code 3. Use its state hash below.
alaya waiting --data /path/to/run
# For a multiple-choice question when none of the listed options apply:
alaya reply --data /path/to/run -- QUESTION '[]'
alaya resume REPLY --model PROVIDER:MODEL --data /path/to/run --json
```

Place reply text after `--` so an open-ended answer such as `--data` or `-m` is
recorded as text rather than parsed as an option. Keep CLI options before `--`.

The `reply` command enforces the recorded answer form before writing any child
state. Yes/no rejects every value except `yes` and `no`. Multiple choice rejects
non-array answers, non-integer or out-of-range numbers, and duplicate numbers.
Open-ended replies accept text. Invalid answers leave the question waiting;
valid answers are recorded unchanged. The browser and command line use this same
underlying answer-form validation, including after the agent has been reconstructed
from its recorded configuration. The page additionally requires nonblank open-ended
text before enabling submission; CLI/API collectors can record empty open text.

Different valid CLI replies to one question form separate branches with the
same workspace. Receiving an answer does not change the task's rules or imply
that the answer is correct. `[]` means that none of the listed candidates apply;
it is not a substitute for an unavailable answer.

This tool supplies the interaction. Answer collection, simulation, budgets and
comparative grading remain the caller's policy.

## Experimental scope

This change adds a question-and-answer tool. Offering it does not establish that
the model will seek help spontaneously, choose useful questions, or benefit from
the answers.

Two exploratory real-model runs on 2026-09-23, one on `primepy` and one on
`toposort`, both used `xmcp:closeai/gpt-5.6-luna` with `ask_user` enabled and made
zero `ask_user` calls. Two runs are insufficient for a statistical conclusion
about spontaneous help-seeking or the tool's effectiveness.

An explicitly prompted `ask_user` run is an integration test and must be reported
separately from spontaneous help-seeking experiments. Its success would not
establish a help-seeking policy or an improvement in task outcomes. Further
experiments are needed to study when models seek help, how they choose question
forms, answer quality, and the effect of answers on task outcomes.
