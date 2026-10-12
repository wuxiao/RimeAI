# 用户语言画像设计

> 本文只维护语言画像（Language Profile）的学习目标、分层模型、固化循环、
> 注入点与数据合同；产品范围见 [`PRD.md`](../PRD.md)，总体架构见
> [`TECHNICAL_DESIGN.md`](../TECHNICAL_DESIGN.md)，任务状态见
> [`TASKS.md`](../TASKS.md)。

| 项目 | 当前值 |
|---|---|
| 文档版本 | 0.1（设计定稿，未实现） |
| 更新日期 | 2026-10-11 |
| 状态 | 设计已确认：混合压缩、固化后删原文、画像可见可编辑、第一版分域 |

## 1. 目标与非目标

### 目标

让输入法**学习用户的语言习惯**：中英混搭、文言与古诗词、特定口语与术语、
接词序列习惯与文体偏好。评判标准只有运行时效果——候选与整句越来越像
"这个人会打的内容"；原始打字记录是否全量保留不是目标，只是原料。

### 非目标

- 不做逐条全量记忆的展示；固化后的原文按合同淘汰。
- 不微调神经排序器权重；学习产物全部是独立于 24M 模型的外挂层。
- 不改变现有可靠性边界：Rime 兜底、数字候选稳定、fail-closed 全部继承。
- 不做跨用户、跨设备上传或共享。

## 2. 概念模型：三层产物 + 一个固化循环

```text
打字历史（原料，滚动窗口，可淘汰）
   │  空闲固化循环（统计必跑；LLM 压缩可选）
   ▼
L1 短语库   这个人常打的"词"        —— 候选池直通、混输词表、云 prompt
L2 用户 LM  这个人的接词序列习惯     —— 排序融合、整句打分
L3 风格画像 这个人"怎么说话"        —— 云请求 system context、风格偏置
```

原始历史只保留"未固化滚动窗口"（见 §5 淘汰规则）；长期资产是三层产物，
全部本地存储、可导出、可清除、用户可见可编辑。

## 3. 分域策略

用户明确选择第一版分域。为避免数据稀疏，域是**两层结构 + 冷启动回退**：

- 域集合：`global` 域 + 每个显式映射的 bundleId 独立域。设置页维护
  `bundleIdentifier → domain` 映射；未映射的 app 全部计入 `global`。
- 冷启动规则：某域累计 commit `< 50` 时不为该域建立独立产物，记录直接
  归入 `global`；达到阈值后第一次固化时才建域。
- 查询链：L1 检索 `当前域 → global` 合并（域命中权重更高）；L2 用
  两层插值（§4.2）；L3 每域一份画像 + 一份 `global` 画像。
- 设置页支持域改名、合并、删除（删除域即将其记录并回 `global`）。

## 4. 数据模型

存储与现有 history 数据库同目录，新增 `language_profile/` 子目录；全部
SQLite/JSON、无服务依赖。

### 4.1 L1 短语库（phrasebook）

```text
entries(
  id TEXT PRIMARY KEY,          -- 文本+域 内容寻址
  domain TEXT NOT NULL,
  text TEXT NOT NULL,           -- 可含中英混排
  pinyin_keys TEXT NOT NULL,    -- 字母段序列，与 HistoryCommit.pinyin 同构
  count INTEGER NOT NULL,
  first_seen_ms INTEGER, last_used_ms INTEGER,
  source TEXT NOT NULL,         -- auto | user | llm
  protected INTEGER DEFAULT 0   -- 用户手动添加/保留，永不自动淘汰
)
```

- 无条目数上限；淘汰用带时间衰减的频次分，低于阈值自动降级删除，
  `protected=1` 与 `source='user'` 豁免。
- 拼音精确/规范化匹配即进候选池（独立建议位，不移动数字候选），
  同时作为混输 resolver 的个人词表——**取代**现有 256 个个人英文词
  上限（迁移：既有词导入为 `source='user', protected=1`）。

### 4.2 L2 用户语言模型（UserNGram）

- 每域一个计数文件 + 一个 `global` 计数文件；阶数与现有
  `ngram_ranker` 基线一致；单条 commit 计数设频次上限，防单一短语
  淹没分布。
- 融合公式（daemon 内）：

  `P = λ1·P_base + λ2·P_user_global + λ3·P_user_domain`

  λ 按各模型有效样本量做收缩式自适应（贝叶斯收缩）；域无数据时
  λ3→0，`global` 数据少时 λ2→0，自动退回现基线行为。

### 4.3 L3 风格画像（profile）

```text
{
  "schema_version": 1,
  "domain": "global",
  "revision": 12,
  "generated_at_ms": ...,
  "generator": "glm-5.3-flash@cloud" | "local",
  "traits": {
    "register": [...],        // 文体倾向：文言/书面/口语 + 权重
    "cn_en_mixing": ...,      // 混输比例与典型模式
    "punctuation_habits": [...],
    "sentence_templates": [...],
    "vocabulary_domains": [...],
    "signature_phrases": [...] // 回灌 L1 候选
  },
  "locked_fields": []          // 用户锁定字段，LLM 不得覆盖
}
```

- 更新方式：增量摘要 + 旧画像 → LLM merge → `revision+1`；保留最近
  N 版可回滚；merge 失败保留旧版。
- 用户在设置页可编辑并锁定字段；`signature_phrases` 经确认后写入 L1。

### 4.4 HistoryStore 改动

- `history_commits` 增加 `consolidation_state`：`raw → consolidated`；
  新增固化水位线（watermark）记录"已完成 L1/L2 且（完成 L3 或 L3 显式
  跳过）"的最大 commit id。
- 检索上下文来源改为：滚动窗口内原文（近 600 字）+ L1 高频短语 +
  画像摘要；已固化原文不再参与 LIKE/embedding 检索。

## 5. 固化循环（空闲压缩）

| 项 | 合同 |
|---|---|
| 触发 | 无组合态且 ≥10 分钟无击键，或每日定时；进程内单例锁 |
| 执行者 | 统计固化（L1/L2）在本地 daemon；L3 LLM 压缩在 cloud broker（复用现有后台循环模式） |
| 范围 | 仅处理 `raw` 且早于滚动窗口（7 天）的增量 |
| 预算 | 单轮 ≤30s，超时分批 |

流水线：

1. **统计固化**（本地必跑、幂等）：增量更新 L1 频次与 L2 计数。
2. **语义固化**（可选）：无云凭据或用户关闭时显式跳过；否则批量摘要
   → merge 画像 → 回灌 `signature_phrases`。
3. **淘汰**：仅当该批完成统计固化 **且**（完成 L3 或 L3 显式跳过）才
   删除原文行并 bump generation，防止旧索引或在途结果复活。

失败处理：LLM 失败不阻塞统计，但该批保留原文等待下轮；任何一步崩溃由
水位线保证下轮续跑。Secure Event Input 期间不触发固化。

## 6. 运行时注入点

| 注入点 | 来源 | 规则 |
|---|---|---|
| 候选池 | L1 | 拼音匹配进独立建议位；不移动数字候选（继承 REQ-KBD-02） |
| 混输 resolver | L1 | 取代个人英文词表，中文/混排片段同权 |
| 本地排序融合 | L2 | §4.2 插值进 daemon 融合分 |
| 整句 decoder | L2 | beam 打分用同一融合 LM；L3 风格特征二期再入 |
| 云请求 | L1+L3 | 当前域高频短语与画像摘要进入请求上下文；决策类型不变（仍只能选池内 ID / 受约束生成） |

## 7. 隐私与安全合同

- 继承：Secure Input 不写入、不固化；凭据不落历史/诊断；generation
  失效机制。
- 新增：L3 云压缩会把滚动窗口外的批量原文发送至已配置网关，仅当用户
  在设置中开启"云压缩"（默认开，可在设置关闭后退化为纯本地统计固化
  + 不更新画像）；请求不带凭据字段之外的数据。
- 画像、短语库、L2 计数全部可一键导出 JSON 与永久清除（bump generation）。
- 用户编辑与锁定优先于任何自动学习结果。

## 8. 评估方案

- 数据：真实使用历史时间切分——前 80% 固化为学习产物，后 20% 做测试。
- 指标与首评门（待首评校准）：
  - 条件 top1 净增益：在现有 +48.03% 基线之上 ≥ +2pt；
  - 个人短语命中率（测试集中命中 L1 条目）≥ 30%；
  - 本地路径 P95 延迟回归 ≤ +1ms；
  - 固化单轮 ≤30s；云压缩单轮费用低于现有 choose 请求预算。
- A/B：同冻结集关闭学习层对照；画像注入 on/off 各跑一轮。

## 9. 实现阶段（入 TASKS.md，编号 LP-xxx）

| ID | 范围 |
|---|---|
| LP-001 | HistoryStore：consolidation_state、水位线、淘汰与 generation |
| LP-002 | L1 短语库存储 + 设置页管理（查看/编辑/删除/保护） |
| LP-003 | L2 UserNGram 计数、两层插值融合进 daemon |
| LP-004 | 固化循环调度与本地统计流水线 |
| LP-005 | L3 画像 schema、merge、云压缩 job（混合策略） |
| LP-006 | 运行时注入：候选池、混输、排序、云请求 |
| LP-007 | 分域映射、冷启动回退、域管理 UI |
| LP-008 | 时间切分评估管线与门；PRD/技术设计修订 |

## 10. 需要修订的既有文档

- PRD 4.1"这不是通用个人学习或反馈训练闭环"与"256 个本地个人英文词"
  条款改为语言画像范围描述。
- PRD 4.2 与 `docs/CLOUD_INPUT_IMPLEMENTATION.md`：新增云压缩决策与
  历史淘汰合同（原"跨应用长期保留"改为滚动窗口 + 固化产物）。
- PRODUCT_DESIGN.md：设置中心新增"语言画像"页信息架构。
