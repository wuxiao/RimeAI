# P0 语料归因与修改说明

本说明适用于 RimeAI P0 冻结源、真实候选数据和由这些数据训练的内部实验
制品。大文件位于本地 `.rimeai/`，默认不随仓库分发。

## 中文 Wikivoyage

- 署名：Wikivoyage contributors。
- 固定来源：`zhwikivoyage-20260701-pages-articles.xml.bz2`。
- 上游 SHA-1：`161380a9ec5e1a30b217667c18849b6610ca2544`。
- 许可证：[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。
- 每条样本的 `source.url` 指向具体条目；该条目的历史页提供贡献者记录。

## MDN 中文翻译内容

- 署名：Mozilla Contributors。
- 固定仓库提交：`9780b8cb15f9973e0bfbf5a5d60d3461b3d386ef`。
- 固定路径：`files/zh-cn`。
- 许可证：MDN 文档正文为
  [CC BY-SA 2.5 或后续版本](https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Attrib_copyright_license)。
- 每条样本的 `source.url` 指向具体 MDN 页面，`source.document` 保留固定
  提交中的相对路径。

## 中文维基百科

- 署名：Wikipedia 贡献者（条目历史页提供贡献者记录）。
- 固定来源：`zhwiki-20261001-pages-articles.xml.bz2` 官方 dump。
- 上游 SHA-1：`04d5eec3c249fdf8604b97f4435e019c60a4ec94`。
- 许可证：[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)，
  附加
  [维基媒体基金会使用条款](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use)。
- 每条样本的 `source.url` 指向具体条目；该条目的历史页提供贡献者记录。
- Wikipedia® 与维基百科标志为 Wikimedia Foundation 注册商标；本数据仅
  涉及文字内容，不构成商标使用或授权。

## 所做修改

RimeAI 对上游材料进行了以下自动化修改：

1. 去除模板、导航、代码块、HTML/Markdown/Wikitext 标记。
2. 解析手动语言转换标记 `-{…}-`，优先采用 `zh-cn` 分支。
3. 维基百科正文在句子级经 OpenCC `t2s`（opencc-python-reimplemented
   0.1.7，Apache-2.0）转换为简体中文。
4. 抽取有限长度中文句子并按源文档去重。
5. 把句子拆为光标前上下文和目标词/长输入目标。
4. 使用固定 pypinyin 版本生成无声调拼音。
5. 使用固定 librime、schema 和 Rime 数据生成 Top-20 候选。
6. 将训练 split 转换为字符 n-gram 计数和解码阈值。

这些修改不表示 Wikimedia、Wikivoyage、Mozilla、MDN、Rime 或任何贡献者
认可 RimeAI。

## 分发边界

当前数据和模型制品仅批准用于本机内部 P0/P1 工程验证。它们混合涉及
CC BY-SA 2.5-or-later、CC BY-SA 4.0 和 Rime 数据的 LGPL-3.0 条款。
任何公开上传、安装包内分发、商业销售或向第三方提供制品的行为，都必须
先确定适用的适配作品许可证，提供完整归因、修改说明、许可证链接和 LGPL
要求的材料。本文是工程合规清单，不是法律意见。
