# Third-Party Notices

本清单覆盖 RimeAI 当前 P0/P1 内部工程路径。公开预览前必须重新对实际
安装包执行依赖扫描和法律审查。

| 组件/内容 | 固定版本或提交 | 许可证 | 当前用途 |
|---|---|---|---|
| librime | 1.17.0 / `33e7814…` | BSD-3-Clause | 真实候选生成 |
| Boost.Regex | 1.91.0 | Boost Software License 1.0 | iOS librime 正则依赖 |
| LevelDB | `99b3c03…` | BSD-3-Clause | iOS librime 用户数据依赖 |
| marisa-trie | `3e87d53…` | BSD-2-Clause / LGPL-2.1-or-later | iOS librime 词典依赖 |
| OpenCC | `556ed224…` | Apache-2.0 | iOS 简繁转换与数据 |
| yaml-cpp | `2f86d137…` | MIT | iOS Rime 配置解析 |
| rime-essay | `e9b1a374…` | LGPL-3.0 | 词汇与语言数据 |
| rime-luna-pinyin | `56b934b0…` | LGPL-3.0 | 拼音字典/schema |
| rime-prelude | `082425ea…` | LGPL-3.0 | Rime 基础配置 |
| rime-stroke | `3a4b0f40…` | LGPL-3.0 | Rime 数据依赖 |
| 中文 Wikivoyage 文本 | 2026-07-01 dump | CC BY-SA 4.0 | 通用冻结语料 |
| MDN 中文文档 | `9780b8cb…` | CC BY-SA 2.5 or later | 开发者冻结语料 |
| jieba | 0.42.1 | MIT | 离线分词 |
| pypinyin | 0.55.0 | MIT | 离线拼音生成 |
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
- [ios/Native/artifact-lock.json](ios/Native/artifact-lock.json)
- [ios/ThirdPartyLicenses](ios/ThirdPartyLicenses)

开发机上的 Homebrew、Xcode、Python 和模型下载缓存不是产品安装包的一部分。
当前 Homebrew librime bottle 的最低部署目标不符合 macOS 正式发行要求。
iOS 内部包已经改为固定源码和 iOS 17 最低目标的受控构建，并随宿主 App
提供当前运行时和数据的许可证文本。LGPL 数据的公开分发方案、源码对应关系
及必要的可替换/重链接材料仍须在公开发布前完成法律审查。
