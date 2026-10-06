# MiniVero

`Alaya.Agents.MiniVero` is Alaya's agent for the Lean implementation and proof tasks of the Vero
benchmark. It is MiniSwe (`docs/miniswe.md`) with Vero's instructions
in place of mini's prompts. Its loop, its tools, its reading of responses, its view and its
handling of long outputs and a full context are MiniSwe's, unchanged.

## 1. Options

MiniSwe's options, with one more and two other defaults. `alaya config --program mini-vero`
prints them all.

| Field | Default | Meaning |
| --- | --- | --- |
| `mode` | `proof` | Vero's evaluation mode for the run: `proof` or `codeproof` |
| `executor.timeout_seconds` | 600 | MiniSwe's is 30 |
| `executor.env` | none | MiniSwe's is mini's overrides |
| `tools` | `["bash", "submit", "time_budget"]` | MiniSwe's has no `time_budget` |

A codeproof run calls `mini-vero --set mode=codeproof`. To let the agent ask
questions, name every tool and the kinds of question it may ask (`docs/agent-api.md` §7):

```sh
--set 'tools=["bash","submit","time_budget","ask_user"]' --set 'question_types=["yes_no"]'
```

## 2. What the model is sent

A system message that names the agent and says Vero's grader decides correctness, then one task
message, in this order:

1. Vero's opening framing: the sandbox is the working directory, and the grader reads it after
   the agent stops.
2. The instance, its `task`, given to `call` as `--set-file task=MINIVERO_TASK.md`: the file of §3.
3. Vero's rule sections: `Marker grammar`, `Oracle commands`, `Grading` for the run's mode,
   `Done condition`, `Checkpointing`, `Anti-cheating`, and the two facts under `Scoring`.
4. This agent's mechanics: repository-relative paths, no shell state between calls, one
   `submit` call; and the image's system and architecture.

The rule sections are Vero's text byte for byte. Each is a file in `Alaya/Agents/MiniVero/`,
cut from Vero's instruction templates (`templates/instruction/` at sunblaze-ucb/vero
`0a7325d`) where the templates branch, so each can be compared with its source by `diff`. Lake
does not track these files: after editing one, touch `Alaya/Agents/MiniVero.lean` and rebuild.
A test fails when the compiled text and the files differ.

## 3. The instance: `MINIVERO_TASK.md`

`benchmarks/vero/render.py` generates it from Vero's trusted benchmark and from the sandbox
that was actually rendered. It holds only what the prompt cannot know in advance:

- **Benchmark scale**: the root project, packages, modules, API functions, specifications, mode.
- **Project layout**: the frozen files, and every editable file with the marker shapes it holds.
- **The mode's task**: Vero's sentences that state the artifact and the grader, for `proof`, or
  for `codeproof`'s Parts A, B and C.
- **Reference**: the original upstream source, only when it is shipped with the sandbox.

Feedback from an earlier attempt is not part of the task: append it with `alaya tell` before
the next `resume`.

## 4. Differences from Vero's own instructions

- **No prescribed way of working.** Vero's `Persistence`, `Workflow` and `Proof strategy`
  sections tell the agent how to work: keep iterating until the budget is spent, follow a fixed
  order of steps, and decompose proofs over lists into helper lemmas. MiniVero leaves them out
  and sends only the rules the grader enforces, so the strategy is the model's own. Vero's
  `Previous iteration feedback` is left out too: feedback is a message appended with
  `alaya tell` (§3).
- **File lists are the sandbox's own.** Vero's base template, shared by both modes, lists
  `Impl/*.lean` as editable even in `proof`, where its mode template says it is frozen. The
  instance lists the files as they are in the run's mode: `Impl/*.lean` is frozen in `proof` and
  editable in `codeproof`.
- **`Checkpointing` is adapted**, the one section not Vero's to the byte. Vero's is for a chunk
  of a known number of minutes, and says to check the time with `date`. Here the budget is
  given per invocation, after the prompt is sent, and the run may be paused and driven on
  later. So the section says the run has a time budget that the `time_budget` tool reports,
  names that tool where Vero says `date`, and says "run" where Vero says "chunk". The advice is
  Vero's: keep the build green, one slot at a time, never leave a slot half-written, wind down
  before the end.
- **The mode comes from the call's configuration**, never from the task file.

## 5. Pacing: `time_budget`

`alaya resume ENTRY --time-budget SECONDS` pauses the run once it has taken that long, and a
later `resume` goes on from its last entry. With `time_budget` among its tools, the agent is told
to pace itself by it.

- The tool takes no arguments and gives `{"seconds_left": N}`: the budget less the run's time
  along its log. So it is right after a pause, when the clock since the start is not.
- Without a budget it gives `{"seconds_left": null, "note": "this run has no time limit"}`.
- The budget is checked before each thing the agent does and never cuts one short, so a run
  can overrun it by one command or one response.
- With `time_budget` left out of `tools`, the `Checkpointing` section is left out too.

## 6. Running

The image build, render, prepare, run and grading commands are in
[the Vero integration](../benchmarks/vero/README.md). In outline:

```sh
alaya new source
alaya call ROOT mini-vero --set-file task=MINIVERO_TASK.md --set model=MODEL --image ghcr.io/msv-lab/alaya-vero-agent:0a7325d
alaya resume CALLED --provider PROVIDER
alaya call LAST grader --image vero-grader-TASK \
  --set command='python /opt/alaya-vero/grade.py --mode proof --benchmark /grader'
alaya resume GRADER
alaya cat GRADED:N .grade/report.md         # N: the position of the grader's command's answer
```

The grader is Vero's own, in an image of the task's: the Vero grader image with the trusted
benchmark added at `/grader` (`docs/log-schema.md` §4). Vero remains the source of the
benchmark definitions and the grading rules.
