# Third-Party Notices

RimeAI 本项目以 [Apache-2.0](LICENSE) 发布；本清单只覆盖第三方组件。
本清单覆盖 RimeAI 当前 macOS/iOS 工程、冻结评测和内部发布制品。构建脚本
会把适用的许可证文本和数据归因复制进制品；公开预览仍须对最终安装包执行
依赖扫描和法律审查。

| 组件/内容 | 固定版本或提交 | 许可证 | 当前用途 |
|---|---|---|---|
| librime | 1.17.0 / `33e7814…` | BSD-3-Clause | 真实候选生成 |
| Boost.Regex | 1.91.0 | Boost Software License 1.0 | macOS/iOS librime 正则依赖 |
| LevelDB | `99b3c03…` | BSD-3-Clause | macOS/iOS librime 用户数据依赖 |
| marisa-trie | `3e87d53…` | BSD-2-Clause / LGPL-2.1-or-later | macOS/iOS librime 词典依赖 |
| OpenCC | `556ed224…` | Apache-2.0 | macOS/iOS 简繁转换与数据 |
| yaml-cpp | `2f86d137…` | MIT | macOS/iOS Rime 配置解析 |
| rime-essay | `e9b1a374…` | LGPL-3.0 | 词汇与语言数据 |
| rime-luna-pinyin | `56b934b0…` | LGPL-3.0 | 拼音字典/schema |
| rime-prelude | `082425ea…` | LGPL-3.0 | Rime 基础配置 |
| rime-stroke | `3a4b0f40…` | LGPL-3.0 | Rime 数据依赖 |
| 中文 Wikivoyage 文本 | 2026-07-01 dump | CC BY-SA 4.0 | 通用冻结语料 |
| MDN 中文文档 | `9780b8cb…` | CC BY-SA 2.5 or later | 开发者冻结语料 |
| jieba | 0.42.1 | MIT | 离线分词 |
| pypinyin | 0.55.0 | MIT | 离线拼音生成 |
| BAAI/bge-small-zh-v1.5 | `7999e1d3…` | MIT | 24M 排序器初始化权重与 tokenizer |
| ONNX Runtime | 1.19.2 | MIT | macOS INT8 排序推理 |
| sherpa-onnx static XCFramework | 1.13.6；embedded revision `0fdffb3e…` | Apache-2.0 | helper 产品语音 runtime；已精确链接，因无获批模型而未形成生产 ASR 能力 |
| ONNX Runtime static XCFramework | 1.27.1 | MIT；须随附版本匹配的 upstream `ThirdPartyNotices.txt` | sherpa-onnx 产品语音 runtime 依赖；已精确链接，因无获批模型而未形成生产 ASR 能力 |
| Hugging Face tokenizers | 0.15.2 | Apache-2.0 | macOS tokenizer 运行时 |
| NumPy | 2.0.2 | BSD-3-Clause | macOS ONNX 输入张量 |
| PyYAML | 6.0.3 | MIT | macOS 冻结配置解析 |
| charset-normalizer | 3.5.0 | MIT | 冻结 Python 运行时传递依赖 |
| CPython | 3.9.6 | PSF-2.0 | macOS 自包含 daemon 运行时 |
| PyInstaller bootloader | 6.21.0 | GPL-2.0-or-later with bootloader exception | macOS daemon 冻结构建 |
| gte-multilingual-reranker-base | `8215cf04…` | Apache-2.0 | 被否决的 P0 实验 |
| Alibaba `new-impl` | `40ced75c…` | Apache-2.0 | GTE 实验代码 |
| Qwen2.5-0.5B (base) | `060db649…` | Apache-2.0 | 拼音约束整句解码路线基座（constrained-v2 评测，LM-001 部署化目标） |
| Qwen2.5-0.5B-Instruct | `7ae55760…` | Apache-2.0 | 已证伪的 prompt 整句路线实验（syllable-decoder-v3） |
| PyTorch | 2.8.0 | BSD-3-Clause | 约束解码与 beam 评测推理（开发机 neural extra，不进产品安装包） |
| Transformers | 4.39.3 | Apache-2.0 | 约束解码与 beam 评测推理（开发机 neural extra，不进产品安装包） |

固定来源、校验值和逐样本归因见：

- [native/rime/data-lock.json](native/rime/data-lock.json)
- [datasets/corpora.lock.json](datasets/corpora.lock.json)
- [datasets/ATTRIBUTION.md](datasets/ATTRIBUTION.md)
- [models/gte.lock.json](models/gte.lock.json)
- [models/qwen2.5-0.5b.lock.json](models/qwen2.5-0.5b.lock.json)
- [models/qwen2.5-0.5b-instruct.lock.json](models/qwen2.5-0.5b-instruct.lock.json)
- [models/bge-small-zh-v1.5.lock.json](models/bge-small-zh-v1.5.lock.json)
- [ios/Native/artifact-lock.json](ios/Native/artifact-lock.json)
- [macos/Native/source-lock.json](macos/Native/source-lock.json)
- [macos/Native/artifact-lock.json](macos/Native/artifact-lock.json)
- [ios/ThirdPartyLicenses](ios/ThirdPartyLicenses)
  - [sherpa-onnx Apache-2.0](ios/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt)
  - [ONNX Runtime MIT](ios/ThirdPartyLicenses/onnxruntime-MIT.txt)
  - [ONNX Runtime 1.27.1 ThirdPartyNotices](ios/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt)

语音 runtime 的固定来源与 checksum 见
[`docs/VOICE_ASR_RUNTIME_INTAKE.md`](docs/VOICE_ASR_RUNTIME_INTAKE.md)。其中
sherpa-onnx `v1.13.6` release tag commit 为 `1cb484af…`，静态 XCFramework 的
C API 自报 embedded revision 为 `0fdffb3e…`；二者分别记录发布来源与实际二进制
身份，不能混写。ONNX Runtime 1.27.1 的版本化第三方 notices 以 Microsoft 官方
[`ThirdPartyNotices.txt`](https://github.com/microsoft/onnxruntime/blob/v1.27.1/ThirdPartyNotices.txt)
为准，公开制品须把它与最终链接内容一起复核并随附。

开发机上的 Homebrew、模型下载缓存、PyTorch、Transformers 和训练工具不属于
macOS 产品安装包。macOS 使用固定源码、arm64、macOS 14 目标的静态 librime
XCFramework；daemon 使用 Developer ID 签名的自包含 ONNX Runtime。iOS 内部包
使用固定源码和 iOS 17 最低目标的受控构建。LGPL 数据的公开分发方案、源码
对应关系及必要的可替换/重链接材料仍须在公开发布前完成法律审查。

helper engine 已直接链接上表两个语音 static XCFramework，但 production model
catalog 仍因权利材料不足而为空；本 notices 条目只记录已链接软件依赖，不构成
任何语音模型再分发批准、质量结论或 Release 产品能力声明。
