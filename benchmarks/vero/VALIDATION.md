# Vero validation

This guide covers the image, the rendered workspace, the preparation helper and
the Alaya workflow. Recorded results identify the executable, source hashes, image
digests, platform, and test inputs used. They establish behavior for those
artifacts; they do not establish that a different working tree or executable
passes the same checks.

## Run the checks

Run from the Alaya repository on Linux with Docker and restic available. Build
the executable with `lake build` and build the images using the commands in
[README.md](README.md). Each test output directory must be new.

```sh
lake build
lake exe tests

AGENT=alaya-vero-agent:0a7325d
GRADER_IMAGE=alaya-vero-grader:0a7325d

python3 benchmarks/vero/tests/integration.py \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" --output /tmp/vero-acceptance-new
python3 benchmarks/vero/tests/regressions.py \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" --output /tmp/vero-grader-regressions-new

# Use a clean Flocq directory exported from the pinned Vero commit:
python3 benchmarks/vero/tests/mathlib.py \
  --benchmark /path/to/pinned/vero/benchmarks/Flocq \
  --agent-image "$AGENT" --grader-image "$GRADER_IMAGE" \
  --output /tmp/vero-mathlib-acceptance-new
```

The Mathlib check records package links, the root snapshot size, and build logs.
It rejects incompatible locks and real host package directories, then builds the
dependency targets and Flocq offline as the host UID:GID, and grades the
untouched attempt: a fail with no specification passed, not an error. A small
fixture without Mathlib cannot establish that the dependency cache works.

## Expected behavior

| Scenario | Expected behavior |
| --- | --- |
| Rendered workspace, no host cache | `source/` has no `.lake/packages`; the task contract sits next to the sandbox |
| Preparation against the image cohort | Only the missing packages are linked to `/opt/vero-packages` |
| A real package directory in the sandbox | Refused, and the directory is left untouched |
| A lock that differs from the image's | Refused instead of silently using the image's revision |
| Offline build of a Mathlib benchmark | `lake build` exits 0 with `--network none`, non-root, through the package links |
| Root snapshot of a Mathlib benchmark | Source files and symlinks only: no dependency trees |
| Grading a blank, a correct, and a tampered attempt | `fail 0/N`, `pass N/N`, `fail`; Vero's reports in `.grade/` |
| An answer file that is a symbolic link | Every check fails as `anti-cheat` |
| An invalid joint claim | A failing `acceptance: joint:...` check; the specifications keep their results |
| An unknown Vero status, a compiler timeout or signal | `Bail out!`, an `error` verdict |

## Validation records

Keep each run's evidence outside the source tree with its test outputs. A
validation record should contain:

- The source revision and working-tree file hashes, executable hash, and
  Lean/Vero versions.
- Resolved agent and grader image digests, plus hashes of the Dockerfile,
  adapters, and patches used to build them.
- Host and container platforms, UID:GID, network settings, exact commands,
  benchmark revision, mode, and any fault-injection inputs.
- The executable used, the rendered sandbox and lock, package links, build logs,
  and the root snapshot size.
- For Mathlib, package-link targets, dependency and benchmark build logs, and
  root snapshot size measured before building.
- Whether source builds used an existing `.lake` directory or image builds used
  Docker layers and download caches, plus skipped checks and untested cases.

Compare source, executable, and image identities before applying recorded results
to an artifact. Distinguish compilation from runtime testing, and a clean source
context from a cache-disabled image build. A check's scope is its recorded
platform, inputs, and commands; it does not establish untested combinations.

## Coverage boundaries

- The images are Linux amd64. The checks run on Linux amd64, and on macOS arm64
  through Docker Desktop's emulation; other hosts are not covered.
- The recorded tests establish the listed cases and workflows for their recorded
  artifacts, not correctness for every benchmark that could be rendered.
