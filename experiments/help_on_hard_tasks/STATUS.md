# Current status

2026-10-07：新版 Alaya 适配和离线验收完成；六条运行已独立评分，第七条 Greenery solo 复测正在串行运行。help 阶段尚未采样。

| 任务 | solo 首轮 | solo 复测 |
| --- | --- | --- |
| Primepy | 0/9，预算终止 | 协议不重复参照 |
| Munkres | 6/19，预算终止 | 0/19，HTTP 429 重试耗尽后停止 |
| Pythonconstraint | 19/20，主动提交 | 18/20，受限流影响后预算终止 |
| Greenery | 3/26，主动提交 | 运行中 |

Munkres 和 Pythonconstraint 复测分别已观察到 12、15 次 429，不能排除基础设施主导失败，本轮不以它们进入困难题 help。完整依据见 [筛选记录](SELECTION.md)。首轮无 HTTP 旁路观察，不能回溯断言其是否限流。所有已评分运行均无输出长度截断。solo 没有 ask_user，零提问不表示不愿求助。

已验证：Alaya 编译、42 项 Lean 相关测试、4 项 runner 防护测试；零模型调用的 ask/reply/continue/grade 探针；微型 Vero 空答案 0/1、正确答案 1/1；四题初始公开 Impl/Spec/Proof/Joint/Bundle/Harness 编译。统计与 HTTP 观察器另有离线测试。

Primepy 首轮的 samples=0 启动偏差保留：新版该值表示无限响应数，其 1800 秒总限正确，实际仅 44 响应。之后 seed 仅 new/call；采样明确 1024 响应上限。Primepy help 的一次 restic PATH 准备失败没有模型调用；修正环境后已准备新 root，未采样。

初始日志的 changed 是 Alaya 的正常工作区根事件；manifest 中 root 字段实际记的是 new 命令返回的 session tip。审阅统计分别记录这两者，检查真正根事件后是否存在消息或工作区注入，不把正常根事件算作人工干预。

当前上游基线 c2aefbea19de06b53357c5b8ee505c859043cc03，分支 codex/help-on-hard-tasks。Docker 正常；XMCP 凭据已从本机 DSH store 找回并实际认证成功，位置已按用户要求安全记住，密钥值不保存于项目。

原始证据：WSL /home/xht/.cache/alaya-demo/help-hard-20261007/。src/ 是冻结构建与采样 runner；runs/ 是独立轨迹；preflight-v2/ 是候选审核；probe-002/ 与 tiny-acceptance.json 是工程验收；http-observations-*.jsonl 是只读观察。Git 仅保存审阅汇总和可维护源文件。旧研究与 PR #50 不改，不 push。

下一步：结束并评分 Greenery 复测，再按合格候选情况进行全新 help；每个真实问题由助手代理回答，累计预算不重置。真人参与和代理答复目前均为 0。
