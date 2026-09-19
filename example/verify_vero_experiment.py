#!/usr/bin/env python3
"""Verify the pilot's lineage/evidence and export its auditable local report."""
import hashlib
import html
import json
import re
import shutil
import sys
from pathlib import Path

from verify_replay import Store, require
from vero_smoke import save


def verify(root):
    root = Path(root).resolve()
    manifest = json.loads((root / "experiment.json").read_text())
    store = Store(root / "trajectory")
    states = store.states()
    q = manifest["question"]
    question = states[q["state"]]
    require(manifest["cache_initially_empty"], "not a fresh initial cache")
    require(question["kind"] == "question", "not a question state")
    require(question["parent"] == q["instruction_state"], "question ancestry")
    require(states[q["instruction_state"]]["parent"] == q["checkpoint"], "checkpoint ancestry")
    for state in (q["checkpoint"], q["instruction_state"]):
        require(states[state]["workspace"] == question["workspace"], "question mutated workspace")
    require(question["question"]["text"] == q["text"], "question text mismatch")

    # Cache is private to this new run. Every saved response must have one matching
    # fresh cache entry; no recorded-action driver is involved.
    cached = {}
    def response_key(response):
        return json.dumps({k: response[k] for k in ("tool_calls", "content", "finish_reason", "usage")}, sort_keys=True)
    for path in (root / "trajectory/cache/v1").glob("*.json"):
        entry = json.loads(path.read_text())
        identity = json.loads(entry["key"])["model"]
        require(identity == {"model": "closeai/gpt-5.4-mini", "temperature": 0}, "model drift")
        for response in entry["responses"]:
            key = response_key(response)
            require(key not in cached, "duplicate cached response")
            cached[key] = response
    all_usage = {"input": 0, "output": 0, "total": 0}
    all_responses = 0
    for state in states.values():
        for event in state["appended"]:
            if event["type"] != "response":
                continue
            response = event["response"]
            key = response_key(response)
            require(key in cached, "model response missing from fresh cache")
            require(cached[key]["tool_calls"] == response["tool_calls"], "cache calls mismatch")
            require(cached[key]["content"] == response["content"], "cache content mismatch")
            require(cached[key]["usage"] == response["usage"], "cache usage mismatch")
            all_responses += 1
            for metric in all_usage:
                all_usage[metric] += response.get("usage", {}).get(metric) or 0

    answer = json.loads((root / "simulated-answer.json").read_text())
    context = json.loads((root / "answer-context.json").read_text())
    request = json.loads((root / "answer-request.json").read_text())
    require(json.loads(request["messages"][1]["content"]) == context, "answer context differs")
    require(request["model"] == "closeai/gpt-5.4-mini", "answer model differs")
    require(context["question"] == q["text"], "answer saw wrong question")
    files = store.files(question["workspace"])
    for name, text in context["files"].items():
        require(text.encode() == store.blob(files[name]), "answer source differs from question workspace")
    expected_feedback = []
    current = q["checkpoint"]
    for _ in range(3):
        expected_feedback.insert(0, [e for e in states[current]["appended"] if e["type"] == "observation"])
        current = states[current]["parent"]
        if current is None:
            break
    require(context["recent_tool_feedback"] == expected_feedback, "answer feedback differs")

    summaries = {}
    shared = q["prefix_seconds"] + q["seconds"] + answer["seconds"]
    transcript = []
    initial = store.files(states[manifest["root"]]["workspace"])
    for label in ("baseline", "control", "simulated"):
        record = json.loads((root / (label + ".json")).read_text())
        parent = record["start"]
        if label != "baseline":
            branch = manifest["branches"][label]
            require(parent == branch["reply_state"], "wrong branch start")
            reply = states[parent]
            require(reply["parent"] == q["state"] and reply["kind"] == "reply", "not a shared-question fork")
            require(reply["workspace"] == question["workspace"], "reply mutated workspace")
            require(reply["appended"] == [{"type": "observation", "call_id": question["question"]["call_id"],
                     "content": branch["reply"]}], "reply text mismatch")
            require(record["budget_seconds"] == manifest["comparison_budget_seconds"], "unequal budgets")
            if label == "simulated":
                require(branch["reply"].startswith(answer["answer"]), "simulated answer was edited")
            else:
                require(branch["reply"].startswith("No answer is available"), "control got advice")
        usage = {"input": 0, "output": 0, "total": 0}
        count = observations = failed_tools = 0
        replies = {r["question"]: r for r in record["replies"]}
        transcript.append("\n## " + label)
        for step in record["steps"]:
            state = states[step["state"]]
            require(state["parent"] == parent, "broken run lineage")
            transcript.append(f"\n### {step['state'][:12]} — {step['elapsed_seconds']:.3f} s")
            for event in state["appended"]:
                if event["type"] == "response":
                    count += 1
                    for metric in usage:
                        usage[metric] += event["response"].get("usage", {}).get(metric) or 0
                    transcript.append(event["response"].get("content") or "")
                    transcript.append("```json\n" + json.dumps(event["response"]["tool_calls"], ensure_ascii=False, indent=2) + "\n```")
                elif event["type"] == "observation":
                    observations += 1
                    content = event["content"]
                    if isinstance(content, dict) and content.get("exit_code") not in (0, None):
                        failed_tools += 1
                    # Include page content, offsets and read errors as well as raw
                    # executor output; a reread is not an empty tool result.
                    displayed = (content["output"] if isinstance(content, dict) and "output" in content
                                 else json.dumps(content, ensure_ascii=False, indent=2)
                                 if isinstance(content, dict) else str(content))
                    transcript.append("```text\n" + displayed + "\n```")
            parent = step["state"]
            if parent in replies:
                extra = replies[parent]
                require(states[extra["state"]]["parent"] == parent, "extra reply ancestry")
                require(extra["text"] == "No further answer is available. Continue solving independently.", "extra advice")
                parent = extra["state"]
        require(parent == record["terminal"], "wrong terminal")
        evaluation = manifest["baseline_evaluation"] if label == "baseline" else manifest["branches"][label]["evaluation"]
        leaf = states[evaluation["state"]]
        require(leaf["kind"] == "evaluation" and leaf["parent"] == parent, "wrong evaluation")
        require(not any(s["parent"] == evaluation["state"] for s in states.values()), "grading not terminal")
        evidence = store.files(leaf["evaluation"]["evidence"])
        for name in ("verdict.json", "artifact.json", "report.json", "report.md"):
            require(store.blob(evidence[name]) == (root / (label + "-evidence") / name).read_bytes(), "evidence export differs")
        require(leaf["evaluation"]["summary"] == evaluation["verdict"], "verdict mismatch")
        final = store.files(states[parent]["workspace"])
        start_files = store.files(states[record["start"]]["workspace"])
        changed = sorted(n for n in set(initial) | set(final)
                         if n.endswith(".lean") and initial.get(n) != final.get(n))
        segment_changed = sorted(n for n in set(start_files) | set(final)
                                 if n.endswith(".lean") and start_files.get(n) != final.get(n))
        impl = store.blob(final["Primepy/Impl/Primes.lean"]).decode()
        source_out = root / (label + "-source")
        for name in final:
            if name.endswith(".lean") and not name.startswith(".lake/"):
                dest = source_out / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(store.blob(final[name]))
        summaries[label] = {"turns": count, "observations": observations, "failed_tool_calls": failed_tools,
                            "usage": usage, "run_seconds": record["elapsed_seconds"],
                            "shared_seconds": 0 if label == "baseline" else round(shared, 3),
                            "charged_seconds": round(record["elapsed_seconds"] + (0 if label == "baseline" else shared), 3),
                            "stop_reason": record["stop_reason"], "terminal": parent,
                            "evaluation": evaluation, "changed_lean_files": changed,
                            "segment_changed_lean_files": segment_changed,
                            "implementation_code_markers": impl.count("@start code def=")}
    result = {"checks_passed": True, "model": manifest["model"], "benchmark": "primepy", "mode": "codeproof",
              "budget_seconds": manifest["budget_seconds"], "question": q,
              "comparison_budget_seconds": manifest["comparison_budget_seconds"],
              "runs": summaries, "unique_solver_responses": all_responses, "solver_usage": all_usage,
              "simulation_seconds": answer["seconds"], "simulation_usage": answer["raw_response"]["usage"],
              "simulation_reported_model": answer["raw_response"].get("model"),
              "binary_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / "bin").iterdir()},
              "limitations": ["one question, one continuation per arm; exploratory only",
                  "researcher-elicited question, selected after baseline; not spontaneous asking",
                  "same model simulated human; no real participants or human thinking-time measurement",
                  "branches share prefix and same time ceiling; early submission remains an outcome",
                  "report view context reconstructs a prospective request using the chosen report agent",
                  "no optional Vero LLM instance judge was used"]}
    save(root / "verification.json", result)
    (root / "transcript.md").write_text("# Fresh model transcript\n" + "\n".join(transcript), encoding="utf-8")
    return result


def render(root, result):
    root = Path(root)
    answer = json.loads((root / "simulated-answer.json").read_text())
    esc = html.escape
    names = {"baseline": "独立基线", "control": "同问题 · 无回答", "simulated": "同问题 · 模拟回答"}
    rows = []
    behaviors = []
    for label, run in result["runs"].items():
        score = run["evaluation"]["verdict"]["score"]
        report = "report.html" if label == "baseline" else "fork.html"
        rows.append(f'<tr><th>{names[label]}</th><td>{score["passed"]}/{score["total"]}</td>'
                    f'<td>{run["run_seconds"]:.1f} s</td><td>{run["charged_seconds"]:.1f} s</td>'
                    f'<td>{run["turns"]}</td><td>{run["usage"]["total"]:,}</td><td>{esc(run["stop_reason"])}</td>'
                    f'<td><a href="{report}#{run["terminal"][:12]}">轨迹</a> · '
                    f'<a href="{label}-evidence/report.md">官方评分</a></td></tr>')
        changed = ", ".join(run["segment_changed_lean_files"]) or "没有修改 Lean 文件"
        behaviors.append(f'<li><b>{names[label]}</b>：本段 {esc(changed)}；'
                         f'{run["observations"]} 条工具结果，{run["failed_tool_calls"]} 次非零退出；'
                         f'最终保留 {run["implementation_code_markers"]}/7 个实现槽起始标记。</li>')
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vero · 真实模型提问对照</title><style>
body{font-family:system-ui,"Microsoft YaHei",sans-serif;background:#f5f3ee;color:#172f2b;margin:0;line-height:1.7}
main{max-width:1160px;margin:40px auto;padding:0 24px}h1{font-size:32px;line-height:1.3}h2{font-size:21px}
.tag{font-size:13px;color:#44645c}section{background:white;padding:24px 28px;border:1px solid #deded5;border-radius:12px;margin:20px 0}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;border-bottom:1px solid #e5e7e3;padding:12px 8px;white-space:nowrap}
.scroll{overflow:auto}a{color:#126d64}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f7f4;padding:18px;font:14px/1.7 ui-monospace,monospace}
summary{cursor:pointer;font-weight:600;padding:8px 0}.muted{color:#5d6c65;font-size:14px}li{margin:6px 0}
</style><main><div class="tag">ALAYA / VERO / FRESH SAMPLING · 探索性实验</div>
<h1>同一个问题，回答有没有帮助？</h1>
<p>真实运行 primepy 的 <b>code-and-proof</b> 任务：完成 7 个素数相关 API 的代码，并证明 9 条固定规格。</p>
<p class="muted">模型：closeai/gpt-5.4-mini，经 XMCP 调用。这里是新采样与新评分；模拟回答者也使用同一模型。</p>
<section><h2>结果对照</h2><div class="scroll"><table><thead><tr><th>运行</th><th>通过规格</th><th>本段用时</th><th>含共同阶段</th><th>本段轮数</th><th>本段 tokens</th><th>停止原因</th><th>证据</th></tr></thead><tbody>'''+"".join(rows)+'''</tbody></table></div>
<p class="muted">30 分钟是上限，允许模型提前提交。两条对照从同一问题状态、相同工作区起跑，共享前缀、提问与模拟回答等待时间；评分时间另计。基线不是这对实验的无回答分支。</p></section>
<section><h2>行为证据</h2><ul>'''+"".join(behaviors)+'''</ul>
<p>运行时间更短本身不能代表效率提高；必须结合通过的规格与实际完成的工作判断。单次分支差异也不能直接归因于回答。</p></section>
<section><h2>发生了什么</h2><ol><li>独立基线停止原因：'''+esc(result["runs"]["baseline"]["stop_reason"])+'''；保留实际结果。</li>
<li>按预先设定的选择规则，从基线的普通状态继续，要求模型针对当前障碍提一个问题。</li>
<li>在同一问题状态建立两个回答子节点：无回答 / 同模型模拟开发者回答。</li>
<li>两条分支分别继续、独立评分。参考实现和评分器始终在 agent 工作区之外。</li></ol>
<p>这是研究者触发的一次提问。它验证流程与观察单次行为，不能据此推断真人收益或统计显著性。</p></section>
<section><h2>实际问题与原样回答</h2><p>下方保留模型在本次检查点实际提出的问题，以及同模型模拟回答。</p>
<details><summary>查看实际英文问题</summary><pre>'''+esc(result["question"]["text"])+'''</pre></details>
<details><summary>查看同模型模拟回答（未由研究者修订）</summary><pre>'''+esc(answer["answer"])+'''</pre></details>
<p class="muted">模拟回答耗时 '''+str(answer["seconds"])+''' 秒。这是模型接口时间，不能代表人的思考时间。回答者只看到问题、当前源码和最近三轮工具反馈，没有参考解或评分结果。</p></section>
<section><h2>检查轨迹</h2><p><a href="fork.html#'''+result["question"]["state"][:12]+'''">打开问题与两个回答分支</a> · <a href="report.html">独立基线轨迹</a> · <a href="transcript.md">完整文本轨迹</a></p>
<details><summary>复核信息与限制</summary><ul>'''+"".join('<li>'+esc(s)+'</li>' for s in result["limitations"])+'''</ul>
<p><a href="verification.json">机器核验结果</a> · <a href="experiment.json">实验设置及节点</a> · <a href="answer-context.json">模拟回答者实际看到的内容</a></p>
<p>轨迹的 view context 是用报告所选 agent 重建的后续请求：基线报告为 mini-swe，分支报告为 mini-ask。历史缓存保存规范化请求；若本次启用实验记录器，model-io/ 私有目录保存实际发送的 JSON 请求与原始响应。不要把重建视图当成历史请求快照。</p></details></section></main></html>'''
    (root / "index.html").write_text(page, encoding="utf-8")


def export(root, dest):
    root, dest = Path(root), Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    for path in root.iterdir():
        if path.is_file() and path.suffix in (".json", ".html", ".md"):
            shutil.copy2(path, dest / path.name)
        elif path.is_dir() and (path.name.endswith("-evidence") or path.name.endswith("-source")):
            shutil.copytree(path, dest / path.name, dirs_exist_ok=True)


if __name__ == "__main__":
    root = Path(sys.argv[1])
    result = verify(root)
    render(root, result)
    if len(sys.argv) > 2:
        export(root, sys.argv[2])
    print(json.dumps(result, ensure_ascii=False, indent=2))
