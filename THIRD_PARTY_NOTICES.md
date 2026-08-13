# Third-Party Notices

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
| Hugging Face tokenizers | 0.15.2 | Apache-2.0 | macOS tokenizer 运行时 |
| NumPy | 2.0.2 | BSD-3-Clause | macOS ONNX 输入张量 |
| PyYAML | 6.0.3 | MIT | macOS 冻结配置解析 |
| charset-normalizer | 3.5.0 | MIT | 冻结 Python 运行时传递依赖 |
| CPython | 3.9.6 | PSF-2.0 | macOS 自包含 daemon 运行时 |
| PyInstaller bootloader | 6.21.0 | GPL-2.0-or-later with bootloader exception | macOS daemon 冻结构建 |
| gte-multilingual-reranker-base | `8215cf04…` | Apache-2.0 | 被否决的 P0 实验 |
| Alibaba `new-impl` | `40ced75c…` | Apache-2.0 | GTE 实验代码 |
| Qwen2.5-0.5B-Instruct | `7ae55760…` | Apache-2.0 | 被否决的 P0 实验 |
| PyTorch | 2.8.0 | BSD-3-Clause | 被否决模型的 P0 推理 |
| Transformers | 4.39.3 | Apache-2.0 | 被否决模型的 P0 推理 |

固定来源、校验值和逐样本归因见：

- [native/rime/data-lock.json](native/rime/data-lock.json)
- [datasets/corpora.lock.json](datasets/corpora.lock.json)
- [datasets/ATTRIBUTION.md](datasets/ATTRIBUTION.md)
- [models/gte.lock.json](models/gte.lock.json)
- [models/qwen2.5-0.5b-instruct.lock.json](models/qwen2.5-0.5b-instruct.lock.json)
- [models/bge-small-zh-v1.5.lock.json](models/bge-small-zh-v1.5.lock.json)
- [ios/Native/artifact-lock.json](ios/Native/artifact-lock.json)
- [macos/Native/source-lock.json](macos/Native/source-lock.json)
- [macos/Native/artifact-lock.json](macos/Native/artifact-lock.json)
- [ios/ThirdPartyLicenses](ios/ThirdPartyLicenses)

开发机上的 Homebrew、模型下载缓存、PyTorch、Transformers 和训练工具不属于
macOS 产品安装包。macOS 使用固定源码、arm64、macOS 14 目标的静态 librime
XCFramework；daemon 使用 Developer ID 签名的自包含 ONNX Runtime。iOS 内部包
使用固定源码和 iOS 17 最低目标的受控构建。LGPL 数据的公开分发方案、源码
对应关系及必要的可替换/重链接材料仍须在公开发布前完成法律审查。
