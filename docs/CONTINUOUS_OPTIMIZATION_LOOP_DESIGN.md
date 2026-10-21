# 持续优化闭环设计（Continuous Optimization Loop）

| 项目 | 当前值 |
| --- | --- |
| 文档版本 | 1.0 |
| 更新日期 | 2026-10-21 |
| 状态 | 设计冻结；任务状态只维护于 [TASKS.md](../TASKS.md) |
| 关联设计 | [语言画像](LANGUAGE_PROFILE_DESIGN.md)、[零 prompt 拼音约束解码](superpowers/plans/2026-10-13-pinyin-constrained-decoder.md)、[技术设计](../TECHNICAL_DESIGN.md) §4.3 |

本文只维护「历史输入 → 异步推送模型服务 → 持续优化输出」这条闭环的目标、分层、
缺口、决策与任务分解；实现合同与状态分别在语言画像设计、TECHNICAL_DESIGN 与
TASKS.md 中维护。

## 1. 目标与非目标

### 目标

把用户的历史输入变成**持续变好的输出**：

- 判据只有运行时效果：候选与整句越来越像「这个人会打的内容」（采纳率、
  条件 top1 净增益、整句句准确率、延迟）。
- 闭环必须**可解释、可暂停、可撤回**：任何优化产物都能关掉、能清空、能回滚，
  且每个产物都能指回它的来源数据。

### 非目标

- 不做运行时在线自学习：权重更新只走离线、显式、可回滚的发布流程。
- 不做端到端平台的教师-学生体系：蒸馏只服务 `LM-002` 约束解码 SFT 这一条
  任务，不做领域 adapter、不做开放式续写（对齐 TASKS.md「不在当前任务表」）。
- 不把用户语料硬编码进模型权重：能用外挂层（L1/L2/L3）解决的个性化优先
  留在外挂层（见 D6）。
- 不改变现有可靠性边界：Rime 同步兜底、数字候选稳定、Secure Input
  fail-closed 全部继承。

## 2. 闭环四层与现状矩阵

```text
L-采集  历史提交 + 交互反馈  ──┐
                                │  (本地优先, 显式开启才上云)
L-异步推送 空闲固化循环 / 异步神经臂 ──┐
                                      ▼
L-优化产物  L1 短语库 / L2 用户 LM / L3 风格画像 / 模型权重(SFT)
                                      │
                                      ▼
L-回灌评估  候选排序·整句打分·混输解析  +  三条离线回归门
```

| 层 | 关键实现 | 现状 |
| --- | --- | --- |
| L-采集 | `HistoryStore.history_commits`（含 `HistoryCommitSource`）、固化水位线 | 历史提交已有；**句级建议的成对反馈缺失（G1）** |
| L-异步推送 | `rimeai_daemon/consolidation.py` 空闲固化循环、`rimeai_daemon/neural_sentence.py` 异步神经臂、broker 云压缩 | 已有（LP-004/005、LM-001） |
| L-优化产物 | L1 `phrasebook_entries`、L2 `user-lm.json.gz`、L3 `StyleProfile`、MLX 8-bit 基座 | 外挂三层已有；权重更新缺失（G4）；**蒸馏数据管道缺失（G2）** |
| L-回灌评估 | `rimeai_daemon/fused_lm.py` 排序融合、整句 beam 打分、`LP-008` 首评 | 注入已有；**闭环回归门缺失（G5）** |

### 缺口清单

| ID | 缺口 | 证据 |
| --- | --- | --- |
| G1 | 句级决策反馈不完整：采纳事件已有部分归因（本地 Tab 采纳记 `localSemantic`、云 Tab 采纳记 `cloudGenerated`），但四类关键反馈缺失——①建议「已展示但被忽略/覆盖/过期」的拒绝事件；②建议与最终选择的 request_id 级配对；③神经迟到帧采纳在 history 与同步 n-gram beam 不可区分（同记 `localSemantic`）；④按段接受后最终 Space 提交记 `rimeMain`（云端/神经归因丢失） | `SemanticSuggestionPipeline.swift` historySource 赋值点（.localSemantic/.cloudGenerated）；LM-001 reveal 记录的④；TASKS.md KBD-007「历史 source 归因为已知 v1 简化」 |
| G2 | 蒸馏数据管道缺失：`cloud_model.py` 的 `_decision_cache` 是进程内 LRU（上限 256），不可持久化、不可复现 | `rimeai_cloud_broker/cloud_model.py:188,358-360` |
| G3 | 外挂层三处缺口：L3 `signature_phrases` 未回灌 L1；L1 只增不淘汰（无容量上限、无时间衰减）；L2 计数聚合与固化压缩未实现 | LANGUAGE_PROFILE_DESIGN §4.3/§4.1；TASKS.md「L2 计数聚合与固化压缩（PLANNED）」 |
| G4 | 权重更新路径缺失：`LM-002` 只有一行 TODO，无数据、无配方、无门 | TASKS.md `LM-002` |
| G5 | 闭环评估门缺失：`LP-008` 首评只覆盖外挂层，模型层与端到端无统一离线门 | LANGUAGE_PROFILE_DESIGN §8 |

## 3. 关键设计决策

| ID | 决策 | 理由 |
| --- | --- | --- |
| D1 | 反馈采集**本地优先**：决策日志落本机 `language_profile/decision_log.db`，默认零上传；上云需独立开关，与 L3 云压缩开关分离 | 采集面覆盖每一次建议展示事件，暴露面比现有 L3 批量摘要大得多，必须默认关闭 |
| D2 | 反馈最小单元是 **(输入, 候选, 采纳结果)** 三元组；只留拼音串（≤256 字节）与结构化元数据，**不记**按键序列、上下文全文、候选池原文 | 与 PRD 隐私合同一致：日志不得记录按键、组合串、上下文、候选正文 |
| D3 | 训练数据必须**可复现**：决策日志 → 冻结数据集（数据集 sha256 + 生成脚本版本 + 源日志区间），训练与评估都绑定该 sha；模型制品锁文件引用数据集 sha | 沿用 `models/qwen2.5-0.5b.lock.json` / `models/qwen2.5-0.5b-mlx-8bit.lock.json` 惯例；无 sha 的质量数字不可复现 |
| D4 | 教师-学生分工固定：云端模型只在 `generate/abstain` 决策上提供软标签；本地约束解码器是学生；**云端生成文本不作金标** | 云端可纠出词典外的字，直接当金标会把不可对齐的字灌进学生（本地解码器受词典掩码约束，无法复现） |
| D5 | 权重更新**离线、显式、可灰度**：SFT 制品必须过三条离线门才能替换基座；替换是发布动作，不是运行时行为 | 运行时代码不得出现「悄悄加载用户训练出的权重」的路径 |
| D6 | **外挂层优先**：个性化优先落 L1/L2/L3；只有模型路径选择类错误才进 SFT | 外挂层可一键清除、可编辑、可导出；权重里的用户语料既不可编辑也不可精确撤回 |
| D7 | 一切产物可撤回：决策日志、短语库、画像、模型制品都可单独清除或回滚；模型制品替换保留上一版 | 与语言画像的导出/清除合同一致（D6 的必要配套） |

### 与既有任务表规则的边界

TASKS.md「不在当前任务表」写明：教师软标签蒸馏、领域 adapter 等只有在新的
真实数据证明必要时才新建任务。本设计的边界是：

- 允许新建的是 **LM-002 自己的数据供给前置**（LM-003 反馈采集、LM-004 数据管道），
  因为 LM-002 已在任务表内、且冻结基线已证明 76 个真实错误中 61 个是
  `model_path_miss`（模型路径选择），**没有反馈与数据管道则 LM-002 无法启动**。
- 不新建教师平台、领域 adapter、开放式续写类任务；LM-004 只产出 LM-002 需要
  的冻结数据集。

## 4. 任务分解

任务状态与完成条件在 TASKS.md 维护，下表只给落点与依赖。

### 阶段 A：反馈采集（闭环的传感层）

#### LM-003 决策日志与偏好对采集

| 落点 | 内容 |
| --- | --- |
| 新增 `rimeai_daemon/decision_log.py` | sqlite `language_profile/decision_log.db`；表 `decisions(id, created_at_ms, source, request_id, composition_id, revision, pinyin, suggestion, confidence, model_artifact_id, outcome, outcome_at_ms)`；`source ∈ {local_rank, local_sentence, neural_late, cloud, phrase_book, continuation}`，`outcome ∈ {pending, adopted, rejected, superseded, expired, ignored}`；索引 `(created_at_ms)`、`(source, outcome)` |
| `rimeai_daemon/neural_sentence.py` | `decode()` 成功返回处写 `outcome=pending` 记录（与 `sentence-late` 帧同 request_id） |
| `rimeai_daemon/server.py` | 同步 infer 返回（`ranked_candidate` / `sentence_suggestion`）按同样 schema 落日志 |
| daemon 协议（Swift `DaemonProtocol.swift`） | 新增 `sentence-feedback` 帧：`{request_id, outcome}`；Swift 在 Tab 采纳 / 选词覆盖 / composition 结束未采纳时上报 |
| 隐私 | 不写上下文全文、不写按键、不写 Secure Input 内容；拼音只取活跃段（≤256 字节）；默认不上云（D1） |

`decision_log` 进程归属（2026-10-21 已拍板）：**daemon 内置**——传感层贴事件源（`decode()` 与同步 `infer()` 同进程写 `pending`，零跨进程开销）；`sentence-feedback` 帧方向 Swift→daemon，与现有 request/迟到帧同连接；daemon 是输入法生命周期必经进程，传感层不依赖可选 broker（无凭据时不跑）；Secure Input 切分点＝Swift 端不发帧 + daemon 不存上下文全文。

云端 teacher 决策持久化（同日已拍板）：**broker 写穿**——`cloud_model.py` 云决策在本进程写穿至本机 `cloud-decisions.db`（`_decision_cache` 保留为内存命中层）；云建议的展示/采纳反馈由 Swift 经现有云连接回传 broker（帧语义同 `sentence-feedback`，request_id 即云请求 id）；daemon 的 decision_log 不含云 generate 文本（隐私面不扩大）；LM-004 读双库，两侧 request_id 空间天然分立不冲突。

依赖：无。**LM-004 与 LM-002 都阻塞在它后面。**

#### LM-004 离线蒸馏数据管道

| 落点 | 内容 |
| --- | --- |
| 新增 `tools/build_sft_dataset.py` | 输入：决策日志 + 持久化的云端决策记录；输出：冻结 jsonl（`{id, pinyin, chosen, rejected, weight, source}`）+ `datasets/sft-constrained-v1.lock.json`（数据集 sha256、生成脚本版本、源日志区间、样本数与去重统计） |
| 隐私 | 需用户显式触发「导出训练集」动作；导出文件 0600（与语言画像导出同口径） |
| 泄漏检查 | 生成即校验与冻结评测集（`.rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl`）零重叠，有重叠即失败退出 |
| 数据源边界 | **云端决策日志必须先持久化**（`cloud_model._decision_cache` 是进程内 LRU，不能作训练源）；已拍板（2026-10-21）：broker 写穿 `cloud-decisions.db`，LM-004 读 daemon `decision_log.db` + broker `cloud-decisions.db` 双库 |
| 最小可用规模 | 训练集是否够用（样本数、去重后规模、覆盖拼音模式数）在数据集生成时写入 lock 统计并评估；不足时明确报告「数据不足，不启动训练」，不用小样本硬跑 |

依赖：LM-003。

### 阶段 B：外挂层补齐（不涉及权重，收益快、风险低）

#### LP-009 L3 `signature_phrases` 回灌 L1
落点：`rimeai_daemon/consolidation.py` 语义阶段成功后，从 L3 画像读
`traits.signature_phrases` → 写 `phrasebook_entries`（`source='llm'`、
`protected=0`，沿用 `phrase_entry_id(domain, text)` 同一 id 规则）。
注意 Swift `PhraseBookStore` 是 schema owner，`source` 取值集合三侧必须一致
（daemon 写、Swift 读、导出三处同时校验）。
完成条件：同一画像 revision 不重复计数（幂等）；回灌短语可在独立建议位命中；
跨读音屏蔽与既有 L1 行为不回归。

#### LP-010 L1 时间衰减与容量上限
落点：`rimeai_daemon/consolidation.py` 统计阶段后新增淘汰步；半衰期按
`last_used_ms` 计算；`protected=1` 与 `source='user'` 豁免。
2026-10-21 前置分布报告（真实库 3348 auto 条目）：count 极端长尾
（p50=1、p75=2、p90=4、p99=18、max=261），数据窗口仅 ~10 天，时间衰减
参数不可校准。据此定值：容量上限 20,000（触发式淘汰至 19,000，按衰减分
最低的 auto 条目；当前 3348 远未触达）；半衰期 45 天为保守初值，待数据
≥60 天后重评；重评前不单独依赖时间衰减路径（淘汰仅由容量触发）。
完成条件：半衰期、容量上限、保护豁免、删除后计数不复活均有单测。

#### LP-011 L2 计数聚合与固化压缩
落点：`rimeai_daemon/user_lm.py` 计数聚合语义 + `rimeai_daemon/consolidation.py`
批处理压缩（连续 run 合并 ≤3 段/域）+ drain/throttle 接线。
完成条件：批内 SUM 语义稳定（乱序输入结果一致）、压缩后 L2 打分与压缩前
在冻结集上一致（**性能收益在 L2 评测里验证**——压缩是工程优化，不是质量目标）。

### 阶段 C：模型层（权重更新）

#### LM-002 约束解码 SFT

（TASKS.md 已有 TODO，此处补配方与门）

| 项 | 内容 |
| --- | --- |
| 靶 | `model_path_miss` 桶 61/76（词典召回与拼音对齐零损失，错误全在模型选路） |
| 数据 | LM-004 产出的冻结数据集（D3：绑定数据集 sha256） |
| 配方 | PinyinGPT 式 LoRA（软标签蒸馏为默认形态——学生是 0.5B 本地模型，教师是云端 glm-5.3-flash；LoRA 精调作为平行的低成本对照）；零 prompt、零 chat template 保持不变（TD-009） |
| 基座对照 | Qwen2.5 0.5B / 2B / 4B base，全部用同一冻结数据集与同一超参族 |
| 门 | ① 冻结集句准确率 ≥ 现制品 +2pp；② `model_path_miss` 桶下降 ≥50%；③ 词典基线已命中的 708 样本不得新增覆盖损失；④ p50 延迟 ≤ 现制品 ×1.2；⑤ 峰值 RSS ≤ 现制品 ×1.2。**门的数据划分**：①/③ 必须同时跑**冻结集**（`p0-librime-1.17.0-luna-simp.jsonl` test，974 样本）与**真实历史留出集**（80/20 时间切分，与 LP-008/LP-012 同口径），任一不达标即失败 |
| 制品 | MLX 8-bit + lock（含数据集 sha、训练超参、代码版本、上一版制品指针）；保留上一版以便回滚（D7） |

依赖：LM-004（→ LM-003）。基座对照可与 LM-003 并行。

### 阶段 D：闭环评估门

#### LP-012 闭环离线回归门
三条门，单命令产出报告，任一失败即非 `DONE-INTERNAL`：

1. **外挂层门**：`LP-008` 首评续期——条件 top1 净增益 ≥ +2pt、个人短语命中率
   ≥30%、泛化 gap ≤ 1.0、本地路径 P95 延迟回归 ≤ +1ms。
2. **模型层门**：冻结集 + 真实历史留出集（时间切分 80/20）上的句准确率、
   `model_path_miss` 桶、延迟与内存（与 LM-002 §门 的数据划分一致）。
3. **端到端门**：真实键盘冻结集 v3（`datasets/keyboard-interaction-v3.jsonl`，
   20 场景）交互切片全 1.0，与 `KBD-001` 同口径。

## 5. 数据合同与隐私

| 数据 | 位置 | 默认是否出机 | 清除 | 导出 |
| --- | --- | --- | --- | --- |
| 决策日志 | 本机 `language_profile/decision_log.db` | 否（D1，独立开关） | 一键清除（随语言画像清除） | 需显式「导出训练集」，0600 |
| 云端决策记录 | 本机 broker `cloud-decisions.db`（`_decision_cache` 写穿） | 否 | 随语言画像清除 | 仅作为 LM-004 输入（D1） |
| L1 短语库 | 本机 `phrasebook.db` | 否 | 一键 | 已有（聚合导出，≤50,000 条 + truncated 标记） |
| L2 用户 LM | 本机 `language_profile/user-lm.json.gz` | 否 | 一键 | 已有 |
| L3 风格画像 | 本机 broker profile 目录 | 仅固化批次 ≤24KB/域/轮 | 一键 | 已有 |
| 训练集 | 本机 `datasets/`（含 lock） | 否 | 一键 | 即数据集本身 |
| 模型制品 | `models/` + lock | 否 | 保留上一版，可回滚 | 随发行包 |

继承的硬边界：Secure Event Input 期间不采集反馈、不写历史、不触发固化、
不使用在途结果；凭据不进历史/诊断/请求体；反馈内容不进入任何云请求体。

## 6. 失败模式与对策

| 失败模式 | 后果 | 对策 |
| --- | --- | --- |
| 反馈噪声（用户随手改选被记为负例） | SFT 学到错误偏好 | 反馈只记「是否采纳该建议」，不推断「为什么不采纳」；权重按 outcome 分档，负例权重保守 |
| 决策日志无限增长 | 磁盘膨胀 | 环形裁剪（保留最近 N 天 + 容量上限），裁剪策略在任务里固定并可测 |
| 采集即上传（实现疏忽） | 隐私事故 | 默认关闭 + 上传路径独立开关 + 「默认零上传字节」断言进测试 |
| 训练集与评测集重叠 | 指标虚高 | 数据集生成即做泄漏检查，重叠非零即失败退出 |
| SFT 制品替换后质量回退 | 输出变差 | 三门不过不发布；保留上一版制品，可一键回滚 |
| L3 回灌把噪声短语灌进 L1 | 候选池污染 | 回灌短语进 `source='llm'` 且不参与自动频次累积；用户可一键停用/删除 |
| 反馈采集拖慢按键路径 | 输入延迟回归 | 采集为异步写（不阻塞按键线程），写入失败只丢一条记录不影响输入 |

## 7. 验收证据要求

每项任务的「已通过」必须绑定同一 revision 的 clean 命令与结果：

- Python：`uv run pytest`（相关子集 + 全量）全绿。
- Swift：`swift test --filter RimeAIInputCoreTests` 与 macOS
  `xcodebuild -project macos/RimeAIInputMethod.xcodeproj -scheme RimeAIInputMethod test`。
- 产物：机器可读报告（沿用 `.rimeai/reports/*.json`）与 lock 文件 sha。
- 真实键盘：沿用 `script/collect_real_keyboard_evaluation.sh` 自动收集器。

## 8. 不在本文范围

- 云端链路的放行（`CLOUD-001`）、公开发布（`RELEASE-001`）、语音资格
  （`VOICE-001`）、iOS（`IOS-001`）。
- 领域词库在线更新与更多领域（`LX-002`）。
- 端到端「实时在线学习」的可行性研究——本文只承诺离线闭环。
