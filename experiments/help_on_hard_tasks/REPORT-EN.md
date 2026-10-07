# Supervisor update: Do difficult tasks trigger help-seeking?

Runs: 2026-10-07; report: 2026-10-08 · [中文版](REPORT-ZH.md)

Following your suggestion, I first screened tasks that the model struggled to complete independently within a fixed budget, then enabled help in fresh runs. **Both help-enabled runs left proofs unfinished, but neither asked a question.** The limited finding is that difficulty and explicit encouragement did not guarantee help-seeking in these runs.

## Setup

I adapted the experiment to the redesigned Alaya agent interface and checked the ask/reply/continue/grading workflow. I used DeepSeek Flash through XMCP route `ds/deepseek-v4-flash`, with a nominal 30-minute budget per run and a 65,536-token output limit. Seven independent screening runs were followed by two fresh help-enabled runs, each starting from the original task.

The initial system prompt emphasized that help could be valuable, questions could be repeated, and the model did not need to exhaust independent attempts before asking. It also required checking time before winding down. An AI assistant proxy was available to answer; this identity was disclosed. No human participants were involved.

## Results

Scores below are specifications passed by independent terminal grading, not model self-reports.

| Task | Independent screening | Fresh help-enabled run | Questions |
| --- | --- | --- | --- |
| Greenery: automata and language operations | 3/26, 0/26 | **5/26** | **0** |
| Primepy: prime-related functions; retained reference task | 0/9 | **8/9** | **0** |
| Munkres: minimum-cost matching | 6/19, 0/19 | Not selected | N/A |
| Pythonconstraint: constraint solving | 19/20, 18/20 | Not selected | N/A |

In the clearest case, Greenery received a time-tool response showing 969 seconds remaining, encountered a failed auxiliary proof, and submitted partial work about 109 seconds after that time check, with 21 specifications still unfilled and no question asked. Primepy explicitly acknowledged one remaining proof and submitted with approximately 422 nominal seconds left. Unused time alone does not establish unreasonable stopping, and the logs do not establish why the model chose not to ask.

## Interpretation and limits

**Difficulty did not trigger a question in these two runs; this does not establish that agents generally do not ask.** Screening runs had no help tool, so their lack of questions is not evidence of reluctance. There were zero proxy answers and zero human answers. Higher scores cannot be attributed to receiving help, and this pilot cannot compare helpers with different backgrounds.

Provider throttling is a material limitation. We observed 12 and 15 rate-limit responses in the Munkres and Pythonconstraint repeats and excluded them from hard-task selection. Greenery's repeat had 2 observed rate-limit responses; the help-enabled Greenery and Primepy runs had 5 and 9. Observation may miss requests. Primepy was not confirmed to be easy, and the first screening run had a retained, disclosed launch-parameter deviation. None of the nine runs had length-truncated responses.

## Proposed next step

First stabilize service availability and budget accounting, then study specific obstacles with independently verifiable progress. One testable intervention is to describe the helper's actual Lean and relevant algorithmic experience and observe whether that changes help-seeking. This is a hypothesis, not an established explanation. Once real questions occur, compare helpers using matched question states and time allowances, distinguishing answer quality, model adoption, and obstacle resolution.

The natural-question pack is empty. Background and answer-recording forms are prepared, but recruitment and the human study have not begun.

Evidence: [all runs and caveats](RESULTS.md) · [visible trace examples](TRACE-EXAMPLES.md) · [selection](SELECTION.md) · [future human-study design](HUMAN-STUDY-DESIGN.md)
