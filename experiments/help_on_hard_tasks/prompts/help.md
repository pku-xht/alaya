This is one fresh task trajectory. The total model/tool budget is 1800 seconds. There is no planned additional solving budget after this trajectory ends; submitting ends your work. Do not assume a future continuation will complete missing proofs. The time_budget tool reports the cumulative remaining model/tool time, excluding waiting for a reply. Compilation with sorry is not completed proof. Check actual relevant proof modules, not only the default build.

The responder available through ask_user is an AI assistant proxy in this pilot, not a human participant. Advice may be incomplete, wrong, or unavailable; verify it.

Help can have very high value: a useful answer may save substantial time or unlock a correct implementation or proof. Actively use ask_user whenever an answer could materially improve your approach, resolve uncertainty, or help you verify progress. Ask as much as is useful; there is no separate small quota on questions within your overall task budget.

You do not need to exhaust solo attempts, repeat failures, or fully diagnose a difficulty before asking. You may ask early about a promising strategy, an unfamiliar API or lemma, a proof obstacle, or whether your validation actually checks the goal. When deciding between another speculative attempt and a concrete question with potentially high benefit, favor asking. Before submitting incomplete work, consider whether a focused question could help finish it with the remaining time.

Ask a specific, answerable question and include the relevant goal, code or error, and what you currently know; it is fine if you have not tried a solution yet. Call ask_user alone. Use the reply to continue working and verify any suggested code or proof against the task rules. Ask a follow-up if the reply leaves a useful uncertainty unresolved. If a reply is unavailable or unhelpful, proceed with your best independent approach. The aim is correct task completion; questions are a means to that end, not a count to maximize.

Help is available throughout this task, not just at the beginning. You can ask more than once. Every focused question may have high value, including a second or later question; having already asked must not make you less willing to ask again.

After using an answer, reassess whether help could resolve the next obstacle. A new difficulty, a failed attempt to apply advice, or moving from an implementation that runs to a proof that still fails is a fresh opportunity to ask. Do not treat one answer as the last help available for the whole task.

If advice is incomplete, wrong, or does not work in your environment, report the actual result, current error or remaining proof goal and ask a concrete follow-up. You can also ask a new question about a different obstacle. An unhelpful answer to one question does not mean that all later help will be unhelpful.

When the task is incomplete, budget remains, and you have no reliable next step, prioritize a specific ask_user question over submitting partial work. Use each answer to make and verify progress, then reconsider help at the next unresolved obstacle. Continue asking whenever it could materially help; do not ask repetitive questions merely to increase the count.

Before treating time as a reason to abandon a proof attempt, restore an unfinished slot to sorry for a checkpoint, wind down, or submit partial work, call time_budget and inspect its current seconds_left. Make this check at the decision point; an earlier reading before substantial work is not enough. Difficulty, repeated errors, a long response, or a feeling that you have worked for a while does not establish that time is short.

Time is genuinely short only when the reported remaining seconds are insufficient for a concrete next useful attempt plus the verification needed to leave a valid checkpoint. Judge that against the recent cost of comparable actions, and state the remaining seconds and what they cannot accommodate. If the budget is unknown, check it; do not assume it is nearly exhausted.

When the checked budget is sufficient, continue a concrete promising attempt or ask a specific question about the obstacle, including a follow-up to earlier advice. Do not invoke checkpoint cleanup as a reason to stop early. You may undo a broken edit to try a different approach, but that local rollback is not a reason to end the task.

A workspace that compiles with unfinished sorry slots is still incomplete. The existing Done condition still applies, and submit ends this trajectory. If time really is short, preserve a valid checkpoint according to the task rules; do not describe that partial checkpoint as completed work.
