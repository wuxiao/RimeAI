# n-gram 语言模型层改进（A/B 阶段）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把字符 n-gram 打分从"多阶等权求和"升级为插值回退（stupid backoff），把 L2 用户语言模型接入整句 beam decoder（补齐 `docs/LANGUAGE_PROFILE_DESIGN.md` §6 的设计-实现差距），并新增句级基准命令量化架构天花板。

**Architecture:** 打分公式改动落在三处既有实现（`rimeai_runtime/ngram_ranker.py`、`rimeai_daemon/user_lm.py`、`rimeai_runtime/beam_decoder.py`），语义统一为 stupid backoff。beam decoder 改为面向 `CharLMScorer` 协议打分，daemon 侧新增 `FusedCharLM` 在概率空间插值静态基座与用户证据，无用户证据时逐位退化为基础打分（冷启动 bit-for-bit）。评测侧新增 `sentence-benchmark` 子命令，产出句正确率 / 字正确率（Levenshtein）/ gold∈Top-10 覆盖率 / 决策分布。

**Tech Stack:** Python 标准库（math/json/gzip），pytest。参考对象：万象语法模型（amzxyz/RIME-LMDG，32GB 语料、trie+mmap、rime-schema-compare 评测口径）。

**Spec:** 本计划依据会话分析（2026-10-13，雾凇拼音/万象对照 RimeAI）；关联设计文档 `docs/LANGUAGE_PROFILE_DESIGN.md`（§4.2 融合公式、§6 注入点"整句 decoder 用同一融合 LM"、§8 延迟预算）与 `docs/P0_FORMATS.md`（Frozen Rime Top-10 Boundary）。姊妹计划 `docs/superpowers/plans/2026-10-13-pinyin-constrained-decoder.md`（Qwen 约束解码）与本计划竞争"整句建议"座位，关系见下节。

## Global Constraints

- 不新增第三方依赖；全部改动只用标准库。
- Fail-closed 语义继承：任何融合/打分异常必须退回基础行为，不得抛出到 `LocalInferenceEngine.infer` 之外改变 `decision` 语义。
- 本地路径延迟预算：P95 回归 ≤ +1ms（`docs/LANGUAGE_PROFILE_DESIGN.md` §8）；FusedCharLM 构造必须 O(1)（只包引用，不复制计数表）。
- 工件写入沿用现有 atomic-write 模式（`write_ngram_model_atomic` / `write_beam_config_atomic`）。
- 神经排序器（HybridSemanticRanker / fusion config）不在本计划范围，仅保证其调用的 `language_score` 签名不变。
- 代码风格随仓库：runtime/daemon 模块用 `from __future__ import annotations`，dataclass 优先。

## 与拼音约束解码计划（constrained-qwen-v1）的关系

- **Task 1/2 是无悔项**：backoff 平滑与条件概率改进静态 n-gram 底座，该底座同时服务排序兜底与整句 beam，无论哪条整句路线胜出都不浪费。
- **Task 3 的价值随姊妹计划结果衰减但不清零**：若 constrained-qwen-v1 在对照赛（其 Task 6）胜出并经其 Phase 2 进入 daemon，本计划的融合 beam 降级为 fail-closed 兜底路径——融合用户 LM 仍作用于兜底路径，但不再承载主力体验。
- **基准统一**：Task 4/5 钉死与姊妹计划相同的冻结数据集，并支持把 `constrained-qwen-v1` 作为可选对照组纳入同一份报告；两套置信度（本计划 margin-logistic vs 神经路线几何平均）**不可直接比较**，报告只并列不裁决。
- **决策门排序**：C 阶段的 octagram 双轨（C3）决策必须排在姊妹计划 Task 6 bake-off 之后（见"后续阶段"）。

## Review Focus

1. **冷启动 bit-for-bit**：带空 UserLanguageModel 与不带 UserLanguageModel 的整句建议必须完全一致（含 `reason`）— 测试钉在 Task 3。
2. **全零计数字符**（候选字符在所有阶计数为 0）：得分有限、无 `log(0)`/除零，beam 仍返回 baseline — 测试钉在 Task 1。
3. **句首短上下文**（context 不足最高阶）：backoff 正确落到低阶而不是跳过位置 — 测试钉在 Task 1。
4. **v1 旧工件拒绝**：`load_ngram_model` 拒绝 `schema_version != 2` 且报错信息可指导重训 — 测试钉在 Task 1。
5. **异常 domain 值**（空串/纯空白/非 str）：FusedCharLM 与 `UserLanguageModel` 现有归一化行为一致，不抛异常 — 测试钉在 Task 3。

---

### Task 1: 静态 n-gram 改 stupid backoff（工件 v2）

**Files:**
- Modify: `rimeai_runtime/ngram_ranker.py:47-63`（`_language_score`）、`:19-21`（权重网格）、`:112-137`（`to_dict` smoothing 段）、`:301-352`（`load_ngram_model`）
- Test: `tests/test_ngram_ranker.py`

**Interfaces:**
- Produces: `NGramRankerModel.language_score(context, candidate) -> float` 签名不变（HybridSemanticRanker 与评估工具依赖它）；dataclass 新增字段 `backoff_alpha: float`；工件 `schema_version` 升为 `2`，`hyperparameters.smoothing` 变为 `{"method": "stupid-backoff", "alpha": <a>, "terminal_numerator": 0.1, "terminal_denominator": 1000.0}`。
- Consumes: 无（首个任务）。

打分算法（签名与测试不能唯一决定，固定如下）：位置级条件概率取最高有计数阶的 MLE，按回退深度乘 α 幂；全部无计数时用 2 阶加 k 平滑兜底：

```text
P(c | h) = MLE_n(c|h) * alpha ** (5 - n)     n = max{order in (5,4,3,2): count_n(h+c) > 0}
         = (count_2 + 0.1) / (prefix_2 + 1000.0) * alpha ** 3   若无任何阶有计数
```

`_language_score` 仍返回候选区间的逐位置 `log P` 均值（保持公开语义）。

- [ ] **Step 1: 写失败测试**（沿用该文件现有合成样本构造模式）

```python
def test_backoff_falls_to_lower_order_when_high_order_unseen():
    # 造样本使 "天气" 的 3/4/5 阶未见、2 阶已见：
    # 有低阶证据的候选 language_score 高于全阶未见的候选
    ...

def test_unseen_everywhere_character_gets_finite_score():
    # 全零候选字符得分有限（math.isfinite），且低于任一有证据候选
    ...

def test_short_context_uses_available_orders():
    # context="" 候选单字：位置从 "^c" 起步，2 阶 gram 命中即有分
    ...

def test_load_rejects_schema_v1_artifact():
    # 写入 schema_version=1 的 payload，断言 NGramModelError 提及重训
    ...

def test_train_reports_selected_alpha():
    # train_ngram_model 返回的 report["selected_hyperparameters"]["backoff_alpha"]
    # ∈ {0.2, 0.4, 0.6, 0.8}
    ...
```

- [ ] **Step 2: 运行确认失败**
  Run: `python -m pytest tests/test_ngram_ranker.py -v`（新用例 FAIL，`backoff_alpha` 未定义）
- [ ] **Step 3: 实现**：`NGramRankerModel` 加字段 `backoff_alpha: float`；`_language_score` 换为上述回退公式；`_BACKOFF_ALPHAS = (0.2, 0.4, 0.6, 0.8)` 加入 `train_ngram_model` 的网格（`ngram_ranker.py:215` 三层循环外再套一层）；`to_dict`/`load_ngram_model` 按 Interfaces 更新，loader 只收 `schema_version == 2`。
- [ ] **Step 4: 运行全量确认通过**
  Run: `python -m pytest tests/test_ngram_ranker.py tests/test_cli.py -v`，Expected: PASS
- [ ] **Step 5: Commit**
  ```bash
  git add rimeai_runtime/ngram_ranker.py tests/test_ngram_ranker.py
  git commit -m "feat: replace equal-weight n-gram sum with stupid backoff (artifact v2)"
  ```

### Task 2: 用户 LM 同步回退公式 + 位置级条件概率

**Files:**
- Modify: `rimeai_daemon/user_lm.py:23-38`（常量区）、`:71-97`（`DomainCounts.mean_log_prob` 拆出条件概率）
- Test: `tests/test_user_lm.py`

**Interfaces:**
- Produces: `DomainCounts.conditional_prob(history: str, character: str) -> float | None`（history 为已确定文本、character 为下一字；None 表示该层完全无证据 `characters <= 0`；公式与 Task 1 相同，`BACKOFF_ALPHA = 0.4` 模块常量）；`mean_log_prob` 改为对候选逐位置调 `conditional_prob` 取均值，公开签名与返回语义不变。`SCHEMA_VERSION`、payload 结构不变（计数格式未变）。
- Consumes: Task 1 的回退算法（复制实现，维持 user_lm 不 import rimeai_runtime 的现状）。

- [ ] **Step 1: 写失败测试**：`test_conditional_prob_uses_backoff`（高阶未见、2 阶见时非 None 且与手算 `MLE_2 * 0.4**3` 一致）；`test_conditional_prob_none_when_domain_empty`；`test_mean_log_prob_unchanged_semantics`（现有用例之外补一个均值 = 逐位置 log 均值的等值断言）。
- [ ] **Step 2: 运行确认失败**
  Run: `python -m pytest tests/test_user_lm.py -v`，Expected: FAIL（方法不存在）
- [ ] **Step 3: 实现**：`DomainCounts` 新增 `conditional_prob`，`mean_log_prob` 改为逐位置复用之；不动 `observe`/persistence。
- [ ] **Step 4: 运行确认通过**
  Run: `python -m pytest tests/test_user_lm.py tests/test_consolidation.py -v`，Expected: PASS
- [ ] **Step 5: Commit**
  ```bash
  git add rimeai_daemon/user_lm.py tests/test_user_lm.py
  git commit -m "feat: add backoff conditional_prob to user LM domains"
  ```

### Task 3: CharLMScorer 协议 + FusedCharLM 接入 beam decoder

**Files:**
- Create: `rimeai_runtime/lm_fusion.py`（协议 + 静态适配器）
- Create: `rimeai_daemon/fused_lm.py`（融合打分器）
- Modify: `rimeai_runtime/beam_decoder.py:59-125`（构造器与 `_next_score`/`_sequence_score`）、`:144-297`（`raw_decode`/`suggest`/`suggest_segments` 加可选 scorer）
- Modify: `rimeai_daemon/engine.py:84-88`（decoder 构建）、`:234-255`（整句路径按请求构造融合打分器）
- Test: Create `tests/test_lm_fusion.py`；Modify `tests/test_beam_decoder.py`、`tests/test_daemon_engine.py`

**Interfaces:**
- Produces（`rimeai_runtime/lm_fusion.py`）:
  ```python
  class CharLMScorer(Protocol):
      max_context_characters: int
      def next_char_log_prob(self, context: str, character: str) -> float: ...
      def character_frequency(self, character: str) -> int: ...

  class StaticCharLM:  # implements CharLMScorer
      def __init__(self, model: NGramRankerModel) -> None: ...
  ```
  `next_char_log_prob` = Task 1 回退公式的 log；`character_frequency` 取 2 阶计数派生（与 `beam_decoder.py:69-75` 现逻辑一致）。
- Produces（`rimeai_daemon/fused_lm.py`）:
  ```python
  class FusedCharLM:  # implements CharLMScorer（鸭子类型，不 import Protocol 也可）
      def __init__(self, base: CharLMScorer, user_lm: UserLanguageModel, domain: str | None) -> None: ...
  ```
  融合按 `docs/LANGUAGE_PROFILE_DESIGN.md` §4.2：`P = λ1·P_base + λ2·P_user_global + λ3·P_user_domain`，λ 来自 `UserLanguageModel.user_weights(domain)`（已含贝叶斯收缩与 0.35 封顶），λ1 = 1 − λ2 − λ3；某层无证据（`conditional_prob` 为 None 或权重为 0）时该层权重归并入 λ1；两层均无证据 → 直接返回 `base.next_char_log_prob`（保证 Review Focus 1）。domain 归一化复用 `UserLanguageModel` 内部逻辑（构造时调一次 `user_lm` 的解析）。
- Consumes: Task 1（`StaticCharLM` 的回退打分）、Task 2（`conditional_prob`）。
- `BeamSentenceDecoder` 改造：构造器保持 `(language_model: NGramRankerModel, guard, config)` 兼容（内部包 `StaticCharLM`，`train_beam_decoder_config` 与既有调用不改动）；`suggest` / `suggest_segments` / `raw_decode` 增加关键字参数 `scorer: CharLMScorer | None = None`，None 时用默认静态打分器。`_next_score` = `0.5 * math.log1p(character_frequency) + next_char_log_prob`（保持频率先验项静态、来自 decoder 自身）。
- `LocalInferenceEngine.infer` 整句分支：`self._user_lm` 非空且取到合法 domain 时构造 `FusedCharLM` 传入；构造与打分抛出的任何异常按现有 fail-closed 风格捕获后用默认打分器重试一次或直接走静态建议。
- 性能预算：beam 每位置打分调用 ≈ beam_width × characters_per_syllable（默认 16×20，30 位置上限即万次级），融合使单次打分成本约翻倍；实现不得引入逐次字典拷贝/重建，实测 P95 由 Task 5 验证，超标先加 gram 查询缓存再讨论降配。
- 神经融合是 n-gram 打分的隐藏依赖方（`neural_ranker.py:658` 调私有 `_candidate_score`，`neural_ranker.py:732` 以其标定 fusion 权重）；本任务不改融合行为，Task 5 负责重标定。

- [ ] **Step 1: 写失败测试**
  - `tests/test_lm_fusion.py`：`test_fused_equals_base_without_user_evidence`（空 UserLanguageModel，逐 (context,char) 断言相等）；`test_fused_shifts_toward_user_domain`（用 `observe` 灌入偏好文本后，偏好字符的 `next_char_log_prob` 高于纯静态）；`test_fused_handles_blank_domain`（`"  "` 与 None 行为一致）。
  - `tests/test_beam_decoder.py`：`test_suggest_accepts_custom_scorer`（传 StaticCharLM 与不传结果一致）；`test_scorer_exceptions_do_not_escape_raw_decode`? — 否：按 Interfaces，beam 不捕获，engine 层捕获；本测试只钉 scorer 参数默认路径。
  - `tests/test_daemon_engine.py`：`test_sentence_path_identical_with_empty_user_lm`（无 user_lm 工件 vs 空 user_lm 工件，`infer` 输出全等）；`test_user_lm_domain_influences_sentence_suggestion`（构造偏置用户 LM 后整句建议改变或 reason 不变但文本变，至少断言不再与静态输出全等且不抛异常）。
- [ ] **Step 2: 运行确认失败**
  Run: `python -m pytest tests/test_lm_fusion.py tests/test_beam_decoder.py tests/test_daemon_engine.py -v`，Expected: 新用例 FAIL（模块不存在）
- [ ] **Step 3: 实现** 三个文件按 Interfaces；`engine.py` 只在 `allow_sentence` 分支构造 FusedCharLM（每请求 O(1)）。
- [ ] **Step 4: 运行确认通过**
  Run: `python -m pytest tests/test_lm_fusion.py tests/test_beam_decoder.py tests/test_daemon_engine.py tests/test_user_lm.py -v`，Expected: PASS
- [ ] **Step 5: Commit**
  ```bash
  git add rimeai_runtime/lm_fusion.py rimeai_daemon/fused_lm.py rimeai_runtime/beam_decoder.py rimeai_daemon/engine.py tests/test_lm_fusion.py tests/test_beam_decoder.py tests/test_daemon_engine.py
  git commit -m "feat: fuse user LM into beam sentence decoding via CharLMScorer"
  ```

### Task 4: `sentence-benchmark` 基准命令

**Files:**
- Create: `rimeai_eval/sentence_benchmark.py`
- Modify: `rimeai_eval/cli.py`（subparsers 区 `cli.py:226-330` 加 parser；handler 仿 `_evaluate_sentence` `cli.py:908` 风格）
- Test: Create `tests/test_sentence_benchmark.py`

**Interfaces:**
- Produces（`rimeai_eval/sentence_benchmark.py`）:
  ```python
  def levenshtein(a: str, b: str) -> int: ...
  def benchmark_sentence_decoder(samples: list[dict], decoder: BeamSentenceDecoder, *, min_confidence: float = 0.0) -> dict: ...
  ```
  返回 report dict：`{"schema_version": 1, "benchmark_type": "sentence-benchmark", "samples": N, "metrics": {"baseline_sentence_accuracy", "decoder_sentence_accuracy", "baseline_char_accuracy", "decoder_char_accuracy", "gold_in_top10_coverage", "mean_edit_distance", "decoder_latency_ms": {"p50", "p95"}}, "decision_counts": {<reason>: count}, "hyperparameters": {"min_confidence": ...}}`。字正确率 = `1 - lev(pred, gold)/max(len(gold),1)` 全样本平均；baseline 取 `candidates[0]`，decoder 取按 `min_confidence` 门控后的建议（`suggestion.text` 或回落 `candidates[0]`，回落原因计入 decision_counts）；`decoder_latency_ms` 为逐样本 decode 耗时的分位数（融合臂另出 `fused_decoder_latency_ms`，供 Task 5 Step 5 的 P95 预算验证）。
- CLI: `sentence-benchmark DATASET --language-model PATH --decoder-config PATH --rime-dictionary PATH [--user-lm PATH] [--command-decoder-config PATH] [--split test] [--min-confidence 0.0]`，结果 JSON 打印到 stdout（随 `train-ngram` 风格）。复用 `load_dataset`、`load_ngram_model`、`load_beam_config`、`PinyinGuard`、`BeamSentenceDecoder`；`--user-lm` 存在时构造 `FusedCharLM` 逐样本传入（domain 取样本 `domain` 字段，缺省 None），并同时输出"静态 vs 融合"两组 metrics（key 前缀 `fused_`）。
- `--command-decoder-config`（可选神经对照组，指向 `examples/constrained_qwen_decoder.json` 一类配置）：经 `CommandSentenceDecoder.from_config`（`rimeai_eval/command_sentence_decoder.py:45`）加载，逐样本产出 `neural_sentence_accuracy`、`neural_abstain_rate`（suggestion 为空比例）；未提供时报告不含 `neural_` 键。置信度与本计划的 margin-logistic 不可比，报告只并列。
- 基准数据集钉死为姊妹计划同款冻结集：`.rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl`（test split）；单测用合成小数据集，不依赖该文件存在。
- Consumes: Task 3 的 `scorer` 参数。

- [ ] **Step 1: 写失败测试**：`test_levenshtein_known_values`（`("", "abc")==3`、`("kitten","sitting")==3`）；`test_benchmark_counts_decisions_and_coverage`（3 个合成样本，gold 分别在/不在 Top-10，断言 coverage 与 decision_counts）；`test_benchmark_report_shape`（断言上列 key 全存在）；`test_command_decoder_arm_omitted_without_flag`（不传 `--command-decoder-config` 时报告无 `neural_` 键；monkeypatch `CommandSentenceDecoder.from_config` 返回假解码器后传 flag，断言 `neural_sentence_accuracy`/`neural_abstain_rate` 存在）；`test_cli_sentence_benchmark_runs`（仿 `tests/test_cli.py` 现有子命令测法，最小工件跑通退出码 0）。
- [ ] **Step 2: 运行确认失败**
  Run: `python -m pytest tests/test_sentence_benchmark.py -v`，Expected: FAIL（模块不存在）
- [ ] **Step 3: 实现** 模块与 CLI 注册。
- [ ] **Step 4: 运行确认通过**
  Run: `python -m pytest tests/test_sentence_benchmark.py tests/test_cli.py -v`，Expected: PASS
- [ ] **Step 5: Commit**
  ```bash
  git add rimeai_eval/sentence_benchmark.py rimeai_eval/cli.py tests/test_sentence_benchmark.py
  git commit -m "feat: add sentence-benchmark command with coverage and edit-distance metrics"
  ```

### Task 5: 重训工件 + 重标定 + 记录基线（运维任务，无新测试）

**Files:**
- 无代码改动；产物写入 `.rimeai/`（模型/配置）与 `.rimeai/reports/`（基准报告）。

- [ ] **Step 1: 重训 n-gram（v2 工件）**
  Run: `python -m rimeai_eval train-ngram <真实数据集路径> --output .rimeai/models/rankers/ngram-backoff-v2.json.gz`（路径按项目现有工件布局调整）
- [ ] **Step 2: 重训 beam config（绑定新 LM sha256）**
  Run: `python -m rimeai_eval train-beam-decoder <数据集...> --language-model <v2 工件> --rime-dictionary <词典> --output <beam config>`
- [ ] **Step 3: 重标定神经融合 + 同步 worker 工件**
  Run: `python -m rimeai_eval train-neural-fusion <数据集> --neural-model <24M 模型目录> --language-model <v2 工件> --rime-dictionary <词典> --output <新 fusion config>`
  必要性：`FusionConfig` 只绑定 `ngram_dataset_sha256`（`neural_ranker.py:306-309`），数据集未变时旧 fusion config 会**静默通过校验**但标定值（neural_weight / margin_threshold）基于旧打分分布，必须重跑。同时把 `tools/ngram_ranker_worker.py` / `tools/beam_sentence_worker.py` 所引用的 n-gram 工件（`examples/ngram_ranker.json` 等配置指向的路径）替换为 v2 工件。另：`language_profile_eval.py:26` 以 n-gram 打分为基线，复跑 language-profile 评估并把漂移后的数字注记进报告（首评 +0.299 nats/字将失效）。
- [ ] **Step 4: 跑基线并归档（钉死冻结数据集 test split）**
  Run: `python -m rimeai_eval sentence-benchmark .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl --language-model <v2> --decoder-config <新 config> --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml --user-lm <用户 LM 工件> > .rimeai/reports/sentence-benchmark-baseline.json`
  记录四个门控数字：`gold_in_top10_coverage`、`decoder_sentence_accuracy - baseline_sentence_accuracy`、`fused_` 相对静态的增量、命令耗时。
- [ ] **Step 5: 整句路径延迟实测**
  用同一冻结集对比静态 beam 与融合 beam 的逐样本耗时分布（`sentence-benchmark` 两组 `metrics` 增加逐样本计时或在 details 里记录），验证本地路径 P95 回归 ≤ +1ms 预算（`docs/LANGUAGE_PROFILE_DESIGN.md` §8）；超标则在 `FusedCharLM` 侧加 gram 查询缓存后重测，仍超标需回到计划裁决。
- [ ] **Step 6:（可选）纳入神经对照组**
  若姊妹计划已产出 `examples/constrained_qwen_decoder.json` 且 worker 可用：加 `--command-decoder-config examples/constrained_qwen_decoder.json` 重跑，`neural_` 指标并入同一报告；不可用则跳过并在报告手注"待 constrained-qwen-v1 bake-off"。C 阶段（尤其 C3 octagram 双轨）的启动决策**排在姊妹计划 Task 6 对照赛之后**，以本报告 + 其 `docs/baselines/constrained-qwen-v1.json` 共同裁决。
- [ ] **Step 7: Commit 报告**
  ```bash
  git add .rimeai/reports/sentence-benchmark-baseline.json
  git commit -m "chore: record sentence benchmark baseline after backoff+fusion"
  ```

## 后续阶段（另行立项，本计划不做）

按 Task 5 的门控数字决定是否启动；**C3 及任何整句路线扩张决策必须排在姊妹计划（constrained-qwen-v1）Task 6 对照赛之后**，避免 n-gram beam、octagram、神经约束解码三路线并存：

| 候选项 | 启动门 | 要点 |
|---|---|---|
| C1 语料扩规模 | 静态 LM 是当前瓶颈（benchmark 显示回退平滑后提升 < 1pt） | 扩 `datasets/corpora.lock.json` 多领域源；先做 C2 |
| C2 计数存储 trie/mmap 化 | 准备承接 >1GB 计数表 | gzip JSON → DAWG/marisa-trie 或 sqlite 只读；万象用 C++ 前缀树 + mmap 的先例 |
| C3 octagram 双轨模式 | 姊妹计划 bake-off 完成且神经路线精度或延时不达标，**同时** `gold_in_top10_coverage` < 85%（冻结边界成为主要损失源） | 自训 n-gram 编译为 `.gram`，librime 编 octagram 插件做引擎内兜底；注意引擎内打分与词库权重的联合调参耦合 |
| C4 词典质量工程 | C3 评估后仍受词库限制 | 借鉴万象方法论（AI 筛选+人工校对+双键词频+错音词库），不得复制 GPL-3.0 词表内容 |

对姊妹计划的建议（不在本计划任务内）：其 Phase 2 接入 daemon 前需先定义与现役 beam 建议的**仲裁策略与置信度校准**——两路线置信度口径不同，不可裸比。

## Self-Review 记录

- Spec 覆盖：§4.2 融合公式 → Task 3；§6 整句注入 → Task 3；回退平滑 → Task 1/2；评测口径 → Task 4；神经层改动按 Global Constraints 排除。C 阶段单列门控。
- 类型一致性：`CharLMScorer.next_char_log_prob(context, character)`、`character_frequency(character)`、`conditional_prob(history, character)` 全文一致；`StaticCharLM(model)` 与 `FusedCharLM(base, user_lm, domain)` 构造签名在 Task 3/4/5 用法一致。
- 比例：5 个任务 + 1 个门控路线图，正文以签名与断言为主，无函数体转写。
- 修订（2026-10-13，对齐姊妹计划）：新增"与拼音约束解码计划的关系"节；Task 4/5 钉死冻结数据集并支持神经对照组；C3 门控改为排在 constrained-qwen-v1 bake-off 之后。
- 修订（2026-10-13 二次，自审三处）：Task 3 新增融合打分的性能预算说明；Task 4 报告增加逐样本 decode 延迟分位数（`decoder_latency_ms` / `fused_decoder_latency_ms`）；Task 5 扩为 7 步——补 `train-neural-fusion` 重标定（旧 fusion config 因只绑数据集 sha 会静默失效）、P0 worker 工件同步、language-profile 基线复跑注记、融合路径 P95 实测门。
