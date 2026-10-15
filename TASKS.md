# RimeAI 开发任务

| 项目 | 当前值 |
|---|---|
| 更新日期 | 2026-10-13 |
| 产品发布状态 | `NOT RELEASED` |
| 当前工作树状态 | 当前功能边界按可审查提交收口；产品仍不可发布 |
| 当前最高优先级 | 推进 `KBD-001` 真实键盘效果闭环；P1B 语言画像数据层与 UI 已收口，待真机冻结集复评 |

本文件是唯一任务状态源。PRD、产品设计、技术设计和专项协议不再维护重复
checkbox 或路线状态。

## 状态定义

| 状态 | 含义 |
|---|---|
| `DONE-INTERNAL` | 内部范围已实现；不代表公开发布 |
| `IN-PROGRESS` | 已有工作树实现，仍在收口或验收 |
| `TODO` | 尚未开始或没有当前完成证据 |
| `BLOCKED` | 依赖前置修复、外部凭据、设备、语料或审批 |
| `DEFERRED` | 明确不在当前发布主线 |

## P0：恢复可复现工作树

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| BUILD-001 | `DONE-INTERNAL` | 恢复受控 librime XCFramework header 合同 | 3 个 slice 的公开 headers 已恢复并纳入 artifact lock；fresh SwiftPM、macOS、iOS build 均不依赖环境头文件路径 |
| BUILD-002 | `DONE-INTERNAL` | 修复 shell 入口与 harness 可执行位 | tracked 入口和被嵌套调用的 shell 脚本为 `100755`；直接调用及 release contract harness 通过 |
| BUILD-003 | `DONE-INTERNAL` | 固定 iOS 工程唯一生成源 | `ios/project.yml` 使用显式源文件清单；独立 regeneration check 与生成的 pbxproj 完全一致 |
| VERIFY-001 | `DONE-INTERNAL` | 为当前完整工作树建立 clean 验证基线 | 同一工作树快照的 fresh Swift/Python、macOS、iOS、C/C++、shell gates 全部通过；命令族与结果记录于技术设计 |
| REPO-001 | `DONE-INTERNAL` | 收口当前未提交变更 | 所有预期新增文件进入版本控制；变更按可审查边界拆分；无意删除或生成物不进入提交 |

当前工作树已按功能边界拆分提交，且在清除外部 header 搜索路径、使用全新 Swift
scratch/Xcode DerivedData 且启用 warnings-as-errors 的条件下保持内部基线。该
基线不替代签名、公证、清洁机、真机或真实数据发布验收。

## P1：macOS 键盘与云增强

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| KBD-005 | `IN-PROGRESS` | 段焦点编辑与定稿中文显示 | 2026-10-13 决策：预编辑区非焦点段显示定稿中文、←/→ 在段间移动焦点、退格按焦点删（活跃拼音→焦点字面量→复活前一段）；CompositionState 段焦点模型（prefixSegments + 焦点 pinyin + focusedSeparatorLiterals + suffixSegments，派生视图拆至 CompositionState+Derived.swift，Xcode 工程已登记新文件）；T1+T2 已落地，KBD-006/007 已随本轮收口；剩余：真机冻结集复评计入 KBD-001 |
| KBD-006 | `DONE-INTERNAL` | 分段向后重推 | 2026-10-15 落地：焦点段定稿/移动后按批重推后缀段定稿文本（每段一次本地 daemon infer，ranked-only、无段布局；上下文 = 应用内上下文 + 前缀定稿 + 焦点段首选猜测 + 字面量 + 之前后缀段定稿）；批锚 compositionID + 焦点段拼音，批内自身应用只递增 revision，daemon 失败/用户编辑整批作废，无 Rime 候选段跳过；中段数字选词只确认焦点段（Rime 学习照常）+ 焦点自动右移，历史留待最终整句提交一次落库，末段选词路径与旧版逐字节一致；管线拆分 +Cloud/+LocalResult/+Schedule/+SuffixRefinement 四 extension（主文件自包含），SemanticSuggestionDependencies 增 rimeCandidates（显式 init 同步补参）；SwiftPM 468（含 7 个 SegmentFocus 新用例）+ pytest 657 + macOS Xcode TEST SUCCEEDED |
| KBD-007 | `DONE-INTERNAL` | 云端整句按段接受 | 2026-10-15 落地（交互决策与原 TODO 不同，经用户确认）：跨段整句建议（段数 ≥ 2 且覆盖全部段）Tab 改为按段应用不提交——`CloudGeneratedSentencePolicy.segmentTexts` 按分隔符拆分（与结构校验同口径），`CompositionState.applySegmentedSuggestion` 写入前缀/焦点/后缀各段定稿后用户 ←→ 逐段复核，Space 整句上屏；任一段无法转换到用户字形或单段建议时回退既有 Tab 提交路径；焦点移动使云端建议失效的既有守卫不变；测试见 SemanticSuggestionPipelineSegmentFocusTests；剩余：真机验收计入 KBD-001，历史 source 归因（最终 Space 提交记 rimeMain）为已知 v1 简化 |
| KBD-001 | `IN-PROGRESS` | 完成真实键盘效果闭环 | 冻结真实输入集覆盖简拼、音近、漏字/音节、无空格混输；分别报告候选进池率、进池后准确率、接受/撤销/回删；重评 0.60 运行门 |
| KBD-002 | `TODO` | 统一 Debug 与 Release 模型制品 | 明确只保留一种产品运行目标，或证明浮点 Debug 与 INT8 Release 等价；安装、诊断和文档显示实际 artifact |
| KBD-003 | `DONE-INTERNAL` | 上屏后智能续句联想（post-commit continuation） | 2026-10-12 完成：默认关闭 opt-in；broker continuation 路由与校验梯 + 真实 qwen3.5:0.8b few-shot 冒烟 10/10 GO（无白名单变更）；协调器/面板/接线完成；真实键盘验收通过（chip 显示、Tab 接受、链式续写、8s 自动隐藏、击键/切会话撤销、开关关闭零请求、历史库 source='continuation' 落库）；修复 broker history_index 无 pinyin 键 KeyError 与 selectMainCandidate 绕过 commitText 两个真实缺陷；review 修复迟到续写帧拆连接/失活后仍 arm/Shift+Tab 误接受；续写 prompt 升级为"逐字紧接/没把握弃权"；已知边界：0.8b 对名句逐字接续会串句，按 Ruling 不做确定性索引补丁，等引入更大模型解决；回归 448 InputCore + 40 macOS + 560 pytest 全绿 |
| KBD-004 | `DONE-INTERNAL` | 整句拼音约束（单一 loose 策略） | 设计变更 2026-10-13：三档约束（exact/fuzzy/loose）移除，仅保留 loose 行为，无用户设置、无 `pinyin_alignment` 请求字段；模型可纠前后鼻音/平翘舌/错别输入，≤128 字符（broker 拒控制字符，>0x20 标量与分段非空段由 Swift 客户端最终把关）、中英混排、segments 分隔符按序复现、anti-echo 用 recent_context 尾部重叠检查；pinyin 输入无条件 `[A-Za-z']` ≤256 字节；broker（cloud_model.py/server.py 单一提词与校验梯）+ 客户端（PinyinAlignmentMode 删除、CloudGeneratedSentencePolicy 单一策略）全链路 |
| LM-001 | `TODO` | 整句解码切换为零 prompt 拼音约束路线（部署化） | MLX/llama.cpp 4-bit 引擎替换 transformers（p50 进交互预算）、beam KV 前缀共享、接入 rimeai_daemon 整句链；冻结对照基线 `docs/baselines/constrained-qwen-v2.json`（92.2% 句准确率 vs 词典基线 72.7%；prompt 路线同集 72.6%，910/974 空建议，已证伪） |
| LM-002 | `TODO` | 约束解码 SFT | 按 cloud decision cache 蒸馏 LoRA（PinyinGPT 配方），基座对照 Qwen 0.5B/2B/4B；作用靶为错误归类的 `model_path_miss` 桶（61/76 真实错误，词典召回与拼音对齐零损失） |
| CLOUD-001 | `BLOCKED` | 放行固定云候选链路 | 使用真实凭据、冻结语料和目标网络通过覆盖增益、98% 纠错 precision、800ms、stale/SEI、费用/限流/代理/撤权矩阵 |
| CLOUD-002 | `DONE-INTERNAL` | 清理旧 Qwen/阿里云/wwcn 口径 | 2026-10-13 完成：`rimeai_cloud_broker/qwen.py` 更名 `cloud_model.py`，`QwenCandidateRanker`/`QwenBrokerError` 更名 `CloudModelClient`/`CloudBrokerError`，全部 "Qwen ..." 错误文案改中性 cloud 口径；隐私中心用户文案（云端数据流、明文 Key 存储位置）与 candidate panel 无障碍标题/tooltip 改中性云端建议/纠错；PRD/PRODUCT_DESIGN/TECHNICAL_DESIGN/README/CLOUD_INPUT_IMPLEMENTATION 统一为智谱 Coding Plan 直连 + generate/abstain 无候选池合同；LaunchAgent 安装脚本导入检查同步更新。`fun.wwcn.*` 为代码签名 bundle ID 事实标识、`tools/qwen_sentence_worker.py` 与 `models/qwen2.5-0.5b` 为真实 Qwen 离线实验工件，均非误导声明、保持不变。全量 grep 复核无残留误导 provider 声明；pytest 574、InputCore 449、macOS 40 全绿 |
| RELEASE-001 | `BLOCKED` | 放行 macOS 公开预览 | 公证/Gatekeeper、清洁机安装升级回滚、代表宿主与 Secure Input、系统级抓包/日志、最低硬件、许可证和用户指标全部通过 |

## P1B：用户语言画像学习

设计与合同见 [docs/LANGUAGE_PROFILE_DESIGN.md](docs/LANGUAGE_PROFILE_DESIGN.md)。产物分三层（L1 短语库、L2 用户 LM、L3 风格画像），由空闲固化循环生成；原始历史固化后按合同淘汰原文。

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| LP-001 | `DONE-INTERNAL` | HistoryStore 固化状态与淘汰 | `history_commits` 增加 `consolidation_state` 与固化水位线；满足“统计完成且（L3 完成或显式跳过）”的批次删除原文并 bump generation；崩溃后可由水位线续跑；单测覆盖双删条件与旧索引失效（9/9） |
| LP-002 | `DONE-INTERNAL` | L1 短语库存储与管理 | 存储层、拼音/域查询、保护/删除、域映射、迁移 API（11/11）；设置页"语言画像"含学习状态、画像概要、短语管理（添加/切换保护/删除）、域映射编辑器（增删/改名合并/删除域）与云压缩开关 |
| LP-003 | `DONE-INTERNAL` | L2 用户 LM 与融合插值 | 每域+global 计数、单 commit 频次上限；两层插值按有效样本量收缩自适应（MAX_USER_WEIGHT=0.35 经首评校准）；域/全局数据不足时退化为现基线（9/9） |
| LP-004 | `DONE-INTERNAL` | 固化循环调度与本地统计 | 空闲≥10 分钟或每日触发、进程内单例锁、单轮分批（批间水位线）；仅处理窗口（7 天）外 `raw` 增量；幂等水位线 + 跨进程事务性领取；固化单属 broker（daemon 只消费产物）（8/8） |
| LP-005 | `DONE-INTERNAL` | L3 风格画像与混合压缩 | 画像 JSON 版本化、merge、单调 rollback 与 `locked_fields`；云压缩走 broker（glm-5.3-flash），无凭据显式跳过且不阻塞统计；坏摘要保留旧版（9/9）；画像仅存储于 broker 本地（merge/rollback），不进入推理 prompt（2026-10-12 决策：prompt 只含 pinyin/recent_context/segments） |
| LP-006 | `DONE-INTERNAL` | 运行时注入 | L2 进入 daemon engine 排序融合（15/15）；L1 短语建议位仲裁：本地+云均无建议时以 `phrase_book` 决策填充独立建议位（数字候选不可移动，pipeline 34/34）；混输个人词表切换到 PhraseBookStore（legacy 256 词幂等迁移 + 接受即学习）；真机冻结集复评计入 KBD-001 |
| LP-007 | `DONE-INTERNAL` | 分域映射与回退 | bundleId→域映射、域改名/合并/删除；commit<50 冷启动回退 global；域优先+global 合并查询链（含在 10/10） |
| LP-008 | `DONE-INTERNAL` | 评估闭环与文档修订 | 时间切分评估器（4/4）；真实历史首评完成（4356 条）：学习增益 +0.299 nats/字、短语命中率 52.3%（>30% 门）、泛化 gap 0.94；冻结集 top1 标注为泄漏监控；报告存 .rimeai/reports/language-profile-first-eval.json |

## P2：语音产品资格

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| VOICE-001 | `BLOCKED` | 取得产品模型与质量资格 | 完成来源、模型权利、再分发和质量审批；production catalog 非空；至少 200 句授权且说话人隔离真实语料通过质量/延迟/资源/热词误伤门 |
| VOICE-002 | `BLOCKED` | 建立正式性能与发布证据 | 与真实 corpus/run 和产品三进程绑定的 authenticated schema-3 evidence 完整通过；schema-2 tracer 不再被当作替代证据 |
| VOICE-003 | `BLOCKED` | 完成真实平台发布矩阵 | 依赖 VOICE-001/002；安装后的命名 XPC、TCC、麦克风/蓝牙/USB、代表宿主、no-INET、无音频落盘、公证、清洁机升级回滚全部通过 |
| SECURITY-001 | `TODO` | 消除 sherpa pathname 同 UID 例外 | 落地 fd/buffer/pread API 或兼容性冻结 fork，并通过 hostile same-UID、重复打开和清理回归 |

## P3：iOS 可行性

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| IOS-001 | `DEFERRED` | 收口 iOS 内部可行性 | 完成真机内存/生命周期/宿主矩阵和最新 TestFlight 验收；Simulator 与部分候选后缀回归只作为内部前置证据 |
| IOS-002 | `DEFERRED` | 决定是否接入 24M 神经排序器 | 给出扩展内存、延迟、包体与收益预算；没有净收益证据则保持 n-gram |

## 已完成的内部里程碑

| 范围 | 状态 | 边界 |
|---|---|---|
| Rime 同步主链、稳定候选与独立语义位 | `DONE-INTERNAL` | 同一工作树快照的 SwiftPM、macOS 与 iOS 严格基线已通过 |
| 24M + n-gram 候选排序与拼音约束 beam | `DONE-INTERNAL` | Debug/Release artifact 尚待统一 |
| 零 prompt 拼音约束 LM 整句解码对照 | `DONE-INTERNAL` | Qwen2.5-0.5B base 仅做 next-token 打分、合法性由冻结词典拼音掩码强制（beam width 4，无提示工程、无 thinking、无 chat template）：冻结集 92.2% 句准确率 vs 词典基线 72.7%（t2s 校正繁简标签伪影后等效 95.6%）；prompt 生成路线同集 72.6%（910/974 空建议）证伪；错误归类显示词典召回与拼音对齐零损失，剩余真实错误为模型路径选择（LM-002 SFT 靶）；评测阶段产物，未接入产品链（LM-001） |
| 真实键盘交互冻结集 v1 | `DONE-INTERNAL` | 七类真实键盘场景、实际候选面板读取、接受/撤销/退格报告器与 0.60 复评入口已建立；Secure Input、stale result 与完整 KBD-001 数据集仍未关闭 |
| 无空格混输、个人英文词和部分候选后缀 | `DONE-INTERNAL` | 部分候选只提交确认前缀，严格验证后的原始拼音后缀继续组合；原生与跨平台回归已纳入 clean baseline |
| IMK 强制提交原样上屏 | `DONE-INTERNAL` | 切换输入法/宿主终止会话时活跃拼音原样上屏、定稿前缀按定稿文本上屏，不再上屏高亮候选（与 squirrel 一致）；deactivateServer 兼作兜底；xcodebuild build/test 与 `swift test --filter RimeAIInputCoreTests`（406 项）通过，真实键盘 ⌃Space 切换实测通过 |
| 设置四页、导入导出、恢复默认和可录制语音快捷键 | `DONE-INTERNAL` | 启停按依赖顺序串行收敛，daemon 必须通过协议握手与 Offline Lock 验证；真实 AppKit/服务矩阵仍属发布验收 |
| 输入源设置页与菜单栏分面图标 | `DONE-INTERNAL` | 设置页保留逐像素一致的横向徽标，菜单栏使用与系统徽标一致的 22×16 模板图标；资源、plist 与 Release ZIP 合同已锁定，本机 TIS 与菜单栏实测通过，清洁机及双外观验收仍属发布门 |
| candidate-ID-only 云 broker 与明文历史控制 | `DONE-INTERNAL` | 真实云效果与发布未放行 |
| 语音 V2 协议、UI、helper、XPC 代码、ASR 制品/评测/tracer | `DONE-INTERNAL` | 仍是默认关闭技术探针，不具备产品资格 |
| iOS 离线 librime + 紧凑 n-gram 原型 | `DONE-INTERNAL` | fresh Simulator unit/UI 基线通过；非产品支持，最新真机验收未完成 |

## 不在当前任务表

教师软标签蒸馏、领域 adapter、开放式续写、商业定价和跨平台同步发布不是当前
MVP 缺口。只有新的真实数据证明必要时，才新建任务；不保留长期“也许会做”的
占位项。

## 维护规则

1. 一项任务只有在完成条件可复现时才能转为 `DONE-INTERNAL`。
2. 代码完成、测试完成、真实环境验收和产品发布是不同状态，禁止互相替代。
3. 新发现的阻塞直接更新现有任务，不追加对话或日记式记录。
4. 完成项只保留稳定里程碑；临时命令、一次性哈希和旧测试计数不进入本文件。
5. 每次状态变化同步更新日期；README 只摘要当前交付边界，不复制逐项任务状态。
