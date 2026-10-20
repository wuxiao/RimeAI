# 部分选词段保留（无分隔符修正）设计提案

- 状态：已实施（D1–D7 于 2026-10-21 拍板；代码落地与测试完成，冻结集
  基线重评与真实键盘验收剩余，计入 KBD-001 流程；对应 TASKS.md `KBD-008`）
- 日期：2026-10-21（提案）/ 2026-10-21（实施）
- 拍板结论：D2/D3 采纳推迟到最终整句提交一次落库；D4 采纳统一改造；
  D5 接受撤销语义变化与基线重评；D1/D6/D7 按提案倾向执行
- 前置：KBD-005/006/007 段焦点模型已落地；本文是段焦点模型对"部分选词"路径的延伸

## 1. 动机与现状缺口

用户无分隔符输入长拼音（如 `ceshishurufanihao`）时，想修正"部分输入"只有两条路，都不理想：

1. **Tab 整句候选**：一次性替换整串，无法只改前半段；
2. **部分选词**：选一个只覆盖前缀的候选（如"测试输入法"），但当前实现把确认前缀
   **直接上屏**并清空段结构（`Selection.swift` `applyCandidateSelection` →
   `insertConfirmedPrefix` → `client.insertText` + `composition.flushPrefix()`），
   剩余拼音 `nihao` 成为新的**单段**组合——已上屏的前缀无法回修。

结论：段级修正（←/→ 移焦点、退格复活段、修正后后缀自动重推）目前只覆盖
"分隔符/字面量"造段路径（`CompositionState.appendLiteral`）与中段选词
（KBD-006 `canMoveFocusRight` 分支）。**部分选词造的段不上屏前不可回修**，
这是段焦点模型的最后一块拼图。

## 2. 目标行为（交互）

无分隔符单段输入 `ceshishurufanihao`，选面板中覆盖前缀的候选"测试输入法"：

1. 前缀段**不上屏**，以定稿中文保留在预编辑区：`测试输入法nihao`（定稿中文 +
   剩余拼音原样，KBD-005 T1 显示模型）；
2. 焦点落在剩余拼音段（末段），候选面板刷新为 `nihao` 的候选；
3. `←` 可移回 `ceshishurufa` 段修正（重选/退格重打），修正定稿后
   `nihao` 段由 KBD-006 自动重推；
4. `Space`/数字选词最终**整句一次上屏**，历史一次落库（对齐 KBD-006/007 先例）。

## 3. 决策点（待拍板）

| # | 决策点 | 选项与倾向 |
| --- | --- | --- |
| D1 | Rime 学习时机 | `rai_engine_select_candidate` **保持即时调用**（学习/词频照旧，与 KBD-006 中段选词一致）。无争议。 |
| D2 | 历史/上下文/热词记账 | **倾向**：推迟到最终整句提交一次落库（对齐 KBD-006"历史留待最终整句提交一次落库"先例；归因沿用已知 v1 简化 source=rimeMain）。代价：中途 Esc/清空组合时该次选词不进历史（学习已发生，仅历史缺失）。备选：前缀即时落库、剩余段最终落库（两笔记录，上下文拼接复杂，不推荐）。 |
| D3 | 热词（voice hotword） | **倾向**：推迟到最终整句提交与历史同点落库；备选：选词即时记录（保持现状副作用）。 |
| D4 | 既有段态下的部分选词 | **倾向**：统一改造——焦点在末段时（无论有无前缀段）部分候选一律不上屏；焦点在中段时维持 KBD-006 既有分支。备选：v1 仅改"无既有段"情形（行为不一致，不推荐）。 |
| D5 | 撤销语义变化（用户可感知） | 部分选词不再即时上屏 → 宿主 undo 不再能撤销"半个词"；修正改由输入法内退格/焦点移动承担。冻结集 `partial-selection` 场景期望值将变化，基线需重评。需明确接受。 |
| D6 | `rawLeadPrefix` 合成候选路径 | 韵母首字母前导的合成候选在部分选词时沿用同一新路径（前导定稿入段）；校验失败回退旧上屏路径。 |
| D7 | 预编辑区长度 | 全串保留后 marked text 变长（多段整句），沿用 KBD-005 `displayString` 既有行为，不设新上限（拼音总长已有 256 字节限制）。 |

## 4. 技术影响面（macOS 主战场）

- `macos/RimeAIInputMethod/RimeAIInputController+Selection.swift:76-105`
  `selectMainCandidate`：`transition.remainingInput != nil && !canMoveFocusRight`
  时走新分支（不再进 `applyCandidateSelection` 的上屏路径）；
  `remainingInput == nil`（整段提交）路径**字节级不变**。
- `Sources/RimeAIInputCore/CompositionState.swift`：新增"焦点段定稿入前缀 +
  剩余拼音设为活跃段"API（语义 = 无后缀时 `moveFocusRight` 的镜像；
  定稿逻辑与 `appendLiteral` 的 pinyin 定稿共用）。
- 历史：`prefixHistoryPinyin`/`suffixHistoryPinyin` 机制已存在（最终提交拼
  全串 historyPinyin），无需新状态。
- 候选面板/marked text：`compositionInput(remainingInput)` + `displayString`
  已有能力，仅接线。
- 云整句按段接受（KBD-007）：段数 ≥ 2 场景增多，Tab 按段复核覆盖面变大，
  逻辑不变。
- iOS：`KeyboardViewController.commit`（`insertText` 前缀上屏）同语义存在，
  但 iOS 键盘尚未接入段焦点模型（单段 String 组合）；**本提案 iOS 范围外**，
  待 iOS 段模型接入时同步。

## 5. 风险与回归

- 冻结集 `partial-selection` 场景：accepted 后宿主即时文本变化 →
  `keyboard-interaction-v1.segment-focus.json` 基线需重评更新（当前
  TASKS.md 以"与 v1 基线逐项一致"为门，属显式验收影响，见 D5）；
- KBD-001 真实键盘复评需新增"无分隔符部分选词 → 回修前段 → 重推 → 上屏"
  全链场景；
- 回退守卫：`CandidateSelectionTransition` 校验失败（remainingInput 非法）
  时回退旧上屏路径，保证 fail-safe；
- Esc/失焦清空组合时已消费前缀丢弃（学习已发生、历史不记，见 D2）。

## 6. 验收标准（拟）

- 单测（SwiftPM）：
  1. 部分选词后 `prefixSegments` 含所选定稿、`pinyin == remainingInput`、
     `displayString == 定稿中文 + 拼音原样`；
  2. `←` 回修前缀段、修正定稿触发后缀重推；
  3. `Space` 整句一次上屏、历史一次落库；
  4. transition 校验失败回退旧路径（与现网行为一致）；
  5. 整段提交（`remainingInput == nil`）路径回归不变；
  6. Secure Input / 混输守卫不回退。
- 真实键盘：冻结集新基线 + KBD-001 复评通过；
- SwiftPM / macOS Xcode / pytest 全绿；iOS 子集构建不受影响（未改 iOS 清单）。
