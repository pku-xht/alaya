# Current status

2026-10-07：已适配上游 `c2aefbea19de06b53357c5b8ee505c859043cc03`，当前分支 `codex/help-on-hard-tasks`。Docker 正常运行。XMCP 凭据已从本机 DSH store 读取且实际采样可用；值不写入本目录。

已完成：

- study-only agent 编译成功；42 项 Lean 相关测试、4 项 Python runner 防护测试通过。
- 无模型调用的 ask/reply/continue/grade 探针通过；微型 Vero 空答案 0/1、正确答案 1/1。
- Primepy、Munkres、Pythonconstraint、Greenery 的公开结构、规格、证明模块均编译通过。初始 sorry 导致的 Test 求值失败单独记录。
- 首批正式评分：Primepy 0/9（5 个 build_error、4 个 unfilled），Munkres 6/19（其余 13 个 unfilled）。两条均由预算终止，无输出长度截断；求助工具在筛选中关闭。不能将这里的零提问解释为不愿求助。
- Primepy 44 次响应、累计 2184.082 秒；Munkres 52 次响应、2084.331 秒。末次模型请求跨过预算，返回后的工具调用没有执行。Primepy 末次调用 430.113 秒、1141 输出 token；仅凭这些记录无法解释服务侧耗时原因，也不能当作“思考了七分钟”。
- Pythonconstraint、Greenery 的首轮 solo 正在运行。Munkres 的全新复测起点已准备，尚未采样。help 阶段尚未开始，助手代理答复和真人答复均为 0。

Primepy 的启动偏差已写入协议：新版 `samples=0` 意为无响应上限；该条仍有 1800 秒总限，保留为首次参照，不删掉重跑。以后新起点只 new/call，实际采样明确 1024 上限。未采样的失败准备目录不算试次。

本机原始证据：WSL `/home/xht/.cache/alaya-demo/help-hard-20261007/`；编译源 `src/`，候选审核 `preflight-v2/`，生命周期探针 `probe-002/`，评分验收 `tiny-acceptance.json`，实际轨迹 `runs/`。这些路径是原始证据而非 Git 交付内容。

首批审阅统计见 `evidence/screening-first-batch.json`。Primepy 本轮没有完成，不能称作已经确认的易题。

下一步：结束并独立评分后两题首轮；按协议复测不完整候选；审阅实质障碍后，最多两道困难题与一条参照从头开展 help 运行。
