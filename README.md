# RimeAI

RimeAI 是基于 Rime 的本地优先语义输入引擎。当前仓库已经完成 P0
离线验证，并实现 P1/P2-internal 的 macOS 输入法、用户级本地 daemon、隐私
控制中心和可恢复安装生命周期。原型已通过自动测试、Apple Development
签名构建、Developer ID hardened-runtime 签名、用户级安装及 LaunchAgent
运行验证；TextEdit 真实输入路径已验证。macOS 输入法已改为受控静态 librime，
daemon 已改为 Developer ID 签名、自包含的 INT8 ONNX Runtime，并以经过冻结集
验证的 24M 神经排序器与 n-gram 融合作为主排序层。公证、完整宿主矩阵和公开
分发法律审查仍未放行。macOS 另有用户主动配置 API Key 后才启用的阿里云
Qwen 增强路径；它与始终无 INET socket 的本地 daemon 是两个独立进程。

仓库另含一个独立的 iOS 内部可行性工程，用于验证宿主 App、离线自定义键盘
扩展和 TestFlight 发布链路。该工程已接入受控构建的原生 librime 1.17.0、
预编译 Rime 数据、候选 UI，以及精确复现冻结 P0 字符 n-gram 评分的只读本地
排序器。iOS 尚未接入规划中的 24M 神经排序器，也尚未完成真机内存和宿主应用
矩阵；它不改变 macOS 首发范围，也不代表 iOS 产品已完成。

产品和技术设计权威见 [DESIGN.md](DESIGN.md)；冻结实验数字与哈希见
[P0_EVIDENCE.md](docs/P0_EVIDENCE.md)，实现证据与外部阻塞见
[P1_IMPLEMENTATION_EVIDENCE.md](docs/P1_IMPLEMENTATION_EVIDENCE.md)，24M 神经
排序器与 11–30 字扩展结果见
[P3_NEURAL_RANKER_EVIDENCE.md](docs/P3_NEURAL_RANKER_EVIDENCE.md)，量化与发布
制品证据见 [P4_RELEASE_EVIDENCE.md](docs/P4_RELEASE_EVIDENCE.md)。

## 当前状态

| 能力 | 状态 |
|---|---|
| 真实 librime Top-20 候选采集 | 已实现，librime 1.17.0 |
| 10,000 条通用/开发冻结数据 | 已实现，文档级 80/10/10 切分 |
| 候选排序质量门 | 浮点 raw 95.69%；INT8 ONNX 0.90 产品门 94.55%，高于浮点产品门 94.42% |
| 候选排序性能门 | INT8 ONNX CPU P50/P95 15.17/42.70ms，冷启动 119.49ms |
| 4,000 条长输入冻结数据 | 已实现，目标文本长度 6 至 10 个汉字 |
| 1,600 条扩展长输入冻结数据 | 已实现，目标文本真实覆盖 11 至 30 个汉字 |
| 长输入整句质量门 | 0.97 阈值下已通过：6–10 字相对提升 44.09%，11–30 字提升 38.46% |
| 长输入性能门 | 11–30 字 P95 14.71ms；超长或不完整拼音显式弃权 |
| GTE 306M 重排实验 | 已否决：质量与延迟均不达标 |
| Qwen2.5 0.5B 整句实验 | 已否决：难例无修复且远超延迟预算 |
| macOS 输入法、daemon、设置中心 | 已实现简/繁、全/半角、中文/西文标点与 AI 隐私设置；输入法无 Homebrew 运行依赖 |
| iOS 离线 librime 候选键盘 | 模拟器引擎与系统键盘 UI 测试通过；真机待验 |
| 本地语义结论展示 | macOS 显式展示分析中、上下文用量、首选一致、完整候选不足、低置信度、长输入拒答、回退或可选候选 |
| 无空格中英混输 | 连续键流按拼音/ASCII 分段；大写缩写、内置技术词和本地学到的英文词原样保留，纯拼音串保留原链路，Tab 接受独立混输建议；大小写真实 librime 样例已覆盖 |
| iOS 过渡语义排序 | 冻结 P0 字符 n-gram 已以只读紧凑制品接入；24M 神经排序器未接入 |
| 用户级后台生命周期 | LaunchAgent、按需启停、崩溃重启与 0600 UDS 已验证 |
| 安装、升级、回滚、卸载 | 自包含 release 的 v1→v3、v3→v1、再升级 v5 已验证；公证/干净机器待验 |
| Offline Lock | daemon 进程无 INET socket；公开版仍需系统级抓包矩阵 |
| 可选 Qwen 云增强 | candidate-ID-only broker、Top-50/错拼扩候选、800ms 门、cloud.env 文件 API Key（0600）已接入；真实云冻结集尚待跑 |
| 长期记忆 | 配置 API Key 后跨应用明文保存 RimeAI 上屏记录，600 字 recent + 最多 8 条 FTS/HNSW 片段；可导出、永久清除 |
| Release 制品 | 输入法 ZIP 5.0MB；daemon 归档约 69MB、安装约 120MB；均有 SHA-256 与 Developer ID 签名 |
| 语音听写协议层 | 独立工作流；消息校验、客户端状态机、服务端核心、UDS 传输层、Coordinator 与真实 socket 全栈回环 31 项测试通过；helper 含 Apple Speech 引擎源码并经真实 launchd 生命周期验证（识别路径待 TCC 真机验证）；UI 接线未实现 |
| 自动化测试 | 云增强新增测试与既有本地测试通过；最新可复现命令见 `docs/CLOUD_INPUT_IMPLEMENTATION.md` |
| 公开分发许可证放行 | 未完成；当前模型制品仅供内部 P0/P1 |

完整证据与放行边界见 [P0_EVIDENCE.md](docs/P0_EVIDENCE.md)。P0 文件中的
测试数量是当时的冻结快照；当前仓库测试数量以本轮测试输出为准。

模型决策：

- 当前 macOS 首选神经排序器：`RimeAI-Ranker-S-24M`，以
  `BAAI/bge-small-zh-v1.5` 初始化，训练为拼音感知 listwise
  Cross-Encoder。验证集选择的 0.5/0.5 神经+n-gram 融合在冻结测试集同时超过
  单独 n-gram 并满足 50ms P95 门，已经接入 macOS daemon。
- 当前 macOS 实现：INT8 ONNX 24M 融合候选排序 + 拼音约束 beam decoder；字符 n-gram
  保留为融合信号和神经运行时故障回退。daemon
  对重排、首选一致、完整候选不足、低置信度、无候选、超长和不完整候选返回
  显式决策。简体拼音从 2 个字符起进入受字典约束的整句解码，当前运行时整句
  展示门槛为 0.60。
- 当前 iOS 过渡实现：从同一冻结 P0 模型确定性导出的 11.2MiB 只读紧凑
  n-gram 制品；只处理 Rime 候选排序，不包含整句 beam decoder。
- 离线教师：`Qwen3-Reranker-0.6B`，不进入本地运行时。
- 可选云运行时只允许固定的 `glm-5.3`（`https://newapi.wwcn.fun/v1`），
  通过候选 ID 合同工作，不能自由生成上屏文本。
- `LFM2.5-Encoder-230M` 仅作为 P0 challenger。

## 架构

```text
licensed source text
        │
        ├── document-level split ──> librime candidate capture
        │                                  │
        │                                  ├── Top-10 candidate evaluation
        │                                  └── long-input evaluation
        │
        ├── 24M pinyin-aware Cross-Encoder + char n-gram ──> candidate ranking
        ├── frozen Rime dictionary + beam search ──> pinyin-safe sentence suggestion
        │
        └── optional cloud.env credential (0600)
             └── separate Qwen broker + plaintext history/FTS/HNSW
                  └── choose one existing exact/fuzzy candidate ID
```

关键产品边界：

- Rime 始终提供同步候选和故障兜底。
- 本地候选排序只处理可见 Rime Top-10，结果不能改变已显示的数字候选；云端
  内部池最多 50 条，但也只能占用一个显式建议位。
- 当前有效的语义候选出现时，用户按 `Tab` 显式采用；`Space` 始终提交 Rime
  第一候选，数字候选的位置不会因异步结果变化。
- 完整候选少于 2 个时不执行重排，并明确显示“完整候选不足”；不得把未比较
  伪装为模型同意 Rime 首选。
- 模型实际比较后仍选择 Rime 第一项时，第二行明确显示具体文本，例如
  `AI 建议：飞机（与 Rime 首选一致）`；该行只解释模型结论，不重复创建可选项。
- 长输入解码的每个字符必须由同一冻结 Rime 词典证明与原拼音一致；超过
  30 字或只覆盖部分拼音时显式拒答，不展示截断句。
- 当前运行时整句展示门槛为 0.60，仍保留 validation 选择的 beam margin 门禁；
  冻结 409 条 test 明细按外层 0.60 重算后整句准确率为 45.97%，相对 Rime
  首选提升 48.03%。真实接受率和撤销率仍需内部预览验证，因此不继续降低
  beam margin 门禁。
- 本地生成的整句必须与当前简繁设置一致；简体模式不会展示或提交繁体整句。
- 当前整句质量证据覆盖 6 至 30 个汉字；30 字仍是硬上限，不能外推为任意
  长度的续写或开放式生成。
- 命令进程超时、崩溃、协议异常或低置信度时回退 Rime。
- 聚合报告默认不包含上下文、拼音、候选或标准答案。
- 未配置 API Key 时不写长期历史、不启动云 broker；配置后会跨应用明文保存
  RimeAI 上屏文本并上传受限上下文。macOS Secure Event Input 会阻止历史写入
  与云请求。移除 Key 会停用云端但保留历史，历史必须单独永久清除。
- 本地 daemon 的 Offline Lock 是永久不变量，不代表独立云 broker 不联网。

## 仓库组成

- `rimeai_eval/`：数据校验、采集、训练、评测和本地进程协议。
- `Sources/`、`Package.swift`：真实 librime C/C++ 桥和 Swift 候选服务。
- `tools/`：冻结数据构造和模型工作进程。
- `script/`：本地候选、排序和整句服务入口。
- `scripts/`：Rime 数据、语料、模型及干净 Python 包构建脚本。
- `models/`、`datasets/`：版本锁、来源与许可证说明；大制品位于
  `.rimeai/`，不会提交。
- `tests/`：Python 与 Swift 公共行为测试。
- `macos/`：InputMethodKit 输入法、隐私中心和 LaunchAgent 模板。
- `ios/`：原生 iOS 宿主与离线键盘扩展的内部可行性工程。
- `src/`、`public/`：产品展示站。

SwiftPM 的 `rime-candidate-service` 与 macOS App 共用
`macos/Native/RimeAIMacRuntime.xcframework`，不再链接 Homebrew librime。

## 环境

- macOS Apple Silicon。
- Python 3.9 或更高版本；训练/导出使用锁定的 `neural` 可选依赖，安装后的
  macOS daemon 自带 Python/ONNX Runtime，不依赖开发机 Python。
- Swift 6 / Xcode。
- macOS 输入法使用固定源码构建的 librime 1.17.0 arm64 静态 XCFramework，
  最低目标 macOS 14；iOS 内部工程使用独立的 iOS 17 device/Simulator 受控
  制品。正式运行包不依赖 Homebrew bottle。
- 冻结语料构造需要 `uv`；依赖版本由 `uv.lock` 固定。

## 从零重建 P0

准备 Rime 数据并构建候选服务：

```bash
scripts/bootstrap_rime_data.sh
swift build --product rime-candidate-service
```

准备固定语料：

```bash
scripts/bootstrap_corpora.sh
```

构建 10,000 条词/短语源并采集真实候选：

```bash
uv run --isolated --extra dataset python tools/build_capture_source.py \
  --wikivoyage .rimeai/corpora/zhwikivoyage-20260701-pages-articles.xml.bz2 \
  --mdn .rimeai/corpora/mdn-zh-cn-9780b8c.tar.gz \
  --essay .rimeai/rime/shared/essay.txt \
  --output .rimeai/datasets/p0-source-20260729.jsonl \
  --general-samples 5000 \
  --developer-samples 5000

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-librime-1.17.0-luna-simp.provenance.json
```

训练并评测候选排序器：

```bash
python3 -m rimeai_eval train-ngram \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --output .rimeai/models/p0-char-ngram-v1.json.gz

python3 -m rimeai_eval evaluate \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --split test \
  --candidate-limit 10 \
  --ranker command \
  --ranker-config examples/ngram_ranker.json
```

准备并训练 24M 神经排序器，再只用 validation 选择融合权重和置信阈值：

```bash
scripts/bootstrap_bge_small_zh.sh

python3 -m rimeai_eval train-neural-ranker \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --base-model .rimeai/models/bge-small-zh-v1.5-7999e1d \
  --base-revision 7999e1d3359715c523056ef9478215996d62a620 \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/rimeai-ranker-s-24m-v1 \
  --device mps

python3 -m rimeai_eval train-neural-fusion \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --neural-model .rimeai/models/rimeai-ranker-s-24m-v1 \
  --language-model .rimeai/models/p0-char-ngram-v1.json.gz \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/rimeai-ranker-s-24m-fusion-v1.json \
  --device cpu
```

构建长输入集、训练解码阈值并评测：

```bash
uv run --isolated --extra dataset python tools/build_long_input_source.py \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --output .rimeai/datasets/p0-long-source-20260729.jsonl \
  --samples 4000

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-long-source-20260729.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.provenance.json

uv run --isolated --extra dataset python tools/build_long_input_source.py \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --output .rimeai/datasets/p0-long-11-30-source-20260813.jsonl \
  --samples 1600 \
  --minimum-target-characters 11 \
  --preferred-target-characters 30 \
  --maximum-target-characters 30

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-long-11-30-source-20260813.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.provenance.json

python3 -m rimeai_eval train-beam-decoder \
  .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.jsonl \
  --language-model .rimeai/models/p0-char-ngram-v1.json.gz \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/p0-beam-sentence-v1.json

python3 -m rimeai_eval evaluate-sentence \
  .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  --decoder-config examples/beam_sentence_decoder.json \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --split test \
  --candidate-limit 10
```

## 测试与构建

```bash
python3.11 -m pytest -q
swift test
python3.11 -m compileall -q -x '(^|/)\._' \
  rimeai_eval rimeai_daemon tools
swift build --product rime-candidate-service
npm run build
scripts/build_python_package.sh /tmp/rimeai-python-dist
```

工作区位于会产生 AppleDouble `._*` 元数据的外接磁盘上。Python wheel
必须通过干净临时目录脚本构建；不要直接从工作区执行普通 `uv build`。
仓库内 `.venv` 可仅用于 `--extra release` 的冻结运行环境，不保证包含 pytest；
回归测试使用安装了 pytest 的 Python 3.11 开发解释器。

## macOS 内部预览

构建并打开设置中心：

```bash
script/build_and_run.sh --settings
```

常规输入设置也会显示在 macOS 菜单栏的 RimeAI 输入法菜单中。默认值为
`简体中文 + 半角字符 + 中文标点`；简繁转换所需的 OpenCC 配置和字典随输入法
离线打包。

安装输入法和用户级 daemon：

```bash
script/install_debug_input_method.sh
```

构建 Developer ID 签名的正式配置输入法 ZIP：

```bash
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
scripts/build_macos_input_method_release.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip 0.1.0 26
scripts/verify_macos_input_method_release.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip
```

构建并安装自包含 INT8 ONNX daemon；安装器要求同名 `.sha256` 侧车文件：

```bash
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
scripts/build_daemon_release.sh \
  /tmp/rimeai-daemon-macos-arm64-0.1.0.tar.gz 0.1.0
script/install_release_daemon.sh \
  /tmp/rimeai-daemon-macos-arm64-0.1.0.tar.gz
script/rollback_release_daemon.sh
```

使用 Developer ID 安装时，显式传入证书、私钥和身份。脚本使用一次性隔离
钥匙串，并在退出时恢复原钥匙串搜索列表：

```bash
RIMEAI_DEVELOPER_ID_CERTIFICATE=/path/to/developer-id.cer \
RIMEAI_DEVELOPER_ID_PRIVATE_KEY=/path/to/developer-id-private-key.pem \
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
script/install_developer_id_input_method.sh
```

默认卸载会把应用和 LaunchAgent 移到废纸篓并保留 Rime/RimeAI 数据：

```bash
script/uninstall_debug_input_method.sh
```

只有显式使用 `--trash-rimeai-data` 才会把 daemon、模型、runtime 和控制标记
移到废纸篓；`Application Support/RimeAI/Rime` 中的 Rime 用户数据始终保留。
当前本机 bundle 使用 `Developer ID Application: WEI WANG (S3T42U45P8)`、
hardened runtime 和 Apple 安全时间戳，深度签名验证通过。它尚未公证，
`spctl` 因 `Unnotarized Developer ID` 拒绝；调试安装只复制并验证输入法，
不会绕过“系统设置”自动启用。请在“键盘 → 输入源 → 编辑 → +”中添加
RimeAI。它仍不是可公开分发的安装包。

输入法 ZIP 不保留 resource fork/扩展属性，并由验证器使用普通 `unzip`
解包后检查无 AppleDouble `._*`、arm64/macOS 14、受控 librime 符号、
Developer ID hardened runtime 和 `codesign --deep --strict`。

配置 Apple `notarytool` keychain profile 后，公证和 stapling 使用：

```bash
RIMEAI_NOTARY_PROFILE=rimeai-notary \
scripts/notarize_macos_input_method.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64-notarized.zip
```

## 数据、协议与许可证

- [P0_FORMATS.md](docs/P0_FORMATS.md)：候选与整句进程协议。
- [VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)：语音听写独立
  工作流的设计与协议草案（`ACCEPTED TARGET STATE`，未实现）。
- [P0_EVIDENCE.md](docs/P0_EVIDENCE.md)：冻结哈希、指标和放行决定。
- [P1_IMPLEMENTATION_EVIDENCE.md](docs/P1_IMPLEMENTATION_EVIDENCE.md)：
  输入法、daemon、隐私和安装生命周期证据。
- [ATTRIBUTION.md](datasets/ATTRIBUTION.md)：语料归因与修改说明。
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：第三方组件清单。

当前冻结数据和模型制品混合了 CC BY-SA 与 LGPL 来源。它们可以用于本地
内部验证，但在公开打包、上传或销售前必须完成具体分发方案的法律审查、
归因、源材料提供和 ShareAlike/LGPL 合规；仓库中的清单不等于法律意见。
