# Alaya project notes

- Alaya is a Lean library and CLI. Use `lean-toolchain`, `lake build`, and relevant `lake exe tests FILTER` checks. Run experiments on Linux/WSL with Docker and restic 0.17 or later.
- Current API references: `docs/language.md`, `docs/runtime.md`, `docs/agents.md`, `docs/cli.md`, and `docs/log-schema.md`. Runs are event logs addressed by entries. Check actual code when older benchmark examples disagree with current configuration.
- The user's responsibility in Trusted Automatic Programming in Lean is human–AI interaction. Read its Overleaf project through signed-in Chrome when needed.
- Full-task experiments start from pristine task roots with policy in the first system message. Historical continuations are diagnostic only. A reply to a naturally occurring question continues the same trajectory and cumulative budget.
- Separate model-generated questions, engineering fixtures, proxy answers, reference answers, and actual human participation. Do not infer motivation from a score or unused time alone.
- Trusted benchmarks and grading checkouts stay outside agent workspaces. Grade terminal leaves only; never show grader results to a running agent. Credentials, raw model traffic, caches, workspaces, and trusted sources belong in ignored scratch.
- Use `.agents/skills/help-policy-experiments/SKILL.md` for the current hard-task study. Its frozen protocol, runner, and current status live in `experiments/help_on_hard_tasks/`. Preserve older studies and PR #50 unchanged.
- Preserve confirmed provider, model, answerer, and budgets. Local verified changes are committed; this task does not authorize new pushes or PRs.
