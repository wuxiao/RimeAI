# RimeAI

RimeAI 是面向 Apple Silicon Mac 的 Rime 本地优先语义输入引擎。Rime 始终
负责同步拼音解析与候选兜底；本地模型在独立建议位提供上下文重排、受拼音
约束的整句建议和无空格中英混输建议。可选云增强只能从客户端候选池中选择，
不能自由生成或自动上屏。

> 当前状态（2026-08-24）：`NOT RELEASED / INTERNAL BASELINE VERIFIED`。
> 同一工作树快照已通过全新 SwiftPM、macOS、iOS、Python、原生与 shell
> 严格验证，但仍有大量未收口变更，也尚未通过签名、公证、真机、真实数据和
> 用户效果等发布门，详见 [TASKS.md](TASKS.md)。

## 权威文档

- [PRD.md](PRD.md)：唯一产品需求与放行范围。
- [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md)：唯一用户流程与交互设计。
- [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)：唯一总体技术设计与当前架构。
- [TASKS.md](TASKS.md)：唯一开发任务、优先级、状态和完成条件。

发生冲突时，当前代码和可复现测试优先于文档；文档之间按上面的职责边界
解释，不再使用“旧文档由页首补丁覆盖”的维护方式。

## 当前交付边界

| 范围 | 最新状态 |
|---|---|
| macOS 键盘主线 | 内部实现已覆盖受控 librime、稳定候选、语义建议、整句、无空格混输、设置与安全输入保护；fresh 严格构建与测试已通过 |
| 本地语义模型 | macOS daemon 已有 24M 神经排序器、n-gram 融合与 beam decoder；Debug/本机安装路径仍使用浮点 24M，Release 制品使用 INT8 ONNX，尚待统一 |
| 可选云增强 | `wwcn New API Gateway`、默认 `glm-5.3-flash`（可选 `glm-5.3`）、候选 ID 选择 + 能力协商式整句生成（generate，≤30 字字典对齐双重校验）链路已实现；上屏后续写联想（continuation，默认关闭，Tab/点击接受）已实现并经本地模型冒烟；真实冻结集、目标网络、费用与发布验收未完成 |
| 语音听写 | 默认关闭的内部技术探针；协议、UI、helper、评测 backend 和诊断 tracer 已实现，但没有获批产品模型、正式语料、TCC/设备与发布证据 |
| iOS | 离线 librime + 紧凑 n-gram 可行性工程；fresh Simulator unit/UI 已通过，24M 模型与最新真机验收未完成 |
| 公开分发 | 未放行；仍需工作树收口、公证、清洁机、宿主/安全输入、网络、许可证和真实用户指标 |

## 核心交互

- Rime 数字候选立即显示，当前组合期间不因异步结果换位。
- 有 Rime 候选时，`Space` 提交 Rime 首选；`Tab` 采纳可选的 AI 建议。
- 开启「上屏后续写联想」（默认关闭）后，上屏文本会触发一次云端续写
  建议，以单条 chip 展示；`Tab` 或点击接受，任意其他按键即刻撤销，
  8 秒无操作自动消失。
- 选择只消费部分拼音的 Rime 候选时，仅提交已经确认的文字前缀；未经修正的
  原始拼音后缀继续保留在组合态，不会随前缀直接上屏。
- 切换输入法或宿主强制结束输入会话时，未确认的活跃拼音原样上屏，
  定稿前缀按定稿文本上屏；任何未显式确认的候选都不上屏。
- “分析中、首选一致、候选不足、低置信度、超时或失败”只解释状态，不创建
  可选项。
- Secure Event Input、旧组合、旧应用会话、旧光标和过期 deadline 的结果全部
  fail-closed。
- 语音模式与键盘组合态分离：默认按住 `⌃⇧V` 说话，也可在设置中录制安全
  快捷键；松开等待 final，`Space`/回车确认听写文本，`Esc` 取消。该流程目前
  不具备公开发布资格。

## 架构概览

```text
macOS InputMethodKit
  ├─ librime ───────────────> 同步候选与上屏兜底
  ├─ local daemon (UDS) ────> 24M + n-gram + beam
  ├─ cloud broker (UDS) ────> 固定 HTTPS 网关 / 候选 ID 选择
  └─ voice runtime
       ├─ Debug: private UDS
       └─ Release: authenticated NSXPC Mach service -> voice helper
```

完整组件、数据流和信任边界见
[TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)。

## 仓库结构

- `Sources/`、`Package.swift`：共享 Swift 核心、Rime 桥、语音与评测组件。
- `macos/`：InputMethodKit 输入法、设置中心和发布工程。
- `ios/`：iOS 宿主与键盘扩展可行性工程。
- `rimeai_daemon/`：本地语义 daemon。
- `rimeai_cloud_broker/`：可选云候选 broker。
- `rimeai_eval/`、`tools/`：冻结数据、训练、评测和质量门。
- `script/`、`scripts/`：开发、安装、构建、验证与发布脚本。
- `tests/`：Swift、Python、C/C++ 与 shell 回归。
- `docs/`：仍在生效的专项协议、安全和制品合同。

## 开发与验证

当前工作树已经建立不依赖 `CPATH` 或旧构建缓存的内部基线。常用入口如下；
完整状态、边界和 Xcode 命令族见 [TASKS.md](TASKS.md) 与
[TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)。

```bash
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
  swift test --scratch-path "$(mktemp -d /tmp/rimeai-swift.XXXXXX)" \
  --no-parallel -Xswiftc -warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest -q -p no:cacheprovider
./scripts/verify_ios_project_generation.sh
./scripts/verify_macos_librime.sh macos/Native/RimeAIMacRuntime.xcframework
./tests/test_rime_partial_candidate_selection.sh
```

这些检查不证明 Developer ID 签名、公证、清洁机安装、真机兼容、真实云/语音
质量或公开发布资格。

## 生效中的专项合同

- [docs/P0_FORMATS.md](docs/P0_FORMATS.md)：键盘候选与整句协议。
- [docs/CLOUD_INPUT_IMPLEMENTATION.md](docs/CLOUD_INPUT_IMPLEMENTATION.md)：
  云候选、凭据、历史与隐私合同。
- [docs/VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)：语音交互与 V2 协议。
- [docs/VOICE_IPC_SECURITY.md](docs/VOICE_IPC_SECURITY.md)：语音 IPC 威胁模型。
- [docs/VOICE_ASR_ARTIFACT.md](docs/VOICE_ASR_ARTIFACT.md)：语音模型制品合同。
- [docs/VOICE_ASR_RUNTIME_INTAKE.md](docs/VOICE_ASR_RUNTIME_INTAKE.md)：
  ASR runtime/model intake 合同。
- [docs/VOICE_EVAL_FORMAT.md](docs/VOICE_EVAL_FORMAT.md)：语音评测与证据 schema。
- [ios/README.md](ios/README.md)：iOS 可行性工程边界。
- [datasets/ATTRIBUTION.md](datasets/ATTRIBUTION.md) 与
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：数据与第三方归因。
