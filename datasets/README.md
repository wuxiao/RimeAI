# 冻结评测语料

`corpora.lock.json` 记录 P0 数据构造所用的原始语料、固定版本、上游校验值和许可证。原始语料下载到 `.rimeai/corpora/`，不会提交到仓库，也不会进入输入法运行时。

当前来源：

- Wikivoyage 中文条目：`CC-BY-SA-4.0`，逐样本保留页面标题和页面 URL。
- MDN 中文翻译内容：冻结样本选择 `CC-BY-SA-2.5`；上游同时允许后续
  版本。逐样本保留仓库内路径和对应 MDN URL。
- 中文维基百科条目：`CC-BY-SA-4.0`，附加维基媒体基金会使用条款；固定
  官方 dump `zhwiki-20261001`。逐样本保留页面标题和页面 URL；正文在
  句子级经 OpenCC `t2s` 转简后再采样，手动语言转换标记解析 `zh-cn`
  分支。
- 拼音转换工具 pypinyin：`MIT`，只用于离线数据构造；繁简转换工具
  opencc-python-reimplemented：`Apache-2.0`，只用于离线数据构造。

生成的文本样本是上述内容的派生数据。词/短语集固定为 20,000 条（Wikivoyage
+ MDN 原有 10,000 条逐字节不变，zhwiki 追加 10,000 条），长输入集从同一
源按可逆的“上下文后缀 + 目标词”规则派生，总量 8,000 条（原有 4,000 条
逐字节不变，zhwiki 追加 4,000 条，全 general 域）。所有 split 按源文档
分配，同一页面不会跨 train/validation/test。

对外分发冻结数据集时必须同时提供本文件、`corpora.lock.json`、
`ATTRIBUTION.md`、逐样本 `source` 字段及相应 CC BY-SA 许可证和署名说明。
模型训练与公开发布仍需单独完成许可证审查；存在清单不等于法律审查已经
通过。
