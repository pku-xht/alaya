# Vero in Alaya

This integration pins Vero at `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09` and Lean at
4.29.1. The pinned image inputs target Linux amd64 (use Docker emulation on an ARM host).
Run these commands from the Alaya repository on Linux with Docker, restic,
and Alaya built (`lake build`). The agent image contains Lean and cached Lake
packages; the grader image adds the pinned Vero installation that renders a
sandbox and prepares it. The agent image never inherits Vero's layers.

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

The patch under `patches/` adds an optional dependency-preparation switch to the
pinned Vero renderer. It is applied only while building the grader image.
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

Proof uses `agents/mini-vero-default.json`; codeproof uses
`benchmarks/vero/mini-vero-codeproof.json`. Both baseline configurations use
`env: []`, `recover_output: false`, and `ask_user: false`.

```sh
CONFIG=benchmarks/vero/mini-vero-codeproof.json
# For MODE=proof: CONFIG=agents/mini-vero-default.json
ROOT=$(.lake/build/bin/alaya root "$RUN/source" \
  --task-file "$RUN/MINIVERO_TASK.md" --agent "$CONFIG" \
  --image "$AGENT" --container-user "$(id -u):$(id -g)" --data "$RUN/audit")
.lake/build/bin/alaya resume "$ROOT" --model PROVIDER:MODEL \
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

On Linux, Alaya defaults to the host UID:GID. The explicit `--container-user`
above documents the non-root choice and records it for the run.

The root records the resolved image ID and the container user, and steps run
with them.

## Reproduce acceptance checks

```sh
lake exe tests
```

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
