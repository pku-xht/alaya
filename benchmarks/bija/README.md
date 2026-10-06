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

`grade.py` grades an attempt as alaya's grader: a call of `grader` runs it on a point of a run,
once the agent is over or stopped there, in the grader image, on the attempt, with the
reference's `tests/` at `/grader` in that image. It replaces the attempt's `tests/` with the
reference's 232 programs, runs the suite, and prints TAP: one check per program run through the
command line (`program AREA/NAME`), then one per program compiled with `bija build` and run
under a bare interpreter (`standalone AREA/NAME`), 464 in all. The pass counts by section of the
specification go to stderr, and the suite's output and JUnit report stay in the workspace, under
`.grade/`.

## Driving it with alaya

The skeleton is a project directory, so a run starts from it directly; `TASK.txt` is the task
statement, kept here so every run is given the same one. The agent and the grader run in the
two amd64 images `Dockerfile` builds from a pinned base: Python, `uv`, and the suite's dependencies,
which containers cannot download, since they run without network. The grader's adds `grade.py`
and the reference programs at `/grader`. The agent's image is published on the GitHub registry,
tagged with the commit it was built from; the grader's holds the hidden tests, so it is built
locally and never published:

```sh
docker build --platform linux/amd64 --target agent \
  -t ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd benchmarks/bija
docker build --platform linux/amd64 --target grader -t alaya-bija-grader benchmarks/bija
```

From the repository root:

```sh
docker pull ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd

export ALAYA_DATA=$PWD/bija-runs   # created by new; every command below uses it
last() { tail -n 1 | cut -d' ' -f1; }
root=$(alaya new benchmarks/bija/skeleton | last)
called=$(alaya call "$root" mini-swe --set model=gpt-oss-120b --task-file benchmarks/bija/TASK.txt \
  --image ghcr.io/msv-lab/alaya-bija-agent:c6cd8bd | last)
end=$(alaya resume "$called" --provider dgx | last)
# mini-swe: done: Submitted: …

grade() { alaya resume "$(alaya call "$1" grader --image alaya-bija-grader \
  --set command='python3 /opt/alaya-bija/grade.py --tests /grader' \
  --set timeout_seconds=1800 | last)"; }
graded=$(grade "$end" | last)          # exits 1 for a fail
# grader: done: fail N/464

alaya log "$graded"                    # the grader's command's answer, then its verdict
alaya cat ANSWER .grade/pytest.txt     # ANSWER: the entry of that answer; the suite's own output
grade "$(alaya stop "$end:200" --reason 'to grade this point' | last)"   # how far it was at 200
```

The image is built from the context `benchmarks/bija`, which leaves out what a local
`uv run pytest` leaves in `reference/tests/` (`.dockerignore`).

The image carries the suite's dependencies, so the agent can run the sample suite itself between
turns with `uv run pytest`.
The agent never sees the reference programs: they are only in the grader's image, which runs
only once the agent is over; the verdict is what the grader's call returns, in the log after
the agent's end.
