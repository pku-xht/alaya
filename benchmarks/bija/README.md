# Bija — a long-horizon task for the agent

Bija is a small imperative language invented for this benchmark: ordinary in most respects, and
deliberately unusual in three that cannot be guessed from familiarity with other languages. The
task is to implement its compiler from a written specification.

| Directory    | What it is                                                                    |
| ------------ | ----------------------------------------------------------------------------- |
| `skeleton/`  | the starting point: the whole specification, the harness, and a `bija` command that reports "not implemented yet" |
| `reference/` | a complete implementation with 232 acceptance programs, 100% statement coverage |

## Why this task

* **It is long.** A correct implementation is a lexer, a parser, static checks, a code
  generator and a runtime — roughly a thousand statements of Python, decomposable into pieces
  that are nonetheless coupled through the specification.
* **It cannot be faked from familiarity.** A variable is a stack of generations that `@` reads
  back into; `attempt` rolls the storehouse back when a block withers, including from inside a
  called deed; `ripen when` defers a block until a checkpoint at which its condition holds.
  An implementation shaped like a conventional language passes the arithmetic and fails these.
* **Progress is a number at every moment.** The suite is whole programs against exact output,
  so a partial implementation scores a fraction rather than an opinion.
* **The grader is bigger than the sample.** The skeleton ships twelve programs from nine of
  the eleven areas; the reference has 232 of the same shape, in all eleven. Running the reference's suite against an agent's
  implementation measures generalisation from the specification rather than fitting to the
  visible tests.

## Running it

Both directories are self-contained uv projects with no runtime dependencies, targeting
`ghcr.io/astral-sh/uv:0.12.7-python3.12-trixie-slim`:

```sh
cd reference && uv run pytest        # 464 tests, all passing
cd skeleton  && uv run pytest        # 24 tests, all failing, until the work is done
```

## The grader

`grade.py` grades an attempt as an alaya grader: `alaya grade --grader` runs it on a point of a
run, once the agent is over or stopped there, in the grader image, in a checkout of the attempt,
with the reference's `tests/` as its trusted input at `/grader`. It replaces the attempt's
`tests/` with the reference's 232 programs, runs the suite, and prints TAP: one check
per program run through the command line (`program AREA/NAME`), then one per program compiled
with `bija build` and run under a bare interpreter (`standalone AREA/NAME`), 464 in all. The pass
counts by section of the specification go to stderr, and the suite's output and JUnit report
stay in the grader's checkout, under `.grade/`.

## Driving it with alaya

The skeleton is a project directory, so a run starts from it directly; `TASK.txt` is the task
statement, kept here so every run is given the same one. The agent and the grader run in the
two amd64 images `Dockerfile` builds from a pinned base: Python, `uv`, and the suite's dependencies,
which containers cannot download, since they run without network; the grader's adds `grade.py`.
Neither holds the reference programs: only the grader is given them, as its input. They are
published on the GitHub registry, tagged with the commit they were built from, and that commit's
`Dockerfile` rebuilds them:

```sh
docker build --platform linux/amd64 --target agent \
  -t ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd benchmarks/bija
docker build --platform linux/amd64 --target grader \
  -t ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd benchmarks/bija
```

From the repository root:

```sh
docker pull ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd
docker pull ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd

export ALAYA_DATA=$PWD/bija-runs   # created by new; every command below uses it
last() { tail -n 1 | cut -d' ' -f1; }
tip=$(alaya new --task-file benchmarks/bija/TASK.txt benchmarks/bija/skeleton --agent mini-swe \
  --model gpt-oss-120b --image ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd | last)
end=$(alaya run "$tip" --provider dgx | last)
# done: Submitted: …

grader=(--grader 'python3 /opt/alaya-bija/grade.py --tests /grader'
        --grader-image ghcr.io/msv-lab/alaya-bija-grader:c6cd8bd
        --grader-input benchmarks/bija/reference/tests --grader-timeout 1800)
graded=$(alaya grade "$end" "${grader[@]}" | last)   # exits 1 for a fail
# done: fail N/464

alaya log --json "$graded" | grep '"external"'  # the grader's answer: its entry, its stdout
alaya cat ANSWER .grade/pytest.txt              # ANSWER: that entry; the suite's own output
alaya grade "$end:200" "${grader[@]}"           # how far it was at position 200
```

Alaya snapshots the whole grader input, so keep `reference/tests/` clean: no `__pycache__/` left
by a local `uv run pytest`.

The image carries the suite's dependencies, so the agent can run the sample suite itself between
turns with `uv run pytest`.
The agent never sees the reference programs: the grader runs only once the agent is over, and copies
them over a checkout that the run's workspace does not follow; the verdict is what the run
returns, in the log after the agent's end.
