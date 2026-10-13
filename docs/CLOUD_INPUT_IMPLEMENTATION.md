# macOS 可选云增强合同

更新日期：2026-10-13
状态：`IMPLEMENTED / EXTERNAL VALIDATION PENDING`

本文只维护当前云候选、凭据、历史与隐私合同。全局产品状态见
[../TASKS.md](../TASKS.md)。

## 1. 产品边界

- 当前上游为智谱官方 Coding Plan 直连，固定 endpoint
  `https://open.bigmodel.cn/api/coding/paas/v4`（产品决策 2026-10-12，
  取代此前的本地 Ollama 方案），排序模型 `glm-5.3-flash`。
- 云增强默认关闭，只有本机存在有效 API Key 且用户启用后才运行；凭据
  以 Authorization Bearer 头发送给上述 endpoint。
- 对话走 OpenAI 兼容 `/chat/completions`：单轮交换（system 消息承载
  不变契约，user 消息承载逐请求数据），响应取 `choices[0].message.content`
  纯文本；请求带 `temperature: 0`、`max_tokens` 与
  `thinking: {"type": "disabled"}`（直连 endpoint 不支持
  reasoning_effort，该开关是唯一有效禁用思考的方式，防止 token 预算
  耗尽在 reasoning 上返回空 content）；`finish_reason=length` 按本地
  abstain 处理，不计云错误。
- 历史向量检索依赖同一 endpoint 的 OpenAI 兼容层 `/v1/embeddings`
  （`text-embedding-v4`，512 维）——embedding 是真批量接口，`index`
  用于对齐多个输入，保持数组结构。后台向量化当前由
  `EMBEDDING_INDEXING_ENABLED = False` 硬停用，检索自动降级为
  FTS，不影响输入。
- 云端唯一的推理决策是 generate（整句生成）或 abstain。整句拼音
  约束是单一策略（设计变更 2026-10-13：三档约束移除，仅保留原
  loose 行为，无用户设置、无请求字段）：prompt 允许模型修正任意
  错别输入（前后鼻音/平翘舌/错别字母），输出为 ≤128 字符文本、
  允许中英混排与标点（broker 侧只拒控制字符 `<0x20` 与 `0x7F`；
  `>0x20` 标量与分段非空段由 Swift 客户端最终把关）；pinyin 字段
  无条件接受 `[A-Za-z']`（混合输入串是大写字母的来源，≤256 UTF-8
  字节）。组句质量由模型保障——规则进 prompt，歧义由
  用户在候选面板取舍。
  broker 不再装载 Rime 字典、不做拼音对齐校验（PinyinGuard 仅保留
  于本地路径）。统一的结构门：非空、≤128 字符无控制字符、segments
  分隔符按序复现、recent_context 尾部复读检查（与
  continuation 策略镜像）。未协商 `text-generation` 能力的旧客户端
  仍 fail-closed 降级 abstain。
- generate 路径的 prompt 不携带候选池：模型直接根据拼音与 recent
  context 推导整句（segments 时连同各段 separator/committed_text
  一次往返）；生成文本恰与某候选相同视为真实
  的一致意见，保持 generate 由客户端可见去重。
- 模型契约是纯文本输出（content 即句子，空/纯空白表示模型放弃组句）：
  大括号包裹的内容会宽容解包（模型违约回显 JSON 字面量时按 abstain
  而非上屏 JSON）；结构门（长度、可打印、分隔符、
  复读）失败 → abstain；通过 → generate（confidence 恒为 1.0，
  reason 恒为 typo_match）。
- Rime 和本地 daemon 不依赖云端；任何云错误都回退既有本地结果。

## 2. 请求合同

| 项目 | 当前值 |
|---|---|
| 请求载荷 | 拼音 + segments（可选）+ recent_context + history_snippets；不再发送候选池与 pool hash（产品决策 2026-10-12：生成契约不读候选池；broker 过渡期对旧客户端仍接受并回显 `candidate_pool_hash`） |
| prompt 视图 | 拼音 + 光标前最近 120 字 context（无汉字则不下发）；不携带候选池、历史 snippet 或画像 hint。模型只回纯文本句子，采纳只过结构门；输出跑飞被 max_tokens 截断时本地按 abstain 处理，不计云错误 |
| 上下文 | recent 最多 600 字，检索 snippet 最多 8 条；仅纳入已确认上屏的文本——`raw_pinyin` 来源（回车把未转换拼音原样上屏）的记录保留在库中供审计/导出，但不写入会话上下文、不进入 recentText 与 snippet 检索 |
| 拼音约束 | 单一策略（无请求字段）：输入 `[A-Za-z']` ≤256 字节；组句纠错与混排由模型负责，本地只做结构门 |
| embedding | `text-embedding-v4`，512 维 |
| 总时限 | 从候选/历史构建开始 30s 墙钟（协议上限 30000ms；本地开发调试临时放宽，正式口径 8s/8000ms） |
| 云输出 | `generate`（含 text）或 `abstain` |

请求绑定 request/composition/session/revision、model、history
generation 和绝对 deadline。输入法构建历史的耗时也计入 30s 墙钟，只把
剩余预算交给 broker。取消或已过期请求不得离开客户端；已发送结果回到输入法后
还要重新验证全部绑定。

## 3. 进程边界

- 输入法通过 owner-only UDS 与 `rimeai-cloud-broker` 通信。
- broker 是唯一允许访问模型 endpoint 的 RimeAI 进程；仅放行固定的
  https 直连 endpoint，loopback `http://localhost:11434/v1` 为仅有
  例外。
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
- 完整 prompt/响应默认不落日志。显式诊断开关：存在
  `~/.config/rimeai/cloud-debug` 标记文件时，broker 把请求/响应全文
  写入 `runtime/rimeai-cloud-broker.log`（prompt 含用户键入的拼音与
  上下文，Authorization 头永不记录）；删除标记立即恢复静默。
- 永久清除会删除历史、提升 generation，并阻止旧索引或在途结果复活。
- 导出使用 JSONL；凭据不进入导出。
- Secure Event Input 时不构造云请求、不写历史，并取消在途本地与云结果。
- 宿主自绘但未启用系统 Secure Event Input 的敏感字段属于平台已知限制。

## 6. 质量与发布门

代码存在不等于效果放行。真实冻结集和目标网络必须同时满足：

- 候选覆盖率绝对提升至少 5 个百分点；
- 纠错 precision 至少 98%（单一策略下对全部请求生效，无档位
  opt-in 区分）；
- 至少 95% 请求在 800ms 内完成；
- stale commit、Secure 推理和 Secure 历史写入均为 0；
- 断网、代理、限流、费用、凭据撤销和跨应用旧结果矩阵通过；
- Developer ID、双进程 Release、公证、清洁机安装升级回滚通过。

当前尚无这组完整外部证据，因此不得宣传云增强已经通过质量或公开发布门。
