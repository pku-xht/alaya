# Vero in Alaya

This integration pins Vero at `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09` and Lean at
4.29.1. The pinned image inputs target Linux amd64 (use Docker emulation on an ARM host).
Run these commands from the Alaya repository on Linux with Docker, restic,
and Alaya built (`lake build`). The agent image contains Lean and cached Lake
packages; the grader image adds the pinned Vero installation, which renders a
sandbox and grades an attempt. The agent image never inherits Vero's layers.

## Pull or build the two images

The images are published on the GitHub registry:

```sh
docker pull ghcr.io/msv-lab/alaya-vero-agent:0a7325d
docker pull ghcr.io/msv-lab/alaya-vero-grader:0a7325d
```

They are built, and can be rebuilt, from the repository root:

```sh
docker build --platform linux/amd64 --target agent -f benchmarks/vero/Dockerfile \
  -t ghcr.io/msv-lab/alaya-vero-agent:0a7325d .
docker build --platform linux/amd64 --target grader -f benchmarks/vero/Dockerfile \
  -t ghcr.io/msv-lab/alaya-vero-grader:0a7325d .
```

The image build resolves the existing `lake-manifest.json` with
`lake resolve-deps`, checks that the lock has not changed, and downloads the
matching Mathlib compiled cache. It builds the dependency targets once to save
Lake's hash sidecars before non-root runtime use. Image metadata is under `/opt/vero-image`.
The dependency cohort supports the seven pinned Mathlib benchmarks:
DedekindReals, Flocq, Huffman, Json, VerifiedIronkv, ecdsa, and Sequences.
Benchmarks without dependencies are supported too. A different lock requires a
matching image; preparation refuses incompatible versions.

The patches under `patches/` add an optional dependency-preparation switch to the
pinned Vero renderer, and make a compiler timeout or signal an exception rather
than a failed specification, so that the grader reports it as an error. They are
applied only while building the grader image.
No changes to a separate Vero checkout are required.

## Render and prepare

Use a clean, trusted benchmark from the pinned Vero revision, without a host
`.lake/` cache: the task's grader image holds all of it. For a small
self-contained example, the fixture below has one specification and supports
both modes. Select the mode once and keep it with the experiment's trusted
configuration.

```sh
BENCHMARK="$(pwd)/benchmarks/vero/tests/fixtures/tiny_trivial"
RUN="$(mktemp -d)"
MODE=codeproof
AGENT=ghcr.io/msv-lab/alaya-vero-agent:0a7325d
GRADER_IMAGE=ghcr.io/msv-lab/alaya-vero-grader:0a7325d

docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$BENCHMARK:/benchmark:ro" -v "$RUN:/rendered" "$GRADER_IMAGE" \
  python /opt/alaya-vero/render.py --benchmark /benchmark \
  --sandbox /rendered/source --mode "$MODE"

docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$RUN/source:/workspace" "$AGENT" \
  python3 /opt/alaya-vero/prepare.py /workspace
```

The layout is:

```text
run/
├── MINIVERO_TASK.md
└── source/
    ├── lean-toolchain
    ├── lake-manifest.json
    └── ...
```

The task's grader is the Vero grader image with the trusted benchmark added at
`/grader`, built once for the task. A call of the grader pins it by digest, so a
verdict names the very benchmark that gave it:

```sh
TASK_GRADER=alaya-vero-grader-$(basename "$BENCHMARK")
printf 'FROM %s\nCOPY . /grader\n' "$GRADER_IMAGE" |
  docker build --platform linux/amd64 --tag "$TASK_GRADER" --file - "$BENCHMARK"
```

Rendering does not resolve or copy host dependencies. Preparation validates the
lock and creates symlinks from the sandbox's Lake packages to
`/opt/vero-packages` in the image. Existing real package directories cause an
error: render a fresh sandbox instead of copying a host cache into it. Restic
preserves these symlinks without including the dependency trees.

## Create and run

Both modes use MiniVero's defaults — `env: []`, `recover_output: false`, and
`tools: ["bash", "submit", "time_budget"]` — and set only the mode (`alaya config --program mini-vero` prints the rest).
The run is graded afterwards, by a call of the grader (below).

```sh
MODE=codeproof    # or proof
last() { tail -n 1 | cut -d' ' -f1; }
ROOT=$(.lake/build/bin/alaya new "$RUN/source" --data "$RUN/audit" | last)
CALL=$(.lake/build/bin/alaya call "$ROOT" mini-vero --task-file "$RUN/MINIVERO_TASK.md" \
  --set mode=$MODE --set model=MODEL --image "$AGENT" --data "$RUN/audit" | last)
.lake/build/bin/alaya resume "$CALL" --provider PROVIDER --container-user "$(id -u):$(id -g)" \
  --time-budget 60 --data "$RUN/audit" --json > "$RUN/first.jsonl"
```

`new` prints the root, and `call` the call of the agent, which `resume` opens and
drives. Exit 4 means the time budget, the run's time summed along its log, was
spent between turns; it is a checkpoint, not a failed or finished run. The last
JSON row is the status, with the entry to go on from:

```sh
ENTRY=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["entry"])' "$RUN/first.jsonl")
.lake/build/bin/alaya resume "$ENTRY" --provider PROVIDER \
  --time-budget 600 --data "$RUN/audit" --json > "$RUN/continued.jsonl"
END=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["entry"])' "$RUN/continued.jsonl")
```

For automation with `set -e`, handle exit 4 explicitly before reading the
checkpoint. A run whose agent is over exits 0, and its last row's `status` says
how it ended; exit 1 means the agent failed, and 3 that it waits for a person. The model
provider requires its usual credentials; the deterministic acceptance test below
does not.

On Linux, Alaya defaults to the host UID:GID; the explicit `--container-user`
above documents that choice. Every command of the run, the grader's included,
runs as that user. Each call's opening records its resolved image ID and its
workdir (`/workspace` unless `call --workdir` says otherwise): the agent's, and
the grader's, whose image holds the trusted benchmark.

## Grade and read reports

A point of the run is graded by calling the task's grader there: `alaya stop`
first, where the agent still runs, then `call … grader`, and `resume`. No
provider is needed, and `resume` exits 0, 1 or 2 with a pass, a fail or an error.

```sh
grade() {
  GRADER=$(.lake/build/bin/alaya call "$1" grader --image "$TASK_GRADER" \
    --set command="python /opt/alaya-vero/grade.py --mode $MODE --benchmark /grader" \
    --data "$RUN/audit" | last)
  .lake/build/bin/alaya resume "$GRADER" --data "$RUN/audit" --json
}
grade "$END" > "$RUN/graded.jsonl"
# the last row: {"entry": ..., "call": "grader", "status": "done", "value": {"status": "pass", "passed": 1, "total": 1, ...}}
```

Any other point is graded the same way. The untouched source, for one, at the
root `new` printed:

```sh
grade "$ROOT" > "$RUN/blank.jsonl"   # exits 1: a fail
```

The grader's reports are in the workspace as it left it, read at the entry of
its command's answer — the `answered` event in the grader's frame:

```sh
ANSWER=$(.lake/build/bin/alaya log "$(tail -n 1 "$RUN/graded.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["entry"])')" \
  --json --data "$RUN/audit" | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin]
frame = [r["frame"] for r in rows if r.get("event", {}).get("type") == "opened"
         and r["event"]["routine"]["name"] == "grader"][-1]
print([r["entry"] for r in rows if r.get("frame") == frame
       and r["event"]["type"] == "answered"][-1])')
.lake/build/bin/alaya ls "$ANSWER" .grade --data "$RUN/audit"
.lake/build/bin/alaya cat "$ANSWER" .grade/report.md --data "$RUN/audit"
```

The grader runs in a container of the task's grader image, by digest, offline,
as the agent's user, on the workspace the log has reached, and the log records
all of it: the grader's call, its command's answer, and the verdict
(`docs/log-schema.md` §4).

The grader's call fixes the mode, in its command, and the trusted benchmark, in its image; the
grader does not read `MINIVERO_TASK.md` or anything else in the workspace to choose either. It
extracts only the answer slots the mode permits — in proof mode, only the
manifest-selected proof files, never an Impl slot — rebuilds from the trusted
benchmark in `/tmp`, writes Vero's `report.json` and `report.md` to `.grade/` in
the workspace, and prints TAP: one check per specification, named
`Module.spec`, with the Vero status appended when it did not pass. An answer
file that is a symbolic link fails every check as `anti-cheat`. An invalid
joint claim adds a separate failing `acceptance: joint:...` check and leaves the
specifications' results as they are, so one passing specification with a
rejected claim is `fail 1/2`, while `report.json` still counts 1/1
specifications.

The statuses a Vero report may contain are read from the pinned Vero, not
written into the grader; a status outside them, a changed specification count,
a compiler timeout or signal, or any exception is a `Bail out!`, and so an
`error` verdict rather than a zero. The verdict's `status` — `pass`, `fail` or
`error` — tells them apart, and `resume` exits 0, 1 or 2 by it.

## Reproduce acceptance checks

```sh
lake exe tests
python3 benchmarks/vero/tests/integration.py \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" \
  --output /tmp/vero-acceptance-new
python3 benchmarks/vero/tests/regressions.py \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" \
  --output /tmp/vero-grader-regressions-new
```

Each output directory must not exist; it keeps the runs' logs and the graders'
reports. Each test builds the task's grader images itself. The integration test
drives both modes through render, prepare, a call at `--workdir /testbed`, a
budget pause and its continuation with a local scripted model (no credentials),
and grading: a blank attempt, graded at the root, fails 0/1; a correct one
passes 1/1 when the agent ends, and again on a fork that grades the same point
anew; a forged task file or a mode downgrade, committed by hand and graded after
a stop, fails; and in codeproof a symbolic link to the trusted implementation is
rejected. It also checks the grader's side of the contract: its workdir, its
trusted files read-only and its user non-root on Linux, the image it runs in, a
timeout that is an error and leaves no container, and a clean retry. The regression test covers the grader's adversarial cases: false
disproofs, frozen and deleted implementation files, symbolic links, joint claims,
unknown Vero statuses, and injected compiler timeouts and signals.

For Mathlib, substitute the pinned Flocq benchmark in the render/prepare
commands. Run `lake build` through the agent image with the same non-root user,
mount, and `--network none`. Verify `.lake/packages/*` are symlinks to the
image, and inspect the root snapshot size before building. The tiny fixture
cannot validate Mathlib caches.

The dedicated Mathlib check records the snapshot size and package links:

```sh
python3 benchmarks/vero/tests/mathlib.py \
  --benchmark /path/to/pinned/vero/benchmarks/Flocq \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" \
  --output /tmp/vero-mathlib-acceptance-new
```

See [VALIDATION.md](VALIDATION.md) for the validation steps, expected behavior,
and evidence to retain with each run.
