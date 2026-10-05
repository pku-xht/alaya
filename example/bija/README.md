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

`grade.py` grades an attempt as an alaya grader: `alaya grade --grader` runs it on a point of a
run, once the agent is over or stopped there, in the Bija image, in a checkout of the attempt, with this directory as its trusted input at `/grader`. It replaces the
attempt's `tests/` with the reference's 232 programs, runs the suite, and prints TAP: one check
per program run through the command line (`program AREA/NAME`), then one per program compiled
with `bija build` and run under a bare interpreter (`standalone AREA/NAME`), 464 in all. The pass
counts by section of the specification go to stderr, and the suite's output and JUnit report
stay in the grader's checkout, under `.grade/`.

## Driving it with alaya

The skeleton is a project directory, so a run starts from it directly; `TASK.txt` is the task
statement, kept here so every run is given the same one. The agent and the grader run in the
Bija image, built from `Dockerfile`: Python, `uv`, and the suite's dependencies, which containers
cannot download, since they run without network. From the repository root:

```sh
docker build -t alaya-bija example/bija

export ALAYA_DATA=$PWD/bija-runs   # created by new; every command below uses it
last() { tail -n 1 | cut -d' ' -f1; }
tip=$(alaya new --task-file example/bija/TASK.txt example/bija/skeleton --agent mini-swe \
  --model gpt-oss-120b --image alaya-bija | last)
end=$(alaya run "$tip" --provider dgx | last)
# done: Submitted: …

grader=(--grader 'python3 /grader/grade.py' --grader-input example/bija --grader-timeout 1800)
graded=$(alaya grade "$end" "${grader[@]}" | last)   # exits 1 for a fail
# done: fail N/464

alaya log --json "$graded" | grep '"external"'  # the grader's answer: its entry, its stdout
alaya cat ANSWER .grade/pytest.txt              # ANSWER: that entry; the suite's own output
alaya grade "$end:200" "${grader[@]}"           # how far it was at position 200
```

The image carries the suite's dependencies, so the agent can run the sample suite itself between
turns with `uv run pytest`.
The agent never sees the reference programs: the grader runs only once the agent is over, and copies
them over a checkout that the run's workspace does not follow; the verdict is what the run
returns, in the log after the agent's end.
