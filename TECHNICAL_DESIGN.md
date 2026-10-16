# RimeAI 技术设计

| 项目 | 当前值 |
|---|---|
| 版本 | 1.0 |
| 更新日期 | 2026-10-13 |
| 状态 | 当前唯一总体技术设计 |
| 当前工作树 | 内部 clean baseline 已通过；功能边界按可审查提交收口，不可发布 |

本文件描述现行架构、数据流、信任边界和验证事实。产品需求与交互分别见
[PRD.md](PRD.md) 和 [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md)；开发状态只在
[TASKS.md](TASKS.md) 维护。

## 1. 当前事实基线

当前工作树已按功能边界拆分为可审查提交。以下基线证明同一工作树快照可从全新
构建目录完成内部验证，但不把“内部可构建”解释为“可发布”。

### 1.1 当前边界

1. macOS 与 iOS 受控 librime XCFramework 的 3 个 slice 已恢复公开 headers；
   header、slice 和 `Info.plist` 合同进入 artifact lock，并由原生 contract test
   与 macOS verifier 校验。
2. tracked shell 入口、嵌套依赖和 harness 已记录为 `100755`；直接执行的构建、
   安装、发布策略和二进制隔离 contract tests 通过。
3. `ios/project.yml` 改用跨平台显式源文件清单；独立 regeneration verifier 在
   临时镜像中生成工程并精确比较 pbxproj、scheme 与 workspace。
4. 真实签名、公证、清洁机、真机、目标网络、正式语料、许可证和用户效果矩阵
   尚未关闭。

### 1.2 验证分层

| 层级 | 同一工作树快照的 clean 命令族 | 结果 |
|---|---|---|
| SwiftPM | 清除 header 环境变量，使用全新 scratch，warnings-as-errors | 全量基线 907 tests / 63 suites（2026-08-24）；2026-10-13 时点 InputCore 子集 449 通过 |
| Python | 禁止 bytecode/cache，warnings-as-errors | 632 tests 通过（2026-10-13），无遗留测试进程 |
| macOS | 全新 DerivedData，arm64，Swift/C/C++ warnings-as-errors | 40 tests 通过（2026-10-13） |
| iOS | 全新 DerivedData，Simulator unit + system-keyboard UI | 11 tests 通过（2026-08-24 基线） |
| Native / shell / generation | XCFramework contract、部分候选 C++ 集成、脚本直接调用、XcodeGen 精确再生成 | 全部通过 |

SwiftPM 与 macOS 构建均显式移除 `CPATH`、`C_INCLUDE_PATH` 和
`CPLUS_INCLUDE_PATH`；Xcode 使用全新 `/tmp` DerivedData。验证前后仓库快照
一致。以上结果关闭内部构建基线，不构成 release qualification。

## 2. 总体架构

```text
目标应用
  ^
  | insertText / marked text
macOS InputMethodKit 输入法
  ├─ RimeEngine + controlled librime
  │    └─ 同步候选、用户选择、部分拼音消费
  ├─ DaemonClient ── private UDS ── rimeai-daemon
  │                                  ├─ 24M ranker
  │                                  ├─ char n-gram
  │                                  └─ constrained beam decoder
  ├─ CloudBrokerClient ── private UDS ── cloud broker ── fixed HTTPS gateway
  │                         ^
  │                         └─ plaintext history / FTS / vector index
  └─ VoiceDictationRuntime
       ├─ Debug: private UDS
       └─ Release: authenticated NSXPC Mach service
                         └─ RimeAIVoiceHelper
                              ├─ Apple Speech probe
                              └─ product-managed sherpa backend (not approved)
```

Rime 是唯一同步主链。所有本地模型、云端和语音组件都可以失败、取消或未安装，
而不破坏纯 Rime 键盘输入。

## 3. macOS 输入主链

### 3.1 Rime 与候选选择

- `RimeAIInputController` 接收 InputMethodKit 事件，`RimeEngine` 封装受控
  librime。
- Rime 候选同步显示；AI 使用独立 `SemanticCandidatePresentation`。
- 有 Rime 候选时 Space 选择 index 0，Tab 选择可用语义候选。
- 当前工作树新增 `CandidateSelectionTransition` 和
  `rai_engine_select_candidate`：UI 候选重新绑定到原生 index；若候选只消费
  拼音前缀，只提交确认文本并保留严格验证后的 ASCII 拼音后缀。
- 候选不足、同首选、低置信度、超长、不完整和字形不一致均是不可选状态。

### 3.2 请求生命周期

每个异步结果至少绑定：

- composition ID 与 revision；
- app session 与当前宿主；
- history generation；
- 绝对 deadline；
- 当前 Secure Event Input 与选择状态。

任何一项变化都会使旧结果失效。取消、超时或进程失败只更新对应来源状态，不得
覆盖另一路的成功结果。

### 3.3 本地上下文

- strict：不读取上下文。
- standard：当前产品会话内最多 100 个字符。
- smart：平台允许时最多 400 个字符。
- 切换应用、关闭 AI 或进入安全输入会清除相关易失上下文。

## 4. 本地 daemon 与模型

### 4.1 进程边界

- Python daemon 使用 owner-only runtime 目录和 Unix Domain Socket，校验同 UID。
- 进程级守卫拒绝 `AF_INET`/`AF_INET6`；本地模型路径永久离线。
- 同 UID UDS 只隔离其他系统用户，不抵御同一登录用户下的恶意进程。
- 协议按 request/composition/session/deadline 校验，串行推理并带失败熔断。

### 4.2 当前制品差异

“当前 macOS 运行时都是 INT8”是不准确的：

| 路径 | 当前模型 |
|---|---|
| Debug 脚本与本机 LaunchAgent | 浮点 24M safetensors |
| Release builder 目标 | INT8 ONNX 24M |
| iOS | 紧凑只读 n-gram，无 24M |

Release INT8 曾有冻结质量与延迟证据；本次 clean baseline 未执行真实签名发布
制品与部署环境资格。Debug 与 Release 必须统一目标，或持续维护并验证等价性。

2026-10-16 结构修复：Release 的 ONNX 加载路径此前在运行时包中是死代码
（`rimeai_runtime/neural_ranker.py` 懒加载 `from .onnx_ranker import ...`，
但该模块从未存在，daemon 遇到 ONNX model_type 即 ModuleNotFoundError）。
现 `rimeai_runtime/onnx_ranker.py` 提供运行时加载/推理（仅 onnxruntime，
Python 3.9 工具链），`rimeai_eval/onnx_ranker.py` 保留导出/量化工具与评估
适配层（RankerError/Ranking 合同）；daemon 诊断的 neural_ranker 条目新增
`model_type` 字段，区分 `rimeai-pinyin-listwise-cross-encoder`（浮点）与
`...-onnx`（INT8）。等价性证明与单一制品决策仍未收口（见 KBD-002）。

### 4.3 排序与整句

- 24M 拼音感知 Cross-Encoder 与 char n-gram 融合，对可比较的 Rime Top-10
  排序。
- beam decoder 只生成可由冻结 Rime 词典证明的整句，最长 30 个汉字。
- 当前外层整句展示门为 0.60，内层 beam margin 保持冻结 validation 选择值。
- 阈值质量数字只对其冻结数据和 artifact 有效，不能外推到真实接受率。
- 整句解码的既定演进方向是零 prompt 的 LM 拼音约束解码：base LM 只做
  next-token 打分，候选合法性由冻结词典拼音掩码强制（无提示工程、无
  thinking、无 chat template）。prompt 生成路线在 0.5B 冻结集上证伪
  （910/974 空建议，准确率等于词典兜底）；对照基线与错误归类冻结于
  [docs/baselines/constrained-qwen-v2.json](docs/baselines/constrained-qwen-v2.json)。
  该路线当前为评测产物，尚未接入 daemon 产品链；部署化与 SFT 见
  [TASKS.md](TASKS.md) 的 LM-001/LM-002。

## 5. 可选云增强

### 5.1 固定合同

- provider：`Zhipu Coding Plan (direct)`
- endpoint：`https://open.bigmodel.cn/api/coding/paas/v4`
- model：`glm-5.3-flash`（单一冻结白名单）
- embedding：`text-embedding-v4`，512 维（后台向量化当前硬停用，检索降级 FTS）
- 请求不携带候选池；云端推理决策只有 generate/abstain，含整句生成
  （≤128 字符）与上屏后续写联想（continuation）两条路由
- 总 deadline：30s 墙钟（协议上限 30000ms，本地开发调试口径；正式发布口径 8s）

broker 模块为 `rimeai_cloud_broker/cloud_model.py`（中性云增强命名，
provider 固定为智谱 Coding Plan 直连）。

### 5.2 数据流与接纳

输入法绑定 composition、revision、session、history generation 和 deadline，
经同 UID UDS 发给 broker（不携带候选池）。broker 只能访问固定 HTTPS
endpoint，只返回 `generate` 或 `abstain`。客户端再次验证全部绑定并过
结构门后才允许展示，采纳需用户显式确认。

### 5.3 凭据与历史

- API Key 位于 `~/.config/rimeai/cloud.env`，目录 0700、文件 0600；它不是
  Keychain，也不抵御 hostile same-UID 进程。
- 凭据不进入设置导出、prompt、历史、日志或诊断。
- 云端配置后，成功上屏记录写入跨应用明文 SQLite，并建立 recent、FTS 和向量
  检索。当前合同最多发送 600 字 recent 和 8 条 snippet。原文只在 7 天滚动
  窗口内保留，窗口外批次固化后按语言画像合同淘汰（详见
  [docs/LANGUAGE_PROFILE_DESIGN.md](docs/LANGUAGE_PROFILE_DESIGN.md)）。
- 移除 Key 只停用云端；历史由独立永久清除操作删除并提升 generation。
- Secure Event Input 阻断请求、历史写入和在途接纳。

详细合同见
[docs/CLOUD_INPUT_IMPLEMENTATION.md](docs/CLOUD_INPUT_IMPLEMENTATION.md)。

## 6. 设置与运行态收敛

- `RimeAISettingsStore` 当前导出 schema 8；导入兼容 schema 5–8（5 为默认
  快捷键迁移，7 为续写联想，8 为语言画像）。
- 语音快捷键可在设置中录制、清除和恢复默认；只接受带修饰键的非系统保留组合，
  冲突或无效输入 fail-closed，运行态变更立即重注册。
- 导入上限 128 KiB；固定 cloud provider/endpoint/model、Offline Lock、凭据、
  应用列表和语音/AI 依赖均 fail-closed。
- API Key、历史、诊断、个人英文词和模型不进入普通恢复默认删除范围。
- daemon、cloud broker、voice helper 按 stop voice/cloud -> daemon、start
  daemon -> cloud -> voice 的依赖顺序串行收敛；失败服务偏好回退为关闭。
- 设置通知只表达期望变化；只有 lifecycle/ready 验证完成才能表达运行态成功。

## 7. 语音架构

### 7.1 产品边界

语音是默认关闭的独立模态。输入法只负责快捷键、状态机、浮层、宿主守卫和最终
上屏；helper 持有音频权限、ASR engine 与服务端状态。语音不进入键盘历史。

### 7.2 V2 协议

消息为 `voice_hello`、`voice_ready`、`dictation_start`、
`dictation_stop`、`dictation_delta`、`dictation_final`、
`dictation_cancel`、`dictation_accept`、`dictation_error`。

Debug UDS 使用 NDJSON；Release XPC 的单个 Data RPC 承载一条无换行 JSON，
预解码上限 64 KiB。状态与字段合同见
[docs/VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)。

### 7.3 Debug 与 Release 启动语法

当前 helper 只接受：

```text
Debug:
  --socket <path>
  --socket <path> --engine unavailable|apple-speech|product-managed

Release:
  --mach-service fun.wwcn.rimeai.voice-helper
```

`evaluation-product-managed --artifact-dir` 已被 parser 和测试明确拒绝。
候选 artifact 评测必须走独立 `rimeai-voice-eval-driver --plan ...`；sealer 与
tracer 也都是独立工具，不向 helper argv 增加策略面。

### 7.4 Release IPC

- 双端校验 Apple anchor、Developer ID OID、Team ID、bundle ID 和 effective UID。
- 每次调用重新核对当前 XPC UID/PID；认证失败不回退 UDS。
- 顶层只允许 Data；每方向单帧 in-flight，有界 32 帧/256 KiB FIFO。
- connection、endpoint、core、output 和 session 代际隔离旧回调。

详细威胁模型见 [docs/VOICE_IPC_SECURITY.md](docs/VOICE_IPC_SECURITY.md)。

### 7.5 产品管理 ASR

- manifest schema v2 只证明制品内容和运行时合同。
- 来源、模型权利、再分发和质量审批只来自 code-shipped trusted catalog。
- `VoiceASRTrustedArtifactCatalog.production` 当前 approvals 为空；Release
  因此没有获批 product-managed ASR。
- 当前 sherpa-onnx 1.13.6、ONNX Runtime 1.27.1 和 16-entry Safe C
  `noexcept` wrapper 已进入工作树并通过当前严格编译/单元基线，但尚无产品模型
  审批或发布环境证据。
- evaluation sealer 与三进程 causal tracer 能固定候选并诊断冷加载；schema 2
  结果固定 `authenticated_production_driver=false`，不是 release evidence。
- snapshot pathname 方案不声称抵御 hostile same-UID 在校验后 rename/cleanup；
  长期需要 fd/buffer/pread API 或兼容性冻结 fork。

专项合同：

- [docs/VOICE_ASR_ARTIFACT.md](docs/VOICE_ASR_ARTIFACT.md)
- [docs/VOICE_ASR_RUNTIME_INTAKE.md](docs/VOICE_ASR_RUNTIME_INTAKE.md)
- [docs/VOICE_EVAL_FORMAT.md](docs/VOICE_EVAL_FORMAT.md)

## 8. iOS

- iOS 17 host 与 keyboard extension 使用静态 librime 1.17 和预构建 Rime 数据。
- `ios/project.yml` 是工程生成源并使用显式跨平台源文件清单；生成后的 pbxproj、
  scheme 与 workspace 必须通过精确 regeneration check，避免双真相。
- 当前语义层只使用紧凑 n-gram，不包含 24M 模型。
- 部分候选选择只提交确认前缀并保留未消费拼音后缀，已进入 native、Swift 与
  fresh Simulator 回归。
- 自定义键盘控件使用稳定 accessibility identifier，避免 iOS 系统键盘 chrome
  的同名 globe/dictation 控件造成 UI selector 碰撞。
- XCFramework headers 与 Simulator unit/UI 基线已完成；真机内存、生命周期、
  代表宿主和 TestFlight 发布验证仍未完成。

## 9. 构建、签名与发布

- macOS 输入法 Release 是唯一顶层 App，语音 helper 内嵌于
  `Contents/Helpers`，两者要求同 Team/version/build。
- Debug voice 使用 UDS；Release voice 只使用命名 XPC Mach service。
- daemon、cloud broker 和模型制品使用不可变 release/selector、校验清单与回滚。
- 公开发布还要求 Developer ID、公证/stapling/Gatekeeper、清洁机安装升级回滚、
  宿主/安全输入、网络、资源和许可证矩阵。
- shell 入口和嵌套依赖已可直接执行，发布 contract fixtures 已通过；真实
  Developer ID 制品、签名、公证、部署与回滚仍未验收，因此不能称为可发布链。

## 10. 现行技术决策

| 决策 | 结论 |
|---|---|
| TD-001 | Rime 是同步主引擎；AI 永远是可失败的增强层 |
| TD-002 | AI 使用单一独立建议位；有 Rime 候选时 Space=Rime、Tab=AI |
| TD-003 | 本地推理放在独立 daemon，输入法不在按键线程运行模型 |
| TD-004 | 云端是独立 opt-in broker；不携带候选池，只返回 generate/abstain（含续写联想）决策 |
| TD-005 | Secure Input、composition/session/generation/deadline 全部 fail-closed |
| TD-006 | Voice Debug 使用私有 UDS；Release 只使用双向认证 XPC，不降级 |
| TD-007 | ASR 内容完整性与产品 Release 资格分离，production catalog 是唯一审批源 |
| TD-008 | 当前不声称抵御任意 hostile same-UID；相关例外必须保留为显式任务 |
| TD-009 | 整句解码演进走零 prompt 拼音约束解码：LM 只打分，拼音掩码保证合法；prompt 生成路线在 0.5B 冻结集上证伪，不再投入 |

## 11. 维护规则

- 本文件只保留当前 clean baseline 的命令族与汇总结果，不维护测试流水、一次性
  哈希、临时路径或本机签名身份。
- 全局状态只在 [TASKS.md](TASKS.md) 更新；专项文档只维护协议与安全合同。
- 任何“已通过”必须绑定同一 revision 的 clean 命令与结果。
- 历史结果由 Git 与机器可读 artifact/baseline 保留，不再复制到活跃设计文档。
