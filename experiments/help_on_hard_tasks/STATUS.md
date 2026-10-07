# Current status

2026-10-08 更新（实验于 10-07 完成）：**本轮已完成，不再采样。** 新版 Alaya 适配、7 条 solo 筛选、2 条全新 help、9 条终点评分和根事件审计均完成。总计 471 次成功模型响应；两条 help 均无 ask_user 请求和实际问题；代理答复、真人答复均为 0；九条均无 length 截断。

阅读入口：[中文导师汇报](REPORT-ZH.md)、[English report](REPORT-EN.md)、[逐条结果](RESULTS.md)、[公开轨迹案例](TRACE-EXAMPLES.md)。正式得分：Greenery help 5/26，Primepy help 8/9。原定上限内少跑一条，最终固定 9 条，不使用第十条。

## 证据与限制

Munkres、Pythonconstraint 复测分别捕获 12、15 次 HTTP 429，未纳入困难题 help。Greenery 两次筛选为 3/26、0/26，有可见实现、验证及证明障碍，带服务干扰限定入选；复测捕获 2 次 429。Primepy solo 0/9，仅按协议保留参照，不能称已确认易题。完整依据见 [筛选记录](SELECTION.md)。solo 没有 ask_user，零提问不表示不愿求助。

两条 help 也受服务影响：Greenery 捕获 5 次 429，Primepy 捕获 9 次。只读观察可能漏采，首轮没有覆盖；不能宣称串行消除了限流。成功响应中的服务重试等待计入 effect elapsed；Munkres 最后抛出的 provider 错误没有 answered 事件，该次等待未计入日志累计时间，故其 1519.540 秒不是实际总墙钟时间。该运行已 stop 并评分，没有补时间。

Greenery solo 复测的 2 次限流已更正此前仅查看最新成功响应造成的漏报，最终记录以 [HTTP 汇总](evidence/http-observed.json) 为准。困难与未求助的可见事实不等于已知模型内在动机；两条 help 的得分提高不构成答复效果证据。

## 验收和运行偏差

已验证 Alaya 编译、42 项 Lean 相关测试、11 项 Python 离线测试（8 runner／根事件、1 统计、2 HTTP 元数据）；零模型调用的 ask/reply/continue/grade 探针；微型 Vero 空答案 0/1、正确答案 1/1；四题初始公开 Impl/Spec/Proof/Joint/Bundle/Harness 编译。九条最终实际初始请求和根事件均重审通过。

Primepy solo 首轮误用 samples=0 启动：新版该值表示无限响应数，1800 秒上限正确，实际 44 响应；保留此偏差。其余八条使用明确的 1024 响应上限。primepy-help-01 因 restic PATH 缺失在准备阶段失败，零模型调用；实际参照运行是 primepy-help-02。未丢弃任何已采样轨迹。

初始 position=0 的 changed 是正常工作区根事件；manifest.root 实际是 new 返回的 session tip。审计分别核查二者及其后有无人工注入，不把正常根事件当作干预。维护版 runner 修正了审计，WSL 的采样 runner 与 binary 在本轮保持冻结。

## 交付与环境

后续真人 [设计](HUMAN-STUDY-DESIGN.md) 和 [记录表](HUMAN-STUDY-FORM.md) 已准备；[自然问题包为空](QUESTIONS.md)。没有招募、发消息或实施真人研究。后续建议不自动启动新实验。

上游基线 c2aefbea19de06b53357c5b8ee505c859043cc03，分支 codex/help-on-hard-tasks。全部模型／评分进程已结束，只读 HTTP 观察器已停止；Docker 无需重启。XMCP 凭据已从本机 DSH store 找回并实际认证成功，按用户要求记住了位置，项目不保存密钥值。

原始证据在 WSL /home/xht/.cache/alaya-demo/help-hard-20261007/：src/ 是冻结构建与采样 runner，runs/ 是独立轨迹，preflight-v2/ 是候选审核，probe-002/ 与 tiny-acceptance.json 是工程验收，http-observations-*.jsonl 是只读观察。Git 仅保存实验源文件、协议和审阅证据；原始模型流量、内部推理、完整工作区及 trusted 解答不纳入。旧研究与 PR #50 保持原样；2026-10-08 用户追加授权推送本分支并创建新 PR。

## PR 兼容性说明（2026-10-08）

发布前合入主分支 f152241，按新的 Builtin catalog 注册实验 agent。本轮采样仍来自 c2aefbe 基线的冻结构建，报告与证据未改写；完整实验源码归档提交为 68cefa9。HelpStudy 单独保留当时的 task wording、显式 time_budget 和原提交行为，没有引入后来 stock MiniVero 的自动报时、提交检查或新增 Persistence 文案。因此本报告不能评价这些新机制的效果。兼容更新仅做离线验证，没有新增模型采样。

兼容验证通过：lake build、43 项相关 Lean 测试、11 项 Python 离线测试；固定公开示例的初始消息与冻结实验构建逐字一致（7819 字节）。没有重新采样。
