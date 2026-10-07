# 困难任务中的求助实验

阅读入口：**[中文导师汇报](REPORT-ZH.md) · [English report](REPORT-EN.md)**。

本轮已完成 7 条 solo 筛选、2 条全新 help。Greenery help 5/26、Primepy help 8/9，两条都没有求助；代理答复和真人答复均为 0。服务限流等限制见报告，不能把这两个样本概括为所有 agent 都不提问。

详细材料：[逐条结果](RESULTS.md)、[公开轨迹案例](TRACE-EXAMPLES.md)、[协议](PROTOCOL.md)、[当前状态](STATUS.md)、[筛选依据与服务局限](SELECTION.md)、[空问题包说明](QUESTIONS.md)。本目录是新版 Alaya 上的新实验；旧报告和 PR #50 保持原样。

问题是：**当模型遇到经过筛选的真实解题障碍时，它会不会主动提问，答复是否被采用？** 当前回答者是 AI 助手代理，不能据此比较不同背景真人的帮助效果。

## 复现入口

Linux/WSL，使用仓库 `lean-toolchain` 编译 Alaya；安装 Docker、restic >=0.17，Python 3；从 DSH YAML 读取凭据时还需 PyYAML。代理与评分环境固定为协议中的 Lean 4.29.1 镜像。现有 `prepare.py` 基于本机历史镜像派生更新的评分镜像，不能宣称无需外部镜像的一键复现。

```sh
lake build
lake exe tests agents/help-study agents/ask-user agents/mini-vero app/catalog
python3 experiments/help_on_hard_tasks/prepare.py --source "$PWD" --root "$SCRATCH/preflight" --vero "$TRUSTED_VERO"
python3 experiments/help_on_hard_tasks/run.py probe --binary "$PWD/.lake/build/bin/alaya" --root "$SCRATCH/probe"
python3 experiments/help_on_hard_tasks/run.py seed --binary "$PWD/.lake/build/bin/alaya" \
  --root "$SCRATCH/runs/TASK-solo-01" --task-root "$SCRATCH/preflight/tasks/TASK" \
  --arm solo --guidance experiments/help_on_hard_tasks/prompts/solo.md
python3 experiments/help_on_hard_tasks/run.py advance --binary "$PWD/.lake/build/bin/alaya" \
  --root "$SCRATCH/runs/TASK-solo-01"
python3 experiments/help_on_hard_tasks/run.py grade --binary "$PWD/.lake/build/bin/alaya" \
  --root "$SCRATCH/runs/TASK-solo-01"
```

`advance` 从进程环境读取 `XMCP_API_KEY`；可用 `--credential-file /path/to/DSH/.credentials.yaml` 读取 `refs.XMCP_API_KEY`。不把密钥放入命令参数。`seed` 不调用模型。新版 CLI 的 `--samples 0` 是**无上限**，不可用作试运行开关。

help 运行使用新的 absent root、`--arm help` 和 `prompts/help.md`。等待问题时，先保存本次公开上下文，在独立副本验证建议，创建答复文本与 provenance JSON（`author_type=assistant_proxy`、`answer_begin`、`public_context`、`validation`、`limitations`），然后：

```sh
python3 experiments/help_on_hard_tasks/run.py reply --binary "$BINARY" --root "$RUN" \
  --answer "$ANSWER" --provenance "$PROVENANCE"
python3 experiments/help_on_hard_tasks/run.py advance --binary "$BINARY" --root "$RUN"
```

不要把这一步变成另开分支的实验；不要在 reply 后重置累计时间。`grade` 必须在终点执行。若发生运行环境中断，保留所有日志，确认最后已记录的 entry 后再恢复同一运行；不能把缓存重放算成新样本。

## 后续真人材料

本轮自然问题包为空。后续真实模型问题产生后才制作问题包，注明提问时的预算、公开代码和错误、希望提供的帮助。试验用代理答案单独存放，不能给正式被试预先看，不拿研究者补写的问题冒充模型问题。[研究设计](HUMAN-STUDY-DESIGN.md) 与 [记录表](HUMAN-STUDY-FORM.md) 尚未实施。

未来背景记录可包括 Lean 使用经验、相关算法／数学知识、编程经验；不能仅按学历或年级断言谁更能帮助模型。答复表记录理解题意、答复原文、自信程度、用时、参考资料及验证方法。真实招募、分组和研究协议是后续工作，本轮不执行。

## 审阅与服务观察

`audit_completed.py --binary "$BINARY" --runs "$RUNS"` 对已评分运行重验实际初始请求与日志根，不采样。`summarize.py` 导出正式得分、实际问题、工具请求与执行数、停止类型、截断及注入审计。manifest 的 root 是 new 命令最后返回的 session tip；真正初始工作区是 position=0 的 changed 事件，两者分开核验。当前维护版只修正审计；本轮使用的采样 runner 与 Lean binary 保持冻结。最终统计保存为 `evidence/results.json`；`evidence/screening-progress.json` 保留七条筛选快照。

`observe_http.py --study-root "$SCRATCH" --output "$SCRATCH/http-observations.jsonl"` 可只读观察本研究 curl 子进程的 HTTP 状态和有单位的 Retry-After 头；不读取凭据、请求、响应正文或进程环境。该旁路可能漏过短进程，未观察到 429 不能证明没有限流。`summarize_http.py INPUT... --output OUTPUT` 合并观察、去重并报告覆盖范围。原始 provider 错误可能带账号标识，不能直接复制进报告或 Git。

服务错误抛出且没有 answered 事件时，其耗时不一定计入日志累计时间。保留中断证据，不能靠重新启动获得隐性额外预算。基础设施若主导结果，则不纳入有效困难判定；不补跑凑数。脚本离线检查：`python3 -m unittest discover -s experiments/help_on_hard_tasks -p 'test_*.py'`。
