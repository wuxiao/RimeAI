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

## 7. 软标签蒸馏可行性实测（2026-10-22 实测，2026-10-24 家族矩阵复测与拍板）

LM-002 新定义的默认形态是「教师 glm-5.3-flash 的 token 分布软标签蒸馏」。
实测结论：**该前提不成立**——智谱 API（`open.bigmodel.cn`）在
coding（`/api/coding/paas/v4`）与标准（`/api/paas/v4`）两端点均对
`logprobs: true, top_logprobs: N` 静默忽略（响应 choice 仅含
`finish_reason/index/message`，无 logprobs 字段；两端点各实测一次，
温度 0、thinking disabled/low 均试过）。

2026-10-24 家族矩阵复测（temperature 0，chat completions 标准参数）：
glm-5.3 / glm-4.7 / glm-4-flash × coding/paas 两端点**全部静默忽略
logprobs**——token 级软标签在智谱家族内平台级不可用。

**拍板（2026-10-24，用户）：A + D + B(教师锁定 glm-5.3) 组合**：

- **D 骨架**：硬标签臂 + LM-004 真实数据重训（0.5B / 1.5B 同数据
  同超参双跑，门不变，管道全套现成）；
- **A+B 合流的数据放大器**：教师 = glm-5.3 序列级——批量造数
  （拼音种子 → 教师生成 → **词典对齐过滤器**：教师句子必须可被
  本地词典掩码路径复现才进训练集，不可复现丢弃并计数，工程化
  尊重 D4「云端文本不作金标」边界）→ 泄漏检查（v2 剔除语义）→
  与真实数据混合；教师在线 adopted 正样本继续随 LM-004 积累；
- **token 级软标签**：智谱家族全灭即关闭；重启触发条件＝供应商
  变更（换出智谱家族且新供应商支持 logprobs），届时重新实测。

执行顺序：数据扩充臂（教师造数 + 对齐过滤器 + 混合管道）可先行；
真实数据到 1000 行后 D 重训双跑冲门；不过门则错误分类复盘。

实测原始响应存 `/tmp/logprobs-test*.json`（会话内临存，结论已录本节）。

## 8. 基座对照（2026-10-22）：Qwen3.5 架构不兼容（负结果）与 Qwen2.5-1.5B 阶梯（正结果）

### 8.1 Qwen3.5-2B：混合线性注意力与 per-path KV 回滚协议不兼容（负结果，证据链完整）

按原计划文档先试 Qwen3.5-2B-Base（8-bit convert + 同配方 2k iters，
train loss 10.4→5.2）后冻结集 **974 全空建议、p50 0.5ms**。逐层诊断：

1. 拼音索引正常（53426/248044 tokens，比 0.5B 更多）；
2. SFT 后自由生成正常中文（排除模型/转换损坏）；
3. beam 展开时 `prompt cache is not trimmable`——`trim(1)/trim(3)` 均
   返回 **0**；
4. 架构根因：Qwen3.5 `layer_types` 为
   `linear_attention×3 + full_attention` 混合——线性注意力层的
   recurrent 状态不可任意修剪，mlx-lm `trim_prompt_cache` 对该架构
   无效。

结论：**Qwen3.5 系列与 TD-009 协议的 per-path KV 回滚缓存机制根本
不兼容**（beam 回跳必触发 fail-closed），协议级扩展（beam 独立
prefill / 混合层选择性修剪）超出对照臂范畴。基座对照改在同代
Qwen2.5 家族内做（更纯控制变量）。4B 下载取消止损。

### 8.2 Qwen2.5-1.5B + 同配方：规模阶梯（正结果）

同数据/同超参/同 seed，仅基座放大：

| 配置 | 句准确率 | model_path_miss | failures | fixed/reg | p50 |
| --- | --- | --- | --- | --- | --- |
| 0.5B 基线（无 SFT） | 0.9220 | 61 | 76 | 201/11 | 115ms |
| 0.5B + SFT 2k | 0.9415 | 44 | 57 | 216/7 | 124ms |
| **1.5B + SFT 2k** | **0.9559** | **32** | **43** | 232/9 | 218ms |

- 1.5B 臂的 target 桶 **-47.5%**（距 LM-002 门的 -50% 线一步之遥，
  且门还要求真实历史留出集双跑）；
- 代价：时延 ×1.8（218ms），超同规模门的 ×1.2 上限——部署取舍是
  精度换延迟，后续可用 INT8/4-bit 或蒸馏回 0.5B 压缩；
- 制品 lock：`models/qwen2.5-1.5b-mlx-8bit-sft.lock.json`（含阶梯表）。

### 8.3 对 LM-002 默认臂的含义

- “基座对照”在同代家族内完成（0.5B→1.5B 单调改善）；Qwen3.5 系
  列在协议扩展前不可作为基座候选；
- 默认臂（软标签/序列级蒸馏，取向待拍板，见 §7）的数据链就绪后，
  1.5B 是更合理的默认学生规模候选（精度达标概率高，延迟预算需要
  产品侧确认）。

## 9. 剩余事项

- 2B/4B 基座对照（同配方的规模消融，LM-002 行内"基座对照"项）；
- 软标签蒸馏默认形态（LM-003 决策日志 → LM-004 冻结数据集后启动），
  本对照臂数字作为其成本/收益基线；
- Release/PyInstaller 打包仍不含 MLX 依赖（与 LM-001 同边界）。

## 10. D 臂首日（2026-10-24）：新数据在当前形态下是稀释项（负结果，四配方全景）

数据：`datasets/sft-constrained-v1.jsonl` 1124 行（真实 193 + 教师
glm-5.3 造数 931，usable=true）。同超参（lr 1e-4 / batch 4 / seed 42
/ max-seq 256 / LoRA 16 层 / 2000 iters，除注明外）只变数据
配方：

| 配方 | 句准确率 | model_path_miss | failures | regressions |
| --- | --- | --- | --- | --- |
| 基线（无 SFT） | 0.9220 | 61 | 76 | 11 |
| 对照臂（纯 zhwiki 8044） | **0.9415** | **44** | **57** | **7** |
| D 纯新数据（1124，ckpt200 最佳） | 0.7382 | — | — | — |
| D 纯新数据 2000 iters | 0.7084 | 248 | 284 | 74 |
| D 混合 ×3（新数据 25%） | 0.9240 | 57 | 74 | 11 |
| D 混合 ×1（新数据 10%） | 0.9343 | 49 | 64 | 10 |

结论：

1. **单调稀释**：新数据占比越高越差（0%→0.9415，10%→0.9343，
   25%→0.9240，100%→0.7084）；纯新数据负迁移（regressions 74
   直接违反门③）且检查点扫描（200/400/800/2000 = 0.738→0.708
   单调降）证明不是 iters 问题，是数据形态问题；
2. **根因：句长/域不同构**——教师造数种子 2-5 词（4-16 音节）
   短句，评测集为长句（45% developer 技术域）；zhwiki 对照臂数据
   恰与评测同构；
3. 混合 ×1 无害（reg 10 vs 基线 11）但无增益——新数据当前质量下
   不带来任何配方收益；
4. **下一步（治本）**：teacher_synthesis 升级长句模式
   （MIN/MAX_WORDS 对齐评测句长分布，4-12 词）重造数 → 混合 ×1
   重训；1.5B 学生按趋势推断同样被稀释，暂不消耗（等长句造数后
   一起跑）；真实数据继续积累（教师造数治标，真实长句偏好才是
   治本）；
5. 制品：`.rimeai/models/qwen2.5-0.5b-mlx-8bit-lm002d{,-mix,-mix1}-v1`
   各带 manifest（weights_sha256 程序化）；均未过门，不替换产品
   基座。

### 10.1 真实历史留出集（2026-10-24 深夜）：趋势反转，混合×1 双集全正

门①③要求冻结集与真实历史留出集双跑。留出集构建：history
整句提交去重（拼音+文本）后排除冻结评测集拼音重叠，时间 80/20
切分，尾部 48 样本（candidates=[gold] 占位，基线恒 1.0 无意义，
decoder 句准确率照常有效；empty 19/48 三模型同值，为约束下无
合法路径样本，公平可比）：

| 模型 | 冻结集（技术域词级） | 真实留出集（用户整句） |
| --- | --- | --- |
| 基线（无 SFT） | 0.9220 | 0.8333 |
| 对照臂（纯 zhwiki） | **0.9415** | **0.7708（负增益 -6.3pp！）** |
| D 混合 ×1 | 0.9343 | **0.8542（+2.1pp）** |

结论修正：

1. **对照臂在真实分布上比基线还差**——zhwiki 技术域 SFT 在用户
   分布上是过拟合伤害；单冻结集数字会完全误导制品选择；
2. **混合 ×1 是唯一双集都不劣于基线的配方**（冻结 +1.2pp /
   真实 +2.1pp）——门①按“现制品=当前部署基座 0.9220”口径差
   0.8pp（+1.2 < +2），门③ reg 10 ≤ 基线 11 ✓；
3. 新数据的作用面确认是**真实分布**——教师造数的种子应从真实
   用户拼音分布采样（history 高频词组合）而非随机词典词，
   冻结集增益继续由 zhwiki 承担；
4. 留出集样本尚小（48），随真实积累每月重评；制品仍不替换
   （门①未满）。

### 10.2 用户分布种子与 iters 补偿（2026-10-24 深夜）：mix2 退步，mix1 定为最佳候选

两个补偿尝试（mix2 = mix1 数据 + 用户分布教师 98 行 + iters
2400 补偿稀释）：冻结 0.9322 / 真实 0.8333——双集都比 mix1
退步（冻结 -0.2pp / 真实 -2.1pp）。iters 2400 让 zhwiki 域
加深重现在真实集上的过拟合伤害；98 行用户教师数据量救不
回来。

辅助正结果：用户分布种子（history 整句+高频词 130 个）教师
造数保持率 **78%**（98/125），远高于随机词典种子的 23%——
种子分布对齐价值实证，且 `teacher_synthesis --seeds-file`
已支持直喂种子（解耦设计）。

**配方全景（五配方，冻结/真实双集）：**

| 配方 | 冻结集 | 真实留出集 |
| --- | --- | --- |
| 基线（无 SFT） | 0.9220 | 0.8333 |
| 对照臂（纯 zhwiki） | 0.9415 | 0.7708 |
| D 混合 ×1（mix1） | 0.9343 | **0.8542** |
| D 混合 ×1 + 用户教师 + 2400 iters（mix2） | 0.9322 | 0.8333 |
| D 纯新数据 | 0.7084 | 未评 |

**结论：mix1 是当前最佳候选制品**（唯一双集全正：冻结 +1.2pp
/ 真实 +2.1pp）；门①差 0.8pp。配方搜索在当前数据规模（真实
+教师 ~1000 行）已到收益边界——下一步依赖真实数据积累周期
（decision_log 预计数周内到数千行）后重跑 mix 配方；教师造数
随 --seeds-file 已就绪随时扩充用户分布数据。

### 10.3 1.5B-mix1（2026-10-24 深夜）：冻结门过线，双制品互补卡门

1.5B + mix1 数据（8943 行，iters 2000，同对照臂超参）：

| 制品 | ①冻结（需≥0.9420） | ①真实（需≥0.8533） | ②miss（需≤30） | ③reg（≤11） | ④p50（≤138ms） |
| --- | --- | --- | --- | --- | --- |
| 0.5B-mix1 | 0.9343 ✗(-0.77pp) | 0.8542 ✓ | 49 ✗ | 10 ✓ | ~124ms ✓ |
| 1.5B-mix1 | **0.9497 ✓(+2.77pp)** | 0.8333 ✗(+0.0pp) | 37 ✗ | 12 ✗(微超 1) | 180ms ✗(×1.56) |

两制品互补卡门：0.5B-mix1 缺冻结侧（0.77pp）与 miss 桶（19
个）；1.5B-mix1 过冻结门（1.5B 基座规模红利）但真实集零增益、
miss 差 7、延迟超 42ms。收敛瓶颈一致指向**真实数据规模**。

1.5B-mix1 的额外价值：为「1.5B 本地教师 → 0.5B 学生」序列级
蒸馏路径提供制品（教师升级：glm→1.5B 本地，零 API 成本，
seeds-file 通道 78% 保持率已验证）——待真实数据积累后与 mix
配方重跑一起评估。

### 10.4 本地 1.5B 教师蒸馏（2026-10-24 深夜）：负结果，教师占比稀释律再次确认

B 实验：1.5B-mix1 当本地教师（约束解码造数 4027 种子：kept 3947
/98%、空 80、错位 0——完胜 API 教师 23% 保持率，且零 API 成本）。
混合重训（zhwiki 8044 + 新数据 4137，教师占 32%，同 mix1 超参）：
冻结 0.9322（持平）/ 真实无泄漏 holdout 0.7826（**基线 0.8261
的 -4.3pp**）——教师占比 32% 的稀释伤害超过规模红利，与 §10
单调稀释律一致。

**无泄漏 holdout 重测**（剔除两教师文件键后 46/48）：

| 制品 | 冻结集 | 无泄漏真实 holdout |
| --- | --- | --- |
| 基线 | 0.9220 | 0.8261 |
| 0.5B-mix1（API 教师 10%） | 0.9343 | **0.8478（+2.2pp，增益真实）** |
| 0.5B-lm002e（本地教师 32%） | 0.9322 | 0.7826（-4.3pp） |

结论：mix1 的真实增益经受住去记忆检验（+2.2pp 与原 +2.1pp 同
量级）；本地教师高占比配方否决——教师占比安全线 ≤10%（与
mix1 同水位）。

### 10.5 彻底干净留出集（2026-10-25）：唯一真实泄漏键 baidu，增益稳定 +2.1pp

按 §10.4 遗留解法执行：以训练侧全集键（zhwiki 语料 4214 键 ∪
sft-constrained-v1 4117 键）逐键核验 holdout 48 键——lock 的
`leak_check.overlapped_pinyin` 27 键中与 holdout 相交的 13 键里，
12 键已随 sft-constrained-v1 重建时的泄漏检查 v2 剔除（不在
当前任何训练源），唯一实际泄漏 = `baidu`（zhwiki 语料侧，
holdout 侧行为英文直通行 real-holdout-0008）。剔除后
`real-holdout-v2.jsonl`（47 行）与训练侧全集键交集 = 0：

| 制品 | 冻结集 | 46/48 近似版 | 47/v2 彻底干净 |
| --- | --- | --- | --- |
| 基线（无 SFT） | 0.9220 | 0.8261 | 0.8261→**0.8298** |
| 0.5B-mix1 | 0.9343 | 0.8478（+2.2pp） | **0.8511（+2.1pp）** |

（基线 46/48 版 0.8261 对应剔 2 教师；v2 剔 1 键 baidu 后为
0.8298；两版增益同量级。）结论：**去记忆检验彻底通过**——
mix1 在零训练键交集的留出集上增益 +2.1pp 与近似版一致，
真实分布增益不是记忆泄漏；制品门①（冻结集 +2pp）仍差
0.8pp，制品继续不替换，随数据积累重评。

复现（重建与评估）：

```bash
# 重建 v2（剔训练侧全集键，交集核验 0）
python3 -c "
import json
tk={r['pinyin'] for r in map(json.loads,open('datasets/sft-constrained-v1.jsonl'))}|{r['pinyin'] for r in map(json.loads,open('.rimeai/datasets/p0-zhwiki-librime-1.17.0-luna-simp.jsonl'))}
hold=list(map(json.loads,open('.rimeai/datasets/real-holdout-v1.jsonl')))
out=[r for r in hold if r['pinyin'] not in tk]
open('.rimeai/datasets/real-holdout-v2.jsonl','w').write(''.join(json.dumps(r,ensure_ascii=False)+chr(10) for r in out))
print(len(out), 'rows; intersection =', len({r['pinyin'] for r in out}&tk))"

# 双模型评估（基线 / mix1）
RIMEAI_MLX_MODEL_DIR="$PWD/.rimeai/models/qwen2.5-0.5b-mlx-8bit-v1" \
  .venv/bin/python -m rimeai_eval evaluate-sentence \
  .rimeai/datasets/real-holdout-v2.jsonl \
  --decoder-config examples/constrained_mlx_decoder.json \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --split test
RIMEAI_MLX_MODEL_DIR="$PWD/.rimeai/models/qwen2.5-0.5b-mlx-8bit-lm002d-mix1-v1" \
  .venv/bin/python -m rimeai_eval evaluate-sentence \
  .rimeai/datasets/real-holdout-v2.jsonl \
  --decoder-config examples/constrained_mlx_decoder.json \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --split test
```

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
