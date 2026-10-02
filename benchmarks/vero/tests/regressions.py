#!/usr/bin/env python3
"""Adversarial grader acceptance tests. All mutations stay in a new --output directory."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil

from _harness import FIXTURE, ROOT, run, state_hash


def fill(path, key, body, prefix="benchmark"):
    text = path.read_text()
    pattern = (r"(-- !" + prefix + r" @start " + re.escape(key) +
               r"[^\n]*\n).*?(?=-- !" + prefix + r" @end " + re.escape(key) + r"(?:\n| ))")
    text, count = re.subn(pattern, lambda m: m.group(1) + body + "\n", text, flags=re.S)
    assert count == 1, (path, key, count)
    path.write_text(text)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--grader-image", required=True)
    p.add_argument("--agent-image", required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    alaya = out / "alaya"
    shutil.copy2(ROOT / ".lake/build/bin/alaya", alaya)
    uid = f"{os.getuid()}:{os.getgid()}"
    data = out / "audit"
    results = []

    def render(name, mode, benchmark=FIXTURE):
        directory = out / name
        directory.mkdir()
        run("docker", "run", "--rm", "--network", "none", "--user", uid,
            "-e", "HOME=/tmp", "-v", f"{directory}:/rendered",
            "-v", f"{benchmark}:/benchmark:ro", args.grader_image,
            "python", "/opt/alaya-vero/render.py", "--benchmark", "/benchmark",
            "--sandbox", "/rendered/source", "--mode", mode)
        return directory / "source"

    def grade(name, source, mode, status, passed, total, benchmark=FIXTURE, command=None):
        root = state_hash(run(alaya, "root", source, "--task", name,
                              "--agent", "mini-vero", "--set", f"agent.mode={mode}",
                              "--model", "gpt-oss-120b",
                              "--image", args.agent_image, "--data", data).stdout)
        command = command or f"python /opt/alaya-vero/grade.py --mode {mode} --benchmark /grader"
        result = run(alaya, "eval", root, "--input", benchmark,
                     "--grader-image", args.grader_image, "--grader", command,
                     "--timeout", "60", "--data", data,
                     codes=({"pass": 0, "fail": 1, "error": 2}[status],))
        evaluation = state_hash(result.stdout)
        record = json.loads((data / "states" / f"{evaluation}.json").read_text())["kind"]["evaluation"]
        assert record["status"] == status, record
        assert sum(c["ok"] for c in record["checks"]) == passed, record
        assert len(record["checks"]) == total, record
        report = None
        if status != "error":
            report = json.loads(run(alaya, "cat", evaluation, ".vero/report.json",
                                    "--data", data).stdout)
        results.append({"name": name, "evaluation": evaluation, "record": record, "report": report})
        print(f"{name}: {status}, {passed}/{total} TAP checks", flush=True)
        return report

    proof = render("proof", "proof")
    proof_file = proof / "TinyTrivial/Proof/Core.lean"
    fill(proof_file, "proof def=disprove_idNat", "  intro h\n  have h1 := h 1\n  cases h1")
    grade("false-disproof-original", proof, "proof", "fail", 0, 1)
    impl = proof / "TinyTrivial/Impl/Core.lean"
    fill(impl, "code def=idNat", "  fun _ => 0")
    grade("false-disproof-tampered", proof, "proof", "fail", 0, 1)

    fill(proof_file, "proof def=disprove_idNat", "  sorry")
    fill(proof_file, "proof def=prove_idNat", "  intro n\n  rfl")
    grade("correct-proof-tampered-impl", proof, "proof", "pass", 1, 1)
    # All implementation slots are frozen, not just the principal code body.
    for slot in ("imports", "global_aux", "code_aux def=idNat"):
        fill(impl, slot, "this is deliberately invalid Lean")
    grade("correct-proof-invalid-impl-aux", proof, "proof", "pass", 1, 1)
    impl.unlink()
    impl.symlink_to("/grader/TinyTrivial/Impl/Core.lean")
    grade("proof-ignores-impl-symlink", proof, "proof", "pass", 1, 1)
    impl.unlink()
    grade("proof-ignores-deleted-impl", proof, "proof", "pass", 1, 1)
    # A proof-file symlink must still be rejected.
    linked = out / "linked-proof"
    shutil.copytree(proof, linked, symlinks=True)
    linked_file = linked / "TinyTrivial/Proof/Core.lean"
    linked_file.unlink()
    linked_file.symlink_to("/grader/TinyTrivial/Spec/Core.lean")
    grade("reject-proof-symlink", linked, "proof", "fail", 0, 1)

    grade("harness-timeout", proof, "proof", "error", 0, 0,
          command="python /opt/alaya-vero/grade.py --mode proof --benchmark /grader --lake-timeout 0")

    # Add a second spec to exercise the actual joint compiler path.
    trusted = out / "trusted-two-specs"
    shutil.copytree(FIXTURE, trusted)
    manifest = json.loads((trusted / "manifest.json").read_text())
    spec = dict(manifest["packages"][0]["modules"][0]["specs"][0])
    spec["name"] = spec["source_theorem"] = "spec_idNat2"
    manifest["packages"][0]["modules"][0]["specs"].append(spec)
    (trusted / "manifest.json").write_text(json.dumps(manifest))
    with (trusted / "TinyTrivial/Spec/Core.lean").open("a") as f:
        f.write("\ndef spec_idNat2 (impl : RepoImpl) : Prop :=\n  ∀ n : Nat, impl.tiny.idNat n = n\n")
    codeproof = render("codeproof", "codeproof", trusted)
    fill(codeproof / "TinyTrivial/Impl/Core.lean", "code def=idNat", "  fun n => n")
    pf = codeproof / "TinyTrivial/Proof/Core.lean"
    for name in ("idNat", "idNat2"):
        fill(pf, f"proof def=prove_{name}", "  intro n\n  rfl")
    grade("two-correct-specs", codeproof, "codeproof", "pass", 2, 2, trusted)
    joint = codeproof / "TinyTrivial/Proof/Joint.lean"
    fill(joint, "def=joint_unsatisfiability", "-- specs=[spec_idNat, spec_idNat]", "solution")
    report = grade("joint-duplicate-keeps-specs", codeproof, "codeproof", "fail", 2, 3, trusted)
    assert report["summary"]["passed_specs"] == 2 and report["joint"]["status"] == "duplicate"
    fill(joint, "def=joint_unsatisfiability", "-- specs=[spec_idNat, spec_idNat2]", "solution")
    fill(joint, "proof def=joint_unsatisfiability", "  sorry")
    report = grade("joint-sorry-keeps-specs", codeproof, "codeproof", "fail", 2, 3, trusted)
    assert report["summary"]["passed_specs"] == 2 and report["joint"]["status"] == "sorry"

    # The adapter reads its vocabulary from the pinned Vero, and a status outside it is an
    # error verdict rather than a silent zero. A Vero rename would otherwise be indistinguishable
    # from a model that failed every specification.
    vocabulary = run("docker", "run", "--rm", "--network", "none", "--entrypoint", "python3",
                     args.grader_image, "-c",
                     "import sys; sys.path.insert(0, '/opt/alaya-vero'); import grade; "
                     "print(sorted(grade.spec_vocabulary()[0])); print(sorted(grade.joint_vocabulary()))")
    assert "'passed'" in vocabulary.stdout and "'no_claim'" in vocabulary.stdout, vocabulary.stdout
    (trusted / "_rename_status.py").write_text(
        "import sys\n"
        "sys.path.insert(0, '/opt/alaya-vero')\n"
        "import vero.evaluation.runner as runner\n"
        "original = runner.run_evaluation\n"
        "def patched(**kwargs):\n"
        "    result = original(**kwargs)\n"
        "    for spec in result.report.specs:\n"
        "        spec.status = 'provably_valid'\n"
        "    return result\n"
        "runner.run_evaluation = patched\n"
        "from grade import main\n"
        "raise SystemExit(main())\n")
    grade("unknown-spec-status-is-an-error", codeproof, "codeproof", "error", 0, 0, trusted,
          command="python /grader/_rename_status.py --mode codeproof --benchmark /grader")
    (trusted / "_rename_joint.py").write_text(
        "import sys\n"
        "sys.path.insert(0, '/opt/alaya-vero')\n"
        "import vero.evaluation.runner as runner\n"
        "original = runner.run_evaluation\n"
        "class Joint:\n"
        "    status = 'inconclusive'\n"
        "def patched(**kwargs):\n"
        "    result = original(**kwargs)\n"
        "    result.report.joint = Joint()\n"
        "    return result\n"
        "runner.run_evaluation = patched\n"
        "from grade import main\n"
        "raise SystemExit(main())\n")
    grade("unknown-joint-status-is-an-error", codeproof, "codeproof", "error", 0, 0, trusted,
          command="python /grader/_rename_joint.py --mode codeproof --benchmark /grader")

    for stage in ("axioms", "joint", "compiler-signal"):
        # Fault injection changes the actual subprocess timeout at the selected
        # stage, not its return value or the verdict. All earlier stages still run.
        driver = trusted / "_force_error.py"
        driver.write_text(
            "import sys\nfrom vero.evaluation import lake\n"
            "original = lake._run\n"
            "def injected(cmd, **kwargs):\n"
            f"    stage = {stage!r}\n"
            "    if stage == 'compiler-signal':\n"
            "        return original(['/bin/sh', '-c', 'kill -TERM $$'], **kwargs)\n"
            "    if ((stage == 'axioms' and 'AxiomCheck_' in ' '.join(cmd)) or\n"
            "        (stage == 'joint' and 'JointCheck.lean' in ' '.join(cmd))):\n"
            "        kwargs['timeout'] = 0\n"
            "    return original(cmd, **kwargs)\n"
            "lake._run = injected\n"
            "sys.path.insert(0, '/opt/alaya-vero')\n"
            "from grade import main\nraise SystemExit(main())\n")
        grade(f"{stage}-error", codeproof, "codeproof", "error", 0, 0, trusted,
              "python /grader/_force_error.py --mode codeproof --benchmark /grader")
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"{len(results)} adversarial cases passed; evidence: {out}")


if __name__ == "__main__":
    main()
