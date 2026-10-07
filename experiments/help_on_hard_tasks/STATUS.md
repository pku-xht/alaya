# Current status

2026-10-07：已适配上游 `c2aefbea19de06b53357c5b8ee505c859043cc03`，当前分支 `codex/help-on-hard-tasks`。Docker 正常运行。XMCP 凭据已从本机 DSH store 读取且实际采样可用；值不写入本目录。

已完成：

- study-only agent 编译成功；42 项 Lean 相关测试、4 项 Python runner 防护测试通过。
- 无模型调用的 ask/reply/continue/grade 探针通过；微型 Vero 空答案 0/1、正确答案 1/1。
- Primepy、Munkres、Pythonconstraint、Greenery 的公开结构、规格、证明模块均编译通过。初始 sorry 导致的 Test 求值失败单独记录。
- Primepy、Munkres 首次 solo 筛选已开始；后两题仅准备起点。当前尚无正式任务得分，无自然求助／代理答复／真人答复结果。

Primepy 的启动偏差已写入协议：新版 `samples=0` 意为无响应上限；该条仍有 1800 秒总限，保留为首次参照，不删掉重跑。以后新起点只 new/call，实际采样明确 1024 上限。未采样的失败准备目录不算试次。

本机原始证据：WSL `/home/xht/.cache/alaya-demo/help-hard-20261007/`；编译源 `src/`，候选审核 `preflight-v2/`，生命周期探针 `probe-002/`，评分验收 `tiny-acceptance.json`，实际轨迹 `runs/`。这些路径是原始证据而非 Git 交付内容。

下一步：结束并独立评分四题首轮；按协议复测不完整候选；审阅实质障碍后，最多两道困难题与一条较易参照从头开展 help 运行。
