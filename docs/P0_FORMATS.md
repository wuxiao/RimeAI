# P0 数据与本地排序器协议

## 数据集格式

数据集使用 UTF-8 JSON Lines。每行是一条独立样本：

```json
{
  "schema_version": 1,
  "id": "developer-001",
  "split": "test",
  "domain": "developer",
  "context": "我们需要给数据库增加一个",
  "pinyin": "suoyin",
  "candidates": ["所以", "索引", "缩印"],
  "gold_text": "索引",
  "tags": ["context-disambiguation", "technical-term"]
}
```

字段约束：

| 字段 | 要求 |
|---|---|
| `schema_version` | 必须为 `1` |
| `id` | 数据集内唯一的非空字符串 |
| `split` | `train`、`validation` 或 `test` |
| `domain` | 非空领域标识，如 `general`、`developer` |
| `context` | 字符串，可以为空 |
| `pinyin` | 非空拼音组合串 |
| `candidates` | 1–20 个唯一、非空候选；数组顺序就是 Rime 基线顺序 |
| `gold_text` | 非空标准答案；允许不在候选中，用于测量 Top-K coverage |
| `tags` | 可选的唯一、非空字符串数组 |

评测默认只读取 `test`。使用 `--split validation`、`--split train` 或 `--split all` 可以显式选择其他范围。
`--candidate-limit 10` 会在请求发送给排序器前冻结 Rime Top-10 边界；
正式 P0 结论必须显式使用该参数。

冻结源在候选采集前没有 `candidates` 字段。`capture` 子命令通过持久候选
进程补齐真实 Rime 候选，并将引擎版本、schema、数据哈希、源/输出哈希及
候选生成 P50/P95 写入单独的 provenance JSON。

## 指标口径

- `top_k_coverage`：标准答案位于原始 Rime 候选集合中的样本比例。
- `top1_accuracy`：全部样本中，排序后第一候选等于标准答案的比例。
- `conditional_top1_accuracy`：仅在标准答案已位于原始候选集合时计算的 Top-1。
- `mrr`：全部样本的平均倒数排名；标准答案不在结果中时记为 0。
- `conditional_mrr`：仅在原始候选已覆盖标准答案时计算的 MRR。
- `cer`：全部样本第一候选相对标准答案的总字符编辑距离，除以标准答案总字符数。
- `conditional_cer`：仅在原始候选已覆盖标准答案时计算的 CER。
- `raw_metrics`：设置置信度阈值时，应用弃权前的原始排序指标。
- `metrics`：应用置信度阈值和错误回退后的实际产品行为指标。
- `ranker.attempted_samples`：实际发送给外部进程的样本数。
- `ranker.successful_samples`：通过完整协议校验的响应数。

报告对数值四舍五入到六位小数。延迟使用单调时钟测量实际外部进程尝试，并报告 nearest-rank P50/P95；熔断后直接回退的样本不稀释模型延迟。

## 外部排序器配置

```json
{
  "schema_version": 1,
  "name": "my-local-ranker",
  "command": ["python3", "path/to/worker.py"],
  "timeout_ms": 400
}
```

要求：

- `command` 是参数数组，不通过 shell 执行。
- 进程在一次评测中只启动一次。
- stdin 和 stdout 使用一行一个 JSON 对象的 UTF-8 JSON Lines。
- 单条响应必须在 `timeout_ms` 内完成。
- stderr 默认丢弃。

## 重排请求

```json
{
  "schema_version": 1,
  "task": "rerank",
  "request_id": "developer-001",
  "context": "我们需要给数据库增加一个",
  "pinyin": "suoyin",
  "domain": "developer",
  "candidates": [
    {"id": "c0", "text": "所以", "baseline_rank": 1},
    {"id": "c1", "text": "索引", "baseline_rank": 2}
  ]
}
```

协议不会发送 `gold_text`、数据 split 或答案排名。

## 重排响应

```json
{
  "schema_version": 1,
  "request_id": "developer-001",
  "ranking": ["c1", "c0"],
  "confidence": 0.93,
  "model_artifact_id": "ranker-v1-q4-sha256-abcd"
}
```

要求：

- `request_id` 必须与当前请求一致。
- `ranking` 必须是全部候选 ID 的严格排列，不能缺失、重复或新增 ID。
- `confidence` 必须是 `[0, 1]` 内的有限数值。
- `model_artifact_id` 必须是非空字符串，并在一次评测中保持不变。
- 响应不能包含自由文本候选；P0 的 `rerank` 任务只允许在原始候选集合内排序。

任一要求不满足时，本条样本计为 ranker error，并使用 Rime 原始顺序计算实际行为指标。

首次超时或协议错误后，评测器会打开该进程在本次运行中的熔断器。后续样本继续以 Rime 顺序计分，但不再发送给已失效的进程，避免重复等待和扩大文本暴露范围。

## 隐私边界

聚合报告不会包含原始文本，但输入数据会发送给用户指定的本地排序器进程。该进程应满足：

- 不联网；
- 不记录请求正文；
- 不把输入写入崩溃报告；
- 不跨评测复用用户上下文；
- 退出后释放内存中的请求。

RimeAI P0 目前验证协议行为，不宣称能够约束或证明任意第三方进程的上述行为。

## 专用字符排序器

```bash
python3 -m rimeai_eval train-ngram dataset.jsonl \
  --output model.json.gz
```

训练器只从 `train` 构造字符 n-gram 和候选频率，只用 `validation` 选择
权重，绝不读取 `test` 标签。模型制品包含输入数据集 SHA-256、split
计数和固定平滑参数。`tools/ngram_ranker_worker.py` 将其暴露为上述
`rerank` 协议。

排序器只重排前 10 个候选中与 Rime 首选等长的完整候选。Rime C API 当前
没有在协议中提供 consumed-input span，等长规则是防止只消费拼音前缀的
单字候选被语义模型提升的保守代理；其他候选保持原顺序。

## 整句解码协议

整句解码使用独立任务，不能伪装为候选排序。

请求：

```json
{
  "schema_version": 1,
  "task": "generate_sentence",
  "request_id": "long-general-001",
  "context": "根据上面的分析，",
  "pinyin": "keyidechuyixiajielun",
  "domain": "general",
  "candidates": ["可以得出以下结论"],
  "max_characters": 30
}
```

响应：

```json
{
  "schema_version": 1,
  "request_id": "long-general-001",
  "suggestion": "可以得出以下结论",
  "confidence": 0.91,
  "model_artifact_id": "pinyin-beam-ngram:sha256-..."
}
```

约束：

- `suggestion` 必须是最多 30 字的单行字符串，也可以为空表示弃权。
- `confidence` 必须是 `[0, 1]` 内有限数值。
- 模型制品 ID 在一次评测中必须稳定。
- 评测器使用冻结 Rime 字典再次验证建议与原拼音一致；不一致时回退
  Rime 首选。
- 首次超时或协议错误后打开熔断器，后续样本不再发送原文。

整句指标以全部样本计算：

- `baseline_sentence_accuracy`：Rime 首选整句完全正确率。
- `sentence_accuracy`：应用有效建议、弃权和故障回退后的整句完全正确率。
- `relative_lift`：`(sentence_accuracy - baseline) / baseline`。

## 拼音约束 beam decoder

```bash
python3 -m rimeai_eval train-beam-decoder long-dataset.jsonl \
  --language-model model.json.gz \
  --rime-dictionary luna_pinyin.dict.yaml \
  --output decoder.json
```

该解码器不是开放式语言模型：

1. 使用 Rime 首选只恢复无声调拼音的音节边界。
2. 每个音节的可选汉字只来自同一冻结 Rime 字典。
3. beam search 用训练 split 的字符 n-gram 评分。
4. 是否显示建议的 margin 阈值只在 validation 上选择。
5. test 标签不进入训练或阈值选择。

因此它从结构上不能输出与原拼音不一致的字符序列；评测端仍保留第二道
独立守卫。
