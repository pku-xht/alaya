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
* **The grader is bigger than the sample.** The skeleton ships twelve programs, one per area;
  the reference has 232 of the same shape. Running the reference's suite against an agent's
  implementation measures generalisation from the specification rather than fitting to the
  visible tests.

## Running it

Both directories are self-contained uv projects with no runtime dependencies, targeting
`ghcr.io/astral-sh/uv:python3.12-bookworm-slim`:

```sh
cd reference && uv run pytest        # 464 tests, all passing
cd skeleton  && uv run pytest        # 24 tests, all failing, until the work is done
```

## The grader

`grade.py` grades an attempt as an alaya grader: `alaya eval` runs it in the Bija image, in a
checkout of the attempt, with this directory as its trusted input at `/grader`. It replaces the
attempt's `tests/` with the reference's 232 programs, runs the suite, and prints TAP: one check
per program run through the command line (`program AREA/NAME`), then one per program compiled
with `bija build` and run under a bare interpreter (`standalone AREA/NAME`), 464 in all. The pass
counts by section of the specification go to stderr, and the suite's output and JUnit report
stay in the evaluation's workspace, under `.grade/`.

## Driving it with alaya

The skeleton is a project directory, so it seeds a trajectory directly; `TASK.txt` is the task
statement, kept here so every run is given the same one. The agent and the grader run in the
Bija image, built from `Dockerfile`: Python, `uv`, and the suite's dependencies, which containers
cannot download, since they run without network. From the repository root:

```sh
docker build -t alaya-bija example/bija

root=$(alaya root --task-file example/bija/TASK.txt example/bija/skeleton --agent agents/mini-swe-default.json \
  --image alaya-bija)

alaya resume "$root" --model dgx:gpt-oss-120b

alaya eval <final-hash> --input example/bija --grader /grader/grade.py --timeout 1800
# <hash>  fail N/464  (… ms)

alaya show <evaluation-hash>                     # the verdict, every check, the grader's output
alaya cat <evaluation-hash> .grade/pytest.txt    # the suite's own output
```

The image carries the suite's dependencies, so the agent can run the sample suite itself between
turns with `uv run pytest`.
The agent never sees the reference programs: the grader copies them over a checkout that is
discarded afterwards, and the verdict is recorded as a leaf.
