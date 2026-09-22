# Choice questions: `ask_user`

MiniSwe and MiniVero can ask a multiple-choice question and wait for an answer.
Set `"ask_user": true` in the agent's JSON configuration to offer the tool. It is
off by default, including when the field is absent in an older configuration.
The root records the setting, so later commands rebuild the same agent.

For example, save this as `mini-vero-questions.json`:

```json
{"family": "mini-vero", "mode": "codeproof", "ask_user": true}
```

The model calls the tool alone, with a question that includes the relevant context
and at least two distinct, nonempty candidate answers:

```json
{
  "question": "Which part should I investigate first? The implementation compiles, but the list proof remains unresolved.",
  "options": [
    "Prove a helper lemma about the recursive step.",
    "Look for a library theorem matching the current goal.",
    "Reconsider the implementation's recursive structure."
  ]
}
```

The waiting question displays these choices numbered from 1 and always appends
`OTHER: Other / custom answer, including none of these or insufficient information.`
The model does not need to supply that option. Validation checks the question's
shape, blank text and duplicate choices (ignoring surrounding whitespace); it
does not check whether a candidate is correct or whether candidates can be combined.
The original tool arguments remain in the trajectory.

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
alaya reply QUESTION 'OTHER: None of these; I need the exact failing goal.' --data /path/to/run
alaya resume REPLY --model PROVIDER:MODEL --data /path/to/run --json
```

A reply can be an option number or arbitrary text, including uncertainty or a
rejection of all candidates. `reply` records the text unchanged; it does not
validate, rewrite or judge the answer. Different replies to one question form
separate branches with the same workspace. Receiving an answer does not change
the task's rules or imply that the answer is correct. If no answer is available,
the caller may record that as a reply so the agent can continue independently.

This tool supplies the interaction. Answer collection, simulation, budgets and
comparative grading remain the caller's policy.
