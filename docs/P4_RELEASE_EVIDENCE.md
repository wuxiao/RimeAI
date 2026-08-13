# P4 量化与发布工程证据

## 结论

状态：**CHECKED IMPLEMENTATION / BLOCKED FOR PUBLIC DISTRIBUTION**

P4 的工程范围已经完成：固定 24M checkpoint、INT8 ONNX 量化、受控 runtime、
Developer ID 签名、自包含 daemon、不可变版本、原子升级、失败恢复、回滚、
受控 macOS librime 和归因清单均已实现并在参考机验证。

Apple 公证、干净机器/最低机型、系统级抓包、十宿主矩阵、真实用户指标和法律
放行依赖外部凭据、设备、用户或法律判断，不能由仓库测试替代。

## 受控输入法原生制品

| 项目 | 值 |
|---|---|
| librime | 1.17.0 / `33e78140250125871856cdc5b42ddc6a5fcd3cd4` |
| 平台 | macOS arm64，最低 macOS 14.0 |
| 链接 | 静态 XCFramework，无共享库、无 Homebrew 运行路径 |
| 静态库 SHA-256 | `6a0ac2766cdce32c027954479f752d1d4622afd3d2463f066fc316d418c716db` |
| 输入法 Release ZIP | `RimeAIInputMethod-0.1.0-build26-macos-arm64.zip` |
| ZIP SHA-256 | `627aeac0b5c5b15e33fa4e7c7241ca80c24148b1d1d6bfe3a5c06cfb9fffc6aa` |
| ZIP 大小 | 约 5.0MB |
| 签名 | Developer ID、hardened runtime、Apple 时间戳 |

原生制品验证器检查静态 librime 的 `_rime_get_api`；输入法归档构建器另检查
最终 bundle 的 `_rai_engine_create` 受控桥接符号，并验证源/制品锁、架构、
deployment target、机器本地依赖、许可证资源和深度签名。
归档使用不保留 resource fork 的 ZIP，并由独立验证器通过普通 `unzip` 解包，
拒绝 AppleDouble `._*`/`.DS_Store` 后再次执行深度严格签名验证。

## INT8 ONNX 模型

| 项目 | 值 |
|---|---|
| 来源 checkpoint | `rimeai-ranker-s-24m:d2e5385dc877f058` |
| 运行制品 | `rimeai-ranker-s-24m-onnx:d812102db0586701` |
| 量化 | opset 17，MatMul/Gemm per-channel dynamic INT8 |
| 模型文件 | 58,144,989 bytes |
| 模型 SHA-256 | `01f4361455f8de882598fea9bb5ebbe61f6543b6ecb6f541a22e15fc47bd2e2d` |
| 融合制品 | `rimeai-24m-fusion:96a44df2d2d8ee63` |
| runtime | ONNX Runtime 1.19.2 / tokenizers 0.15.2 / CPU |

冻结 test 的 0.90 产品门 conditional Top-1 为 94.5501%，P50/P95 为
15.17/42.70ms，冷启动 119.49ms，无推理错误。raw 相对浮点下降约 0.63 个
百分点，产品门结果相对浮点产品门提高约 0.13 个百分点。

## 自包含 daemon release

最终内部制品：

| 项目 | 值 |
|---|---|
| 版本 | `0.1.0-internal-preview.5` |
| 制品 ID | `rimeai-daemon-release:315af4a363792510` |
| archive SHA-256 | `fe615551886854de55158566fc51ffbb35e4ea6730200eddc64e21eeeab3a073` |
| 压缩/安装大小 | 约 69MB / 120MB |
| Mach-O | 72 个，全部 arm64、最低 macOS 14 |
| 签名 | Developer ID、hardened runtime、Apple 时间戳 |
| 运行探针 | 20/20 成功，中位数 5.75ms，最大 6.39ms；上下文消融通过 |
| 网络 | 只有 0600 Unix socket，无 INET socket |

release 清单固定每个文件的相对路径、大小和 SHA-256，并分别记录语义 checkpoint
ID 与 ONNX runtime ID。模型结构、来源 ID、量化格式、opset、有限阈值、文件
集合和哈希任一异常都会拒绝加载并回退纯 Rime。

## 安装、升级与回滚

真实执行记录：

1. 安装浮点 v1 并完成 LaunchAgent 健康检查。
2. v1 原子升级至 ONNX v3。
3. v3 回滚至 v1，模型制品握手通过。
4. 再升级 v3/v4，随后升级到修复默认 socket 守卫并附带准确 runtime
   许可证文本的 v5。

`current` 和 `previous` 是同目录相对链接，使用不跟随目标的原子替换。安装或
回滚失败时恢复选择器、plist 和原服务。卸载把 LaunchAgent 与 release 目录移入
废纸篓，不删除 Rime 用户数据。

## 仍需外部完成

- 本机未配置 `RIMEAI_NOTARY_PROFILE`；公证脚本已实现，但 Gatekeeper 当前按
  预期报告 `Unnotarized Developer ID`。
- 需要干净 macOS 14/15/26 机器及最低 Apple Silicon 设备验证安装、升级、
  常驻内存、冷启动、能耗、温度和长时间稳定性。
- 需要系统级抓包与日志审计、十个代表宿主应用及 secure input 实测。
- 需要内部预览用户的曝光、接受、10 秒撤销和大幅回删指标。
- CC BY-SA/LGPL 数据、模型和第三方材料须由法律审查给出公开分发方案。
- iOS 当前仍为紧凑 n-gram 可行性工程；Windows/Android 属于后续独立平台项目。
