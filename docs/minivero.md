# MiniVero

`Alaya.Agent.MiniVero` is Alaya's small agent for Vero Lean implementation and proof tasks. Use it with `--agent mini-vero` for root, step, resume, HTML, and `show --view` commands.

## How it works

MiniVero reuses MiniSwe's bash and submit tools, action parsing, executor, and control loop. Alaya provides the trajectory store, snapshots, checkpoints, HTML reports, and external evaluation.

Before a run, vero-codegen renders a Vero sandbox and creates `MINIVERO_TASK.md`. Its full text is passed in MiniVero's opening user message. The task contract states the mode, editable marker interiors, frozen files, proof obligations, permitted alternatives, required checks, and Vero's grading constraints.

The agent then inspects the relevant Lean declarations and compiler output. It may edit only the designated marker interiors, and it uses the libraries present in the rendered project. A submission ends the agent run; Vero's external grader determines whether the task passed.

MiniVero defaults to 200 model turns and a 600-second shell-command timeout. The experiment runner can apply additional attempt and wall-clock limits.

## Context view

MiniVero currently uses MiniSwe's linear history unchanged. Every earlier message remains in the model context, while the complete raw trajectory is also retained for reports, evaluation, and later analysis. This is the baseline used for experiments.

MiniSwe still truncates a single tool output of at least 10,000 characters to its beginning and end before placing it in the model context. No multi-turn compaction or summary is applied before the baseline is evaluated.

## Running

Build and test Alaya:

```bash
lake build
lake exe tests mini-vero
```

Run against an already rendered Vero source directory:

```bash
alaya root "$(cat /path/to/source/MINIVERO_TASK.md)" /path/to/source --agent mini-vero --data /path/to/audit
alaya step STATE --agent mini-vero --model PROVIDER:MODEL --data /path/to/audit --json
alaya html /path/to/report.html --agent mini-vero --data /path/to/audit
```

`../vero-codegen` contains the experimental runner, task-contract generation, Docker image builder, Vero grading adapter, and integration tests. Vero itself remains the source of benchmark definitions and grading rules.

```bash
alaya eval STATE --data /path/to/audit --grader '/path/to/vero-python /path/to/vero-codegen/grade.py "{checkout}" "{out}" --run /path/to/run'
```
