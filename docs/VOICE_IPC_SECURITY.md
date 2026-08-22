# 语音 IPC 威胁模型与实现边界

状态：`CHECKED IMPLEMENTATION / RELEASE VALIDATION PENDING`。传输已按不可变
构建配置分流：Debug 只允许显式私有 Unix Domain Socket（UDS），Release
只允许双向认证 NSXPC/Mach service。代码和自动化证据已经覆盖认证策略、逐帧
门、背压和代际；输入法与 nested helper 的真实 Developer ID 配对静态门已
通过，命名 service 运行、macOS 14、TCC、公证与清洁机器验证仍是公开分发
阻塞项。

## 1. 受保护资产

- 已获 TCC 授权的麦克风采集能力。
- 尚未确认的临时/最终听写文本。
- 输入法当前 owner、宿主 client、光标与会话身份。
- `start`、`stop`、`cancel`、`accept` 等控制消息的完整性与时序。

不把协议版本、bundle identifier、socket 路径或随机 request ID 当作秘密。

## 2. Debug 私有 UDS 基线

`developmentInsecureUDS` 是编译期 Debug 后端，不是 Release 失败时的回退。
它提供：

- socket 位于当前用户的 Application Support runtime 目录；服务端、生命周期
  与安装器都要求目录由当前用户拥有且精确为 0700，socket 由当前用户拥有、
  类型为 socket 且精确为 0600，并拒绝 macOS 扩展 ACL；helper 使用 0177
  umask 让 socket 从创建时即为私有权限。权限设置或复验失败会尝试停用并
  显式报告任何回滚失败，不会宣称已安全关闭；
- 协议逐字段校验、64 KiB 行上限、连接代际与 session/request ID；
- 非法 hello、未知消息、坏 JSON、旧连接和迟到结果 fail-closed；
- Helper 默认关闭，输入法不会在 Secure Input 或无合法宿主目标时启动会话。

这能隔离其他普通用户并阻止偶然误连，但**不能验证同一登录用户下的进程
代码身份**。固定 `client_id` 只是协议声明，不是认证。

在普通 0600/0700 文件中保存随机 token 也不能解决这个威胁：同 UID 恶意
进程能够读取相同文件。只有由代码签名访问组保护的 Keychain 密钥才可能作为
认证材料；在 ad-hoc 开发签名下没有稳定的访问组身份，因此不采用文件 token
或伪安全的共享 nonce 作为发布门。

## 3. 威胁与当前处置

| 威胁 | Debug UDS | Release NSXPC |
|---|---|---|
| 其他本机用户连接 Helper | 0700/0600 owner、mode 与 ACL 门拒绝 | 双端代码签名门之外仍要求 effective UID 为当前用户 |
| 同 UID 进程假冒输入法启动麦克风 | 未隔离；属于已知开发边界 | helper 只接受满足严格 Developer ID requirement 的精确输入法 identifier，并在每次调用复验 UID/PID |
| 同 UID 进程假冒 Helper 注入文本 | owner/client/caret 门可降低上屏风险，但不能认证来源 | 输入法对 Helper 执行对称 requirement，并在每次回调复验 UID/PID |
| 重放旧会话/旧连接 | connection generation、request ID 与状态机拒绝 | 再叠加 XPC connection generation、UUID token 与 server-core epoch |
| 连接失败后降级到不认证传输 | 仅适用于显式 Debug | Release 构造失败或认证失败返回 fail-closed transport，绝不回退 UDS |
| Helper 被动态注入未签名代码 | 不作为发布证据 | Developer ID requirement 已编码；Hardened Runtime/Library Validation 与真实制品仍需发布审计 |
| 同 UID 进程停止服务、删除 socket 或制造资源耗尽 | 可造成拒绝服务 | 不把本地同 UID DoS 当作可由 IPC 认证消除；安全目标是阻止其获得麦克风能力或伪造/读取听写文本 |

## 4. Release 实现：认证 XPC Mach Service

Release 路径已实现为当前用户 LaunchAgent 暴露的 XPC Mach service：

1. LaunchAgent 的 `MachServices` 注册固定服务名
   `fun.wwcn.rimeai.voice-helper`；Helper 使用
   `NSXPCListener(machServiceName:)`，输入法使用
   `NSXPCConnection(machServiceName:options: [])`。Debug 渲染 LaunchAgent 时会
   删除 `MachServices`，改为显式 `--socket` 参数。
2. 双端在 listener/connection `activate()` **之前**设置代码签名 requirement。
   当前严格表达式同时包含 `anchor apple generic`、精确对端 identifier、
   Developer ID 中间证书 OID `1.2.840.113635.100.6.2.6`、Developer ID
   Application 叶证书 OID `1.2.840.113635.100.6.1.13` 与精确叶证书
   `subject.OU` Team Identifier。Team 只从当前进程签名读取，不从候选 peer、
   用户偏好或可写文件派生，也不固定每次构建都会变化的 CDHash。
3. Helper listener admission 与客户端首个 `ping` reply 都要求正 PID 且
   effective UID 等于当前用户。随后 `ping`、client→helper `sendFrame`、
   helper→client `receiveFrame` 每次进入导出对象时，都通过
   `NSXPCConnection.current()` 复验调用来自当前 connection、PID 为正且 UID
   匹配。签名 admission 与逐调用 UID/PID 门全部成功后才允许业务帧。
4. XPC 顶层只承载 `Data` 与 `Bool`/空 reply，接口只 allowlist `NSData`。
   每次调用恰好一条无 NDJSON 尾随换行的 JSON 消息，并在解码前执行 64 KiB
   上限与既有 Codable 逐字段校验，不复制第二套业务状态机。
5. 两个方向都使用 ACK 驱动的有界单飞 FIFO：同一时刻一帧在途，默认最多
   32 帧、合计 256 KiB。溢出、负 ACK、proxy 错误或重复/迟到 ACK 会关闭并
   清空该代队列，不能释放旧队列中的下一帧。
6. 新连接的 `ping` 只建立认证屏障，不替换活跃连接；首个合法
   `voice_hello` 才执行 latest-wins promotion。客户端 connection generation 与
   authenticated generation、服务端 UUID connection token 与 server-core epoch、
   业务 request/session ID 共同阻止旧帧、旧异步引擎输出、旧 disconnect 或旧
   ACK 跨连接生效。
7. Release 构建把独立签名 Helper 放在输入法 `Contents/Helpers`，两端必须
   具有同一 Team、version/build 和各自精确 identifier；验证器同时执行严格
   requirement 与 Helper entitlement 白名单。运行时从外层签名资源渲染
   LaunchAgent，直接执行 nested helper，不复制第二份可漂移的可执行制品。
   认证失败、服务中断或 requirement 不满足时只禁用语音并保持普通键盘路径；
   Release 不自动降级 UDS。

选择 XPC 的原因是 macOS 14 最低目标已具备公开的 peer identity 与代码签名
requirement API。当前 Network.framework UDS 接受连接时不公开底层 fd、peer
PID 或 audit token，无法在不替换传输层的前提下可靠完成同等级校验。另一种
可行但维护成本更高的方案是用 BSD UDS 自行 accept，读取 peer audit token，
再通过 Security.framework 验证动态代码；不作为默认路线。

## 5. 签名与开发模式

- Release 制品：输入法与 Helper 必须由同一 Team 的 Developer ID Application
  身份签名。严格 requirement 不只检查 `TeamIdentifier + identifier`，还固定
  Apple generic anchor 与 Developer ID 的中间/叶证书 OID；Apple Development、
  ad-hoc、错误 Team 或错误 identifier 均不满足。
- ad-hoc 本机开发：没有跨版本稳定的 designated requirement，编译配置只允许
  显式 `developmentInsecureUDS`；0700/0600/ACL 门只提供“同 UID 信任”，不得
  计作发布安全证据。
- requirement 字符串由构建配置或签名制品元数据生成，不放入可由用户偏好
  修改的设置，也不在失败时回显 audit token、完整签名信息或消息正文。

## 6. 验证状态与测试矩阵

### 已通过的自动化与只读探针

以下证据验证实现结构，但不替代真实系统集成验证：

- Swift 协议/状态机测试覆盖 9 消息往返、字段和 64 KiB 边界、握手、超时、
  latest-wins、取消、显式确认、熔断、连接/效果代际与真实 UDS 回环；UDS
  另覆盖 0700/0600 owner/mode、扩展 ACL 拒绝和坏帧断开。
- `VoiceDictationXPCTransportTests` 的匿名 NSXPC 回环覆盖
  hello→start→stop→final→accept、非法候选不替换当前连接、旧 server-core
  epoch 丢弃、单飞 FIFO 顺序、容量溢出/负 ACK、invalidate/重复 reply、认证
  `ping` 前回调拒绝、ping 超时/错误 UID、重用 request ID 与并发引擎事件顺序。
- requirement 单元测试固定 Apple generic anchor、两个 Developer ID OID、精确
  Team/identifier，并拒绝可注入的 identifier/Team 语法；XPC payload 测试确认
  单条无换行 JSON 与 64 KiB 解码前上限。
- 安装器与 bundle verifier 的 shell harness 覆盖默认 `apple-speech`、Debug
  删除 `MachServices`/使用 UDS、Release 保留命名 Mach service/不含 socket
  参数、双 bundle requirement、完整 `voice_ready` 解析、失败回滚及
  authenticated-XPC 健康检查不调用 `nc -U`。
- Developer ID 成对 ZIP 已验证同 Team/version/build、nested helper 标准代码
  位置、唯一 audio-input entitlement、Hardened Runtime、无 AppleDouble、
  签名内 LaunchAgent 模板及 fail-closed probe policy；Release 生命周期的模板
  渲染纯逻辑测试覆盖包含特殊字符的路径和错误 policy。
- 本机 macOS SDK 的 Swift 5/6、`arm64-apple-macosx14.0` 只读编译探针已确认
  listener/connection signing requirement、peer UID/PID、
  `NSXPCConnection.current()` 与 `NSData` allowlist API 可在 macOS 14 目标编译；
  匿名 listener 探针确认 reply 后的 peer UID/PID 与导出回调身份可读取。它不是
  macOS 14 真机或命名 launchd service 证据。

### 尚未完成的发布验证

- 当前已静态验签的 Developer ID 输入法与 Helper，必须在用户 LaunchAgent
  命名 Mach service 上完成双向连接，并证明错误 identifier、错误 Team、Apple
  Development、ad-hoc/未签名与同 UID 冒充者均在 `hello`/TCC 前被拒绝。
- 必须在真实 macOS 14 机器验证 listener admission、首个 ping 后 peer identity、
  每个导出方法的 `NSXPCConnection.current()`、interruption/invalidation，以及
  connecting/listening/finalizing/pending-confirm 各阶段均不误提交。只把部署
  target 设为 macOS 14 或对 SDK typecheck 不算完成。
- 必须完成麦克风与 Speech Recognition TCC 的首次授权、拒绝、撤销、重试和
  多设备路径；认证失败不能触发 TCC 提示，日志不得包含音频、听写文本或认证
  材料。
- 必须完成 Developer ID 成对制品的 notarization、nested helper 与外层 App
  分别 stapling/validation 和 Gatekeeper，及
  清洁机器上的首次安装、输入法先升级/helper 先升级、崩溃中断、回滚、协议
  不兼容与 Team 迁移矩阵。
- 必须在睡眠/唤醒、快速启停、Helper crash/restart、输入法/宿主切换和长时间
  背压下回归有界内存、重认证与普通键盘持续可用。

## 7. 放行判定

Debug 可在明确接受“当前登录用户内进程互信”时继续使用私有 UDS。Release
双向认证 XPC 代码路径已经存在且不会回退 UDS，但在第 6 节真实 Developer ID、
macOS 14、TCC、公证与清洁机器矩阵完成前，语音仍默认关闭，不宣称已达到公开
分发放行。

## 参考

- Apple：[`NSXPCConnection`](https://developer.apple.com/documentation/foundation/nsxpcconnection)
  的 peer UID/PID 与 `setCodeSigningRequirement(_:)`。
- Apple：[`TN3127: Inside Code Signing: Requirements`](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。
- Apple：[`SecCodeCopyGuestWithAttributes`](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:))
  与 audit-token guest 属性，供 BSD UDS 备选方案参考。
