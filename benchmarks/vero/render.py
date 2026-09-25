"""The MiniVero task contract: what is specific to one run.

The contract holds what the agent's own instructions cannot know before a sandbox
exists — which benchmark and mode this is, what the project contains, which files are
frozen, which marker slots sit in each editable file, and the work this mode asks for.
When it is part of the run, it also states reference material that was shipped.
Chunking and prior feedback are resume-state facts owned by the experiment runner, not by
this task contract.

"""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:  # runtime imports follow Vero package discovery
    from vero.generation.benchmark import Benchmark

Mode = Literal["proof", "codeproof"]


def _q(path: str) -> str:
    return f"``{path}``"


def _rel(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def _editable_files(bench: Benchmark, sandbox: Path, mode: Mode) -> list[Path]:
    files: list[Path] = []
    if mode == "codeproof":
        files.extend(sandbox / _rel(path, bench.root) for path in bench.all_impl_files())
    files.extend(sandbox / module.proof_rel() for module in bench.iter_modules() if module.specs)
    if mode == "codeproof":
        files.append(sandbox / bench.joint_file_rel())
    return files


def _existing(paths: list[Path], what: str) -> list[Path]:
    """Fail loudly when a file the contract describes is not in the sandbox.

    Dropping a missing file silently would hide a broken render or a changed
    layout from the agent and from the experiment log alike.
    """
    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            f"{what} missing from the rendered sandbox: "
            + ", ".join(str(path) for path in missing)
        )
    return paths


def _slot_signature(prefix: str, key: str, fields: dict[str, str]) -> str:
    """One marker's shape, as the ``Project layout`` section writes it."""
    parts = ["!solution"] if prefix == "solution" else [key]
    if "def" in fields:
        parts.append("def=" + ("<fn>" if key in {"code", "code_aux"} else "<thm>"))
    if "kind" in fields:
        parts.append("kind=<k>")
    if "target" in fields:
        parts.append("target=<spec>")
    return " ".join(parts)


def _slot_shapes(path: Path) -> list[str]:
    """The distinct marker shapes a file holds, in the order they first appear."""
    from vero.generation.benchmark import load_slots

    shapes: dict[str, None] = {}
    for slot in load_slots(path):
        shapes.setdefault(_slot_signature(slot.prefix, slot.key, slot.fields), None)
    return list(shapes)


def _file_lines(paths: list[Path], sandbox: Path) -> list[str]:
    return [f"- {_q(_rel(path, sandbox))}" for path in paths]


def _editable_lines(paths: list[Path], sandbox: Path) -> list[str]:
    return [
        f"- {_q(_rel(path, sandbox))} — marker slots: "
        + ", ".join(_q(shape) for shape in _slot_shapes(path))
        for path in paths
    ]


def _has_upstream(sandbox: Path) -> bool:
    """Whether reference material was shipped into this sandbox.

    An ``upstream_source/`` directory counts only once it holds a file.
    """
    upstream = sandbox / "upstream_source"
    return upstream.is_dir() and any(path.is_file() for path in upstream.rglob("*"))


# The text each run carries for its mode: what the artifact is and how it is graded, with
# the lines that tell the model how to work left out.
PROOF_MODE_TASK = """\
## Your task in ``proof`` mode

``canonical : RepoImpl`` is the curator's reference implementation.
``Impl/*.lean`` is **frozen** in this mode — do NOT edit it.
The reference implementation is NOT guaranteed correct; the specs are the ground truth, and your job is to determine per spec whether ``canonical`` satisfies it.

For every spec ``S``, ``Proof/<Module>.lean`` contains a paired stub:

```
theorem prove_<bare_S>    : spec_<bare_S> canonical   := by sorry
theorem disprove_<bare_S> : ¬ spec_<bare_S> canonical := by sorry
```

(``<bare_S>`` = ``S`` with the ``spec_`` prefix stripped.)

**Fill exactly one of each pair.** Both outcomes are equally legitimate:

- ``prove_<bare_S>`` — the reference impl satisfies ``S``.
- ``disprove_<bare_S>`` — the reference impl violates ``S``.
  A concrete counter-witness (e.g. ``exact ⟨inputs, by decide⟩``) is sufficient; you need not refute the universally-quantified form.

``proof_aux`` / ``global_aux`` / ``imports`` are available for file-level helpers."""

CODEPROOF_MODE_TASK = """\
## Your task in ``codeproof`` mode

### Part A — Fill implementations in ``Impl/*.lean``

Every ``!benchmark code def=<fn>`` slot currently holds a single ``sorry``.
Replace each with a real implementation matching the declared signature (``abbrev <Fn>Sig := …`` directly above the ``def``).

- ``canonical`` wires the bundle fields to your stubs, so ``spec_S canonical`` is a proposition about YOUR code.
- ``Test.lean`` runs ``#guard`` conformance tests; ``lake build`` fails on any false assertion.
- Trivial values (``default`` / ``[]`` / ``0``) fail ``Test.lean`` — write real code.

### Part B — Discharge each spec in ``Proof/<Module>.lean``

For every spec ``S``, three stubs exist:

```
theorem prove_<bare_S> : spec_<bare_S> canonical                  := by sorry
theorem unsat_<bare_S> : ¬ ∃ impl : RepoImpl, spec_<bare_S> impl  := by sorry
theorem sat_<bare_S>   : ∃ impl : RepoImpl, spec_<bare_S> impl    := by sorry
```

**Fill exactly one per spec.**

- ``prove_<bare_S>`` — your implementation satisfies ``S``.
- ``unsat_<bare_S>`` — ``S`` is unsatisfiable by ANY impl.
  Reserve for specs that are actually broken.
- ``sat_<bare_S>`` — some impl satisfies ``S``.
  **Lone `sat_<S>` is NOT a pass** (graded ``unpaired_sat`` — trivially provable by exhibiting an ad-hoc impl, so it demonstrates nothing about YOUR code).
  Only counts when paired with a verified ``joint_unsat`` claim (Part C) that names ``S``.

### Part C (OPTIONAL) — Joint unsatisfiability

A set of ≥ 2 specs may be jointly unsatisfiable even though each is individually satisfiable.
``Proof/Joint.lean`` has one dormant slot for such claims.

To make the claim:

1. In the ``!solution`` body, replace ``specs=[<FILL: …>]`` with your list. No duplicates.
2. Uncomment the ``!benchmark claim`` block with ``joint_unsat <specs> by`` (same order).
   This only keeps the local file compiling; the grader discards it.
3. Fill the ``!benchmark proof`` block with a tactic body proving ``¬ ∃ impl, spec_a impl ∧ spec_b impl ∧ …``.
   The grader re-renders from your ``!solution`` list and this body.
4. Helper lemmas go in ``!benchmark proof_aux`` at file level, before the ``claim`` block.
5. Every listed spec must also have its ``sat_<bare_S>`` filled (that's what demonstrates the joint claim is non-trivial).

To skip: leave ``Joint.lean`` untouched. No penalty."""

MODE_TASKS: dict[Mode, str] = {"proof": PROOF_MODE_TASK, "codeproof": CODEPROOF_MODE_TASK}

REFERENCE_NOTE = """\
## Reference — original upstream source

The ``upstream_source/`` directory contains the original upstream implementation this benchmark was translated from (with a ``PROVENANCE.txt`` giving the exact repository and commit). It is provided purely as reference material to help you understand the intended behaviour; it is **not** part of the Lean project, is not built, and is not graded. You do not have to use it."""


def render_minivero_task(
    bench: Benchmark,
    sandbox_dir: Path,
    *,
    mode: Mode,
) -> str:
    """Return the task contract for one materialized sandbox.

    ``bench`` is the benchmark loaded from the trusted copy and ``sandbox_dir`` the
    sandbox rendered from it, as the runner passes them to the sandbox setup. Only the
    public benchmark shape is used.

    """
    if mode not in {"proof", "codeproof"}:
        raise ValueError(f"unsupported MiniVero mode: {mode!r}")
    if mode not in bench.modes_supported:
        raise ValueError(f"benchmark {bench.benchmark_id!r} does not support {mode!r}")

    sandbox = Path(sandbox_dir).resolve()
    modules = list(bench.iter_modules())
    n_specs = sum(len(module.specs) for module in modules)
    n_apis = sum(len(module.apis) for module in modules)
    package_names = ", ".join(package.name for package in bench.packages)
    module_names = ", ".join(module.name for module in modules)

    frozen_rel = [
        bench.root_hub_rel,
        bench.harness_rel,
        bench.test_rel,
        bench.lakefile_rel,
        "lean-toolchain",
    ]
    frozen_rel.extend(package.bundle_rel for package in bench.packages)
    frozen_rel.extend(module.spec_rel for module in modules if module.spec_rel)
    if mode == "proof":
        frozen_rel.extend(module.impl_rel for module in modules if module.impl_rel)

    frozen = _existing([sandbox / path for path in frozen_rel if path], "frozen files")
    editable = _existing(_editable_files(bench, sandbox, mode), "editable files")

    # A file that is both frozen and editable would make the contract contradict itself.
    overlap = sorted(
        {_rel(path, sandbox) for path in frozen} & {_rel(path, sandbox) for path in editable}
    )
    if overlap:
        raise ValueError(f"files listed as both frozen and editable: {overlap}")

    lines = [
        f"# MiniVero task contract — {bench.benchmark_id} ({mode} mode)",
        "",
        "The facts of this run, and the work this mode asks for. The rules for editing markers, ",
        "the checks that matter, the grading, and the completion condition are in the agent's own ",
        "instructions; what follows is what those instructions cannot know in advance — what this ",
        "project contains, which files and slots it has, and the description of this mode's work.",
        "",
        "## Benchmark scale",
        "",
        f"- Root project: {_q(bench.root_package)}.",
        f"- Packages: {len(bench.packages)} ({package_names}).",
        f"- Modules: {len(modules)} ({module_names}).",
        f"- API functions: {n_apis}.",
        f"- Specifications to discharge: {n_specs}.",
        f"- Evaluation mode: {_q(mode)}.",
        "",
        "## Project layout",
        "",
        "Frozen — must stay byte-identical:",
        *_file_lines(frozen, sandbox),
        "",
    ]

    if mode == "proof":
        lines.extend(
            [
                "Editable only via ``!benchmark`` marker slots:",
                *_editable_lines(editable, sandbox),
            ]
        )
    else:
        impl = [path for path in editable if "/Impl/" in _rel(path, sandbox)]
        proof = [
            path
            for path in editable
            if "/Proof/" in _rel(path, sandbox) and path.name != "Joint.lean"
        ]
        joint = [path for path in editable if path.name == "Joint.lean"]
        if len(impl) + len(proof) + len(joint) != len(editable):
            raise ValueError(f"editable file outside Parts A/B/C: {editable}")
        lines.extend(
            [
                "Editable only via ``!benchmark`` marker slots, by part:",
                "",
                "**Part A — implementations:**",
                *_editable_lines(impl, sandbox),
                "",
                "**Part B — proofs:**",
                *_editable_lines(proof, sandbox),
                "",
                "**Part C (optional) — joint claim:**",
                *_editable_lines(joint, sandbox),
            ]
        )

    upstream = _has_upstream(sandbox)
    if upstream:
        lines.extend(["", REFERENCE_NOTE])
    lines.extend(["", MODE_TASKS[mode]])
    lines.append("")
    return "\n".join(lines)



def render(benchmark: Path, sandbox: Path, mode: Mode, task_file: Path | None = None,
           source_context: str = "lean") -> Path:
    from vero.generation.benchmark import Benchmark
    from vero.generation.sandbox import create_sandbox
    sandbox = sandbox.resolve()
    task_file = (task_file or sandbox.parent / "MINIVERO_TASK.md").resolve()
    if task_file == sandbox or sandbox in task_file.parents:
        raise ValueError("task file must be outside the agent sandbox")
    if sandbox.exists():
        raise FileExistsError(f"sandbox already exists: {sandbox}")
    if task_file.exists():
        raise FileExistsError(f"task file already exists: {task_file}")
    bench = Benchmark(benchmark)
    create_sandbox(benchmark, sandbox, mode=mode, source_context=source_context,
                   prepare_dependencies=False)
    (sandbox / "INSTRUCTION.md").unlink(missing_ok=True)
    task_file.parent.mkdir(parents=True, exist_ok=True)
    task_file.write_text(render_minivero_task(bench, sandbox, mode=mode), encoding="utf-8")
    return task_file


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Render a Vero sandbox and an external task contract.")
    parser.add_argument("--benchmark", required=True, type=Path)
    parser.add_argument("--sandbox", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("proof", "codeproof"))
    parser.add_argument("--task-file", type=Path)
    parser.add_argument("--source-context", choices=("lean", "full"), default="lean")
    args = parser.parse_args()
    print(render(args.benchmark, args.sandbox, args.mode, args.task_file, args.source_context))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
