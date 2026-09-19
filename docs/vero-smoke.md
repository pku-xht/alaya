# Fresh Vero smoke runs

`example/vero_smoke.py` runs Alaya on Vero's `primepy` codeproof task: seven APIs
and nine fixed specifications. A six-turn smoke checks the execution and grading
path; it is not a complete solve attempt or a model-capability estimate.

Use Vero commit `0a7325df9e9e6dbc275c0ad483b3d1cbe38d9b09` from
[sunblaze-ucb/vero](https://github.com/sunblaze-ucb/vero). Its toolchain is Lean
4.29.1. Alaya itself uses the separate version in `lean-toolchain` (4.31.0).
Keep Vero and its reference implementation outside the agent container. On Windows,
use a Linux filesystem in WSL: Vero includes filenames that Windows reserves.

Install Vero's Python dependencies in a virtual environment. The render, extract,
and grading path uses `hydra-core python-dotenv loguru jinja2 pydantic pyyaml`.
Set `PYTHONPATH` to Vero's `src` and put Lean 4.29.1 on `PATH` for grading.
Build the isolated image using the unpacked official Lean 4.29.1 Linux release:

```sh
docker build -f example/Dockerfile.vero -t alaya-vero:lean4.29.1 /path/to/lean-4.29.1-linux
```

Supply `XMCP_API_KEY` through the environment. Never put a real key in a command,
source file, or report. The existing route is `xmcp:closeai/gpt-5.4-mini`, using
`https://llm.xmcp.ltd/chat/completions` with temperature zero. Check the configured
route with a minimal real API request before a paid experiment; do not substitute
a different model when a route fails.

```sh
python example/vero_smoke.py --vero /path/to/vero --alaya /path/to/alaya \
  --image alaya-vero:lean4.29.1 --output /private/NEW_RUN --steps 6 --seconds 1800
```

The output directory must not exist. Each new sample starts with an empty model
cache. The container has no network or model credential and receives only the
rendered task. Official grading rebuilds a separate copy; evaluation states are
terminal leaves and never become continuation workspaces. Optional Vero LLM
instance judging is not run; new instance sites require separate review.

The runner includes the complete `INSTRUCTION.md` in the opening request using
`root --instruction-file`, preserving its text and trailing newline. It writes
`delivered-task.txt` and its SHA-256 into the manifest. See the
[delivery and recovery contract](output-recovery.md).

Outputs include `run.json`, the complete CAS trajectory and cache, official
`evidence/report.md`, `verification.json`, and `report.html`. A score and a successful
infrastructure check are separate results. Preserve early submissions, compilation
failures, and timeouts. Keep raw prompts, replies, trajectories, and source patches
private unless their publication has been separately reviewed and authorized.

For exact transport evidence, install the optional recorder with
`python example/record_model_io.py install /private/bin`, prepend that directory to
`PATH`, and set a distinct `ALAYA_MODEL_IO_DIR` per run. It forwards to `/usr/bin/curl`
without changing the endpoint or payload, records request/response bodies, and
does not read credential config or headers. Capture failure is explicit.

The paired-answer procedure is in [vero-experiment.md](vero-experiment.md); the
fresh old/new implementation results are in
[output-recovery-experiment.md](output-recovery-experiment.md).
