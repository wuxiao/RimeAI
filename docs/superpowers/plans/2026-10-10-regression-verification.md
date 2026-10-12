# RimeAI 全功能自动化回归验证计划

> **For agentic workers:** 本计划是验证型计划（非实现计划）。每个任务独立验收：执行命令 → 对照预期结果 → 记录 PASS/FAIL。GUI 任务由 KimiCU Computer Use 驱动。

**Goal:** 对 RimeAI 仓库做一次全功能自动化回归，覆盖 Python 单测、SwiftPM 单测、macOS/iOS 工程测试、原生与 Shell 合同测试、Web 前端、daemon/cloud broker 活体服务、真实键盘端到端，确保所有功能正常运行。

**Architecture:** 分四层验证：(1) 单元/合同测试层——README 标准命令直接跑；(2) 活体服务层——UDS 协议探针验证 daemon 与 cloud broker；(3) 构建层——Web 前端构建与预览；(4) 端到端 GUI 层——Computer Use 驱动 TextEdit 真实打字验收输入法。长构建任务后台执行，快速任务前台并行。

**Tech Stack:** python3.11 + pytest 8.3.4、Swift 6.1 SwiftPM、xcodebuild + xcodegen、iOS Simulator (iPhone 18 Pro, iOS 27.0)、Node/Vite、KimiCU MCP（AX 树 + 截图）。

**基线参考:** TECHNICAL_DESIGN.md §1.2 — SwiftPM 907 tests / Python 456（当前实收 470）/ macOS 31 / iOS 11。

**当前状态前提（已核实）:**
- 工作树干净（HEAD `0e93bce`）
- `.rimeai/models/` 制品齐备；`~/.config/rimeai/cloud.env` 存在
- `~/Library/Input Methods/RimeAIInputMethod.app` 已安装
- runtime sockets 存在（`rimeai.sock`、`rimeai-cloud.sock`），LaunchAgent 可能已在运行
- iOS 模拟器 iPhone 18 Pro (iOS 27.0) 已 Booted

## Global Constraints

- Python 测试必须用系统 `python3.11`（`.venv` 无 pytest）
- SwiftPM 构建必须清除 `CPATH`/`C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH`，使用全新 scratch path
- xcodebuild 使用全新 `-derivedDataPath`
- 语音 product-managed ASR 在 Release 必然 fail-closed（production catalog 为空）——这是预期行为，不是失败
- 真实云输入受 CLOUD-001 任务约束；GUI 云输入验证仅在 daemon/broker 活体正常时顺带观察，不强求

## Review Focus

1. 安装的 `RimeAIInputMethod.app` 可能落后于源码——回归以**源码构建产物**的测试为准，GUI 冒烟仅验证已装版本可用性
2. `filterwarnings = ["error"]`：pytest 中任何 warning 即失败，属预期严格性
3. GUI 打字验收依赖系统辅助功能/输入源状态；切换输入源失败时如实报告，不强行重试
4. daemon probe 要求 `offline_lock=true`——若为 false 记为 FAIL（网络守卫失效）
5. iOS 模拟器测试依赖已 Booted 的 iPhone 18 Pro；模拟器状态变化时用 `xcrun simctl boot` 恢复

---

### Task 1: Python 单元测试回归

- [ ] 运行: `PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest -q -p no:cacheprovider`
- [ ] 验收: 全部通过（0 failed），收集数 ≥ 470；记录实际通过数
- [ ] 覆盖面: rimeai_eval、rimeai_daemon（含 offline 网络守卫）、rimeai_cloud_broker（stub ranker 全链路）、voice 评测、release manifest

### Task 2: SwiftPM 单元测试回归（后台长任务）

- [ ] 运行: `env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH swift test --scratch-path $(mktemp -d /tmp/rimeai-swift.XXXXXX) --no-parallel -Xswiftc -warnings-as-errors`（后台）
- [ ] 验收: 全部测试通过，总数 ≈ 907（对照基线，允许合理增减）；记录实际数

### Task 3: macOS 输入法工程测试（后台）

- [ ] 运行: `xcodebuild -project macos/RimeAIInputMethod.xcodeproj -scheme RimeAIInputMethod -derivedDataPath $(mktemp -d) test`
- [ ] 验收: `RimeAIInputMethodTests` 全部通过（InputSourceIconContract、SettingsWindowSupport、VoiceIntegrationSmoke，基线 31 tests）

### Task 4: iOS 模拟器工程测试（后台）

- [ ] 运行: `xcodebuild -project ios/RimeAIiOS.xcodeproj -scheme RimeAI -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath $(mktemp -d) test`
- [ ] 验收: 单测 + 键盘 UI 测试全部通过（含 `nihao`→`你好` 系统键盘场景，基线 11 tests）

### Task 5: 工程/原生/Shell 合同测试

- [ ] `./scripts/verify_ios_project_generation.sh` → 退出码 0
- [ ] `./scripts/verify_macos_librime.sh macos/Native/RimeAIMacRuntime.xcframework` → 退出码 0
- [ ] `./tests/test_rime_partial_candidate_selection.sh` → 退出码 0（C++ 部分候选回归）
- [ ] `tests/test_voice_release_policy.sh`、`tests/test_voice_helper_binary_isolation.sh`、`tests/test_voice_helper_target_isolation.sh`、`tests/test_install_voice_helper.sh`、`tests/test_verify_voice_helper_bundle.sh`、`tests/test_voice_performance_tracer_executable_isolation.sh`、`tests/test_verify_macos_input_method_release_payload.sh` → 逐个退出码 0

### Task 6: Web 前端构建 + 浏览器验收（Computer Use）

- [ ] `npm run build` → 构建成功，产出 dist/
- [ ] `npm run preview` 后台起服务
- [ ] KimiCU 浏览器打开 http://localhost:4173（或 preview 输出端口）→ 验收：页面标题/主文案渲染、无控制台报错迹象、核心区块可见

### Task 7: daemon / cloud broker 活体协议探针

- [ ] 对 `~/Library/Application Support/RimeAI/runtime/rimeai.sock` 发 `{"type":"hello"}` → `status=ok` 且 `offline_lock=true`
- [ ] 对同一 socket 发推理请求 → 返回合法候选结果
- [ ] 对 `rimeai-cloud.sock` 发 hello → 握手兼容（endpoint/models/capabilities 匹配）；未配置 key 时 broker 应正常握手、推理 abstain/错误回退
- [ ] 若服务未运行：用 `script/start_daemon.sh` 启动后再探针

### Task 8: 真实键盘端到端（Computer Use）

- [ ] KimiCU 定位/启动 TextEdit，获取输入焦点
- [ ] 将输入源切到 RimeAI（若未启用：报告状态；已启用则继续）
- [ ] 通过键盘事件输入拼音（如 `nihao`），验收：候选面板出现、选字后中文上屏（预期 `你好`）
- [ ] 再输入一个含整句/云候选场景的序列，验收无崩溃、回退正常
- [ ] 验收通过后恢复原输入源

## 执行顺序

1. 先启动后台长任务：Task 2、3、4
2. 前台并行快速任务：Task 1 → Task 5 → Task 7 → Task 6
3. 最后 GUI 端到端：Task 8
4. 全部完成后汇总回归报告（PASS/FAIL 表 + 基线对照 + 发现的问题）
