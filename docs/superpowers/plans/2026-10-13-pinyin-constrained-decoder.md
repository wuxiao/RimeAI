# 拼音约束解码（Constrained Decoding）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用拼音约束解码（lime 路线）替换 prompt 式生成：模型只做 next-token 概率打分，合法性由解码器掩码强制保证，零 prompt、零 thinking，并在现有评测框架里与 prompt 路线（`syllable-decoder-v3`）打一场对照赛。

**Architecture:** 新增纯逻辑模块 `rimeai_runtime/constrained_decoder.py`（词表拼音索引 + 约束贪心解码，不依赖 torch，可用假打分器单测）；新增进程 worker `tools/constrained_qwen_worker.py` 复用现有 stdin/stdout 协议与已锁定的 Qwen2.5-0.5B 权重（MPS fp16），把 `model.generate()` 换成带 KV cache 的逐步掩码解码；最后经 `rimeai-eval evaluate-sentence` 跑冻结数据集出基线。

**Tech Stack:** Python（现有 `.venv`，无新依赖）、torch 2.8.0 / transformers 4.39.3（已锁定）、pytest。

**Spec:** 本计划自带完整规格（源于 2026-10-13 会话分析）。参考实现：`tools/qwen_sentence_worker.py`（被替换的 prompt 路线）、`rimeai_runtime/pinyin_guard.py`（拼音一致性）、`rimeai_eval/command_sentence_decoder.py`（协议）、https://github.com/xushengfeng/lime `main.ts`（约束解码思想参考）。

> **召回边界（与 lime 的关键差异，2026-10-13 修订）**：`PinyinTokenIndex` 只索引 `PinyinGuard.pronunciations`（Rime 词典条目）覆盖的 token，**不是** lime 的全词表拼音索引。这带来两个后果：(1) 词典外的字/词永远不可能被解码出来（由 `fuzzy_segment_ok` 终门与词典口径保持一致，是安全性选择）；(2) 本对照赛检验的是「约束解码 vs prompt 生成」，**不检验** lime 的字典外召回优势。若需要量化召回边界损失，见 Task 7 错误归类中的 `dict_recall_miss`（词典外字）与 `index_recall_miss`（词表无 token）桶。

## Global Constraints

- 版本锁定：torch `2.8.0`、transformers `4.39.3`，模型 ~~`Qwen/Qwen2.5-0.5B-Instruct` revision `7ae557604adf67be50417f59c2c2f167def9a775`、权重 SHA-256 `fdf756fa7fcbe7404d5c60e26bff1a0c8b8aa1f72ced49e7dd0210fe288fb7fe`~~（**已被终审裁决取代**：实测 instruct 裸分布不适配零提示打分，改用 `Qwen/Qwen2.5-0.5B` base revision `060db6499f32faf8b98477b0a26969ef7d8b9987`、SHA-256 `88c142557820ccad55bb59756bfcfcf891de9cc6202816bd346445188a0ed342`，见 `models/qwen2.5-0.5b.lock.json` 与账本）→（后续裁决：解码行为修复后 `PROMPT_VERSION` = `constrained-v2`）。
- 不新增任何运行时依赖；纯逻辑模块不得 import torch/transformers（worker 才可以）。
- Worker 协议冻结（`rimeai_eval/command_sentence_decoder.py:134-222`）：请求 `{schema_version:1, task:"generate_sentence", request_id, context, pinyin, domain, candidates, max_characters}`，响应 `{schema_version:1, request_id, suggestion, confidence, model_artifact_id}`；`suggestion` ≤30 字符、单行；空字符串 = 弃权。
- 环境变量沿用：`RIMEAI_QWEN_MODEL_DIR`、`RIMEAI_QWEN_DEVICE`（mps→fp16 / cpu→fp32）、`RIMEAI_RIME_DICTIONARY`。
- 模糊音对冻结为 `rimeai_cloud_broker/cloud_model.py:236-238` 的规则集，双向：`an↔ang`、`en↔eng`、`in↔ing`、`z↔zh`、`c↔ch`、`s↔sh`。
- 单元测试不得下载模型：用假打分器/假 tokenizer 双打。
- 上下文以纯文本喂入（无 chat template、无指令 token），artifact 版本串 `constrained-v1`。

## Review Focus

以下输入类是协议隐含但各任务测试未必覆盖、最可能咬人的，逐条钉到归属任务：

1. **首音节无合法 token**（生僻组合、误入英文）：必须返回 `suggestion=""`，不得崩溃或自由生成 → Task 2 测试。
2. **拼音串消耗超过 `max_characters=30`**：中途触顶时整体弃权（空串），不得返回半句 → Task 2 测试。
3. **模糊音键入**（用户敲 `si ji` 想要 `四季`；敲 `si` 想匹配读 `shi` 的 token）：解码命中且最终门放行 → Task 3 测试。
4. **多音字**（`长` = chang/zhang 两套读音）：两读音各自成为候选，由模型概率选路，不因多读音漏配 → Task 1 测试。
5. **空 context**（`context=""`）：无上文仍正常解码，仅依赖模型先验 → Task 4 测试。

---

### Task 1: 词表拼音索引 `PinyinTokenIndex`

**Files:**
- Create: `rimeai_runtime/constrained_decoder.py`
- Test: `tests/test_constrained_decoder.py`

**Interfaces:**
- Consumes: `PinyinGuard`（`rimeai_runtime/pinyin_guard.py:22`，`.pronunciations: Dict[str, FrozenSet[str]]`，值为空格分隔音节串）。
- Produces:
  - `PinyinTokenIndex.build(tokenizer, guard: PinyinGuard) -> PinyinTokenIndex`（`tokenizer` 鸭子类型：`.vocab_size: int` 与 `.decode(ids: list[int]) -> str`，transformers tokenizer 天然满足）
  - `.candidates(prefix: Sequence[str], *, fuzzy: bool = False) -> dict[int, tuple[str, ...]]`：键 = token id，值 = 该 token 本次匹配消费的音节（必须是 `prefix` 的前缀）；`fuzzy=False` 时逐音节全等，`fuzzy=True` 时用 Task 3 的模糊等价（Task 1 先实现精确版，签名带 `fuzzy` 参数但 fuzzy 分支 `raise NotImplementedError`，Task 3 补齐）。

- [ ] **Step 1: 写失败测试**

```python
class _StubTokenizer:
    vocab_size = 8  # id: 0..7
    _tokens = ["你", "好", "世界", "的", "是", "<pad>", "\n", "长"]

    def decode(self, ids):
        return self._tokens[ids[0]]
```

测试要点：用 `PinyinGuard(pronunciations={"你": frozenset({"ni"}), "好": frozenset({"hao"}), "世界": frozenset({"shi jie"}), "的": frozenset({"de"}), "长": frozenset({"chang", "zhang"})})` 构造 guard，断言：
- `candidates(("shi", "jie", "hao"))` 含 token「世界」→ `("shi", "jie")`，含「好」对应的仅当 prefix 首音节是 `hao`（此例不含）；
- `candidates(("chang",))` 与 `candidates(("zhang",))` 都含「长」（多音字）；
- `.candidates(("ni", "hao"))` 含「你」→ `("ni",)`；`<pad>`、`\n`、词表外文本永不出现在任何候选里；
- `candidates(())` 返回空 dict。

- [ ] **Step 2: 跑测试确认失败**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: FAIL（`ModuleNotFoundError: rimeai_runtime.constrained_decoder` 或同名类不存在）

- [ ] **Step 3: 实现 `PinyinTokenIndex`**

`build` 遍历 `range(tokenizer.vocab_size)`，`tokenizer.decode([token_id])` 得到文本；文本是 `guard.pronunciations` 的键时，把每个读音按空格拆成音节元组存入 `token_syllables: dict[int, frozenset[tuple[str, ...]]]`，同时建首音节倒排 `first_syllable_tokens: dict[str, set[int]]`。`candidates()` 只在首音节（及 fuzzy 时其等价音节）命中的 token 里做前缀比对，O(候选数 × 音节数)。

- [ ] **Step 4: 跑测试确认通过**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rimeai_runtime/constrained_decoder.py tests/test_constrained_decoder.py
git commit -m "feat(runtime): pinyin token index for constrained decoding"
```

### Task 2: 约束贪心解码 `ConstrainedGreedyDecoder`

**Files:**
- Modify: `rimeai_runtime/constrained_decoder.py`
- Test: `tests/test_constrained_decoder.py`

**Interfaces:**
- Consumes: Task 1 的 `PinyinTokenIndex.candidates(prefix, fuzzy=...)`。
- Produces:
  - `DecodeResult`（dataclass：`text: str`、`confidence: float`、`consumed_syllables: int`）
  - `ConstrainedGreedyDecoder.decode(scorer, syllables: Sequence[str], index: PinyinTokenIndex, *, max_characters: int = 30, fuzzy: bool = False) -> DecodeResult`（context 不进本函数——它已在 scorer 内部预填充）
  - 打分器协议 `scorer(step_token_ids: Sequence[int]) -> Mapping[int, float]`：给定"已生成序列"，返回下一步全词表概率；测试用 dict 双打，worker（Task 4）用 `make_scorer(tokenizer, model, device, context_ids)` 以 KV-cache 前向实现。

- [ ] **Step 1: 写失败测试**

假打分器示例（规则：序列为空时 `{"你": 0.6, "世界": 0.35}`，首 token 是「你」时 `{"好": 0.9}`）。测试断言：
- `decode(scorer, ("ni", "hao"), index)` → `text == "你好"`，`consumed_syllables == 2`，confidence 为两步概率的几何平均（pytest.approx）；
- 首步概率均 < 0.9 且存在更长覆盖 token 时触发**长词优先**：argmax 为 0.35 的「世界」时若其概率 ≥ 0.5 × 最优单字概率则选「世界」（用相反的假分布各测一次，钉死规则：`当且仅当 argmax 概率 < 0.9 时，在概率 ≥ 0.5 × argmax 的候选中选音节覆盖最长者`）；
- `syllables` 任一位置无合法候选 → `DecodeResult(text="", confidence=0.0, consumed_syllables=已消费数)`（Review Focus 1）；
- 生成的汉字数将超过 `max_characters` → 整体弃权返回空 text（Review Focus 2）；
- 平局（等概率等覆盖）时选 token id 较小者，保证确定性。

- [ ] **Step 2: 跑测试确认失败**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: 新测试 FAIL（`ConstrainedGreedyDecoder` 不存在）

- [ ] **Step 3: 实现 `decode`**

循环：`probs = scorer(generated)`；`allowed = index.candidates(remaining, fuzzy=fuzzy)`；按上述长词优先规则与平局规则选 token；累计 `math.log(max(p, 1e-12))`；消费对应音节；终止条件为音节耗尽 / 无候选 / 触顶弃权。首步 `scorer(())`。`confidence = exp(Σlogp / 步数)`，与 `tools/qwen_sentence_worker.py:219-223` 算法一致。

- [ ] **Step 4: 跑测试确认通过**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rimeai_runtime/constrained_decoder.py tests/test_constrained_decoder.py
git commit -m "feat(runtime): pinyin-constrained greedy decoder with long-word priority"
```

### Task 3: 模糊音等价与最终一致性门

**Files:**
- Modify: `rimeai_runtime/constrained_decoder.py`
- Test: `tests/test_constrained_decoder.py`

**Interfaces:**
- Consumes: Task 1 的 `candidates(..., fuzzy=True)` 分支、`PinyinGuard.segment`（`pinyin_guard.py:74`）。
- Produces:
  - `fuzzy_equal(a: str, b: str) -> bool`（Global Constraints 的 12 个方向映射）
  - `fuzzy_segment_ok(guard: PinyinGuard, text: str, typed_syllables: Sequence[str]) -> bool`：text 在 guard 的某套读音下逐音节模糊等价于 `typed_syllables` 时为 True。

- [ ] **Step 1: 写失败测试**

- `fuzzy_equal("an", "ang")`、`fuzzy_equal("zh", "z")` 为 True；`fuzzy_equal("an", "en")`、`fuzzy_equal("shi", "xi")` 为 False；自反恒 True；
- `index.candidates(("si", "ji"), fuzzy=True)` 含读 `shi jie` 的「世界」（Review Focus 3，沿用 Task 1 的 stub guard/tokenizer）；
- `decode(..., fuzzy=True)` 敲 `si ji` 出「四季」路径成立（假打分器给出对应分布）；
- `fuzzy_segment_ok(guard, "四季", ("si", "ji"))` 为 True（guard 里「四」读 `si`、「季」读 `ji` 时精确命中也算过）；`fuzzy_segment_ok(guard, "世界", ("si", "jie"))` 为 True（shi↔s 模糊）；`fuzzy_segment_ok(guard, "世界", ("wu", "jie"))` 为 False。

- [ ] **Step 2: 跑测试确认失败**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: 新测试 FAIL（`fuzzy_equal` 不存在）

- [ ] **Step 3: 实现模糊等价与门**

`fuzzy_equal`：`a == b or (a, b) in _FUZZY_PAIRS`（常量表含全部 12 个有序对）。`candidates` 的 fuzzy 分支：对剩余音节串的首音节生成 `{s} ∪ {fuzzy_equal 等价音节}` 后查倒排，其余音节逐位用 `fuzzy_equal` 比对。`fuzzy_segment_ok`：调 `guard.segment(text, " ".join(typed))` 拿精确切分，None 时再用 `guard.pronunciations` 枚举 text 各字读音做逐位模糊比对（长度必须相等）。

- [ ] **Step 4: 跑测试确认通过**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add rimeai_runtime/constrained_decoder.py tests/test_constrained_decoder.py
git commit -m "feat(runtime): fuzzy pinyin equivalence and final consistency gate"
```

### Task 4: 约束解码 worker

**Files:**
- Create: `tools/constrained_qwen_worker.py`
- Test: `tests/test_constrained_qwen_worker.py`

**Interfaces:**
- Consumes: Task 1-3 全部；`tools/qwen_sentence_worker.py` 的 `validate_request`（`qwen_sentence_worker.py:91-127`，原样复制，勿改动原文件）、`sha256_file`、版本/权重锁定常量（复制 `MODEL_REVISION`/`MODEL_SHA256`/`EXPECTED_TORCH`/`EXPECTED_TRANSFORMERS`）。
- Produces:
  - `load_runtime()`（与 `qwen_sentence_worker.py:44-88` 同构，artifact_id 末段换成 `constrained-v1`）
  - `make_scorer(tokenizer, model, device, context_ids) -> Callable[[Sequence[int]], Mapping[int, float]]`：内部持 `past_key_values`，首调用预填充 context，之后每步前向单 token，返回 `torch.log_softmax(logits[0].float(), -1).exp()` 对候选 token 的截取 dict；
  - `handle_request(runtime, guard, index, request: dict) -> dict`：纯函数式协议处理（校验 → `guard.segment(candidates[0], pinyin)` 切音节（失败则整体视为单音节串，沿用 `qwen_sentence_worker.py:257-259`）→ `ConstrainedGreedyDecoder.decode(fuzzy=True)` → `fuzzy_segment_ok` 终门不过则置空 → 写响应 dict）。

- [ ] **Step 1: 写失败测试**

不加载真模型：monkeypatch `load_runtime`，用假 tokenizer（真实 `AutoTokenizer.from_pretrained` 若本地有 model dir 则用真的，否则用 stub：`vocab_size`、`decode`、`encode(text) -> list[int]` 三方法）与假 model（`forward` 返回固定 logits 的 stub 对象）。断言：
- 合法请求 → 响应含 `schema_version/request_id/suggestion/confidence/model_artifact_id`，`model_artifact_id` 以 `constrained-v1` 结尾；
- `context=""` 正常出建议（Review Focus 5）；
- 拼音无解 → `suggestion == ""` 且 `confidence == 0.0`；
- `fuzzy=True` 路径：敲 `si ji` 期望输出「四季」类候选或空（由假分布决定，测试钉死一种）。

- [ ] **Step 2: 跑测试确认失败**

Run: `uv run pytest tests/test_constrained_qwen_worker.py -v`
Expected: FAIL（模块不存在）

- [ ] **Step 3: 实现 worker**

结构对齐 `qwen_sentence_worker.py`：`main()` 读环境变量、锁版本/权重、建 guard + `PinyinTokenIndex.build(tokenizer, guard)`（启动时一次，打印耗时）、stdin 循环调 `handle_request`。context 直接 `tokenizer.encode(context)`（无 chat template），`torch.inference_mode()` 包裹整个循环。

- [ ] **Step 4: 跑测试确认通过**

Run: `uv run pytest tests/test_constrained_qwen_worker.py -v`
Expected: PASS

- [ ] **Step 5: 手工冒烟（有真模型目录时）**

Run: `RIMEAI_QWEN_MODEL_DIR=.rimeai/models/qwen2.5-0.5b-base-060db64 RIMEAI_QWEN_DEVICE=cpu RIMEAI_RIME_DICTIONARY=.rimeai/rime/shared/luna_pinyin.dict.yaml bash -c 'echo "{\"schema_version\":1,\"task\":\"generate_sentence\",\"request_id\":\"smoke\",\"context\":\"\",\"pinyin\":\"nihaoshijie\",\"domain\":\"general\",\"candidates\":[\"你好世界\"],\"max_characters\":30}" | uv run python tools/constrained_qwen_worker.py'`
Expected: 一行 JSON，`suggestion == "你好世界"`。注意模型目录是 **base**（`qwen2.5-0.5b-base-060db64`，对应 `models/qwen2.5-0.5b.lock.json`），不是 instruct——与 Global Constraints 的终审裁决一致；实际目录以 `.rimeai/models/` 布局为准（`find .rimeai/models -name "model.safetensors"` 定位），目录缺失则跳过本步并在交付说明中注明。拼音是无分隔连写串（如 `nihaoshijie`），worker 内部用 `guard.segment(candidates[0], pinyin)` 切音节。

- [ ] **Step 6: Commit**

```bash
git add tools/constrained_qwen_worker.py tests/test_constrained_qwen_worker.py
git commit -m "feat(tools): prompt-free constrained qwen sentence worker"
```

### Task 5: 服务脚本与解码器配置

**Files:**
- Create: `script/constrained_qwen_service.sh`（以 `script/qwen_sentence_service.sh` 为模板，改 exec 目标为 `tools/constrained_qwen_worker.py`）
- Create: `examples/constrained_qwen_decoder.json`
- Test: `tests/test_constrained_decoder.py`（追加）

**Interfaces:**
- Consumes: `CommandSentenceDecoder.from_config`（`command_sentence_decoder.py:45-79`）。
- Produces: 评测可直接引用的解码器配置，name `constrained-qwen-v1`，command `["./script/constrained_qwen_service.sh"]`，timeout_ms `60000`。

- [ ] **Step 1: 写失败测试**

追加测试：`CommandSentenceDecoder.from_config(Path("examples/constrained_qwen_decoder.json"))` 成功且 `.name == "constrained-qwen-v1"`。

- [ ] **Step 2: 跑测试确认失败**

Run: `uv run pytest tests/test_constrained_decoder.py -v`
Expected: 新测试 FAIL（配置文件不存在）

- [ ] **Step 3: 写脚本与配置**

脚本逐行对照 `qwen_sentence_service.sh`（离线 env、`RIMEAI_QWEN_*` 透传、`exec python -u`）。配置对照 `examples/qwen_sentence_decoder.json` 的三字段。

- [ ] **Step 4: 跑测试确认通过 + `bash -n` 语法检查**

Run: `uv run pytest tests/test_constrained_decoder.py -v && bash -n script/constrained_qwen_service.sh`
Expected: PASS，无语法错误输出

- [ ] **Step 5: Commit**

```bash
git add script/constrained_qwen_service.sh examples/constrained_qwen_decoder.json tests/test_constrained_decoder.py
git commit -m "feat(eval): constrained qwen decoder service and config"
```

### Task 6: 对照基线（constrained vs syllable-decoder-v3）

> **2026-10-13 执行修订**：基线在执行中经历了 v1→v2 两次裁决（beam 路径 KV 历史错误、裸音节模糊匹配缺陷，见 `docs/baselines/constrained-qwen-v2.json` 的 `history_note`），最终产物为 `constrained-qwen-v2.json`，worker `PROMPT_VERSION = constrained-v2`，解码从贪心升级为 beam width 4。本任务按 v2 口径记录。

**Files:**
- Create: `docs/baselines/constrained-qwen-v2.json`

**Interfaces:**
- Consumes: Task 5 的配置；冻结数据集 `.rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl`（test split，SHA 见 `docs/baselines/macos-local-int8-test-v1.json`）；词典 `.rimeai/rime/shared/luna_pinyin.dict.yaml`。

**Recording requirements（2026-10-13 修订）**：基线文件必须显式记录解码参数。beam 路径（width、per-path history）直接决定结果；贪心专用启发式参数 `ARGMAX_CONFIDENT = 0.9` 与 `LONG_WORD_FLOOR = 0.5`（源自 lime 手调，未在本基座做过敏感性验证）**只在 `beam_width<=1` 时生效**，worker 实跑 beam width 4 不受其影响——这一点要写进基线文件，避免后人误以为 92.2% 的结果是这两个 magic number 的函数。

- [x] **Step 1: 跑约束解码器**

Run: `uv run --extra neural rimeai-eval evaluate-sentence .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl --decoder-config examples/constrained_qwen_decoder.json --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml --split test`
Expected: 正常输出准确率与延迟统计；`model_artifact_id` 含 `constrained-v2`。

- [x] **Step 2: 跑 prompt 基线（同一 split 同一命令，换 `--decoder-config examples/qwen_sentence_decoder.json`）**

Expected: 正常完成（此为现有 P0 实验 worker，应直接可跑）。

- [x] **Step 3: 写基线文件**

`docs/baselines/constrained-qwen-v2.json` 对照 `macos-local-int8-test-v1.json` 的字段风格：dataset path/sha/split/samples、model artifact_id、准确率、弃权率、latency p50/p95、与 prompt-v3 的逐项对照结论、reproduce 命令行。

- [x] **Step 4: Commit**

```bash
git add docs/baselines/constrained-qwen-v2.json
git commit -m "docs(baselines): constrained-qwen-v1 vs syllable-decoder-v3 bake-off"
```

### Task 7: 错误归类（2026-10-13 增补）

> **动机**：Task 6 只有聚合数字（92.2% 准确率、19 个 pinyin_rejection），输赢都无法指导 Phase 2/3 的取舍——不知道错误是「词典召回边界造成」「gold 与键入拼音根本对不上」还是「路径存在但 beam/模型没选对」，就无法判断下一杆该打在 beam、KV 优化还是 SFT 上。

**Files:**
- Modify: `rimeai_runtime/constrained_decoder.py`（新增纯函数 `gold_path_reachable` + `PinyinTokenIndex.readings_by_text()`，不依赖 torch）
- Create: `tools/constrained_error_taxonomy.py`
- Test: `tests/test_constrained_decoder.py`（追加）

**Interfaces:**
- `PinyinTokenIndex.readings_by_text() -> Dict[str, FrozenSet[Syllables]]`：token 文本 → 读音集合（懒构建缓存），供可达性判定做子串拼覆盖。
- `gold_path_reachable(index, gold_text, syllables, *, fuzzy=True) -> bool`：gold 能否被索引 token 完整拼出且逐音节（模糊）对上键入音节。索引读音按字组合（每字一音节），所以判定 = 音节数与字数相等 + 逐位置读音可模糊对上 + token 文本可拼覆盖整句。
- `tools/constrained_error_taxonomy.py`：输入 details JSONL + 词典 + tokenizer 目录，对每个 `applied_hit == false` 样本归类五桶：
  1. `gate_fuzzy_mismatch`：`status == "fallback-pinyin"`（worker 模糊门放行、eval 端严格门拒收；另计其中 `raw_suggestion == gold_text` 的「被门吃掉的赢面」数）
  2. `dict_recall_miss`：gold 含词典外字（召回边界直接证据）
  3. `pinyin_mismatch`：gold 读音与键入拼音（含模糊、缩写）对不上，模型原理上不可能产出
  4. `index_recall_miss`：拼音对得上，但 gold 文本无法被索引 token 拼覆盖（如词典有读音、词表无对应单字 token）——tokenizer 词表召回边界，**不是**拼音失败（2026-10-13 评审后从 `pinyin_mismatch` 拆出）
  5. `model_path_miss`：产出路径存在，beam/模型选错——SFT 与 beam 的作用靶
- 输出 JSON：各桶计数（零计数的桶也显式列出）+ cross-cutting（baseline_hits / fixed / regressions / simplified_equivalent_wins，后者经 `--t2s-table` 的 OpenCC TSCharacters 字级映射计算）+ 每桶至多 8 个样例（id/pinyin/gold/raw_suggestion），结果写回 `docs/baselines/constrained-qwen-v2.json` 的 `error_taxonomy` 字段。

> **Task 7 结果（2026-10-13 已执行，评审修订后数字）**：76 失败 = 61 model_path_miss + 9 gate_fuzzy_mismatch + 6 index_recall_miss + **0 pinyin_mismatch** + **0 dict_recall_miss**。横切发现：33/76 是繁体 gold + 简体等价答案的标签伪影（等效准确率 95.6%，含全部 6 个 index_recall_miss），11/974 是覆盖掉正确字典首选的回退（对照 201 个修复，绝对提升 19.5pp）。详见基线文件 `error_taxonomy` 字段。结论：词典召回边界在本数据集上零损失；剩余真实错误几乎全是模型路径选择——Phase 3 SFT 的作用靶得到量化确认。

---

## 后续阶段（不在本计划内，另行立计划）

> **2026-10-13 执行修订**：beam（width 4，per-path KV history）已随 constrained-v2 提前落地；KV 前缀共享是当前最明确的延迟杠杆。

1. **Phase 2 部署化**：MLX/llama.cpp 4-bit 引擎替换 transformers（延时可进本地交互预算）；beam 路径的 KV 前缀共享缓存；接入 `rimeai_daemon`。
2. **Phase 3 SFT**：按 cloud decision cache 蒸馏数据做 LoRA（PinyinGPT 配方），Qwen3.5-0.8B/2B/4B 基座对照。作用靶由 Task 7 的 `model_path_miss` 桶量化。
