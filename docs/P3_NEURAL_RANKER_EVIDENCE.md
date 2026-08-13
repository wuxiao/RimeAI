# P3 神经语义排序与扩展长句证据

## 结论

状态：**CHECKED IMPLEMENTATION / QUANTIZED MACOS RELEASE CANDIDATE**

`RimeAI-Ranker-S-24M` 已完成训练、冻结集比较和 macOS daemon 接入。生产路径
使用验证集选择的 0.5/0.5 神经+n-gram 分数融合，n-gram 同时保留为神经推理
失败时的本地回退。11–30 字长句已建立独立冻结集并通过完整拼音、准确率和
延迟检查。

这些结果允许内部 macOS 使用。自包含运行时、INT8 量化、签名、制品清单和
回滚已完成；它们不解除公证、法律审查、最低设备和真实用户接受率等外部门槛。

## 24M 排序器

- 基础模型：`BAAI/bge-small-zh-v1.5`
- 固定 revision：`7999e1d3359715c523056ef9478215996d62a620`
- 架构：4 层、hidden size 512、8 attention heads
- 训练后参数量：24,176,129
- 输入：最多 100 字应用内上下文、无声调拼音音节 token、候选 marker、
  Rime 原始位次和 Top-10 候选
- 训练：listwise cross entropy，3 epochs；上下文歧义样本重复采样
- 数据隔离：只读取 train/validation，manifest 记录 `test_samples_used = 0`
- 神经制品 ID：`rimeai-ranker-s-24m:d2e5385dc877f058`
- 融合制品 ID：`rimeai-24m-fusion:5b4d49e54e480249`

融合权重和置信阈值只由 validation 选择。冻结 test 的 Rime Top-10 结果：

| 指标 | 结果 |
|---|---:|
| covered samples | 789 / 974 |
| n-gram conditional Top-1 | 94.6768% |
| 24M 融合 raw conditional Top-1 | 95.6907% |
| 24M 融合 raw conditional CER | 3.2589% |
| 0.90 产品阈值 conditional Top-1 | 94.4233% |
| 0.90 产品阈值低置信回退 | 19 |
| CPU P50 / P95 | 15.24ms / 35.79ms |
| 预热冷启动 | 1.84s |
| 推理错误 | 0 |

0.90 产品阈值结果应与同样应用置信回退的基线比较，不能拿它代替 raw 模型
能力。daemon 可以展示 0.55 以上的可选语义候选，但只有 0.90 以上结果会由
`Space` 采用。

## 上下文消融

对 test 中 680 条至少包含两个完整等长候选的样本，保持拼音和候选不变，只把
上下文替换为空：

| 指标 | 有上下文 | 空上下文 |
|---|---:|---:|
| Top-1 | 94.7059% | 93.6765% |

上下文使 21 条结果发生变化，其中 14 条从错误变正确、7 条从正确变错误。
真实 daemon 示例：上下文“如果事件循环为空，则程序会”、拼音 `tuichu`、
候选“推出/退出/退除”返回“退出”，置信度约 0.93；去掉上下文后保持 Rime
首选“推出”。这证明当前词义判断实际使用了同一应用先前已上屏文本。

## 11–30 字完整长句

扩展数据由同一许可源和文档级 split 派生，保持原始 split，不读取 test 标签
选择阈值：

- 样本数：1,600（developer/general 各 800）
- split：train 1,273 / validation 149 / test 178
- 目标长度：11–30 字，每个长度均有真实样本
- 候选引擎：librime 1.17.0，`luna_pinyin_simp`
- dataset SHA-256：
  `4eea3e7d3638dd6596e8d2c5f4189986209c7dd65c1c83f3abccebeb860ec41d`

0.97 产品阈值的冻结 test 结果：

| 长度 | Rime 首选准确率 | 整句准确率 | 相对提升 | P95 |
|---|---:|---:|---:|---:|
| 6–10 字 | 31.0513% | 44.7433% | 44.0948% | 6.97ms |
| 11–30 字 | 21.9101% | 30.3371% | 38.4617% | 14.71ms |

11–30 字 test 中 105 条建议通过 0.97 阈值。所有可提交建议都必须由冻结 Rime
词典证明覆盖完整拼音；超过 30 字、只有拼音前缀候选或置信度不足时返回空结果，
不会把半句话伪装成完整推导。

## daemon 稳定性

PyTorch MPS 在 LaunchAgent 的“请求超时但底层原生调用仍继续、下一请求进入”
场景发生过原生段错误。生产 daemon 因此采用 CPU，并做了两项修复：

1. Socket 开放前执行模型预热，首个用户请求不承担 lazy kernel 开销。
2. 所有原生推理进入单线程 executor；asyncio 任务取消或超时后，下一请求也不
   会与仍在运行的底层调用并发。

回归测试覆盖超时后立即发起下一请求。安装后的真实 Unix Socket 连续 20 次
神经请求全部成功，P50 10.09ms、最大 30.91ms；握手同时报告语言模型、整句
配置、Rime 字典、神经 manifest 和融合配置的路径与 SHA-256。

## INT8 ONNX 运行时

浮点 checkpoint 已按 opset 17 导出并对 MatMul/Gemm 执行 per-channel dynamic
INT8 量化。运行制品只包含模型、tokenizer 和身份清单：

- ONNX 制品 ID：`rimeai-ranker-s-24m-onnx:d812102db0586701`
- 来源 checkpoint：`rimeai-ranker-s-24m:d2e5385dc877f058`
- INT8 模型：58,144,989 bytes，SHA-256
  `01f4361455f8de882598fea9bb5ebbe61f6543b6ecb6f541a22e15fc47bd2e2d`
- 量化融合制品 ID：`rimeai-24m-fusion:96a44df2d2d8ee63`
- runtime：ONNX Runtime 1.19.2、tokenizers 0.15.2、CPU、串行请求

量化后重新只使用 validation 校准融合与置信阈值，再运行同一冻结 test：

| 指标 | INT8 ONNX |
|---|---:|
| covered samples | 789 / 974 |
| raw conditional Top-1 | 95.1838% |
| 0.90 产品门 conditional Top-1 | 94.5501% |
| CPU P50 / P95 | 15.17ms / 42.70ms |
| 冷启动 | 119.49ms |
| 推理错误 | 0 |

量化 raw 相对浮点 raw 下降约 0.63 个百分点，低于 1 个百分点门；量化产品门
结果比浮点产品门 94.4233% 高约 0.13 个百分点。P95 仍低于 50ms 模型目标，
也远低于 400ms UI 截止。领域分层为 developer 98.3908%、general 89.8305%、
mixed 95.1417%、technical 98.3908%，因此不能把总体数字外推成所有场景同质。

## 尚未解除的门槛

- 量化模型的大制品位于不提交的 `.rimeai/` 目录；可重复发布脚本、逐文件
  清单、Developer ID 签名、版本化安装和回滚已完成。
- LaunchAgent 使用自包含 Python 3.9.6 + ONNX Runtime，不依赖本机 Python、
  PyTorch、Transformers 或 safetensors。
- Apple 公证、最低 Apple Silicon 设备的能耗/温度和长时间稳定性未验。
- iOS 仍使用紧凑 n-gram 过渡制品；Windows/Android 尚未实现。
- 接受率、10 秒撤销/回删率和十个宿主应用矩阵需要真实内部预览数据。
