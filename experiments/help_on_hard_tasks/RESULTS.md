# 最终结果账本

2026-10-07 · 7 条筛选 + 2 条开放求助 = 9 条已采样、已终点评分的轨迹。数据源：[结果 JSON](evidence/results.json)、[HTTP 观察汇总](evidence/http-observed.json)。

## 逐条记录

| Run | 正式通过 | 成功响应数 | 已记录时间（秒） | 结束方式 | 捕获的 HTTP 429 |
| --- | ---: | ---: | ---: | --- | ---: |
| primepy-solo-01 | 0/9 | 44 | 2184.082 | 预算暂停后 stop、评分 | 无观察覆盖 |
| munkres-solo-01 | 6/19 | 52 | 2084.331 | 预算暂停后 stop、评分 | 无观察覆盖 |
| pythonconstraint-solo-01 | 19/20 | 79 | 1734.615 | 主动 submit | 无观察覆盖 |
| greenery-solo-01 | 3/26 | 46 | 1690.696 | 主动 submit | 无观察覆盖 |
| munkres-solo-02 | 0/19 | 41 | 1519.540* | 限流重试耗尽后人工 stop、评分 | 12 |
| pythonconstraint-solo-02 | 18/20 | 36 | 1906.202 | 预算暂停后 stop、评分 | 15 |
| greenery-solo-02 | 0/26 | 44 | 1806.064 | 预算暂停后 stop、评分 | 2 |
| greenery-help-01 | 5/26 | 49 | 939.649 | 主动 submit | 5 |
| primepy-help-02 | 8/9 | 80 | 1377.758 | 主动 submit | 9 |

合计 **471 次成功模型响应**，无 length 截断。两个 help 均有 4 次实际 time_budget 检查、0 次 ask_user 请求、0 个实际问题、0 条代理答复。solo 不提供 ask_user；其零问题不属于求助意愿的观测。九条均未通过整题全部规格，部分规格通过不等于整题完成。

首次求助时间、答复制作／等待时间、建议采纳、答复后的局部进展均不适用。真人答复与参与者均为 0。问题包详见 [QUESTIONS](QUESTIONS.md)。

## 时间和终止口径

固定参数为 XMCP `ds/deepseek-flash`、temperature=0、max_tokens=65536、output_tokens=65536、累计 1800 秒模型／工具时间及 1024 响应上限。框架在步骤边界检查预算，正在执行的单步可能超额，因此记录时间可超过 1800 秒。日志状态 paused 的运行均在终点评分前 stop，不再恢复。

表中时间来自日志记录的 effect elapsed，并非纯模型思考时间。成功请求中的服务重试等待也计入；不能把 HTTP Retry-After 头相加当作精确损失时间。*Munkres 复测最后抛出的 provider transient 错误没有 answered 事件，最后失败请求的等待未进入累计时间，1519.540 秒低于实际墙钟运行时间；没有借此续跑补时间。HTTP 观察是 best-effort，捕获数是已知记录，未捕获不等于未发生。

Greenery help 在时间工具返回还剩 969 秒之后遇到证明错误，939.649 秒时提交部分成果；Primepy help 在 1377.758 秒提交，名义剩余约 422 秒。两条均没有提问，且提交说明承认未完成证明。日志能确认动作，不能确定其内在动机，也不能仅凭余时判定停止不合理。

## 审计、筛选及偏差

- 九条初始请求审计均通过：正确模型、工具与初始 system guidance；正常初始工作区根事件后无人工消息或改动注入。缓存、数据和工作区各自独立。实际请求与执行过的工具分别计数。
- Munkres、Pythonconstraint 复测可能受限流主导，未纳入困难题 help。Greenery 带服务限制作为探索性困难题入选；Primepy 按协议保留参照，未被确认易。筛选证据快照仍为七条，不用 help 结果事后改写选择，详见 [SELECTION](SELECTION.md)。
- primepy-solo-01 的 `--samples 0` 在新 CLI 中表示无限，造成预定轨迹提前启动、响应上限未强制；1800 秒总限和模型／提示正确，实际 44 响应。保留该偏差，其余八条正确限制为 1024 响应。
- primepy-help-01 因准备环境漏 restic PATH 而失败，零采样，目录保留；primepy-help-02 是唯一实际 Primepy help 运行。最终少于原协议 10 条上限，不追加空出的试次。
- 两条 help 同时改变了求助工具和指导，且没有任何答复。不能用 solo/help 分差估计提示或答复的独立因果效果。

## 复核与材料

新版框架已通过编译、42 项相关 Lean 测试、11 项 Python 离线测试；零模型调用的 ask→reply→continue→grade 探针与微型评分正反例均通过。四题初始公开 Lean 模块编译检查通过。九条正式轨迹均已独立评分、重审实际初始请求；所有采样和只读观察已结束。

[中文导师汇报](REPORT-ZH.md) · [English report](REPORT-EN.md) · [三则公开案例](TRACE-EXAMPLES.md) · [Primepy help 公开证据](evidence/primepy-help-trace.json) · [冻结协议](PROTOCOL.md)
