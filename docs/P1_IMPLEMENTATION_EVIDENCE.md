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
  -> n-gram 重排 + 拼音约束 beam 建议
  -> 组合/修订/应用会话/截止时间校验
  -> 独立语义候选位，用户主动上屏
```

输入法保留 Rime 用户词频提交。AI 超时、协议异常、熔断、关闭、应用策略命中
或 Secure Event Input 命中时，不阻塞纯 Rime。

## 正确性与隐私

- 主候选数字位置在异步结果到达后不变化。
- 旧组合、旧修订和旧应用会话结果不可显示。
- 默认上下文只包含当前应用最近上屏的最多 100 字；严格模式为 0，智能模式
  显式读取光标前最多 400 字。
- 输入法和 daemon 都约束候选数量、上下文长度、拼音字符、输出长度、
  置信度、换行和候选注入。
- daemon 验证 Unix socket 对端 UID，运行目录权限为 0700、socket 为 0600。
- daemon 进程启动后安装 process-wide guard，拒绝创建 `AF_INET` 和
  `AF_INET6` socket，只保留 Unix socket。
- 默认诊断只存事件计数和延迟区间，不保存原始按键、拼音、上下文、候选或
  完整句子。
- Offline Lock 在当前开发者预览强制开启，控制中心显示 daemon 返回的真实
  状态、制品路径和 SHA-256。

## 本地生命周期

- 安装器把 Python daemon 源码和三个已校验制品复制到
  `~/Library/Application Support/RimeAI`，不依赖项目所在外接卷。
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
| `python3 -m pytest -q` | 61 passed |
| `swift test` | 21 passed |
| Python compileall | passed |
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
  `rerank, sentence, cancel, deadline, latest-request-wins, offline-lock`
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
2. macOS 26 能注册、启用并解析该 TIS mode，但 `TISSelectInputSource`
   返回 `-50`；真实 TextEdit 完整输入路径因系统输入源信任门未关闭而不能
   宣告通过。
3. 当前 Homebrew librime 1.17.0 bottle 的最低构建版本高于项目声明的
   macOS 14。公开包必须使用受控、双架构/目标版本明确的自带构建。
4. 当前内部 daemon 使用 Xcode Python。公开包必须替换为自包含、签名且可
   公证的运行时。
5. 冻结语料、模型和 librime 相关的 CC BY-SA/LGPL 分发方案仍需具体法律
   审查和履约。
6. 仍需公证安装包、升级/回滚、网络抓包、最低设备和真实应用/安全字段支持
   矩阵。
7. 用户真实接受率和接受后撤销/大幅回删率需要内部预览样本，不能由离线集
   或单元测试代替。

V0/V1 语音轨没有开始，也不阻塞当前纯键盘内部预览。
