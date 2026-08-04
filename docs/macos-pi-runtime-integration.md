# macOS 原生客户端与 Pi Runtime 融合：研究与架构决策

> 状态：**bundled Runtime 的本机实现、App 启动、manifest 校验、Unix-socket smoke、Runtime-owned workspace 文本创建/编辑/移动/删除、受限图片预览、原生消息图片附件、Thread Git checkpoint/review、独立 selection 的多窗口，以及 legacy `auth.json` 的 Keychain 受控迁移已完成；菜单栏后台、登录生命周期和远程能力仍在实施。**
>
> 范围覆写：当前用户明确要求不做代码签名、公证、Gatekeeper/DMG/Sparkle 发布。本文保留相关研究作为未来参考，但所有当前验收以 exact dependency lock、manifest/hash、Node 版本/架构和真实 Runtime smoke 为准。
>
> 调研快照：**2026-08-05**。本轮已将锁定的 `@earendil-works/pi-*@0.81.1`、Pi 上游 SDK/RPC/extension 文档，以及 Apple 的 XPC、ServiceManagement 文档与当前实现交叉复核。Pi SDK、Node、Bun 与 macOS API 仍会演进；进入每个发布阶段前必须重新核对锁定版本和平台行为。
>
> 关联总方案：[macOS 原生应用方案](./macos-native-app-plan.md)

## 1. 执行摘要

Pi Agent 的正式架构采用**原生 App + 内嵌 Runtime 的混合方案**：

- 产品界面、窗口、菜单、设置、权限、通知和更新使用 SwiftUI + AppKit；
- `Pi Agent.app` 随包携带固定版本的 Node、Agent Runtime、Pi SDK、`node-pty` 和必要资源；
- Pi SDK 运行在长期存活的 Node Runtime 中，通过 `AgentSessionRuntime` 管理 session 创建、恢复、切换、fork、流式事件和工具；
- Swift 进程不链接 Pi SDK、不嵌入 libnode，也不直接把 `pi --mode rpc` 当作产品主协议；
- Swift 只依赖稳定、版本化、可生成类型的 **Native Contract**，当前传输继续使用本机 Unix domain socket 上的 HTTP + WebSocket；
- Pi RPC 保留为 Runtime 内部的兼容 driver、第三方 harness 接入和故障隔离工具，不负责产品级多 session orchestration；
- 第一版随 App 打包经过验证的固定 Node LTS 和裁剪、锁定的 production dependency tree；调研时优先候选是 Node 24 LTS，Node SEA 与 Bun 单文件仅保留为后续 spike；
- Runtime 与 App 是一个不可拆分的本地构建单元，普通用户不需要安装 Node、npm 或 Pi CLI；本阶段不对外宣称已签名、公证或可经 Gatekeeper 分发。

最终推荐结构如下：

```text
Pi Agent.app
├── PiAgent                         SwiftUI/AppKit 产品进程
│   ├── Features / Stores
│   ├── RuntimeClient               只依赖 Native Contract
│   └── RuntimeSupervisor           发现、握手、启动、重连和退出协调
├── PiAgentRuntimeHost              可选的轻量原生生命周期 helper
│   └── 校验 manifest、监督进程、管理后台运行；不处理 session 数据流
└── Bundled Agent Runtime           固定 Node + TypeScript/JavaScript runtime
    ├── Native Contract server      Unix socket command/event/terminal channels
    ├── Session orchestration       多 session、投影、幂等和恢复
    ├── PiSdkRuntimeAdapter         唯一直接导入 Pi SDK 的边界
    │   └── AgentSessionRuntime
    ├── OmpRpcRuntimeAdapter        OMP 或隔离型 subprocess driver
    ├── SessionEventHub
    └── TerminalService / node-pty
```

一句话结论：**完整嵌入 Pi 能力，但把它嵌入 App 自带的 Node Runtime，而不是嵌入 Swift GUI 进程。**

当前实现已经提供：`macos/PiAgentRuntime/package-lock.json` 的 exact production closure、`build-runtime.mjs` 生成的 `runtime-manifest.json`、CycloneDX 1.5 `runtime-sbom.cdx.json` 与可复算的 third-party notices inventory、启动前的 SHA-256/Node 版本/架构自检、`/runtime/hello` 协议握手、Swift `RuntimeSupervisor` 的按需启动/重连、Application Support 专属 socket、项目 security-scoped bookmark，以及 `verify-app.sh` 驱动的 bundle/Runtime/Swift socket smoke。SBOM 仅列出目标架构上实际安装的 production component；其 notices inventory 同时公开每个 package 自带的 LICENSE/NOTICE/COPYING 文件和未随 tarball 附带的缺口，避免把 lockfile 元数据误当成已分发 notice。

## 1.1 2026-08-05：上游资料复核后的明确决策

这次复核回答用户最直接的问题：**应该让 Pi Agent 更深地融入 macOS App，但不应该把 Pi 的 Node SDK 强行塞入 Swift GUI 进程。**

这里的“完整嵌入”是交付和产品边界的完整嵌入：用户安装一个 `Pi Agent.app`，其中包含原生界面和受 App 监督的 Runtime；并不要求所有代码运行在同一个进程、使用同一种语言。推荐组合如下：

```text
Pi Agent.app
├─ SwiftUI + AppKit                     原生窗口、菜单、权限、通知、可访问性
│  └─ RuntimeClient                     只认版本化 product contract
└─ AgentRuntime/                        随 App 发布、与 App 同版本
   └─ Node + Pi SDK adapter             session、工具、扩展、PTY、持久化的唯一所有者
      ├─ AgentSessionRuntime             Pi 的多 session / cwd replacement 语义
      ├─ node-pty                        唯一 PTY 所有者
      ├─ Pi/OMP driver adapters          harness 差异隔离
      └─ Unix socket HTTP + event stream 本机命令、snapshot 与实时增量
```

这个结论不是推测：Pi 官方 SDK 明确把「自定义 web、desktop、mobile UI」列为使用场景，并说明 `AgentSessionRuntime` 是 new、resume、fork、import 与 cwd-bound service 重建的正确层；它还特别要求 session replacement 后重新订阅事件、重新绑定 extensions。现有 `PiSdkRuntimeAdapter` 应继续是唯一接触这些 SDK 类型的地方，而不是让 Swift View 或 IPC DTO 反向依赖 Pi 私有对象。[Pi SDK](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)

同一份上游资料还给出了取舍边界：Pi RPC 是为其他进程/其他语言控制 headless agent 提供的 LF-JSONL 协议；其文档对 Node/TypeScript 集成明确建议直接使用 `AgentSession`，而非再启动一个 subprocess。RPC 因而保留为未来第三方 harness、隔离 driver、诊断工具或受限 compatibility mode，而不是本 App 的主数据模型。RPC 的 extension UI 子协议也只覆盖 select/confirm/input/editor 等有限交互，并对若干 TUI 能力降级；若以它作为 Swift 的产品主协议，仍需在外层补完多 session、PTY、插件、审批和持久化的编排层。[Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)

| 选择                                                       | 是否采用      | 原因                                                                                                                                                  |
| ---------------------------------------------------------- | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Swift 直接链接/嵌入 Node 与 Pi SDK                         | 否            | GUI crash domain 会与 extension、provider、native addon、dynamic resource loader 和 PTY 绑定；没有官方 Swift SDK，维护的是 ABI bridge，不是产品能力。 |
| Swift 为每个 session 启动 `pi --mode rpc`                  | 仅兼容 driver | 适合非 Node host 或单 agent 隔离，无法复用现有 Runtime 的 multi-session、terminal、OMP 与恢复语义；还需实现 RPC extension-UI 转发。                   |
| Swift 原生壳 + 随包长期 Node Runtime + 直接 Pi SDK adapter | **主方案**    | Pi SDK 是官方支持的嵌入路径；现有 session daemon 是这一 Runtime 的事实所有者，可保住 event streaming、PTY、插件与既有测试。                           |
| 保留用户全局 Node / `pi-web-sessiond`                      | 仅开发兼容    | 对普通用户不可重复：Node、Pi 包、native addon 与配置会漂移，App 也无法给出可验证的版本/完整性边界。                                                   |

这也与 T3 Code 的可借鉴边界一致：它让 server runtime 统一拥有 agent session、workspace、VCS、terminal 与 filesystem，桌面/网页/移动端只消费一个类型化、订阅式合同；客户端不直接执行这些副作用。Pi Agent 借鉴这个所有权模型和“连接 supervisor 在 View 之外”的原则，但不引入其 Electron UI、Effect 技术栈或整套 event sourcing。[T3 Code architecture](https://github.com/pingdotgg/t3code/blob/main/docs/internals/overview.md)

### 1.1.1 2026-08-05：本仓库源码与上游 SDK 的交叉核验

本结论不是只根据产品架构图得出；它已与当前仓库以及锁定的 Pi SDK
`@earendil-works/pi-coding-agent@0.81.1` 的实际边界逐项核对：

| 已核验事实                                                                                                                                                         | 代码证据                                                                                                                                                                                           | 对架构决策的影响                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Pi 的 SDK 明确把自定义 desktop UI 列为嵌入场景；`AgentSession` 提供流式订阅，而 `AgentSessionRuntime` 负责新建、切换、fork、clone 与导入后的 session replacement。 | [`Pi SDK`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)；锁定版本见 [`macos/PiAgentRuntime/package.json`](../macos/PiAgentRuntime/package.json)。             | Runtime 应直接使用 SDK；Swift 不应为每个 Thread 重新包装一个 CLI subprocess。             |
| 上游要求 session replacement 后重新订阅事件、重新绑定 extensions。                                                                                                 | [`Pi SDK session runtime`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md#agentsessionruntime)。                                                                 | 这类生命周期语义必须收敛在 Node adapter，而不是泄漏为 Swift 对上游对象的知识。            |
| 本仓库已经把 `createAgentSessionServices`、`createAgentSessionFromServices`、`createAgentSessionRuntime` 和 SDK `SessionManager` 的实例检查集中在一个小 adapter。  | [`src/server/sessions/piSdkRuntimeAdapter.ts`](../src/server/sessions/piSdkRuntimeAdapter.ts)。                                                                                                    | 保持并加强这一 adapter 是低风险路线；升级 Pi 时只需审计、测试这一边界和 Native Contract。 |
| bundled launcher 在 manifest、Node 版本与架构校验完成后，才载入编译出的 `sessiond`。                                                                               | [`macos/PiAgentRuntime/runtime-launcher.mjs`](../macos/PiAgentRuntime/runtime-launcher.mjs)。                                                                                                      | “完整嵌入”已经有正确的交付雏形：普通用户无需外部 Node、npm 或开发期 daemon。              |
| 当前 Runtime 已能承载私有 Unix socket、HTTP command、WebSocket events、Runtime epoch 与 receipt；Swift 已仅通过该 Contract 调用。                                  | [`src/server/sessiond.ts`](../src/server/sessiond.ts) 与 [`macos/PiAgent/Sources/PiAgentCore/UnixSocketRuntimeClient.swift`](../macos/PiAgent/Sources/PiAgentCore/UnixSocketRuntimeClient.swift)。 | 继续收紧既有 Contract 与恢复语义，比改成第二套 Swift-to-RPC 协议更有价值。                |

因此，后续实现的“更深融合”有一个可验证的定义：新增 Pi 能力先以
`PiSdkRuntimeAdapter → Runtime product service → Native Contract → Swift feature`
穿过四层；不得让 Swift import Pi 类型、不得从 Swift 直接启动 `pi --mode rpc`，也不得让 UI 直接拥有 Git、文件或 PTY。
这既保留 Pi SDK 的官方 session/extension 语义，也保留 macOS 客户端可重建、Runtime 可恢复的故障隔离。

### 1.1.2 本轮复核新增的边界结论

这不是只看架构介绍得出的偏好，而是把上游 API 的选择条件与当前产品职责逐项对齐后的结论：

| 一手资料与当前事实                                                                                                                                                                                                                                                 | 对 Pi Agent 的含义                                                                                                    | 固化的做法                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 当前根项目实际安装的 `@earendil-works/pi-agent-core`、`pi-ai` 和 `pi-coding-agent` 均为 `0.81.1`；App Runtime 的独立 `package.json`/lock 将这三个包精确锁到同一版本。                                                                                              | 开发依赖的 `^0.81.1` 不能成为发布边界；但「SDK 进 Node Runtime」不是概念方案，已经是可锁定、可审计的产品依赖闭包。    | Runtime 继续以独立 exact lock、manifest/hash 和 `/runtime/hello` 发布；Swift 只协商 Native Contract 版本与 Runtime manifest 版本。                                |
| Pi SDK 将 custom web/desktop/mobile UI 列为使用场景，并明确说需要 session replacement/cwd-bound service 重建时应使用 `AgentSessionRuntime`；内置 interactive、print、RPC mode 都使用这一层。                                                                       | 本产品有 new/resume/fork/import、多 project cwd、extension rebind 和重连，不是一个一次性 prompt 的 CLI wrapper。      | `PiSdkRuntimeAdapter` 继续成为唯一的 SDK lifecycle 边界；每次 runtime replacement 在 Node 内重建订阅与 extension bridge，再向 Swift 投影稳定事件。                |
| Pi RPC 是 stdio 上严格 LF 分帧的 JSONL 协议；上游同时说明 Node/TypeScript host 应直接使用 `AgentSession`，跨语言或隔离进程才优先 RPC。RPC 的 extension dialog 子协议虽能承载部分 sheet 交互，却不替产品提供多 session、workspace、Git、PTY、receipt 或恢复所有权。 | Swift 直接启动 `pi --mode rpc` 不会删掉 Runtime，只会迫使我们再写一个 orchestrator，并把 Swift 绑到一条次级上游协议。 | RPC 只保留为 future driver/harness/诊断或需要强隔离的 adapter；不得作为原生 App 的主控制面。                                                                      |
| Apple 将 XPC 定义为 App 与受控 helper 之间的跨进程服务；它改善生命周期和权限隔离，但不会执行 Node module loader、Pi extension discovery 或 `node-pty` 的产品编排。                                                                                                 | XPC 不是“让 Pi 变成 Swift SDK”的替代品；现在改 transport 会增加一层 bridge，却不减少 Node Runtime。                   | 未签名、非 Sandbox 的当前 App 保持 private Unix socket HTTP/WebSocket；未来签名/Sandbox 以独立 RuntimeHost/XPC spike 验证 bookmark capability hand-off 后再决定。 |
| macOS 13+ 的 `SMAppService` 管理 Login Item、LaunchAgent/Daemon；注册受用户批准控制，Login Item 会立即启动并可在崩溃后被系统重启。                                                                                                                                 | 这适合用户显式选择的后台可用性，不适合把开发期常驻 daemon 偷换成每位用户的默认行为。                                  | 首发保持 App-managed Runtime；仅在完成 crash/idle/退出矩阵后，以可见开关和 `SMAppService` 增加 Login Item，而不暴露手工 `launchctl`/systemd 配置。                |

因此，本项目的“完全嵌入”验收仍然是 **一个 `Pi Agent.app` 即可运行且不依赖全局 Node、npm、Pi CLI 或开发 daemon**；它刻意不是单进程、也不是把所有上游协议和副作用搬进 SwiftUI。这个定义同时保留原生体验、Pi SDK 的官方生命周期能力，以及 UI/Runtime 相互独立的崩溃恢复空间。

### 1.2 因此必须坚持的 integration rules

1. **SDK 只在 Runtime adapter 内。** Swift DTO 只承载 Pi Agent 自己的 `SessionProjection`、`CommandReceipt`、`RuntimeEvent`、terminal bytes/resize 等产品语义；不能泄漏 `AgentSession`、SDK event 或 provider 私有类型。
2. **App 与 Runtime 是一个版本单元，但保持两个故障域。** App window/UI 崩溃后可重新连接仍在运行的 Runtime；Runtime 异常退出则报告可恢复错误，不把 UI 一起带走。
3. **Command 与 event 分开。** 所有产生副作用的 command 都要有 client 生成的 `commandId`、runtime epoch 和可查询 receipt；流式 UI 从按序 event + join snapshot 恢复，断线绝不盲目重放 prompt、Git 或 approval。
4. **Runtime 是唯一 shell/PTY 所有者。** SwiftTerm 或未来 terminal renderer 只渲染与发送 input/resize/reconnect；原生 UI 不自行 `fork` 第二条 shell。
5. **文件授权是 Native 边界，而不是 cwd 字符串。** `NSOpenPanel`/security-scoped bookmark 负责用户授权；Runtime 只能接收明确授权的 project capability。若未来启用 App Sandbox，必须实测 bookmark 在 Runtime 进程中的解析与生命周期，不能假设父进程拿到的 POSIX 路径自动授权给子进程。Apple 的文档要求持久 bookmark 在每次使用时 resolve、`startAccessingSecurityScopedResource()`，并明确说明跨进程传递需要 bookmark 数据而非仅传 path。[Apple: sandbox file access](https://developer.apple.com/documentation/Security/accessing-files-from-the-macos-app-sandbox)
6. **后台与登录启动只能是显式选项。** 默认 App-managed Runtime 随用户的显式生命周期运行；只有在用户开启后才评估 Login Item/LaunchAgent。macOS 的 ServiceManagement 把 Login Item 与 background helper 作为不同模型，不能用开发期常驻 LaunchAgent 偷换成产品默认行为。[Apple: Service Management](https://developer.apple.com/documentation/servicemanagement)

### 1.2.1 调研复核：SDK、完全嵌入和 XPC 不是三选一

这里最容易被名称误导。Pi 上游没有可供 SwiftUI 直接调用的「macOS App SDK」；本项目应使用的是
`@earendil-works/pi-coding-agent` 的 **Node/TypeScript SDK**。它的职责是创建
`AgentSession` / `AgentSessionRuntime`、加载资源与扩展、管理模型和 session replacement；Swift
的职责是产品界面和系统能力。因此，正确的决策不是在「SDK」和「完整嵌入」之间二选一，而是：

> **以 Pi Coding Agent SDK 实现 App 内 Runtime，并将该 Runtime 作为完整嵌入的 macOS 产品组件发布。**

这保留了 SDK 的类型安全、session replacement 和 extension 语义，同时让普通用户只面对一个
`Pi Agent.app`。Pi 官方文档也给出了明确边界：同一 Node 进程且需要直接 agent state、工具和扩展定制时，
优先 SDK；跨语言或需要独立进程隔离时，才使用 stdin/stdout RPC。[Pi SDK: run modes and RPC choice](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)

| 方案                                                                 | 对当前技术栈的评价                                                                                                                                     | 决策                                                          |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| Swift 直接调用 Pi（假设存在 App SDK，或自己嵌 libnode）              | 没有上游 Swift API；会把 Node loader、动态 extension、provider、`node-pty` 与 GUI 绑成同一 crash/升级域。                                              | 不做。                                                        |
| Swift 每个 thread 启动 `pi --mode rpc`                               | 是官方的跨语言路径，但 Swift 仍要重建多 session、持久化、PTY、Git、extension dialog 和断线幂等；会重复已有 Runtime 所有权。                            | 仅保留作兼容 driver、调试或受隔离的 provider adapter。        |
| Swift 原生 App + bundle 内长期 Node Runtime，Runtime 直接使用 Pi SDK | 复用本项目已存在的 Pi SDK、Fastify/WebSocket、`node-pty`、OMP 和 sessiond 测试资产；同时保持原生 UI。                                                  | **当前主线。**                                                |
| 上述结构再用 XPC 替换 Unix socket                                    | XPC 能提供 macOS 生命周期/权限隔离，但并不会让 Swift 获得 Pi SDK，也不消除 Node Runtime；需要针对 Node child、bookmark 和 streaming 做完整重构与实测。 | 作为 Sandbox/签名后的独立 spike，不阻塞当前 Native Contract。 |

「完全嵌入」的验收应是 _没有外部 Node、npm、Pi CLI 或开发 sessiond 是运行前提_，而不是「只有一个
进程」。把不稳定的 extension、provider SDK 与 native addon 放在长期 Node Runtime，反而能让 Swift UI
崩溃后重新连接同一个 session owner。这个故障域分离也与 XPC 的设计目标一致：Apple 将 XPC 定位为把
稳定性或权限边界隔开的 helper 通道，而不是强迫所有产品逻辑进主进程。[Apple: XPC overview](https://developer.apple.com/documentation/xpc)

### 1.2.2 XPC 与安全授权的正确阶段

当前未签名、非 Sandbox 的本机版本继续使用 private Unix socket：其合约已经覆盖 command receipt、
snapshot、WebSocket events 和 terminal bytes，最适合先完成 session/reconnect/PTY 的可靠性矩阵。现已实现的
project capability token + canonical real-path allow-list 是 **同用户 Runtime 的产品级授权边界**：App 每次启动
bundled Runtime 生成仅在 child environment 中传递的 token；Runtime 对除 `/health` 与 `/runtime/hello` 外的
所有请求要求该 header，并只接受授权 root 或其 canonical descendant 的 `cwd`。`authorize-project` 是 epoch-bound、
receipt-safe mutation，原生客户端在读取 session projection 前先完成该 receipt；streaming WebSocket 同样发送 token。
focused service/route/WebSocket tests 与 bundle smoke 分别覆盖缺 token `401`、未授权 cwd `403`、授权后访问以及
receipt retry。这不是 macOS 内核强制的 security scope，也不能替代 sandbox entitlement。

当产品进入签名/Sandbox 交付时，新增一个有明确验收的 XPC RuntimeHost spike，而不是将现有 Node Runtime
草率改成 XPC：

1. Swift 从 `NSOpenPanel` 获取 security-scoped bookmark data，持久化并处理 stale bookmark；
2. 将 **bookmark data 而非纯路径** 交给受同一签名/entitlement 约束的 RuntimeHost/XPC service；
3. 接收方自行 resolve，并在需要的时间窗内开始/停止 security-scoped access；
4. RuntimeHost 再以窄 capability 将已授权目录交给 Node Runtime；Runtime 必须仍拒绝未经登记的 cwd；
5. 以真实 agent prompt、Git、PTY、extension discovery、App crash/reconnect 验证，而不是只验证能 `stat` 一个文件。

Apple 明确说明 security-scoped bookmark 需要相应 entitlement，且 bookmark data 可以传递给另一个进程（例如
XPC service 或 launch agent）再由接收方 resolve；纯 POSIX path 没有这个授权语义。[Apple: persistent and cross-process file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) 对于 sandboxed command-line helper，Apple 还要求它继承宿主 App 的 sandbox；因此把 Node runtime 变成 helper/XPC service 时，必须把 entitlements、bookmark 流向和 native addon 加载一并实测，而非只替换传输层。[Apple: embedding a helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

### 1.2.3 来自 T3 Code/Codex 类产品的可复用原则

T3 Code 的可取之处不是 Electron 或 React 这一层，而是其 Node WebSocket server 统一包装 agent runtime、向客户端提供实时 session 的模型；它也把 project/thread 管理、Git 和实时协作视为同一工作区能力。[T3 Code: architecture overview](https://pingdotgg-t3code.mintlify.app/introduction) Pi Agent 应借鉴下面四项，且已经与当前 Native Contract 对齐：

- **Project 是一级容器，thread/session 是其子项。** 原生 sidebar 固定为 `Project → active Threads → Archived`，不把 sessions 放在 project 之外的并列导航；
- **UI 只投影状态，Runtime 独占副作用。** session、shell/PTY、Git、session files、扩展交互和 command receipt 均只有 Runtime owner；
- **实时订阅优先于 polling。** transcript、activity、terminal 与 pending extension interaction 全部走可恢复 event stream；重连先取 authoritative snapshot，再按 `seq` 接增量；
- **适配层隔离上游。** `PiSdkRuntimeAdapter` 和可选 RPC/OMP driver 允许后端演进，Swift 只承诺本项目版本化 Native Contract，而不是上游私有 event schema。

这些原则说明现阶段不应再新增一个「Swift → Pi RPC → sessiond」的平行控制面，也不应把 Web UI 嵌回原生 App。要继续投入的地方是收紧现有 Runtime contract、授权、生命周期与可验证恢复，而不是复制一套 agent engine。

### 1.3 打包与性能：本阶段不把 SEA/Bun 当作主线

保留固定 Node runtime、production lock 与 manifest/hash 的 bundle 结构。2026-08-04 已从 Runtime 的直接依赖和 exact lock 中移除 CodeMirror、xterm、Lit、Lucide、Marked 以及 Fastify static/compress 等浏览器 Web/UI 专用根依赖；重新构建后，manifest 资源数从 **47,474** 降至 **41,351**（少 6,123 项），arm64 的 `AgentRuntime` 为 **483 MB**，完整未签名 `.app` 为 **488 MB**。`verify-app.sh` 已重新验证 manifest、Node 架构、Runtime health/hello、idle abort receipt、socket、session projection 与 Swift contract check。这个结果证明当前裁剪没有破坏已覆盖的 Runtime 路径；它不是“最小闭包已证明”或“SBOM/license audit 已完成”的声明。

Node SEA 仍标为 **Stability 1.1 / Active development**，且在启用 code cache 时 `import()` 不可用；Pi 的动态 extensions、资源发现与 native addons 正是不能在没有专项验证时塞进单文件的范围。因此 SEA/Bun 只能作为未来的冷启动/体积 spike，验收应覆盖 `node-pty`、Pi resources、extension discovery、PTY、session restore 和 crash/reconnect，而不是只看到一个可执行文件就替换当前 Runtime。[Node SEA documentation](https://nodejs.org/api/single-executable-applications.html)

对照项目可以参考 Syncthing for macOS 的产品责任划分：原生 App bundle 携带并管理自己的后台二进制，提供可选登录启动，而不是要求用户自行搭建 service。Pi Agent 采用这个“一个安装物、一个受管内部引擎”的分发模型；其会话/PTY 合同仍然由本项目维护，不复制对方实现。[syncthing-macos](https://github.com/syncthing/syncthing-macos)

### 1.4 下一阶段的可验证交付，而非继续加一层壳

| 优先级 | 交付                                                                                             | 完成证据                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P0     | 把 receipt 从 abort 扩展到 prompt、create/fork/import、archive/delete、terminal、Git 与 approval | **已交付**：Prompt、原生创建 session、archive、restore、archived delete、Fork/Import、terminal create/continue、Git stage/unstage/commit/push，以及 Pi extension dialog response。相同 `commandId` 重试返回同一 receipt，payload 冲突返回 `409`，原生客户端在 transport 结果未知时仅查询 receipt。Runtime 还在 `PI_WEB_DATA_DIR/native-runtime-command-receipts.json` 以原子 `0600` ledger 先登记 command intent、再登记终态 receipt；新 epoch 对同 ID/同 fingerprint 只返回原 receipt、绝不重放 side effect。若进程在两次登记之间退出，恢复时该条会成为“结果未知、禁止重放”的明确失败，要求刷新事实而不是猜测性重试。剩余工作是完整端到端断线矩阵。                                   |
| P0     | 原生 approval/extension-UI bridge                                                                | **已交付**：Pi `select`、`confirm`、`input` 与 `editor` 被投影为 Swift 原生 sheet；取消、SDK timeout/Abort、session replacement、Runtime shutdown 和 App 重连都有确定语义。                                                                                                                                                                                                                                                    |
| P0     | project authorization 的 Runtime capability                                                      | **当前 non-sandbox logical capability 已交付**：project bookmark 仍由 Swift 持有；bundled Runtime 只接受 App launch token，并用 `realpath` 的 root/descendant allow-list 拒绝 raw/relative、缺失、sibling-prefix 和 symlink-escape cwd。Swift 显示 Authorizing/Authorized/failed 状态，未授权时不创建 thread/prompt/terminal。Sandbox 下 bookmark data → XPC RuntimeHost → Node 的真实 capability hand-off 仍是独立 P1 spike。 |
| P1     | lifecycle recovery matrix                                                                        | 覆盖关闭窗口、App crash/reopen、Runtime crash、sleep/wake、terminal reconnect；任何场景不出现重复 prompt 或第二个 PTY owner。                                                                                                                                                                                                                                                                                                  |
| P1     | dependency closure、SBOM 与冷启动测量                                                            | 基于实际 staging tree 的资源清单、license/SBOM、arm64/x64 smoke、hash 时延和 Runtime 首次 ready 时间。                                                                                                                                                                                                                                                                                                                         |
| P2     | provider/harness driver 扩展                                                                     | 先以 `SessionRuntimeDriver` capability contract 接入，再决定 Pi RPC 或其他 CLI driver；不让 provider 特性穿透 Swift UI。                                                                                                                                                                                                                                                                                                       |

## 2. 本次研究要回答的问题

本决策集中回答五个问题：

1. 原生 Swift 客户端应该直接使用 Pi SDK、Pi RPC，还是继续依赖独立服务？
2. “完整嵌入 macOS App”应该发生在哪一层，是否意味着单进程？
3. 如何保住当前已经存在的多 session、流式 transcript、PTY、OMP、插件和认证能力？
4. Node、native addon、后台 helper、签名、公证和更新应如何组合成可分发产品？
5. 如何避免 Pi SDK 升级时把 Swift UI 和产品协议一起拖入大规模重写？

不在本次范围内：重新设计产品视觉、重写 Pi SDK、把 terminal/PTY 改写成 Swift，以及立刻交付可公证 DMG。本文件决定边界和实施顺序，不把未来工作描述成已完成。

## 3. 当前代码事实

### 3.1 当前已经是 Pi SDK 集成

`src/server/sessions/piSessionService.ts` 已直接从 `@earendil-works/pi-coding-agent` 使用：

- `createAgentSessionRuntime()`；
- `createAgentSessionServices()`；
- `createAgentSessionFromServices()`；
- `SessionManager`。

当前主路径并不是通过 shell 拼接 `pi` 命令。`PiSessionService` 已经在 Node 进程内创建 `AgentSessionRuntime`，这与 Pi 官方 SDK 为自定义 desktop/web UI 提供的嵌入方式一致。

[Pi SDK 文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)明确区分了两个层次：

- `createAgentSession()` / `AgentSession` 适合单个活动 session；
- `createAgentSessionRuntime()` / `AgentSessionRuntime` 适合 new、resume/switch、fork、import 以及 cwd-bound service 重建。

官方内置 interactive、print 和 RPC mode 也使用 `AgentSessionRuntime` 这一层。因此，桌面产品的 Node Runtime 继续使用 SDK 并不是临时方案，而是 Pi 官方支持的程序化集成路径。

### 3.2 当前 `sessiond` 已经是长期 Runtime 的雏形

`src/server/sessiond.ts` 当前创建并持有：

- `SessionEventHub`；
- `AuthService`；
- `PiSessionService`；
- `OmpSessionService` 与 `MultiRuntimeSessionService`；
- `TerminalService` 与 `node-pty`；
- session/unread/activity persistence；
- Unix socket 上的 command、session event 和 terminal routes。

这意味着 Runtime 所有权已经集中在一个长生命周期进程。原生客户端当前通过 Unix socket 和 WebSocket 消费它，UI/API 重载不会天然拥有或终止 Agent session。

正式产品化需要把这个“本机开发服务”收敛为随 `.app` 发布、由 App/RuntimeHost 管理、拥有版本握手和 manifest 的 bundled Agent Runtime，而不是另写第二套 session engine。

### 3.3 原生 vertical slice 已验证的边界

`macos/PiAgent` 已经具备可验证的原生切片：

- SwiftUI/AppKit 原生窗口；
- Project → Thread 侧边栏；
- Runtime health 和 session projection；
- session event WebSocket、snapshot 与 `seq` 去重；
- 事件驱动的流式 transcript；
- Prompt 提交；
- SwiftTerm surface；
- terminal input、resize 和 reconnect。

所以当前问题已经从“Swift 能不能展示 Pi”转变为“如何把 Runtime 和依赖安全地装进 App，并形成可升级的产品边界”。

### 3.4 当前依赖声明不适合作为 App 内 Runtime manifest

项目当前安装的 Pi SDK 版本是 `0.81.1`。三个 Pi 包声明为 `devDependencies`，同时通过较宽的 `peerDependencies` 范围要求外部环境提供：

```text
@earendil-works/pi-agent-core
@earendil-works/pi-ai
@earendil-works/pi-coding-agent
```

这适合 npm 插件/开发仓库，但不适合自包含 `.app`。正式 Runtime 必须拥有单独的 production dependency closure，并记录：

- 精确解析后的 Pi SDK 版本；
- 精确 Node 版本；
- npm lockfile/hash；
- 目标架构；
- native addon 和 helper 列表；
- WASM、模板、prompt、extension 与 provider assets；
- license notices 与 SBOM；
- 每个关键文件的 SHA-256。

普通用户首次启动时不得执行 `npm install`，也不得从用户全局 npm 环境补齐 Pi SDK。

### 3.5 已发现的 native/resource 打包面

本机已安装依赖至少包含以下非普通 JavaScript 资源：

| 依赖面            | 当前发现                                                       | 发布影响                                         |
| ----------------- | -------------------------------------------------------------- | ------------------------------------------------ |
| `node-pty`        | Darwin `pty.node` 与 `spawn-helper`，分别有 arm64/x64 prebuild | 必须按架构验证、从内向外签名，并做真实 PTY smoke |
| Pi TUI native     | `darwin-modifiers.node`                                        | 即使 UI 不使用 TUI，也要确认生产裁剪后是否仍可达 |
| Clipboard         | Darwin universal、arm64、x64 `.node`                           | 只打包实际目标所需变体，验证 Hardened Runtime    |
| Photon            | `photon_rs_bg.wasm`                                            | Runtime manifest 必须覆盖 WASM 与加载路径        |
| Extensions/assets | 动态发现的 skills、prompts、themes、extensions                 | 不能假设普通单文件 bundler 能静态发现完整依赖图  |

这份 inventory 只是当前 node_modules 的证据，不是最终 SBOM。发布流水线必须从 production staging tree 重新生成并校验。

## 4. 不可破坏的产品约束

无论采用哪条集成路径，都必须满足：

1. App 是唯一面向普通用户的安装和启动入口；
2. 主界面不使用 Electron、Tauri 或 WebView；
3. App 重绘、窗口关闭或 UI 崩溃不能隐式终止活动 Agent；
4. session、terminal、Git/file side effect 只能有一个事实所有者；
5. transcript 使用事件流和可恢复 snapshot，不能退回轮询；
6. terminal renderer 不自行 fork 第二套 shell，PTY 仍由 Runtime 持有；
7. Swift 不依赖 Pi 私有 TypeScript 类型；
8. 用户不需要全局 Node、npm 或 Pi CLI；
9. App、Runtime、native addon 和 helper 作为一个版本单元发布；
10. 未知结果、断线或超时不能触发非幂等命令的盲目重放；
11. 本地协议默认不开放 TCP localhost 端口；
12. 开发模式仍可连接 checkout 中的 sessiond，但这种能力不能成为生产安装前提。

## 5. 方案比较

| 方案                                              | 优点                                                                          | 主要问题                                                                                                                                              | 决策                     |
| ------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| Swift 进程内嵌 Pi SDK/libnode                     | 表面上只有一个进程，调用链短                                                  | 没有官方 Swift SDK；需要把 Node module loader、filesystem、dynamic extensions、native addon、PTY 和 Provider SDK 一起塞进 GUI；崩溃域、签名和升级耦合 | **拒绝**                 |
| Swift 直接启动 `pi --mode rpc`                    | 官方跨语言 JSONL；进程隔离；适合单 Agent harness                              | Swift 必须重做多 session orchestration、auth、terminal、OMP、插件和持久化；通常演化成每 session 一进程或额外调度器                                    | **仅作兼容/诊断 driver** |
| App 自带长期 Node Runtime，Runtime 内直接使用 SDK | 复用当前代码和测试；完整多 session、事件、PTY、插件和定制 tools；SDK 类型安全 | 需要做好 helper 生命周期、依赖裁剪、签名、公证和升级                                                                                                  | **主方案**               |
| 依赖用户全局 `pi-web-sessiond` / npm 安装         | 开发迭代简单，现状改动少                                                      | 普通用户环境不确定；版本漂移；安装、权限和故障不可控                                                                                                  | **仅开发兼容**           |
| Bun `--compile` 单文件 Runtime                    | artifact 简洁；支持嵌入 assets 和 N-API addon                                 | Node 兼容、signals、PTY、dynamic extension、provider SDK 和 native addon 需要长期验证                                                                 | **后续 spike**           |
| Node SEA                                          | 官方 Node，可减少外部文件                                                     | 仍是 active development；module loading、dynamic import 和 native addon 需要特殊处理                                                                  | **首发暂缓**             |

### 5.1 为什么不把 Pi SDK 直接嵌入 Swift

“原生 macOS App”描述的是产品界面、系统行为和分发体验，不等于所有代码必须在一个 Swift 进程内执行。

Pi SDK 是 Node/TypeScript API，其核心行为依赖 Node 文件系统和模块语义；Pi 的 skills、context、prompt、extension 与 provider 集成也围绕目录和动态资源发现。再加上 `node-pty` 和 native addon，把这些能力塞进 Swift GUI 需要自行嵌入 libnode 或 JavaScript runtime，并建立一套 C/Objective-C bridge。

这样做不会消灭进程与协议复杂度，只会把它们变成更难测试的进程内 ABI，同时让任意 provider/native addon 崩溃直接带走窗口进程。对当前技术栈没有收益证据。

### 5.2 为什么 Pi RPC 不作为 App 主协议

[Pi RPC 文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)定义了 stdin/stdout 上严格 LF 分隔的 JSONL：command 带可选 request id，response 回显 id，events 异步流出。它很适合其他语言控制一个 Pi 进程。

但它解决的是“如何控制一个 headless Pi Agent”，不是 Pi Agent 产品全部 orchestration：

- 项目和 workspace registry；
- 多 Runtime / 多 session 列表与调度；
- 全局 unread/notification/activity；
- terminal lifecycle 和 reconnect；
- OMP 等其他 driver；
- 产品级权限、配置、幂等、epoch/sequence 和升级 gate。

如果 Swift 直接以 RPC 为主协议，这些能力最终仍需要一个 orchestrator。当前 `sessiond` 已经承担这个角色，而且内部直接使用 Pi SDK。删除它再在 Swift 中重写，会丢失已验证能力而没有产生新的清晰边界。

RPC 的正确位置是 `SessionRuntimeDriver` 的一种实现：当第三方 Agent 只有 CLI/RPC、某个 Pi 版本需要强隔离，或测试 harness 需要观察原始协议时使用。

### 5.3 为什么长期 Node Runtime 是正式产品组件

长期 Runtime 能自然提供。当前原生 `WindowGroup` 已让每个窗口构造自己的 UI model 与 project bookmark store，但把同一条 immutable Runtime connection/supervisor 注入全部窗口；因此 Project/Thread/transcript/terminal selection 相互独立，而一个窗口关闭或刷新不会重新启动或停止另一个窗口使用的 session。

长期 Runtime 还提供：

- App/UI 重启时 session 不丢；
- 多窗口连接同一事实源；
- 每个 Agent session 不必重复加载完整 SDK/provider/extension tree；
- PTY 在 View 重建后继续存在；
- Web/CLI 兼容层与原生 App 观察同一状态；
- Runtime crash 可以与 UI crash 分离诊断；
- 后续远程 Runtime 复用相同 product contract。

它不是用户需要管理的“服务器”，而是 `.app` 的内部引擎，类似原生壳包装并监督 bundled daemon 的成熟 macOS 模式。[Syncthing for macOS](https://github.com/syncthing/syncthing-macos)就是可参考的开源分发案例：原生 App bundle 携带自己的后台 binary、提供可选登录启动，并由 App 自己管理更新。Pi Agent 的业务协议和 UI 会更复杂，但发布责任边界相同。

## 6. 目标所有权与模块边界

### 6.1 唯一事实所有者

| 事实/能力                                | 所有者                                  | 其他进程能做什么                            |
| ---------------------------------------- | --------------------------------------- | ------------------------------------------- |
| Agent session、队列、stream、fork、abort | Agent Runtime                           | Swift 只提交 command、显示 projection       |
| Pi SDK 对象与 subscription               | `PiSdkRuntimeAdapter`                   | orchestration 不暴露 SDK 类型               |
| PTY process、cwd、环境与 byte stream     | `TerminalService` / Runtime             | SwiftTerm 只渲染和发送 input/resize         |
| 项目、workspace、Runtime 配置            | Agent Runtime                           | Swift 展示、编辑经过校验的 contract         |
| Runtime 进程启动与版本协调               | `RuntimeSupervisor` / `RuntimeHost`     | Runtime 不反向拥有 App 窗口                 |
| 窗口、分栏、选中项、原生菜单             | Swift App                               | Runtime 不持久化纯 UI 状态                  |
| session UI cache                         | Swift App，可重建                       | 不能成为 session 事实源                     |
| secret                                   | Keychain，受限 credential bridge        | 不进入 UI store、普通日志或 command payload |
| 项目目录授权                             | Swift security-scoped bookmark / 授权层 | Runtime 只获得已授权路径能力                |

### 6.2 引入 `SessionRuntimeDriver`

当前 `PiSessionService` 体积较大，并直接接触 Pi SDK。迁移时应先建立窄 adapter，而不是同步重写业务：

```text
MultiRuntimeSessionService
└── SessionRuntimeDriver
    ├── PiSdkRuntimeAdapter
    │   └── @earendil-works/pi-coding-agent
    ├── OmpRpcRuntimeAdapter
    └── PiRpcRuntimeAdapter          可选兼容/隔离实现
```

建议的 driver 能力模型是产品语义，而不是 SDK 类的镜像：

```ts
interface SessionRuntimeDriver {
  readonly runtimeId: string;
  readonly capabilities: RuntimeCapabilities;

  create(input: CreateSessionInput): Promise<SessionHandle>;
  resume(input: ResumeSessionInput): Promise<SessionHandle>;
  prompt(input: PromptCommand): Promise<CommandReceipt>;
  steer(input: QueueCommand): Promise<CommandReceipt>;
  followUp(input: QueueCommand): Promise<CommandReceipt>;
  abort(input: AbortCommand): Promise<CommandReceipt>;
  fork(input: ForkCommand): Promise<SessionHandle>;
  snapshot(sessionId: string): Promise<SessionSnapshot>;
  subscribe(sessionId: string, sink: SessionEventSink): Unsubscribe;
  dispose(): Promise<void>;
}
```

这里的类型必须属于 PI WEB/Pi Agent contract。`AgentSession`、`AgentSessionRuntime`、SDK message/event class 和 provider 私有结构不能穿过 driver，更不能编码进 Swift。

### 6.3 `PiSdkRuntimeAdapter` 的特殊责任

Pi 官方文档指出：new/switch/fork/import 后 `runtime.session` 会替换，subscription 绑定的是旧 `AgentSession`，extension 也需要重新绑定。因此 adapter 必须统一承担：

1. 创建 cwd-bound services；
2. 创建并持有 `AgentSessionRuntime`；
3. 每次 session replacement 后原子地解绑旧 subscription；
4. 重新绑定 extension 和 event projection；
5. 发布新的 runtime/session generation；
6. 将 SDK event 投影为稳定的 product event；
7. 将 SDK 错误映射为稳定错误码，同时保存内部诊断；
8. 在 `dispose()` 时按确定顺序释放 subscription、session、services 和资源。

这也是防止 SDK 升级扩散的关键 seam。升级 Pi 包时，绝大多数变化应限制在 adapter、fixture 和 compatibility tests 内。

当前已完成第一层收口：`PiSessionService` 不再直接调用 `createAgentSessionRuntime`、`createAgentSessionServices` 或 `createAgentSessionFromServices`；这些 SDK lifecycle factory 调用和 `SessionManager` 的运行时校验都在 `PiSdkRuntimeAdapter` 内。服务仍保留项目自定义 tool、delegation 与 session event orchestration，避免为了“只有一个 import”而把产品规则也塞进 SDK adapter。session replacement 的 subscription/extension rebind 与稳定 event projection 仍是下一层待收口工作。

## 7. Swift 与 Runtime 的 Native Contract

### 7.1 Contract 不等于 Pi SDK，也不等于 Pi RPC

Native Contract 面向产品能力，至少分三条逻辑通道：

```text
command channel   请求、验证、receipt、结果和幂等
event channel     session/activity/auth/runtime 事件流
terminal channel  原始 PTY bytes、input、resize、close 和 reconnect
```

第一阶段继续复用已验证的 Unix socket HTTP + WebSocket，避免在 Runtime 打包同时替换 transport。Swift feature 只依赖 `RuntimeClient`、`RuntimeEventStreamClient` 和 `RuntimeTerminalClient` 协议，HTTP/WebSocket 细节留在 transport 层。

当现有协议的 framing、背压或多路复用成为可测瓶颈时，再迁移到统一的 length-prefixed message stream。不能在同一个发布切片里同时更换 SDK adapter、Runtime 所有权和 wire protocol。

### 7.2 启动握手

App 连接后必须先完成 `hello`，在握手成功前不发送 mutation：

```json
{
  "protocolMajor": 1,
  "protocolMinor": 0,
  "appVersion": "…",
  "runtimeVersion": "…",
  "runtimeEpoch": "…",
  "runtimePid": 123,
  "nodeVersion": "…",
  "piSdkVersion": "…",
  "architecture": "arm64",
  "capabilities": ["sessions.events", "terminals.reconnect"],
  "latestSequence": 42
}
```

规则：

- protocol major 不兼容时拒绝 mutation，并进入可操作的诊断/升级页面；
- minor 兼容使用 capability negotiation，不靠 App 猜测字段存在；
- `runtimeEpoch` 每次全新 Runtime 实例变化；
- `sequence` 只在同一 epoch 内比较；
- App 重连先取 snapshot，再从水位接 event stream；
- manifest 声明的版本必须与运行时 `hello` 一致，不一致立即失败。

### 7.3 命令 receipt 与幂等

创建 session、Prompt、fork、archive、delete、terminal create 等 mutation 必须携带：

- `commandId`；
- `idempotencyKey`；
- 调用者和目标 Runtime epoch；
- 接受时间和稳定状态。

最小状态：

```text
received → accepted → running → completed | failed | cancelled
```

断线、timeout 和“没有看到 response”都不是重复提交的理由。App 保存原 idempotency key，先查询 command 状态；只有 Runtime 明确表示未接收或该 key 已安全终止，才能决定下一步。

当前 Runtime receipt store 已覆盖 `POST /runtime/commands/abort-active-work`、原生 Prompt、New Thread、Import Thread、archive、restore、archived delete、Fork Thread、terminal create/continue、原生 Git stage/unstage/commit/push，以及 `POST /sessions/:sessionId/interactions/:interactionId/respond`；`GET /runtime/commands/:commandId` 支持 timeout 后查询。所有这些 mutation 都以 `commandId + runtimeEpoch + payload fingerprint` 绑定：相同 intent 只执行一次，冲突或 stale epoch 返回 `409`。Swift 在 socket transport 结果未知时只查 receipt，不会盲重放。archive/restore/delete 成功后再拉取 session projection；delete 仍由服务端拒绝非 Archived 会话，原生 UI 也只在 Archived 分组提供二次确认入口。terminal receipt 返回 Runtime-owned terminal projection，避免一次未知 socket 写入生成第二个 PTY，continue 也不会重复替换已退出 terminal 的 PTY。abort 会对 Pi/OMP 中真正仍有 streaming、compaction、shell 或 queued work 的 session 逐一 abort，只有 receipt completed 且无失败项时，App 才停止自己拥有的 Runtime。Fork Thread 使用只读候选项 projection 和独立 `fork-session` receipt，Import Thread 也通过 Pi SDK 的 `importFromJsonl()` 进入同一 session replacement/rebind 生命周期。

#### Fork Thread 的产品合同

`GET /sessions/:sessionId/fork-candidates` 返回倒序的 `{ entryId, label }` user-message projection；Swift 仅展示 label，不能从 transcript 自行推断 Pi entry。用户选择后，`POST /sessions/:sessionId/fork` 必须携带 `cwd`、`runtimeId`、`entryId`、`commandId` 和 `runtimeEpoch`。receipt 的 `forked` 结果只包含新的 `SessionProjection`（以及可选 `promptDraft`），不泄漏 `AgentSessionRuntime`、Pi message 或 provider 类型。

Runtime 在执行时再次验证 entry 仍属于当前可 fork 的 user-message 集，并复用现有 tree-exclusive gate、active-work gate、Pi `runtime.fork()`、replacement subscription/extension rebind 和相关 session 命名。候选项在 sheet 打开后失效、同时有流式工作或 Runtime epoch 改变都会失败而非“猜测性重试”。Socket 写入结果未知时，App 只以同一 `commandId` 查询 receipt；它绝不第二次提交 Fork。

#### Import Thread 的产品合同与权限边界

原生客户端要求先选中一条 active thread，再通过 `NSOpenPanel` 选择 `.jsonl` 文件。`POST /sessions/:sessionId/import` 必须携带当前 thread 的 `cwd`、`runtimeId`、用户选择的绝对 `inputPath`、`commandId` 和 `runtimeEpoch`。Runtime 只接受普通 `.jsonl` 文件，并通过 Pi SDK `importFromJsonl(inputPath, currentProjectCwd)` 复制文件到 Pi session storage、替换 Runtime session、重新建立 subscription/extensions；receipt 仅返回导入后的 `SessionProjection`。

当前未启用 App Sandbox：App 与 bundled Node Runtime 以同一用户身份运行，所以 `NSOpenPanel` 选中的 POSIX 路径可传给 Runtime。这个事实**不是** security-scoped bookmark 跨进程授权的证明。Sandbox 前必须将 path 传输替换为明确的 bookmark/capability hand-off，并使用真实 child Runtime 验证 resolve、`startAccessingSecurityScopedResource()`、失败与 revoke 行为。导入中的 socket 未知结果仍只允许读取同一 receipt；绝不以第二次 `importFromJsonl()` 作为恢复手段。

#### 原生 Git 的产品合同

Swift inspector 通过 `/git/status?cwd=`、`/git/diff?cwd=&path=&staged=`、`/git/push-preview?cwd=` 与 `/git/revert-preview?cwd=` 读取 Runtime projection；Swift **绝不**用 `Process()` 运行 Git。`POST /git/stage`、`/git/unstage`、`/git/discard`、`/git/commit`、`/git/push` 与 `/git/revert-head` 都必须携带 `cwd`、`commandId` 和 `runtimeEpoch`，并分别使用 `stage-git-paths`、`unstage-git-paths`、`discard-git-paths`、`commit-git`、`push-git`、`revert-git-head` receipt。`discard`、`push` 与 `revert-head` 还必须携带 `confirmed: true`；Runtime 会在执行前重新评估 policy，而不接受 remote、branch、refspec、force 或任意 commit 参数。每个完成 receipt 返回新的 `GitStatus` projection；commit/revert 还返回新 commit hash 和 subject。socket 写入未知时，App 只读取同一 receipt，不能再次执行 mutation。

Runtime 用经过净化的环境启动 Git，并设置 `GIT_TERMINAL_PROMPT=0`，所以不能因隐藏的凭据交互而在后台卡住；这不是 Keychain credential broker，认证失败会以明确错误返回。当前 UI 支持 root worktree 的 status/diff、逐文件 stage/unstage、已跟踪且未暂存的 root file 明确确认后 discard、原生 commit sheet，以及当前 branch 到既有 tracking upstream 的受限 push；保留 Git hooks，不会用 `--no-verify` 绕过项目政策。`Undo Latest Commit` 先取 Runtime preview，要求 Git worktree/index 完全干净、`HEAD` 存在且是单 parent non-merge commit；确认后只运行 `git revert --no-edit HEAD`，因此新增反向 commit 而不移动 `HEAD` 或改写历史。discard 不删除 untracked files，不触碰 index，拒绝 rename 和所有 submodule path。push preview 拒绝 detached HEAD、缺 upstream、ahead 为零和任何 `behind > 0` 的分支，执行时使用 Runtime 从 Git 解析出的 remote/ref，而非 UI 输入。内嵌 submodule 的内容可展示和查看 diff，但原生 inspector 明确拒绝直接 stage/unstage/discard，必须先在该 submodule 自己的 checkout 完成操作；superproject 的 submodule pointer 仍可按普通 root path 暂存。任意 reset、任意 commit revert、force push、set-upstream、tag、remote deletion 和任意路径执行仍未提供。

#### Pi extension dialog 的产品合同

Runtime 在 Pi session 绑定 extensions 时，将 `ctx.ui.select`、`confirm`、`input` 和 `editor` 接到 daemon-owned interaction service。`GET /sessions/:sessionId/interactions?cwd=&runtimeId=` 只返回稳定 projection：opaque interaction id、session/cwd、kind、title、可显示 message/options/placeholder/prefill、创建时间和可选 timeout。SDK callback、extension implementation、Promise resolver 和任何 Pi 私有类型都不会离开 Node Runtime。

当 interaction 打开或关闭时，Runtime 在既有 session WebSocket 上发 `extension.interaction.opened`/`closed`。Swift 不做定时轮询：连接 snapshot 后拉取一次权威列表，随后只在这两个事件到达时重新拉取。这样浏览器/App 短暂断开不会取消 extension 请求；重连后若 timeout 尚未发生，sheet 会按 Runtime 的现状恢复。SDK `AbortSignal`、SDK timeout、session extension rebind、session close 和 Runtime shutdown 都会从服务端撤销 projection 并以该类型的安全默认值结束（select/input/editor 为取消，confirm 为 `false`）。

回应必须使用 `POST /sessions/:sessionId/interactions/:interactionId/respond`，带 `cwd`、`runtimeId`、`commandId`、`runtimeEpoch` 和且仅有一种 kind-compatible response（`cancelled`、`selected`、`confirmed` 或 `text`）。Runtime 再次校验 interaction 仍属于该 session/cwd 且 value 与 kind/options 匹配；完成 receipt 返回已消费 interaction projection。若 Swift 没有看到 socket 写入结果，只读回同一 receipt，绝不再次响应。`input` 目前没有 Pi SDK 传来的 secret metadata，因此按普通文本 field 展示；未来只有 SDK 合同新增明确的敏感字段后，才可提升为 `SecureField`。

### 7.4 Event projection

#### 项目隔离的原生活动通知

原生任务提醒不是 broad global event stream 的另一种消费者。bundled App 用 project-capability token 调用 `GET /sessions/notifications/events?cwd=…`；该 WebSocket 在 Runtime 侧只转发同一 canonical cwd 的 `notifications.summary`，不会暴露其他项目的 status、activity、transcript 或 tool event。收到 summary 后，App 使用同一授权项目的 `GET /sessions/:sessionId/notifications` 读取 bounded inbox，再决定是否生成系统提醒。

系统通知是显式 opt-in：Settings 默认关闭，只有用户切换后才请求 macOS alert/sound 授权。通知正文只来自 Pi extension 的明确 `notify` 记录；Swift 不会从 provider 事件、Prompt、terminal、tool output 或 transcript 生成正文。App 首次订阅会先将已有 inbox 项加入有界 seen cache，之后以 Runtime daemon instance、project、session 和通知 id 去重；所以断线重连、多窗口或同一 summary 的重复发送都不应产生重复 alert。App 在前台时只更新本地投影，不显示 macOS toast。

通知点击携带的最小 metadata 只含 version、opaque session id 和 cwd。它只能选择一个当前已打开、已授权且 cwd 匹配的 Thread；如果没有这样的窗口，App 只被激活，用户仍需通过原有 bookmark 流程选择/重开项目。该点击不能以 raw path 扩展 filesystem authority，也不会把 notification body、secret 或 transcript 写入 `userInfo`。此交付与 Login Item 独立：Runtime 的背景运行入口已存在，但用户可选的登录启动仍是后续工作。

Pi SDK 原始事件应投影为 UI 所需的稳定事件，例如：

- `session.started`；
- `message.started` / `message.delta` / `message.completed`；
- `tool.started` / `tool.updated` / `tool.completed`；
- `queue.changed`；
- `session.compactionChanged`；
- `session.completed` / `session.failed`；
- `terminal.output` / `terminal.exited`；
- `runtime.authChanged` / `runtime.healthChanged`。

每个 event 包含 `runtimeEpoch`、单调 `sequence`、`sessionId`、可选 `commandId` 和 schema version。Swift 不应从 SDK event name 或 provider message shape 推导生命周期。

### 7.5 Pi RPC adapter 的协议要求

如果引入 `PiRpcRuntimeAdapter`，必须遵守官方 RPC 的严格 JSONL：

- 仅以 LF `\n` 分隔 record；
- 允许输入 CRLF 时只去掉尾部 CR；
- 不使用会把 Unicode line separator 当换行的通用 reader；
- command 使用 request id，与 response 相关联；
- stdout 只承载协议，普通日志走 stderr；
- 对异步 event 做有界队列和背压；
- child process exit、signal、半条 JSON 和未知 response id 都映射为确定的 driver failure。

RPC adapter 输出的仍是相同 `SessionRuntimeDriver` 语义，不把 JSONL 直接转发给 Swift。

## 8. 进程与生命周期设计

### 8.1 默认首发模型

首发先使用 App-on-demand 模式：

```text
App launch
  → validate exact Runtime manifest and resource hashes
  → discover compatible runtime socket
  → connect existing compatible runtime OR launch bundled runtime
  → hello / version / epoch handshake
  → restore projections from snapshot + events
```

`RuntimeSupervisor` 使用确定的 socket namespace 与跨进程 `.sessiond-launch.lock`：失败探测后先持锁、再次 hello/health，只有锁内仍不可用才启动 bundled child，并持锁直到 handshake 成功或失败。因此两个 App 实例不会因为同时看见空 socket 而各自拉起 child。检测到不兼容旧 Runtime 时，不得直接覆盖或并行写同一份状态；先进入升级协调。

### 8.2 关闭窗口与退出 App

关闭最后一个窗口不是 `SIGTERM` 的同义词。用户显式退出且存在活动任务时显示三种清晰结果：

1. 继续后台运行；
2. 停止任务并退出；
3. 取消退出。

没有活动任务时，按照用户的“关闭后继续运行”设置决定保留或优雅停止 Runtime。不能在 `applicationShouldTerminate` 中无等待地杀进程。

当前已实现退出协调：App 在 `applicationShouldTerminate` 中先异步刷新 `/health`；有活动 session 或 health 不可用时显示“保持 Runtime 并退出 / 停止自有 Runtime 并退出 / 取消”。“停止”先执行 epoch-bound、可查询的 `abort-active-work` receipt；只有所有已识别 active work 成功 abort，才调用 `RuntimeSupervisor.stop()`。`RuntimeSupervisor` 只会终止它自行 `Process.run()` 的 child，不会停止 `PI_AGENT_RUNTIME_SOCKET` 指向的开发/外部 Runtime。Prompt、New Thread、单会话 Import/Fork/archive/restore/archived delete、terminal create/continue、Git mutation 和 extension dialog response 都采用相同的 receipt 恢复策略；Runtime-owned `0600` command ledger 跨 restart 保留终态 receipt。若记录只到 action 开始而 Runtime 已退出，恢复后会明确标为不可重放的未知结果，不会自动再提交副作用。

### 8.3 Runtime crash 与 App crash

- Runtime crash：App 保留最后 projection，标记为 stale，展示 crash id/log 路径；恢复前不得把 in-flight mutation 当作失败并重放；
- App crash：如果用户开启后台 host，Runtime 继续；否则由 lease/父进程策略在安全窗口后退出；
- App 重开：先发现和握手已有 Runtime，按 epoch + sequence 重建状态；
- terminal：Runtime 存活时 reconnect 原 PTY；Runtime 已死时显示 exit，不偷偷创建新 shell。

### 8.4 后台运行与 `SMAppService`

Apple 在 macOS 13+ 提供 [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) 管理 Login Item、LaunchAgent 和 daemon。推荐分两阶段：

1. 第一阶段由 App 打开时启动 bundled Runtime，不默认注册后台服务；
2. 用户明确开启“登录启动/关闭窗口后继续运行”后，再评估 Login Item 或 LaunchAgent 的独立交付。

后台能力必须可见、可撤销，并在设置中显示当前注册状态。不要在首次启动时静默安装常驻项。

### 8.5 是否使用 XPC

[`XPC`](https://developer.apple.com/documentation/xpc)适合原生进程隔离、受控接口和由系统管理的 helper 生命周期，但 Node Runtime 已经有 Unix socket 产品协议。为所有 session/event/terminal 数据再包一层 XPC 会增加双桥接和大流量序列化成本。

可选的 `PiAgentRuntimeHost` 应保持很薄：

- 验证 manifest、资源完整性和 Runtime 兼容性；
- 启动、监督和停止 Node Runtime；
- 回报 pid、版本、health 与退出原因；
- 协调 Login Item/LaunchAgent 和 App update；
- 提供有限的 credential/bookmark broker。

App ↔ RuntimeHost 可使用 XPC；App ↔ Node 的业务数据继续走 Unix socket。RuntimeHost 不解析 transcript delta，不拥有 session，也不代理 PTY bytes。

### 8.6 App 更新状态机

```text
update downloaded
  → gate new mutations
  → query active sessions and terminals
  → notify user / wait / checkpoint according to policy
  → stop or hand off runtime with explicit final state
  → replace complete App + helper + Runtime unit
  → verify manifest、Node 架构和资源 hash
  → migrate protocol/state
  → launch and reconcile old command receipts
```

Sparkle 只负责安全分发 App bundle；active-session gate、checkpoint、Runtime 协调和回滚是产品责任。

## 9. Runtime 打包决策

### 9.1 首发：真实 Node + production staging tree

第一版不追求单文件。当前实现生成如下逻辑布局；它是未签名 App 内的自包含 Runtime，不会从用户 PATH 或全局 npm 环境寻找依赖：

```text
Pi Agent.app/Contents/
├── MacOS/
│   └── PiAgent
└── Resources/
    └── AgentRuntime/
        ├── node/bin/node
        ├── node/lib/                Node 的动态库闭包
        ├── dist/
        ├── node_modules/            Runtime package-lock 的 production closure
        ├── package.json
        ├── package-lock.json
        ├── runtime-launcher.mjs
        └── runtime-manifest.json
```

`scripts/macos/build-runtime.mjs` 在受控 staging 目录中以 `npm ci --omit=dev` 安装
`macos/PiAgentRuntime/package-lock.json`，复制根项目编译后的 `dist/`、Node executable 与 Node `lib/`，然后生成每个普通文件及 symlink 的 SHA-256 manifest。`runtime-launcher.mjs` 在加载 `sessiond` 前复核 Node 版本、架构、Node hash 与所有 Runtime 资源；Swift 在启动其拥有的 child 前进行同一份资源预检。`scripts/macos/smoke-runtime.sh` 则使用 App 内的真实 Node/Runtime，经 Unix socket 验证 `/health`、`/runtime/hello` 和 Swift contract check。

某些 npm native addon 依赖相对路径，不能为了目录好看就直接移动。后续 dependency-closure 裁剪必须先在下面两种方式中验证后再定：

- 保持 production package layout，并对每个 Mach-O 的架构、依赖与可加载性做审计；
- 将 native code 放入标准 code location，并由受测 loader manifest 映射到稳定路径。

当前范围不执行 `codesign`、公证、Gatekeeper、DMG 或 Sparkle。完整性基线不是“未签名即不验证”：exact lock、manifest、SHA-256、symlink escape check、Node 版本/架构检查与真实 Runtime smoke 都是当前发布前必须通过的检查。若将来重新启用公开分发，Apple 的 [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) 才是嵌套代码由内向外签名的参考；它不属于本阶段验收。

仓库当前 `engines.node` 的 `>=22.19.0` 是兼容下限，不是桌面发布 pin。根据 [Node 官方发布状态](https://nodejs.org/en/about/previous-releases)，调研时 Node 24 是 LTS，首发应优先用 Node 24 最新安全补丁做完整验证；如果 Pi SDK 或 native addon 的证据要求 Node 22，再把 Node 22 作为有期限的兼容基线。最终 manifest 必须记录完整 patch 版本和官方 binary checksum，不能只写 major。

### 9.2 Runtime 自有 package manifest

不要直接把仓库开发用 `node_modules` 整体复制进 App。增加专门的 Runtime build manifest：

- Pi SDK 与运行所需包使用 exact version，不用 `^`；
- 只包含 production dependencies；
- `npm ci` 在干净 staging directory 执行；
- 禁止生命周期脚本从网络下载未记录 binary；
- 对每个 Mach-O 执行 `file`、`lipo -info` 和依赖审计；
- 生成文件清单和 SHA-256；许可证与 SBOM 在 dependency closure 裁剪完成后补入；
- App build 消费已经完成验证的 staging artifact。

当前 npm package 的 peer dependency 仍可服务 CLI/Web 分发；bundled Runtime 的 manifest 是另一个发布边界，不应依赖 consumer resolution。

### 9.3 架构策略

当前仅在本机构建并验证与当前 Node 架构一致的 App bundle；尚未产出 DMG。后续若决定支持多个 CPU 架构，分别生成：

- Apple Silicon arm64 App bundle；
- Intel x86_64 App bundle（如果产品决定支持 Intel）。

只有在 Node、所有 `.node`、spawn helper 和 Swift dependencies 的 universal2 合并、Runtime manifest、完整 smoke 与生命周期验收全部通过后，才合并 universal artifact。不要在同一 App 中混入“可能永远不会加载”的其他平台 binary。

### 9.4 Node SEA 为什么暂缓

[Node Single Executable Applications](https://nodejs.org/api/single-executable-applications.html)当前仍标注 Active Development。官方文档说明 injected main 默认不能从文件系统加载普通模块；动态 `import()` 不能加载文件系统模块；native addon 需要作为 asset 写出到临时文件再用 `process.dlopen()`。

PI WEB 当前依赖动态 extension/resource discovery、`node-pty`、clipboard addon、WASM 和多类 provider SDK。SEA 并非不可用，但第一版采用它会让“产品打包”与“重写 module/resource loader”绑在一起，风险高于节省的文件数量。

只有满足下列条件才重新评估：

- Runtime 已有完整资源 manifest；
- 动态 extension 安装边界已经冻结；
- native addon extraction 目录、完整性、清理和并发规则有 E2E 证明；
- 连续长 session、PTY、auth、插件和更新 smoke 与普通 Node 基线等价。

### 9.5 Bun compile 为什么只做后续 spike

[Bun single-file executable](https://bun.com/docs/bundler/executables)支持嵌入 asset、目录和 N-API addon；[Bun Node-API 文档](https://bun.com/docs/runtime/node-api)说明多数现有 Node-API extension 可以直接工作。这使它比 SEA 更值得做独立实验。

但“多数”不等于当前完整技术栈已兼容。Bun spike 必须使用真实 Runtime，而不是 hello-world，至少覆盖：

- `node-pty` spawn、resize、signal、退出码、10 MB 输出；
- Pi session new/resume/fork/abort/compaction；
- project/global extension 和 skill discovery；
- provider auth/OAuth 与 Keychain bridge；
- clipboard/native addon 与 WASM；
- sleep/wake、App crash reconnect、Runtime crash recovery；
- Runtime manifest 校验、App move、重启与本地替换安装。

若任何一项需要维护大规模兼容 patch，继续使用真实 Node。单文件体积不是产品成功指标，可靠升级和 session 不丢才是。

### 9.6 动态 extension 与 native code 政策

Pi 的 JavaScript extension、skill、prompt 和 context discovery 可以保留，但首发必须把“动态资源”与“动态 native code”区分开：

- 允许从已授权项目读取受 policy 管理的 JavaScript/TypeScript extension 和文本资源；
- 不允许 extension 在 App 首次启动或运行中执行不受控的 `npm install`；
- 不允许 Node Runtime 加载未进入发布 manifest 或 architecture 不匹配的 bundled `.node`/dylib；
- 需要 native addon 的第三方扩展必须经过独立审核、构建、manifest/兼容测试，或放入受限 subprocess，不得自动注入主 Runtime；
- Runtime 应记录 extension id、来源、hash 与加载结果，但日志不得包含 credential 或完整敏感 Prompt。

未签名阶段以 Runtime manifest 为唯一 bundled-native-code allowlist；不接受运行时 `npm install` 或未审计 native addon。若未来开启签名/沙盒，必须另立 ADR 决定 Team ID、Hardened Runtime 与 library validation，不为方便插件加载而默认放宽限制。

## 10. 安全与 macOS 权限边界

### 10.1 首发分发与 Sandbox

第一阶段是受开发者主动安装、未签名的本地 App bundle，不把 Mac App Store sandbox 作为前提。原因不是放弃安全，而是 coding agent 需要用户授权后的任意项目目录、PTY、Git、shell、provider CLI 和动态工具能力。它不应被表述成可对所有普通用户直接公开分发的 artifact。

即使不启用 App Sandbox，也必须实现最小权限和明确授权：

- 只访问用户选择或配置的项目目录；
- destructive tool 继续经过 Agent policy/用户确认；
- Runtime 不监听外部网卡；
- 不把 shell environment 全量回传给 Swift；
- 日志默认脱敏；
- 诊断包生成前显示包含范围。

### 10.2 Unix socket 安全

- socket parent directory 权限 `0700`；
- socket 权限 `0600`；
- 使用每个用户和 app channel 唯一的稳定路径；
- 启动时拒绝 owner、类型或权限不符合预期的现有 socket；
- 首次握手验证 protocol、manifest identity 和每次启动的随机 nonce；
- nonce 通过权限受限文件、继承 fd 或 RuntimeHost 安全通道传递，不写命令行；
- 所有外部 remote connection 走独立的认证和 TLS 设计，不能复用本地信任假设。

当前 bundled Runtime 已执行前三项：`prepareSessiondSocketPath()` 只清理 stale socket，并拒绝替换普通文件、symlink、FIFO 或设备；Fastify listen 后以 `0600` 固化 socket。退出时按 `dev`/`ino` 删除自身创建的 socket，避免误删后来替换路径的进程。bundled Native client 还会在每次 HTTP 或 WebSocket 连接前以 `lstat` 验证 socket 是当前用户拥有的 Unix socket、精确为 `0600`，且父目录是当前用户拥有的 `0700` directory；macOS 连接成功后再用 `getpeereid` 验证 peer UID。Swift 在这个 `0700` Runtime 目录维护一个当前用户拥有的 `0600`、256-bit launch nonce 文件；只有 Runtime 从该路径读取到合法 nonce 时才启动，hello 通过回显该 nonce 证明身份。App 在启动**新** Runtime 前轮换 nonce，重开 App 则先用已保存值验证并复用健康 Runtime；每次 hello/重连都会比对，且 nonce 不进入命令行、日志或普通 command payload。显式外部/开发 socket 维持兼容模式，不被 bundled-only gate 意外拒绝。受限 nonce 传递已经落地；未来若引入 Sandbox/XPC，再以 bookmark capability hand-off 和 XPC peer requirement 重新审计同一边界。

### 10.3 Keychain 与 credential bridge

bundled Runtime 已将 Pi SDK 的 `CredentialStore` 接到一个受限的 `Security.framework` helper。secret 只在 Runtime 与 helper 的 stdin/stdout 边界出现；Swift feature store、Native Contract、JSON 日志和 command receipt 都不持有明文 API key、access token 或 refresh token。Keychain 列表只返回 provider ID 与 credential type。

legacy `auth.json` 的初始迁移实现是**保守的 copy-with-readback**，不是文件删除或 merge：

1. Native Settings 仅请求只读预览，显示 provider ID、`oauth`/`api_key` 类型和冲突状态，绝不显示 credential 内容；
2. Runtime 以 Pi SDK 当前的 `auth.json` schema 验证文件，限制文件/单 credential 的大小以及 provider ID 形状；
3. 如果 Keychain 已有同一 provider，则整个迁移拒绝，绝不覆盖、合并或备份旧 Keychain secret；
4. 用户二次确认后，Runtime 逐项写入 Keychain 并逐项 readback 验证类型；
5. Runtime 在 `PI_WEB_DATA_DIR/native-auth-migrations.json` 写入 `0600` 原子 journal；journal 只有 migration ID、时间、provider/type、是否由本迁移创建和状态，不含 secret；
6. 成功后旧 `auth.json` 保留不动；“退休/移入废纸篓”不是这一切片的能力；
7. 已验证成功的 migration 可从原生 UI 发起 rollback，rollback 只删除 journal 已确认由这次迁移创建的 Keychain 项，旧文件始终保留。

迁移写入和 rollback 都是 runtime-epoch-bound `commandId` mutation。socket 调用结果未知时 App 只查询相同 receipt，绝不新建第二次写入。若某次写入之后发生 Runtime 级崩溃、无法证明某个 Keychain item 的归属，journal 会保留 `rollback-required`，而不是冒险删除不确定来源的 credential。真实 provider 的 OAuth/API-key E2E 仍需在用户的账号上手动验证；本地测试仅证明 storage、redaction、冲突与 rollback 语义。

### 10.4 项目目录与 bookmarks

Swift 使用 `NSOpenPanel` 获得用户选择，并保存 security-scoped bookmark 及 stale 状态。[Apple 文件访问文档](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)是未来 Sandbox/跨进程授权设计的基线。

第一版站外分发仍保留 bookmark 层，原因是它提供明确的项目授权、路径移动恢复和未来 sandbox 迁移 seam。当前 bundled Runtime 额外要求 App launch token，并在 `POST /runtime/projects/authorize` 成功后才接受该 canonical root 或真实子目录的 cwd；错误 token、raw relative cwd、目录不存在、sibling prefix 和 symlink escape 都被拒绝。原生侧在加载 session 前完成授权 receipt，且把授权状态显示为 Authorizing、Authorized 或 failed。bookmark stale、目录消失或权限撤销时返回可解释错误，不静默扩大到父目录或整个 Home。该组合在非 Sandbox 分发中是产品级边界，**不能**表述为跨进程 security-scoped bookmark 已生效。

旧 PI WEB `projects.json` 的迁移采用更窄的 App-owned 流程：Runtime 只能做只读候选预览，最多返回 legacy project ID、名称、绝对路径和创建时间；Finder 中逐项选择同一路径才会创建 native bookmark。native catalog 写入后必须按 ID/path 重新读取，才会在 App-owned `UserDefaults` migration journal 写入迁移 ID、legacy/native ID 与路径、`created` 所有权标记、时间和状态。该 journal 不保存 bookmark data、旧 JSON 副本、项目内容或任何 credential，因而不能宣称为 `0600` Runtime 文件。若记录 journal 失败，App 只补偿删除本次新建且回读匹配的 catalog 项。Rollback 先持久化 `rollingBack`，再按 journal 验证每个 ID/path，只删除 `created: true` 的 native bookmark，最后 readback 为 `rolledBack`；旧文件、项目目录、session、credential 与手动添加的项目都不在其写入集合内。遇到中断或不匹配时保留显式状态并报错，不猜测性删除。Settings 的只读 legacy migration overview 还会枚举 `projects.json`、Pi `auth.json`、`archived-sessions.json`、`machines.json` 和 `session-unread.json`，但只投影 path/identity、是否存在、动作、项目/credential 候选数量与读取错误；它从不读取或返回 machine token/header、unread 内容、bookmark bytes 或 credential。`auth.json` 仅显示可以迁入 Keychain 的 credential 数量、资格和冲突，实际写入仍需在 dedicated migration flow 显式确认并 readback。其余 actions 明确为：projects 必须重新授权，archived sessions 已复制且保留来源，machines/unread 没有安全 native target 而保持原处。这是迁移范围的诚实报告，不是把远程 machine 或 unread state 伪迁入原生 App。bundled Runtime 对 legacy archived session 同样先复制和验证，再原子写入新 archive index；它通过 `PI_AGENT_PRESERVE_LEGACY_SESSION_ARCHIVE=1` 保留旧 index 与 archive 文件并回报 `legacyState: "preserved"`。这让 native migration 具有回退来源，且不能把清理旧目录藏在 App 启动中；旧 Web/CLI path 的原有 cleanup 策略保持兼容。

未签名分发的卸载也保持同样的最小写入面：App 提供“卸载 App、保留数据”，不会隐式清除。它先通过 bundled Runtime health 拒绝 active session，再由 `PiAgentUninstaller` 等待 App 退出；helper 只接受当前父 PID、`Pi Agent.app` 名称、`com.realchendahuang.pi-agent` bundle identifier 和 bundle 内固定 `Contents/Helpers/PiAgentUninstaller` 路径同时匹配的请求，随后使用 macOS Trash API 移动 app bundle。`PiAgentUninstaller`、`PiAgentDataEraser` 与 Keychain helper 均由 `native-helpers-manifest.json` 的 SHA-256 覆盖，bundled Runtime 启动前会校验三者。`~/Library/Application Support/Pi Agent`、Keychain、bookmarks、migration journals、项目目录和 legacy PI WEB data 都不在卸载 helper 的写入集合内；App 可在 Settings 直接 Reveal 该保留目录。

对需要重置原生 App 的用户，Settings 还提供一个独立的“Erase All Native Pi Agent Data”操作。它并非卸载的隐式副作用：两次 health 检查都必须确认 zero active sessions，用户还必须输入固定确认短语；随后 `PiAgentDataEraser` 在 App 退出后再次验证自身固定路径、父 PID、app name 和 bundle identifier。它只能把精确的 `~/Library/Application Support/Pi Agent` 目录移到 macOS Trash、清除 Pi Agent 自己的 preferences domain，并删除 exact `com.realchendahuang.pi-agent.credentials.v1` Keychain service 的 items；它没有项目路径或 legacy 路径输入，因此不会触及 project checkout、legacy PI WEB state、App bundle 或其他 Keychain service。文件数据可从 Trash 恢复，Keychain credential 则在 UI 和文档中明确说明不可恢复。未签名交付不实现 Login Item 注销，任一身份/路径校验、health gate 或 Trash 写入失败时 helper 不会继续删除额外目标。

## 11. 版本、兼容和升级策略

### 11.1 四个版本轴

每个 release 明确记录：

| 版本轴                  | 用途                                |
| ----------------------- | ----------------------------------- |
| App version             | 用户看到的产品版本                  |
| Runtime version         | Agent Runtime 实现与数据迁移版本    |
| Native Contract version | Swift 与 Runtime wire compatibility |
| Pi SDK exact version    | 上游 SDK adapter compatibility      |

不能使用 App version 推断 protocol compatibility，也不能让 npm semver range 在用户机器上动态选 Pi SDK。

### 11.2 兼容规则

- 同一 App bundle 默认只启动 manifest 指定的 Runtime；
- 开发模式可以连接 checkout Runtime，但 UI 明确显示 Development Runtime；
- protocol major 必须精确兼容；
- minor 通过 capabilities 前向兼容；
- 数据迁移具备 journal、preflight、backup、commit 和 rollback；
- SDK 升级先在 adapter compatibility suite 中通过，再进入 App release；
- release artifact 不允许 Runtime 或 Pi SDK 自我更新，统一由 App update 替换整个 bundle。

### 11.3 Pi SDK 升级门

升级 `@earendil-works/pi-*` 前必须验证：

1. session new/resume/switch/fork/import；
2. subscription 在 session replacement 后重新绑定；
3. prompt/steer/follow-up 的接受与 queue 语义；
4. tool start/update/end projection；
5. abort、retry、compaction 和 error mapping；
6. extension discovery、extension UI 与 custom tools；
7. auth、model registry 和 provider selection；
8. session 文件兼容和 migration；
9. PTY/session 并发与 graceful dispose；
10. Native Contract fixtures 未发生无意漂移。

## 12. 分阶段实施路线

### Phase A：先隔离 SDK，不改变行为

- 定义 `SessionRuntimeDriver` 产品接口；
- 将 Pi SDK import 收口到 `PiSdkRuntimeAdapter`；
- 把现有 `PiSessionService` orchestration 与 SDK construction 分开；
- 为 session replacement、subscription rebind、事件投影和 dispose 增加 contract tests；
- 保持当前 systemd sessiond 和 Web/Native 客户端行为不变。

退出条件：现有测试通过，SDK 类型不再穿透 orchestration，真实 Pi session smoke 与重构前等价。

### Phase B：建立可复现的 Runtime artifact

- 新增 Runtime production manifest 和 exact dependency lock；
- 从干净 staging tree 构建；
- 生成 native/resource inventory、hash、license 和 SBOM；
- 分别构建 arm64/x64；
- 对 Node、`node-pty`、clipboard、WASM、extensions 做启动/长跑 smoke。

退出条件：没有全局 Node/npm/Pi 的干净账户能直接启动 artifact，完成真实 session 和 PTY。

### Phase C：把 Runtime 装入 `.app`

- 实现 `RuntimeSupervisor`；
- 加入 manifest/hash/architecture preflight；
- 实现 single instance、socket discovery、hello/epoch/capability handshake；
- App launch 按需启动 bundled Runtime；
- App 重开先重连，不盲目生成第二个 Runtime；
- systemd 继续作为 Linux/开发部署方式，不进入 macOS 产品路径。

退出条件：移动到随机路径的 bundled `.app` 能完成 session、stream、terminal、App crash/reopen 和 Runtime graceful quit，并且不会连接全局 daemon 或用户 PATH 中的 Node。

### Phase D：后台 host 与系统集成

- spike 并决定 `PiAgentRuntimeHost`；
- 实现用户主动开启的 `SMAppService` Login Item/LaunchAgent；
- 完成关闭窗口、退出、活动任务和更新状态机；
- 接入 OSLog、通知、Keychain broker 和 bookmark recovery。

退出条件：后台开关可见且可撤销；登录启动、App crash、sleep/wake、权限撤销均有确定行为。

### Phase E：未来的签名、公证、更新和发布（当前不执行）

- 从内到外签名所有 nested code；
- 验证 Hardened Runtime entitlements；
- notarize App/DMG 并 staple；
- 接入 Sparkle，完成 active-session gate 和完整 bundle rollback；
- 在干净 arm64/x64 账户执行 Gatekeeper、session、PTY、Keychain、升级与卸载 E2E。

此阶段仅在用户明确重新授权公开分发时恢复；它不是当前完成原生 Runtime 的退出条件。

### Phase F：可选打包优化

- 用相同 acceptance suite 对 Bun compile 做独立 spike；
- Runtime 资源和 extension 边界冻结后再评估 Node SEA；
- 只有可靠性、启动时间、体积和维护成本有量化净收益才切换。

## 13. 测试与验收矩阵

### 13.1 SDK adapter

- new/resume/switch/fork/import 后 session generation 正确；
- 旧 subscription 完全解绑，新 subscription 不漏首个事件；
- extension 重新绑定；
- prompt accepted 与 completed 分离；
- stream、tool、retry、compaction、abort 事件按序投影；
- dispose 幂等，无 orphan timer/process/listener；
- SDK error 不泄露 secret，内部诊断仍可关联。

### 13.2 Native Contract

- Swift 与 TypeScript 共享 schema/fixture；
- hello major/minor/capability 组合测试；
- epoch 改变后拒绝旧 mutation；
- snapshot 与 event join 无重复、无缺口；
- command timeout 后查询原 receipt，不重复提交；
- 慢消费者有背压上限和明确 resync；
- terminal bytes 不经过 JSON 文本转码。

### 13.3 生命周期

- App launch 同时发生两次仍只有一个 Runtime；
- 关闭窗口不杀活动 session；
- App crash/reopen 恢复同一 session 和 PTY；
- Runtime crash 不触发 Prompt 自动重放；
- sleep/wake 后 socket/event stream 可恢复；
- Login Item enable/disable/readback；
- 更新时有活动 Agent，能够等待、取消或明确停止；
- 新 Runtime 启动失败可回滚旧完整 App bundle。

### 13.4 当前本地 artifact 验收

- 干净 macOS 账户，无 Node/npm/Pi；
- arm64/x64 与 manifest 一致；
- `node-pty` spawn/resize/signal/exit；
- provider auth、Keychain、bookmark stale/re-authorize；
- 10 MB terminal 输出和长 transcript；
- App 移动路径后仍能启动；
- 通过 `scripts/macos/verify-app.sh` 的 manifest、Runtime socket 与 Swift contract smoke。

签名、公证、Gatekeeper、DMG、Sparkle 升级和卸载的 E2E 仅属于未来独立发布阶段，不在当前验收中。

## 14. 最终验收条件

只有满足以下条件，才能把 bundled Pi Runtime 宣称为已经交付：

- `.app` 内含固定 Node、Pi SDK、Runtime 和全部实际运行资源；
- 干净机器无需 npm/CLI/systemd 即可创建真实 Pi session；
- Swift 只依赖版本化 Native Contract；
- Runtime 内通过 `PiSdkRuntimeAdapter` 使用 `AgentSessionRuntime`；
- 多 session、stream transcript、tool events 和 terminal reconnect 均通过；
- App 关闭、崩溃、重开和升级不丢失或重复提交活动工作；
- Runtime manifest、Node、资源 hash、架构与本地 socket smoke 均通过；
- Keychain/bookmark 权限边界可解释并可撤销；
- 发布 artifact 有 runtime manifest、hash、SBOM 和 license notices；
- Web/CLI/systemd 兼容路径与 macOS bundled Runtime 的支持边界有文档。

截至本文件调研日期，这些条件**尚未全部达成**。已经落地的包括 bundled Node Runtime、exact production lock、资源 manifest/hash、`/runtime/hello`、Swift RuntimeSupervisor、项目 bookmark、App-token + canonical-path Runtime project boundary、事件流 transcript、原生 terminal surface、Pi SDK lifecycle adapter、跨实例 launch lock、Runtime-owned workspace tree/file projection，以及文本文件的新建、编辑保存、移动/重命名、二次确认删除、受支持图片格式的受限预览、原生消息图片附件和 Thread Git checkpoint/review。Composer 只允许 Pi 原生 inline image 支持的 PNG/JPEG/GIF/WebP：最多 16 个，每张上限 4.5 MB；Swift 对用户选择的文件临时读取并 base64 传给 Runtime，Runtime 在 receipt 建立前以同一上限再次验证。SDK 产出的持久化 image content 通过 session contract 返回，Swift 只用 `NSImage` 渲染该 socket payload，既不读取 workspace 图片 URL，也不增加浏览/文件权限。checkpoint 在 Runtime 的 `PI_WEB_DATA_DIR` 以 `0600` 原子文件存放，包含当前 Git status 与各自最多 256 KiB 的 staged/unstaged diff，并将任意裁剪显式标为 `truncated`；它只支持回看，不创建 Git ref，也不把 checkpoint 伪装为恢复点。每个 mutation 都有 runtime epoch、`commandId`、payload fingerprint 与可查询 receipt；`native-runtime-command-receipts.json` 还会在 action 前私有地持久化 intent、在 action 后持久化终态，因此 Runtime restart 后同 ID/intent 不会造成第二次 side effect，而中断中的记录明确失败且不重放。bundled smoke 在自建临时授权项目中验证写入、receipt retry、读取、移动、删除、checkpoint list、native attachment rejection 及 direct-submodule stage/unstage/confirmed discard。App-bundled Keychain `CredentialStore`，以及 abort-active-work、Prompt、New Thread、Import Thread、Fork Thread、archive、restore、archived delete、terminal create/continue、Git stage/unstage/commit、checkpoint、legacy auth migration/rollback 和 Pi extension dialog response 的 command receipt 也已交付。Provider status、OAuth/API-key Native Contract、原生登录 sheet 与自动 flow polling 已交付；legacy `auth.json` 现在支持 redacted preview、显式迁移、`0600` journal、readback 和仅删除本次创建项的 rollback，且不删除 source file。真实 provider E2E 仍未完成。App-owned Runtime 的 socket 断线、sleep/wake 和 restart recovery 已有单次恢复 gate、refresh generation 与打包 smoke 覆盖。Keychain helper 仅允许 Pi Agent 固定 service 和 provider-id account，secret 经 stdin/stdout 在 Runtime 与 `Security.framework` helper 间传递，不写入 SwiftUI state、JSON log 或 command-line argument；list 仅投影 provider/type。下一步是 Sandbox 下 bookmark data 到 child Runtime 的真实 capability hand-off、dependency-closure/SBOM/license 审计和完整的人工 crash/lifecycle matrix；不能将这些已实现切片误报为完整发布版。

## 15. 主要一手资料

- [Pi SDK](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)
- [Pi `AgentSessionRuntime` 示例](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/sdk/13-session-runtime.ts)
- [Pi RPC mode](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [Pi extensions 与 RPC UI 交互](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple `SMAppService.register()`](<https://developer.apple.com/documentation/servicemanagement/smappservice/register()>)
- [Apple XPC](https://developer.apple.com/documentation/xpc)
- [Apple：管理持续运行的 macOS 后台进程](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac)
- [Apple：访问 macOS App Sandbox 外文件](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple Code Signing Guide：Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
- [Node Single Executable Applications](https://nodejs.org/api/single-executable-applications.html)
- [Node.js Releases](https://nodejs.org/en/about/previous-releases)
- [Bun single-file executable](https://bun.com/docs/bundler/executables)
- [Bun Node-API compatibility](https://bun.com/docs/runtime/node-api)
- [Syncthing for macOS](https://github.com/syncthing/syncthing-macos)
