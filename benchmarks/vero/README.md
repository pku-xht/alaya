# Vero in Alaya

This integration pins Vero at `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09` and Lean at
4.29.1. The pinned image inputs target Linux amd64 (use Docker emulation on an ARM host).
Run these commands from the Alaya repository on Linux with Docker, restic,
and Alaya built (`lake build`). The agent image contains Lean and cached Lake
packages; the grader image adds the pinned Vero installation, which renders a
sandbox and grades an attempt. The agent image never inherits Vero's layers.

## Build the two images

```sh
docker build --platform linux/amd64 --target agent -f benchmarks/vero/Dockerfile \
  -t alaya-vero-agent:0a7325d .
docker build --platform linux/amd64 --target grader -f benchmarks/vero/Dockerfile \
  -t alaya-vero-grader:0a7325d .
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
`.lake/` cache. Alaya snapshots the entire trusted input directory. For a small
self-contained example, the fixture below has one specification and supports
both modes. Select the mode once and keep it with the experiment's trusted
configuration.

```sh
BENCHMARK="$(pwd)/benchmarks/vero/tests/fixtures/tiny_trivial"
RUN="$(mktemp -d)"
MODE=codeproof
AGENT=alaya-vero-agent:0a7325d
GRADER_IMAGE=alaya-vero-grader:0a7325d

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

Rendering does not resolve or copy host dependencies. Preparation validates the
lock and creates symlinks from the sandbox's Lake packages to
`/opt/vero-packages` in the image. Existing real package directories cause an
error: render a fresh sandbox instead of copying a host cache into it. Restic
preserves these symlinks without including the dependency trees.

## Root and run

Both modes use MiniVero's defaults — `env: []`, `recover_output: false`, and
`ask_user: false` — and set only the mode (`alaya config --agent mini-vero` prints the rest).

```sh
MODE=codeproof    # or proof
ROOT=$(.lake/build/bin/alaya root "$RUN/source" \
  --task-file "$RUN/MINIVERO_TASK.md" --agent mini-vero --set agent.mode=$MODE \
  --image "$AGENT" --data "$RUN/audit")
.lake/build/bin/alaya resume "$ROOT" --model PROVIDER:MODEL --container-user "$(id -u):$(id -g)" \
  --time-budget 60 --data "$RUN/audit" --json > "$RUN/first.jsonl"
```

Exit 4 means the time budget was spent between turns; it is a checkpoint, not a
failed or finished run. The last JSON row contains the state to resume:

```sh
STATE=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["state"])' "$RUN/first.jsonl")
.lake/build/bin/alaya resume "$STATE" --model PROVIDER:MODEL \
  --time-budget 600 --data "$RUN/audit" --json > "$RUN/continued.jsonl"
STATE=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["state"])' "$RUN/continued.jsonl")
```

For automation with `set -e`, handle exit 4 explicitly before reading the
checkpoint. A submitted run exits 0. The model provider requires its usual
credentials; the deterministic acceptance test below does not.

On Linux, Alaya defaults to the host UID:GID; the explicit `--container-user`
above documents that choice. Every command of the run, and by default the grader,
runs as that user. The root records the resolved image ID and the workdir (`/workspace`
unless `root --workdir` says otherwise), and every step and evaluation inherits
them.

## Grade and read reports

```sh
.lake/build/bin/alaya eval "$STATE" --data "$RUN/audit" \
  --grader-image "$GRADER_IMAGE" --input "$BENCHMARK" \
  --grader "python /opt/alaya-vero/grade.py --mode $MODE --benchmark /grader"
# EVALUATION_HASH  fail 0/1  (… ms)
.lake/build/bin/alaya ls EVALUATION_HASH .vero --data "$RUN/audit"
.lake/build/bin/alaya cat EVALUATION_HASH .vero/report.md --data "$RUN/audit"
```

Alaya snapshots the trusted benchmark, mounts that snapshot read-only at
`/grader`, runs the grader image by digest, offline, as the agent's user, in a
fresh checkout of the state at its workdir, and records all of it with the
verdict (`docs/trajectory-schema.md` §4).

The command fixes the mode and the trusted benchmark; the grader does not read
`MINIVERO_TASK.md` or anything else in the checkout to choose either. It
extracts only the answer slots the mode permits — in proof mode, only the
manifest-selected proof files, never an Impl slot — rebuilds from the trusted
benchmark in `/tmp`, writes Vero's `report.json` and `report.md` to `.vero/` in
the checkout, and prints TAP: one check per specification, named
`Module.spec`, with the Vero status appended when it did not pass. An answer
file that is a symbolic link fails every check as `anti-cheat`. An invalid
joint claim adds a separate failing `acceptance: joint:...` check and leaves the
specifications' results as they are, so one passing specification with a
rejected claim is `fail 1/2`, while `report.json` still counts 1/1
specifications.

The statuses a Vero report may contain are read from the pinned Vero, not
written into the grader; a status outside them, a changed specification count,
a compiler timeout or signal, or any exception is a `Bail out!`, and so an
`error` verdict rather than a zero. The exit status of `eval` is 0 for pass,
1 for fail, 2 for error.

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

Each output directory must not exist; it keeps the trajectories, the recorded
evaluations and their reports. The integration test drives both modes through
render, prepare, `root --workdir /testbed`, a budget stop and its continuation
with a local scripted model (no credentials), and grading: a blank attempt fails
0/1, a correct one passes 1/1, a forged task file or a mode downgrade fails, and
in codeproof a symbolic link to the trusted implementation is rejected. It also
checks the grader's side of the contract: its workdir, read-only input, non-root
user on Linux, a timeout that is an error and leaves no container, and a clean
retry. The regression test covers the grader's adversarial cases: false
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
