# RimeAI 开发任务

| 项目 | 当前值 |
|---|---|
| 更新日期 | 2026-08-24 |
| 产品发布状态 | `NOT RELEASED` |
| 当前工作树状态 | 可复现内部基线已通过；工作树仍未收口且不可发布 |
| 当前最高优先级 | 收口 `REPO-001`，随后推进 `KBD-001` 真实键盘效果闭环 |

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
| REPO-001 | `IN-PROGRESS` | 收口当前未提交变更 | 所有预期新增文件进入版本控制；变更按可审查边界拆分；无意删除或生成物不进入提交 |

当前工作树已在清除外部 header 搜索路径、使用全新 Swift scratch/Xcode
DerivedData 且启用 warnings-as-errors 的条件下建立内部基线。该基线只证明源码、
工程生成和本地 contract tests 可复现，不替代签名、公证、清洁机、真机或真实数据
发布验收。

## P1：macOS 键盘与云增强

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| KBD-001 | `IN-PROGRESS` | 完成真实键盘效果闭环 | 冻结真实输入集覆盖简拼、音近、漏字/音节、无空格混输；分别报告候选进池率、进池后准确率、接受/撤销/回删；重评 0.60 运行门 |
| KBD-002 | `TODO` | 统一 Debug 与 Release 模型制品 | 明确只保留一种产品运行目标，或证明浮点 Debug 与 INT8 Release 等价；安装、诊断和文档显示实际 artifact |
| CLOUD-001 | `BLOCKED` | 放行固定云候选链路 | 使用真实凭据、冻结语料和目标网络通过覆盖增益、98% 纠错 precision、800ms、stale/SEI、费用/限流/代理/撤权矩阵 |
| CLOUD-002 | `IN-PROGRESS` | 清理旧 Qwen/阿里云口径 | 用户文案、错误分类和公共代码命名统一为中性云增强或当前 `wwcn New API Gateway / glm-5.3`；无误导性 provider 声明 |
| RELEASE-001 | `BLOCKED` | 放行 macOS 公开预览 | 公证/Gatekeeper、清洁机安装升级回滚、代表宿主与 Secure Input、系统级抓包/日志、最低硬件、许可证和用户指标全部通过 |

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
| 无空格混输、个人英文词和部分候选后缀 | `DONE-INTERNAL` | 部分候选只提交确认前缀，严格验证后的原始拼音后缀继续组合；原生与跨平台回归已纳入 clean baseline |
| 设置四页、导入导出、恢复默认和可录制语音快捷键 | `DONE-INTERNAL` | 启停按依赖顺序串行收敛，daemon 必须通过协议握手与 Offline Lock 验证；真实 AppKit/服务矩阵仍属发布验收 |
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
