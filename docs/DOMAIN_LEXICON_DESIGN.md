# 领域词库（Domain Lexicon）设计

状态：已实现（核心层 + 设置 UI + 构建工具 + 示例词库）。

## 1. 问题与边界

L1 短语库（LP-002）只覆盖**自动学习**（auto）、**用户手工单条添加**（user）
与 LLM 产物（llm）。专业领域（IT、医学、法律、金融……）的高频术语在冷启动
阶段既不在 Rime 基础词典（朙月拼音，词表陈旧）里，也没被用户打过足够的次数，
独立建议位无法命中，导致专业用户开箱体验差。

领域词库补齐的是**预置词库资产**：可安装、可更新、可启停、可屏蔽、可批量
导入的静态词条集合，与学习型短语在查询侧融合、在存储侧分离。

架构约束（继承，不可破坏）：

- 不修改 Rime 用户词典、不读取完整 userdb（隐私边界，PrivacyCenter 承诺）。
- 不移动数字候选；词库短语只进独立建议位（REQ-KBD-02，与
  `tryPhraseBookFill` 同一落点）。
- 击键路径纯内存读（快照），SQLite 只在后台刷新与设置页写路径出现。
- 冻结词典基线不受影响：本能力不触碰 `.rimeai/rime/shared` 与
  `data-lock.json`，评测基线无需重跑。

## 2. 数据模型（phrasebook.db schema v2）

学习库与词库资产同库异表，融合查询无需跨库；学习表结构不变。

```sql
-- 词库清单：一个词库挂一个域，整体安装/替换/启停/卸载
CREATE TABLE lexicons (
    id             TEXT PRIMARY KEY NOT NULL,   -- dict.yaml name 字段规范化（[a-z0-9-]）
    name           TEXT NOT NULL,               -- 显示名
    domain         TEXT NOT NULL,               -- 挂载域，默认 global
    version        TEXT NOT NULL,
    entry_count    INTEGER NOT NULL,
    enabled        INTEGER NOT NULL DEFAULT 1,
    license        TEXT NOT NULL DEFAULT '',
    attribution    TEXT NOT NULL DEFAULT '',
    installed_at_ms INTEGER NOT NULL
);

-- 词库词条：主键含注音，一词多行 = 多音字（如「重载」chongzhai/zhongzai）
CREATE TABLE lexicon_entries (
    lexicon_id  TEXT NOT NULL,                    -- 无外键约束
    text        TEXT NOT NULL,
    pinyin_keys TEXT NOT NULL,                  -- 规范化：小写、去空格、ü→v
    weight      INTEGER NOT NULL DEFAULT 50,    -- 1–99，词频级
    blocked     INTEGER NOT NULL DEFAULT 0,     -- 用户屏蔽（跨全部读音）
    PRIMARY KEY(lexicon_id, text, pinyin_keys)
);
```

要点：

- **无外键、无 CASCADE**：实现不建 `REFERENCES … ON DELETE CASCADE`，也
  不开 `PRAGMA foreign_keys`；词条随词库删除由 `DomainLexiconStore`
  显式完成（`uninstall` 先删 entries 再删 lexicon 行）。依赖外键级联会
  在未开 `foreign_keys` 时静默失效，文档必须写明真实机制。
- 挂载域的字符集与 L1 学习表一致：`[a-z0-9-]`、≤64 字符
  （`PhraseBookDomain.validate` 为唯一入口）。
- `phrasebook_entries.source` 枚举新增 `lexicon`，仅用于**查询侧**把词库命中
  包装成 `PhraseBookEntry` 返回给既有 pipeline；词库词条永不写入学习表，
  不参与 consolidation prune / 统计 / 导出。
- `renameDomain` / `deleteDomain` 必须级联迁移 `lexicons.domain`。
- DDL 全部 `IF NOT EXISTS`，`DomainLexiconStore` 与 `PhraseBookStore` 共享
  同一份 `LexiconSchema.install`，`user_version` 只由 PhraseBookStore（库
  owner）推进到 2。

## 3. 导入格式（Rime dict.yaml）

兼容 Rime 生态（雾凇 cn_dicts、rime-essay、各类转换词库均可直接导入）：

```text
---
name: it-programming
version: "1"
...
冠心病	guan xin bing	100
重载	zhong zai	80
重载	chong zai	80        ← 同词多行 = 多音字
克罗恩病	ke luo en bing
```

解析规则（`RimeDictYamlParser`）：

- 头部只解析 `name:` / `version:`（行级解析，不引入 YAML 依赖）。
- 词条行以 Tab 分列：`text \t code \t weight?`；`#` 注释与空行跳过。
- 权重兼容 Rime 的 `100` 与 `100%` 两种写法，剥 `%` 后钳制到 1–99
  （Rime 权重为词频比例，超出按比例映射：`max(1, min(99, w / 10))`）。
- 拼音规范化：小写、多空白合一并去除、`ü`→`v`；非 `[a-z]+` 音节记入
  invalid（整行拒绝），解析报告返回 accepted / rejected 明细。
- 同词库重复 (text, pinyin) 行合并取最大权重。
- 单词库词条上限 200,000（防御性，雾凇全量 cn_dicts 也在限内）。
  超限抛 `DomainLexiconError.tooManyEntries(count:)`（**不是**
  `emptyDictionary`——设置页会把「词库太大」显示成「词库为空」）。

无注音词条不在导入端注音：注音在**构建期**完成（见 §6 工具链），导入端
要求词条自带拼音键，保持 Swift 侧零词典依赖。

## 4. 融合查询与排序

击键路径不变：`RimeAIPhraseBookService` 快照（30s 过期、后台刷新）同时
装载学习短语与**已启用词库的未屏蔽词条**（统一包装为
`PhraseBookEntry(source: .lexicon, count: weight)`），
`phrases(matchingPinyin:bundleIdentifier:)` 在内存中融合排序：

1. 精确拼音命中 > 前缀命中；
2. 本域 > global 域；
3. **学习短语（auto/user/llm）> 词库短语**——个人化数据优先于预置资产；
4. score：学习 `count` vs 词库 `weight`；
5. 最近使用 / 文本序稳定兜底。

SQL 侧 `PhraseBookStore.phrases(matchingPinyin:)` 保持原语义（仅学习表），
词库命中只经快照融合，避免两条查询路径分叉。

## 5. 管理能力（设置 UI + 服务层）

PrivacyCenter「语言画像」页新增「领域词库」节（NSStackView 程序化风格，
与短语管理一致）：

- 词库列表（名称/域/版本/词条数/状态）+ 导入（NSOpenPanel 选
  `.dict.yaml`，指定挂载域）+ 启用/禁用 + 卸载 + 词条浏览（文本/拼音/权重）
  + 词条屏蔽/解除（跨全部读音）。
- 同 id 重复导入 = 版本替换（删旧词条重插，blocked 状态不保留——资产是
  可再生的，用户屏蔽决定可重新施加）。

服务层写路径全部经 `DomainLexiconStore` 队列，成功后异步刷新快照。

## 6. 构建工具链与示例词库

`tools/build_domain_lexicon.py`：`source.tsv`（词 [\t权重]，人工只写词）
→ 用 `luna_pinyin.dict.yaml` 自动注音（词级优先，逐字回退取首音，未覆盖
词条输出报告人工补）→ `dist/<name>.dict.yaml` + `dist/manifest.json`
（name、version、license、attribution）。示例词库 `lexicons/it-programming/`
（自建，CC0-1.0），后续领域按同一管线扩展。

注意：`lexicons/it-programming/dist/` 里的产物**已预构建并入库**；重跑构建
需要本地准备 `luna_pinyin.dict.yaml`（仓库内没有，需从 luna_pinyin 上游取），
没有它时 `--annotate` 无法完成。

## 7. 许可证边界

内置资产仅收录自建（CC0）或明确可再分发授权的词表；导入 GPL 词库
（如雾凇 cn_dicts）属于**用户侧行为**，不入库、不分发，无传染面。

## 8. 后续扩展（未做）

- 词库在线更新通道（版本对比 + 增量下载）；
- 词条级权重手工调整（当前仅屏蔽/解除）；
- 按应用自动推荐挂载域；
- 英文 token 融合（`englishTokens` 目前仍只读学习表）。
