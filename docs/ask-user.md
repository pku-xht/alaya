# Questions: `ask_user`

MiniSwe and MiniVero can ask a question and wait for an answer. The tool is off by default;
naming it in the agent's `tools` at `root` offers it, and the root records the list, so later
commands rebuild the same agent. The list replaces the default one, so it names the default
tools too: `bash` and `submit`, and for MiniVero `time_budget`.

For example, `--agent mini-swe --set 'agent.tools=["bash","submit","ask_user"]'`, or
`--agent mini-vero --set agent.mode=codeproof --set 'agent.tools=["bash","submit","time_budget","ask_user"]'`.

## Question forms

One tool supports three forms, selected by the required `question_type` field:

| `question_type` | `options` | Answer control and accepted reply |
| --- | --- | --- |
| `yes_no` | `[]` | Two radio buttons; exactly `yes` or `no` |
| `single_choice` | At least two distinct, nonempty candidates | Radio buttons; exactly one candidate, or the system-provided **None of the above** |
| `open_ended` | `[]` | A text area; free text |

Earlier experimental `multiple_choice` runs are not supported. Start a new run
in a fresh data directory when switching from that format.

The model calls the tool alone and includes the relevant context in `question`.
All three fields are required. Yes/no and open-ended questions require an empty
`options` array. For single-choice questions, the model must provide only the actual
candidate answers and must not offer **None of the above**: every choice has that answer
already, the answer interface appends it, and a call that lists it as a candidate is a format
error like any other malformed call.
No free-text custom-answer option is added.

```json
{
  "question_type": "yes_no",
  "question": "Should the function preserve duplicate elements? The prose does not specify this.",
  "options": []
}
```

```json
{
  "question_type": "single_choice",
  "question": "Which approach should be tried next? The implementation compiles, but the recursive list proof remains unresolved.",
  "options": [
    "Prove a helper lemma about the recursive step.",
    "Look for a library theorem matching the current goal.",
    "Reconsider the implementation's recursive structure."
  ]
}
```

For this single-choice question, reply `1`, `2`, or `3` to choose exactly one
model-provided candidate; the model is returned that number. The answer interface also
offers **None of the above**, which returns the string `none_of_above`: the person has judged
that none of the candidates is correct. This differs from **Unable to answer**,
which reports that the person cannot answer. Leaving every radio button unselected
is not an answer and cannot be submitted. Use an open-ended question when an
alternative answer or an explanation is needed.

```json
{
  "question_type": "open_ended",
  "question": "What invariant should the helper lemma express? The induction step splits the list at its head.",
  "options": []
}
```

Validation checks the tool arguments, blank text, duplicate choices (ignoring
surrounding whitespace) and a candidate that is the reserved answer. It does not check whether
a candidate is correct. The
original arguments, including `question_type`, remain in the trajectory so
studies can distinguish the question forms. The waiting state also records the
question as its text and its form, a choice's candidates within the form. Answer
collectors do not need to parse options out of formatted text.

## Answer in the browser

From a Linux/WSL checkout, start the local answer page with Python 3.10+ (standard
library only) and a built Alaya CLI:

```bash
lake build
python3 example/answer_questions.py --alaya .lake/build/bin/alaya --data /path/to/run
```

The default address is `http://127.0.0.1:8765/`. Use `--port PORT` to choose another
fixed port, for example when running a second answer server. If the chosen port
is occupied, startup fails instead of switching ports. `--port 0` explicitly
chooses a temporary free port; that address may change on restart.

Open the printed address. The page shows the questions waiting in that data directory:

- For yes/no, select one of the two buttons before submitting.
- For single choice, select exactly one candidate or **None of the above** before
  submitting. Selecting a different answer replaces the previous selection.
- For open-ended questions, type a nonblank answer in the text area.
- For every supported question type, **Unable to answer** records that no answer was available.
  It does not select `no` or **None of the above**, or send an empty text answer.

The current question and answer controls are shown by default. **Full conversation**
expands the original task, recorded messages, tool calls, tool results and earlier
human replies on this branch, through the question. The task appears within the
starting instructions, without a separate task panel. The conversation does not
include sibling branches, later answers or evaluations.
This is the recorded history, rather than a newly generated summary or only the
model's compressed context. The model should still include the background needed
to understand its question.

**Project files** browses the question state's workspace snapshot, including
hidden files and directories. It is read-only and does not follow subsequent
workspace edits. UTF-8 files up to 1 MiB are displayed in full; binary files,
larger files, symbolic links and special files show an explicit preview limitation.
Links are never followed. Paths containing backslashes or colons cannot be opened
in this portable browser. Browsing reads snapshot metadata and requested files;
it never checks out over the agent's live workspace.

Selections are not recorded until **Submit answer** is clicked. A successful
submission saves a reply in the existing trajectory and removes the question
from the waiting list. The page listens for new questions automatically; there
is no manual refresh control. Newly observed questions are appended, while
existing questions keep their position, unsubmitted answers, focus, and expanded
context. The same branch waits for a reply before continuing to its next question.
An error keeps the current selection so it can be corrected or resubmitted. A stale page cannot
accidentally submit a second answer to a question that is no longer waiting.
Opening history, browsing files, or retrying failed reads also preserves input.

The connection status shows whether updates are available. Disconnections are
retried automatically, including after the local server restarts on the same
port for the same data directory, without reloading the page or clearing an
unfinished answer. Reuse the default port or the same explicit `--port` value
when restarting; the page cannot discover a different port. An unavailable update source
does not clear the existing questions. Answer submissions are never automatically
retried. The server sends authenticated events at `/api/events`, checks for
waiting-state changes once per second while clients are listening, and shares
that check across listeners. It does not sample a model.

The server listens only on the local loopback address and does not start a model
run. Continue from the recorded reply with the normal `resume` command. The CLI
remains available for scripted answer collection and deliberate reply branches.

## Waiting and replying

`ask_user` produces `Effect.ask`, whose answer is a `Reply` (`docs/agent-api.md` §2); the step
stops at it, and the `reply` command answers it. It runs no workspace command. A response combining it with another
tool is a format error before any tool runs. Ordinary step and format-error limits
still apply. Both the model context and HTML report retain the question and reply.
If the question used the last allowed model turn, continuing its reply records
`LimitsExceeded` without another model call.

With `--time-budget`, the recorded model-step time carries through a reply.
Time spent waiting for a person is not a model step and does not consume that
budget. Pass the intended total budget again when resuming; if it is already
spent, Alaya stops without another model call.

```bash
alaya root --task-file /path/to/source/MINIVERO_TASK.md /path/to/source \
  --agent mini-vero --set agent.mode=codeproof --set 'agent.tools=["bash","submit","time_budget","ask_user"]' --model MODEL --data /path/to/run
alaya resume ROOT --provider PROVIDER --data /path/to/run --json
# A question stops resume with exit code 3. Use its state hash below.
alaya waiting --data /path/to/run
# For a single-choice question, choose one model-provided candidate:
alaya reply --data /path/to/run -- QUESTION '2'
# Or, when none of the listed candidates is correct:
alaya reply --data /path/to/run -- QUESTION 'none_of_above'
# Alternatively, when the person cannot answer (all supported question types):
alaya reply --data /path/to/run --unavailable -- QUESTION
alaya resume REPLY --provider PROVIDER --data /path/to/run --json
```

Place reply text after `--` so an open-ended answer such as `--data` or `-m` is
recorded as text rather than parsed as an option. Keep CLI options before `--`.

The `reply` command reads the text as a reply to the recorded question before writing any
child state (`Question.parseReply`). Yes/no rejects every value except `yes` and `no`. Single
choice accepts one number from 1 through the number of model-provided candidates, or the
exact string `none_of_above`. Arrays, blank selections, and out-of-range numbers
are rejected. Open-ended replies require nonblank text. A text that is no reply leaves the
question waiting. A reply is recorded as the value that says it: `"yes"` or `"no"`; a
candidate's number, the same however it was typed, so `2` and ` 2 ` are one reply and one
state; `"none_of_above"`; or an open answer's text, verbatim, surrounding whitespace included.
The browser and command line go through this same reading, including after the agent has been
reconstructed from its recorded configuration. The browser, CLI/API, and core all reject empty
or whitespace-only open answers, using the browser's Unicode whitespace definition.

Different valid CLI replies to one question form separate branches with the
same workspace. Receiving an answer does not change the task's rules or imply
that the answer is correct. `none_of_above` means none of the listed candidates is correct;
it is not a substitute for an unavailable answer.

`reply --unavailable` creates the same kind of reply child, but its recorded result is
the JSON object `{"status":"unavailable"}`. The next model request receives that
object under the original `ask_user` call ID. An answer is never an object: an open answer
is a string with its exact text, so even one containing the literal text
`{"status":"unavailable"}` is distinct from the unavailable status. Both paths
retain the question's workspace and the existing continuation limits. The caller
resumes from the returned reply hash as usual.

Read-only collectors use the same commands the page does:

```bash
alaya show --data /path/to/run --json -- QUESTION
alaya ls --data /path/to/run --json -- QUESTION ''
alaya ls --data /path/to/run --json -- QUESTION src
alaya cat --data /path/to/run --json -- QUESTION src/Main.lean
```

`show --json` gives the question's `history`: one `{state, kind, events}` per state from the
root to the question, with their original events, the task among the root's. `ls --json` gives
the `path` and its immediate `entries`, by name; `cat --json` previews an entry, with `path`,
`kind` (`text`, `binary`, `too_large`, `symlink`, `directory` or `other`), `content` (only for
`text`) and `size`. The empty directory path names the project root. None of them samples a
model or creates a reply. They read any state, so the page reads only the questions it has
listed, never an evaluation and the grader's evidence in it.

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
