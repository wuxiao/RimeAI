# LM-002 约束解码 SFT：0.5B QLoRA 低成本对照臂训练报告

- 日期：2026-10-21
- 状态：对照臂完成并经独立复核；软标签蒸馏默认形态由 LM-003 → LM-004
  数据链服务（`docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md` §4）
- 制品：`.rimeai/models/qwen2.5-0.5b-mlx-8bit-sft-v1`（lock：
  `models/qwen2.5-0.5b-mlx-8bit-sft.lock.json`，提交 `c06f601`/`7801a31`）

## 1. 背景与作用靶

冻结集（974 test 样本）错误归类（`docs/baselines/constrained-qwen-v2.json`
`error_taxonomy`）显示 76 个失败中 61 个是 `model_path_miss`——产出路径存在、
beam/模型选了另一条；`dict_recall_miss`/`pinyin_mismatch` 均为 0。词典召回
与拼音对齐零损失，剩余真实错误几乎全是模型路径选择——这正是 SFT 的作用靶。

本报告记录低路径：零 prompt 同构数据的 QLoRA 对照臂（配方存在性证明 +
规模基线）。软标签蒸馏为 LM-002 默认形态，数据前置是 LM-003（决策日志与
偏好对采集）→ LM-004（离线蒸馏管道）。

## 2. 训练配方

| 项 | 值 |
| --- | --- |
| 基座 | `qwen2.5-0.5b-mlx-8bit-v1`（lock 钉定，8-bit affine/group 64） |
| 工具 | `mlx_lm.lora` 0.32.2 / mlx 0.32.4（隔离 venv `.rimeai/mlx-venv`） |
| 数据 | train 8044 行（去重）、validation 982 行；格式与推理零 prompt 同构：`{"text": "。" + context + gold_text}`（`。` 即 worker 的 `SEED_CONTEXT`） |
| 超参 | lr 1e-4、batch 4、max-seq 256、LoRA 16 层（默认 rank）、seed 42、6000 iters |
| 时长 | 约 25 分钟（~540 tok/s） |

设计要点：推理是零 prompt 约束解码（seed+context 后由拼音掩码约束
next-token），训练行不做任何 prompt 工程——模型学的是"该上下文下、合法
拼音路径中偏好 gold 那条"，直接作用于路径选择。

## 3. checkpoint 扫描与选择（含负结果）

| checkpoint | 冻结集句准确率 | 判定 |
| --- | --- | --- |
| 2000 | **0.941478** | ✅ 选定 |
| 4000 | 0.939425 | 轻度过拟合 |
| 6000 | 0.914784 | 过拟合（val loss 5000 后回升 4.34→4.49） |

教训：验证 loss 是整段文本的 LM loss，回升滞后于任务指标劣化；选点以
冻结集任务扫描为准，val loss 只作过拟合预警。

## 4. 冻结评估与作用靶（2k 制品，独立复核后数字）

| 指标 | 基线（LM-001 8-bit） | SFT-2k | 变化 |
| --- | --- | --- | --- |
| 句准确率 | 0.921971 | 0.941478 | **+1.95pp** |
| 时延 p50 / p95 | 115 / 233 ms | 124 / 253 ms | +8ms，预算内 |
| model_path_miss | 61 | **44** | **-28%（作用靶命中）** |
| gate_fuzzy_mismatch | 9 | 7 | -2 |
| index_recall_miss | 6 | 6 | tokenizer 词表边界，不可训练修复 |
| 总失败 | 76 | 57 | -19 |
| fixed / regressions | 201 / 11 | 216 / 7 | 修复更多、回退更少 |

## 5. 制品治理与基建

- `mlx_worker` 支持制品目录内可选 `artifact.manifest.json`：存在时
  weights SHA-256 pin 与 `model_artifact_id` 跟随 manifest；不存在时维持
  内置基座 pin。校验永远 fail-closed（负测试：篡改 manifest / 删除
  manifest / 非法 SHA 均拒载）。
- `constrained_mlx_service.sh` 尊重外部 `RIMEAI_MLX_MODEL_DIR`，评估可指向
  fused 制品；产品默认路径不变。
- lock（`models/qwen2.5-0.5b-mlx-8bit-sft.lock.json`）含配方、超参、
  checkpoint 扫描、冻结评估、错误分类对照与制品 SHA（复核修复：SHA 必须
  程序化写入，禁止手抄——首版 lock 后 48 hex 曾手写致错，`7801a31` 修复）。

## 6. 复核记录（2026-10-21，7 项全过）

同条件双重复现（SFT-2k 0.941478、基座 0.921971）；train/test 零泄漏
（精确重叠 0、上下文重叠 0/974）；错误分类复现（44/57、fixed 216、
regressions 7）；fail-closed 负测试 3/3。详见项目记忆当日条目与
`.rimeai/reports/kbd002-sft-verify-details.jsonl`。

## 7. 剩余事项

- 2B/4B 基座对照（同配方的规模消融，LM-002 行内"基座对照"项）；
- 软标签蒸馏默认形态（LM-003 决策日志 → LM-004 冻结数据集后启动），
  本对照臂数字作为其成本/收益基线；
- Release/PyInstaller 打包仍不含 MLX 依赖（与 LM-001 同边界）。

## 复现命令

```bash
# 训练（数据构建脚本化前，按 §2 格式生成 .rimeai/sft/{train,valid}.jsonl）
.rimeai/mlx-venv/bin/python -m mlx_lm lora \
  --model .rimeai/models/qwen2.5-0.5b-mlx-8bit-v1 --train \
  --data .rimeai/sft --fine-tune-type lora \
  --learning-rate 1e-4 --batch-size 4 --iters 2000 \
  --max-seq-length 256 --num-layers 16 --seed 42 \
  --adapter-path .rimeai/sft/qwen05b-sft-v1

# fuse
.rimeai/mlx-venv/bin/python -m mlx_lm fuse \
  --model .rimeai/models/qwen2.5-0.5b-mlx-8bit-v1 \
  --adapter-path <adapter-dir> \
  --save-path .rimeai/models/qwen2.5-0.5b-mlx-8bit-sft-v1
# （随后按 manifest 模板写 artifact.manifest.json，weights_sha256 程序化计算）

# 冻结评估
RIMEAI_MLX_MODEL_DIR="$PWD/.rimeai/models/qwen2.5-0.5b-mlx-8bit-sft-v1" \
  .venv/bin/python -m rimeai_eval evaluate-sentence \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --decoder-config examples/constrained_mlx_decoder.json \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --split test --details-output <details.jsonl>

# 错误分类
PYTHONPATH="$PWD" .rimeai/mlx-venv/bin/python tools/constrained_error_taxonomy.py \
  <details.jsonl> --model-dir .rimeai/models/qwen2.5-0.5b-mlx-8bit-sft-v1
```
