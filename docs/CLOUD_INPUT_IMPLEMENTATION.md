# macOS 可选云增强合同

更新日期：2026-08-24
状态：`IMPLEMENTED / EXTERNAL VALIDATION PENDING`

本文只维护当前云候选、凭据、历史与隐私合同。全局产品状态见
[../TASKS.md](../TASKS.md)。

## 1. 产品边界

- 当前服务为 `wwcn New API Gateway`，固定 endpoint
  `https://newapi.wwcn.fun/v1`，默认排序模型 `glm-5.3-flash`，
  可选 `glm-5.3`。
- 文件和类中的 `qwen` 名称是历史遗留，不代表当前阿里云 Qwen 配置。
- 云增强默认关闭，只有本机存在有效 API Key 且用户启用后才运行。
- 云端只能返回本次候选池中的 ID，不能自由生成、扩写或静默改写文本。
- Rime 和本地 daemon 不依赖云端；任何云错误都回退既有本地结果。

## 2. 请求合同

| 项目 | 当前值 |
|---|---|
| 精确候选 | Rime Top-30 |
| 总候选池 | 精确候选 + 受限单编辑错拼，去重后最多 50 |
| 上下文 | recent 最多 600 字，检索 snippet 最多 8 条 |
| embedding | `text-embedding-v4`，512 维 |
| 总时限 | 从候选/历史构建开始 800ms |
| 云输出 | `keep`、`abstain` 或池内 candidate ID |
| 接纳门 | 精确候选至少 0.85；模糊候选至少 0.98 |

请求绑定 request/composition/session/revision、候选池摘要、model、history
generation 和绝对 deadline。输入法构建候选与历史的耗时也计入 800ms，只把
剩余预算交给 broker。取消或已过期请求不得离开客户端；已发送结果回到输入法后
还要重新验证全部绑定。

## 3. 进程边界

- 输入法通过 owner-only UDS 与 `rimeai-cloud-broker` 通信。
- broker 是唯一允许访问固定 HTTPS endpoint 的 RimeAI 进程。
- 本地 `rimeai-daemon` 继续拒绝 `AF_INET`/`AF_INET6`。
- UDS 和 0600 文件只隔离其他本地用户，不抵御 hostile same-UID 进程。

## 4. 凭据

API Key 只保存在 `~/.config/rimeai/cloud.env`：

- 配置目录 0700、文件 0600；
- 内容使用 `RIMEAI_CLOUD_API_KEY=`；
- 同目录临时文件 + 原子替换；
- 不写入 plist、设置导出、数据库、prompt、历史、日志或诊断；
- 输入法按需读取并经 UDS 交给 broker，broker 只在进程内存中使用。

这是明文用户配置文件，不是 Keychain。它可能被同 UID 进程、用户备份或同步工具
读取；启用 UI 必须披露该边界。

## 5. 历史与隐私

云端配置后，成功上屏记录写入本机明文 SQLite WAL，用于 recent、FTS 和向量
检索。记录包含宿主标识、时间、来源、拼音与提交文本，并跨应用长期保留。

- 移除 API Key 只停用云增强，不自动删除历史。
- 永久清除会删除历史、提升 generation，并阻止旧索引或在途结果复活。
- 导出使用 JSONL；凭据不进入导出。
- Secure Event Input 时不构造云请求、不写历史，并取消在途本地与云结果。
- 宿主自绘但未启用系统 Secure Event Input 的敏感字段属于平台已知限制。

## 6. 质量与发布门

代码存在不等于效果放行。真实冻结集和目标网络必须同时满足：

- 候选覆盖率绝对提升至少 5 个百分点；
- 模糊纠错 precision 至少 98%；
- 至少 95% 请求在 800ms 内完成；
- stale commit、Secure 推理和 Secure 历史写入均为 0；
- 断网、代理、限流、费用、凭据撤销和跨应用旧结果矩阵通过；
- Developer ID、双进程 Release、公证、清洁机安装升级回滚通过。

当前尚无这组完整外部证据，因此不得宣传云增强已经通过质量或公开发布门。
