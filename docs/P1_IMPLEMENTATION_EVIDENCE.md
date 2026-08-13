# P1 / P2-internal 实现证据

## 结论

状态：**CHECKED IMPLEMENTATION / BLOCKED FOR PUBLIC DISTRIBUTION**

纯键盘 P1 技术原型和 P2-internal 的隐私、后台生命周期及本地数据控制已经
实现并在参考机运行。当前结果允许继续内部使用和真实应用矩阵测试，但不代表
可公开发布。

## 已实现链路

```text
InputMethodKit key event
  -> bundled librime 同步 Top-10
  -> 稳定数字候选行
  -> 100ms debounce
  -> 当前用户 0600 Unix Domain Socket
  -> 24M 神经+n-gram 融合重排 + 拼音约束 beam 建议
  -> 组合/修订/应用会话/截止时间校验
  -> 独立语义状态/候选位，用户通过 Tab 或高置信度时的 Space 主动上屏
```

输入法保留 Rime 用户词频提交。AI 超时、协议异常、熔断、关闭、应用策略命中
或 Secure Event Input 命中时，不阻塞纯 Rime。

daemon 对正常“无额外候选”也返回显式决策：`same_top_candidate`、
`below_confidence` 或 `no_candidate`。候选窗因此能区分模型仍在分析、模型认同
Rime 首选、低置信度回退、无候选、服务不可用和真正失败，不再把空字符串同时
解释成所有情况。

daemon 对超过 30 字和未覆盖完整拼音的整句候选分别返回
`sentence_too_long`、`sentence_incomplete`。两种结果都不携带可提交文本，避免
把截断句误当作完整推导。

## 正确性与隐私

- 主候选数字位置在异步结果到达后不变化。
- 旧组合、旧修订和旧应用会话结果不可显示。
- 默认上下文只包含当前应用最近上屏的最多 100 字；严格模式为 0，智能模式
  显式读取光标前最多 400 字。
- 标准模式上下文保存在输入法进程内；同一应用的 InputMethodKit 控制器重建
  后可续接，切换应用、Secure Event Input、关闭 AI 或清除数据时立即擦除。
- 输入法和 daemon 都约束候选数量、上下文长度、拼音字符、输出长度、
  置信度、换行和候选注入。
- daemon 验证 Unix socket 对端 UID，运行目录权限为 0700、socket 为 0600。
- daemon 进程启动后安装 process-wide guard，拒绝创建 `AF_INET` 和
  `AF_INET6` socket，只保留 Unix socket。
- 默认诊断只存事件计数和延迟区间，不保存原始按键、拼音、上下文、候选或
  完整句子。
- 请求延迟从 100ms debounce 后真正发送到 daemon 时开始计时；过期结果、
  非法结果、首选一致、低置信度、无候选、排序候选展示和整句展示分别计数。
- Offline Lock 在当前开发者预览强制开启，控制中心显示 daemon 返回的真实
  状态、制品路径和 SHA-256。

## 本地生命周期

- release 安装器把自包含 Python/ONNX Runtime daemon、语言模型、整句配置、
  Rime 字典、INT8 24M 模型、融合配置和许可证复制到版本化 release 目录，
  不依赖项目所在外接卷、系统 Python、PyTorch 或 Homebrew。
- `current`/`previous` 相对符号链接原子切换；安装和回滚都先校验 archive、
  manifest、逐文件哈希、签名、架构和最低系统，再启动并执行模型制品握手。
- 用户级 LaunchAgent 使用本地启用标记控制存活；AI 开关关闭后标记消失、
  daemon 退出、socket 消失，重新开启后恢复。
- 安装器读取已保存的 AI 开关；用户已经停用 AI 时，重装只加载 LaunchAgent
  定义，不创建启用标记、不启动 daemon，也不创建 socket。
- LaunchAgent 失败时在启用标记存在期间重启；不开放 localhost HTTP/TCP。
- 控制中心分别显示 AI 服务/模型与 Rime 用户数据占用。
- “停用 AI 并清除本地制品”只把 daemon、模型、runtime、控制标记和
  LaunchAgent 移到废纸篓；路径合同测试证明不包含 `Rime/` 用户目录。
- debug 卸载默认把应用和 LaunchAgent 移到废纸篓，保留全部用户数据。

## 2026-07-29 验证结果

参考环境与 P0 相同：M1 Pro、32GB、macOS 26.4.1、Xcode 26.6。

| 检查 | 结果 |
|---|---|
| `python3.11 -m pytest -q` | 93 passed |
| `swift test` | 21 passed |
| `python3.11 -m compileall -q -x '(^|/)\\._' rimeai_eval rimeai_daemon tools` | passed |
| 干净 sdist/wheel 构建与全新 venv 导入 | passed |
| `npm run build` | passed |
| Xcode debug build | passed |
| 嵌入 dylib 重新签名后的 `codesign --deep --strict` | passed |
| Developer ID hardened-runtime 深度签名 | passed，含 Apple 安全时间戳 |
| debug 安装与 TIS mode 解析 | passed |
| LaunchAgent 冷启动与模型握手 | passed |
| 停用偏好下重装 | marker、daemon、socket 均保持不存在 |
| AI 关闭 / 开启 | marker、daemon、socket 按预期消失 / 恢复 |
| daemon Internet 描述符 | 0 |
| daemon Unix socket | 1 个监听 socket，0600 |

daemon 握手报告：

- `offline_lock = true`
- capabilities：
  `rerank, sentence, cancel, deadline, latest-request-wins, offline-lock,`
  `decision-reasons, long-input-reasons`
- language model SHA-256：
  `36457c630dc8376df8a9aa74cf94faa78eb43febc6779618ae0792b33d879b49`
- beam config SHA-256：
  `82bea01cd4fd688454cdb4c695b18c16433317bb3f00d6399223e46c5e839483`
- Rime dictionary SHA-256：
  `75bcf6eb3ff62b129882ed89cc22b2d80a5347aa72bcfa2ccc839bac298e7314`

## 公开发布阻塞

1. 当前 bundle 已使用 `Developer ID Application: WEI WANG
   (S3T42U45P8)`、hardened runtime 和 Apple 安全时间戳完成深度签名；
   尚未公证，因此 `spctl --assess` 仍以 `Unnotarized Developer ID` 拒绝。
2. 当前参考机已能注册并用 `TISSelectInputSource` 选择输入源，TextEdit 真实
   候选窗也已验证；完整宿主应用、最低系统版本和安全字段矩阵仍未完成。
3. macOS 已改用从固定源码构建的 librime 1.17.0 静态 arm64 XCFramework，
   最低目标 macOS 14；Intel 不在首发范围。
4. daemon 已改用自包含 Python 3.9.6 + ONNX Runtime 1.19.2，动态 INT8 模型，
   不携带 PyTorch、Transformers 或 safetensors；Developer ID 签名和时间戳通过。
5. 冻结语料、模型和 librime 相关的 CC BY-SA/LGPL 分发方案仍需具体法律
   审查和履约。
6. 仍需公证、干净机器、网络抓包、最低设备和真实应用/安全字段支持矩阵；
   本机版本化升级和回滚已经通过。
7. 用户真实接受率和接受后撤销/大幅回删率需要内部预览样本，不能由离线集
   或单元测试代替。

V0/V1 语音轨没有开始，也不阻塞当前纯键盘内部预览。

## 2026-08-08 候选可见性修复验证

- macOS 候选窗在发出请求前立即显示“本地模型：分析中”。
- 正常 abstention 不再消失：实际 TextEdit 输入 `mingling` 后，候选窗稳定显示
  “本地模型：首选一致”。
- 取消旧请求与清空可见结论已拆开，普通会话生命周期不会把刚完成的结果重置
  成“本地模型待命”。
- 实际用户级 UDS 握手包含 `decision-reasons`，并报告冻结模型制品 ID；上下文
  “请执行这条”、候选“明令/命令”的真实请求返回“命令”，置信度约 0.918。
- iOS 键盘扩展已捆绑确定性导出的 `RAINGRM1` 只读制品，精确复现冻结 P0
  字符 n-gram 评分，并把模型状态放在原生 Rime 候选之前的独立位置。规划中的
  24M 神经排序器、真机内存与宿主矩阵仍是未完成门槛。
- 最终回归：Python 66 passed、Swift 28 passed、iOS Simulator 集成与真实
  系统键盘 UI 5 passed；macOS Debug 构建、签名校验、安装与 daemon 探针通过。

## 2026-08-12 语义提交与长输入边界修复

- 高置信度重排候选（置信度至少 0.90）和整句建议（至少 0.97）可由用户按
  `Space` 主动采用；未达到门槛或没有语义候选时仍提交 Rime 第一候选，数字
  候选的位置不变。
- 候选窗显示本次推理使用的应用内上下文字数，并在 `Space` 会采用语义候选时
  明示“Space 采用”。
- 同一应用中的 InputMethodKit 控制器停用、重建和重新连接不再丢失进程内短期
  上下文；切换应用、Secure Event Input、关闭 AI 和清除数据仍会擦除上下文。
- decoder 会在所有候选中寻找覆盖完整拼音的候选；若只得到前缀、超过 30 字，
  或原始拼音超过协议上限，则显式显示不可选的回退原因，不返回半句话。
- macOS daemon 已接入经过冻结集验证的 24M 神经+n-gram 融合排序器；n-gram
  保留为融合信号和故障回退。
- 新增 1,600 条 11 至 30 字冻结长句集，联合 validation 校准没有读取 test
  标签。30 字仍是硬上限，不能外推到任意长句或开放式续写。
- 最终回归：Python 72 passed、Swift 32 passed、macOS Debug 构建与深度签名
  通过；系统 Python 3.9 导入检查、LaunchAgent 握手和 30/31 字实时 UDS 边界
  探针通过。安装器会在替换现有服务前先执行系统 Python 兼容性检查。

## 2026-08-13 神经排序与扩展长句验证

- `RimeAI-Ranker-S-24M` 已完成 3 epochs listwise 训练。验证集选择的神经与
  n-gram 0.5/0.5 融合在冻结 test 上达到 conditional Top-1 95.6907%，高于
  n-gram 的 94.6768%；生产 CPU P95 35.79ms，预热冷启动 1.84s。
- 上下文消融的 680 条可比样本中，有上下文 Top-1 94.7059%，空上下文
  93.6765%；21 条结果发生变化，14 条改善、7 条回退。
- 11–30 字冻结 test 在 0.97 产品阈值下从 Rime 首选 21.9101% 提升到
  30.3371%，相对提升 38.4617%，P95 14.71ms。6–10 字回归仍相对提升
  44.0948%。
- daemon 在开放 Socket 前预热模型，并用单线程 executor 串行化不可取消的
  原生推理。该边界修复了超时后下一请求与旧 MPS 调用并发导致的段错误；生产
  LaunchAgent 使用 CPU，连续 20 次真实 UDS 请求全部成功。
- 当前量化握手制品 ID 为
  `rimeai-24m-fusion:96a44df2d2d8ee63:beam-2086df1a334c`，并报告五类制品。
  完整数据、指标和剩余门槛见
  [P3_NEURAL_RANKER_EVIDENCE.md](P3_NEURAL_RANKER_EVIDENCE.md)。

## 2026-08-13 受控原生依赖与自包含发布验证

- macOS librime 1.17.0 从固定 revision `33e78140250125871856cdc5b42ddc6a5fcd3cd4`
  构建为静态 arm64 XCFramework；库 SHA-256 为
  `6a0ac2766cdce32c027954479f752d1d4622afd3d2463f066fc316d418c716db`，
  最低目标 macOS 14，无共享库或 Homebrew `/opt/homebrew` 路径。
- 正式配置输入法 build26 ZIP 为 5.0MB，SHA-256
  `627aeac0b5c5b15e33fa4e7c7241ca80c24148b1d1d6bfe3a5c06cfb9fffc6aa`；
  Developer ID、hardened runtime、Apple 时间戳、arm64、macOS 14 和受控桥接
  符号验证通过。ZIP 无 AppleDouble 元数据，普通 `unzip` 后深度严格验签通过。
  当前未公证，`spctl` 正确报告 `Unnotarized Developer ID`。
- daemon v5 release 制品 ID `rimeai-daemon-release:315af4a363792510`，归档
  SHA-256 `fe615551886854de55158566fc51ffbb35e4ea6730200eddc64e21eeeab3a073`；
  72 个 Mach-O 全为 arm64/macOS 14，逐文件清单、hardened runtime 和库验证
  策略通过，归档约 69MB、安装约 120MB。
- frozen daemon 真实启动后 20 次请求全部成功，中位数 5.75ms、最大 6.39ms，
  进程只有用户级 Unix socket，没有 INET socket。
- 真实执行 v1→v3 升级、v3→v1 回滚、再升级到 v3/v4，最后升级到修复默认
  socket 守卫并附带准确 tokenizers 许可证的 v5；每次均通过目标制品握手。
  当前 LaunchAgent 运行 v5。
- 当前参考机 M1 Pro 上，v3–v5 同架构 runtime 热态 `ps` RSS 约 383MiB，
  `footprint` 总计约 342MB；这不是最低机型能耗/温度放行证据。
- 公证脚本已实现提交、等待、staple、Gatekeeper 验证和最终归档重哈希；本机
  未配置 `RIMEAI_NOTARY_PROFILE`，没有伪造公证通过记录。
- 最终自动回归：Python 93 passed、Swift 32 passed、受控 librime 冒烟通过、
  SwiftPM 候选服务无 `/opt/homebrew`/`/usr/local` 依赖、前端 production build
  通过。iOS Simulator 当前没有 booted 设备，因此本轮未重复运行 UI 测试。
