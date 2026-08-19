# macOS 可选 Qwen 云增强实现说明

日期：2026-08-14  
状态：**CHECKED IMPLEMENTATION / EXTERNAL EFFECTIVENESS PENDING**

## 结论

macOS 输入法已经接入一个明确选择加入的阿里云 Qwen 增强路径。它不替代
Rime，也不解除本地 daemon 的永久 Offline Lock。未配置 API Key 时，不启动
云 broker、不写长期历史，输入行为与既有本地路径一致。

配置 Key 后，输入法继续立即显示 Rime 候选，并行运行本地排序和云请求。云端
只能从请求携带的候选 ID 中返回一个结果；输入法再次核对请求、会话、组合串、
修订号、候选池哈希、模型、历史 generation、Secure Event Input 和 800ms
绝对截止时间后，才允许把它显示在既有的单一显式建议位。过期或非法结果直接
丢弃，不阻塞 Space 的 Rime 兜底。

客户端先完成同 UID UDS 的版本、endpoint、模型和能力握手，再发送包含输入
正文的推理帧。候选池和历史快照构建也计入同一个 800ms 上限，实际发给 broker
的是剩余预算；取消或被新按键替代且尚未发送的请求不会离开客户端。

## 固定合同

| 项目 | 固定值或上限 |
|---|---|
| endpoint | `https://newapi.wwcn.fun/v1` |
| 可选模型 | `glm-5.3`（禁用 thinking，`max_tokens: 100`） |
| embedding | `text-embedding-v4`，512 维 |
| 凭据 | `~/.config/rimeai/cloud.env`（0600，`RIMEAI_CLOUD_API_KEY=`），不写 plist、数据库或日志 |
| 精确候选 | Rime Top-30 |
| 总候选池 | 精确候选 + 受限单编辑错拼候选，去重后最多 50 |
| 上下文 | recent 最多 600 字，相关片段最多 8 条 |
| 截止时间 | 从候选/历史构建开始的绝对上限 800ms；向 broker 传递剩余预算 |
| 云输出 | `keep`、`abstain` 或请求内一个 candidate ID |
| 接纳门 | 精确候选至少 0.85；模糊候选至少 0.98 |

API Key 的持久副本只存在 `~/.config/rimeai/cloud.env`（KEY=VALUE、目录 0700、
文件 0600，写入走同目录临时文件 + 原子替换）。打字路径直接读取该文件；若
文件暂时不可读，只跳过当次云请求，不会擅自关闭用户已启用的云增强设置。
读取成功后仅通过 `0600`、同 UID 校验的私有 UDS 临时交给 broker，broker
不再调用 `/usr/bin/security`，也不会把凭据写入 Qwen prompt、历史或日志。
明文文件的权衡：0600 只防其他本地用户，不防同 UID 进程；文件可能进入
Time Machine 或 dotfile 同步工具——这是为绕开 ad-hoc 签名下 Keychain
ACL 不稳定所做的有意取舍。从旧版本升级时需重新录入一次 API Key；旧
Keychain 条目可用
`security delete-generic-password -s fun.wwcn.inputmethod.RimeAI.qwen`
清理。

## 历史与隐私

只要 API Key 已配置，RimeAI 的成功上屏文本就会跨应用写入本机明文 SQLite
WAL；本地 AI 开关、应用禁用策略和 strict/standard/smart 档位不会关闭这条
历史。记录无限期保留，包含上屏时间、来源和宿主标识，用于近期窗口、FTS
召回与 embedding/HNSW 检索。HNSW 文件只保存向量图和行标识，原文仍在
SQLite。控制中心提供 JSONL 导出和永久清除；清除会提升 generation，使在途
请求与旧索引结果失效。近期文本、FTS 片段和 generation 在同一个数据库串行
快照中读取；HNSW 文件也绑定 generation，清除与索引保存竞态不会复活旧图。
移除 API Key 只停用云能力，不隐式删除历史。

macOS Secure Event Input 激活时不构造云请求、不记录历史，并取消在途本地及
云推理。该保证针对系统可观察到的 Secure Event Input；宿主自行绘制但未启用
系统安全输入的敏感控件无法由输入法可靠识别。

## 进程与发布边界

- 本地 `rimeai-daemon` 保持拒绝 `AF_INET`/`AF_INET6` 的进程级网络守卫。
- `rimeai-cloud-broker` 是独立 LaunchAgent、独立 0600 UDS 和独立启用标记，
  是唯一允许访问固定云端 endpoint 的进程。
- debug/release 安装、回滚和卸载脚本已包含云 broker；release 构建器会生成
  第二个签名可执行文件，验证器会检查其签名、权限和帮助探针。
- 新的双进程 release 归档尚未完成真实 Developer ID、公证、干净机器安装与
  回滚证据，因此不能沿用旧 release 归档的已验证声明。

## 质量门与当前证据

`rimeai-eval evaluate-cloud` 接受逐条 JSONL 观察值，并同时计算：基线/扩展候选
覆盖率、覆盖增益、纠错 precision、端到端 Top-1、800ms 内完成率/P95、stale
commit、Secure 推理与 Secure 历史写入。默认放行门为：

- 候选覆盖率绝对提升至少 5 个百分点；
- 纠错 precision 至少 98%；
- 至少 95% 请求在 800ms 内完成；
- stale commit、Secure 推理、Secure 历史写入均为 0。

本地 24M 基线已冻结在
[`baselines/macos-local-int8-test-v1.json`](baselines/macos-local-int8-test-v1.json)，
记录 conditional Top-1 94.5501%、数据/模型哈希和复现命令。它是既有证据的
机器可读锁，不是本轮重新执行得到的结果。

本轮本地验证：

| 检查 | 结果 |
|---|---|
| `swift test` | 53 tests passed |
| Xcode arm64/macOS 14 controlled-librime build | passed |
| 云 broker/evaluation/history/HNSW Python 测试 | included in the full Python suite |
| 完整 Python 测试 | 107 passed |
| `uv lock --check`、Python compile、shell syntax、plist lint | passed |

尚未提供 API Key 或真实语料，因此没有声称云路径已经通过覆盖率、98% 纠错
precision 或 800ms 网络门。上线前还必须在冻结的真实错拼/正常输入集合、目标
地区网络和最低支持 Mac 上运行评测，并完成恶化率、费用、限流、断网、代理、
凭据撤销、Secure Event Input 和跨应用陈旧结果矩阵。
