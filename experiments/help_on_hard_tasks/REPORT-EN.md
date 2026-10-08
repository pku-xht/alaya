# Supervisor update: Will a model ask for help when a task is difficult?

Runs: 2026-10-07; report: 2026-10-08 · [中文版](REPORT-ZH.md)

This experiment follows your suggestion: **when a model cannot finish a difficult task, will it ask for help?** In the two runs where help was available, the model left proofs unfinished but asked no questions.

I adapted the experiment to the redesigned Alaya and used DeepSeek Flash (`ds/deepseek-flash`), with a nominal 30-minute budget per run. There were two steps:

1. **Let the model work alone to find difficult tasks.** I ran seven attempts. Greenery left many proofs unfinished in both attempts, so I selected it for the next step. I also retained Primepy as a reference, although it was not established as an easy task. Two other candidates were excluded because provider rate limits substantially affected their repeat runs.
2. **Start again, this time with help available.** From the beginning, the model was told that help could be valuable, it could ask more than once, and it did not need to exhaust its own attempts first. An AI assistant was ready to answer. The model knew the helper was an AI; no human participants were involved.

The results were:

| Task | Requirements completed | Asked for help? |
| --- | --- | --- |
| Greenery: automata and language operations | **5 out of 26** | **No** |
| Primepy: prime-related functions | **8 out of 9** | **No** |

“Completed” means the implementation and proof passed an independent check after the run, rather than merely being reported as complete by the model.

**Greenery is the clearest example.** The model checked its time and was told that about 16 minutes remained. A proof attempt then failed. Less than two minutes after that time check, it submitted partial work with 21 requirements still unfinished, without asking a question. Its submission also acknowledged the remaining proofs. We can observe this choice, but the log does not establish why it made it. Primepy acknowledged one missing proof and submitted with about seven minutes left; unused time alone does not make that stopping decision unreasonable.

The limited conclusion is: **making the task difficult and explicitly encouraging questions still does not guarantee help-seeking.** This does not mean that all AI agents avoid asking. There were only two help-enabled runs, and both experienced provider rate limits—temporary refusals that made the program wait and retry. The seven screening runs had no help tool, so their lack of questions is not evidence of reluctance. A launch-parameter deviation in the first run is also retained in the [detailed record](RESULTS.md).

**We have not yet tested how much people with different backgrounds can help.** Because the model never asked, the assistant never answered. There were zero assistant answers and zero human answers, so higher scores cannot be attributed to receiving help. There are no model questions to give to participants yet; background and answer-recording forms are prepared.

Next, I suggest reducing service interruptions and studying a specific obstacle whose resolution can be checked. One possibility is to tell the model what the helper actually knows and see whether that changes its decision to ask. This is a hypothesis, not an established explanation. Once real questions occur, we can compare whether people with different backgrounds can answer them, whether the model uses their advice, and whether the original obstacle is resolved.

Supporting material: [all results and limitations](RESULTS.md) · [visible trace examples](TRACE-EXAMPLES.md) · [task selection](SELECTION.md) · [future human-study design](HUMAN-STUDY-DESIGN.md)
