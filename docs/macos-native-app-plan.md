# Pi Agent for macOS：彻底原生化方案

> 状态：Phase 0、Phase 1 与 bundled Runtime 的本机实现已落地；当前可构建、校验并启动未签名的原生 `.app`，生命周期、Runtime-owned workspace 文本创建/编辑/移动/删除、受限图片预览、原生消息图片附件、Thread-owned Git checkpoint/review 与 App-bundled Keychain credential store 已实现；旧 auth 迁移和远程能力继续实施。
>
> 当前范围覆盖：用户明确要求**不做代码签名、公证或 Gatekeeper 发布**。本地完整性依赖固定 Node、exact npm lock、runtime manifest、SHA-256、架构检查和真实 socket smoke；签名相关工作不构成本阶段门槛。
>
> 目标：把 PI WEB 改造成真正的 macOS 原生桌面应用 **Pi Agent**。产品主界面、窗口、菜单、设置、通知、权限、更新与安装全部使用 macOS 原生能力；不使用 Electron、Tauri 或 WebView 作为产品界面。现有 TypeScript/Node 会话核心作为 App 内嵌运行时保留，逐步从浏览器控制面中解耦。
>
> 开源与产品调研快照：**2026-08-05**。本轮已用 Pi 上游 SDK/RPC/extension 文档和 Apple XPC、ServiceManagement 文档复核 Runtime 集成边界；外部项目的维护状态、许可证和 API 稳定性在真正引入依赖时必须重新核实。

当前已经可验证的实现位于 `macos/PiAgent`：SwiftUI 原生窗口、Runtime health/hello contract、Unix-socket client、项目目录选择与 security-scoped bookmark、Project → Thread 侧边栏、session projection、session event WebSocket + `seq`/snapshot 去重、事件驱动 transcript、真实 Prompt 提交、SwiftTerm 原生 terminal surface、PTY input/resize/reconnect，以及 contract-check executable。`scripts/macos/build-app.sh` 会组装 App 内的固定 Node、production dependency closure、launcher 与 SHA-256 manifest；`verify-app.sh` 会完整校验 bundle、启动内部 Runtime，并以 Swift client 做 socket smoke。2026-08-04 的实际 staging build 已裁掉浏览器 UI 专用 Runtime 根依赖，manifest 从 47,474 项降至 41,351 项，仍通过 Runtime/Swift smoke；完整数据与尚未完成的 SBOM/license 边界见 [Pi Runtime 融合决策](./macos-pi-runtime-integration.md)。Prompt 不再通过固定间隔轮询等待完成。它仍不是 DMG/自动更新产品，也不改变现有 Web UI 或 sessiond 的事实所有权。

## 1. 结论

第一版采用下面的技术边界：

- **SwiftUI + AppKit** 构建完整原生界面，不嵌入现有 Lit 页面。
- **Pi Agent.app** 是唯一面向普通用户的安装、启动、设置和升级入口。
- 现有 Pi/OMP、会话持久化、PTY、Git、工作区、认证和插件核心保留为随 App 打包、由 manifest 校验的 **Agent Runtime**。
- App 与 Runtime 默认通过仅限本机用户访问的 **Unix domain socket** 通信，不开放 localhost 端口。
- App 关闭窗口不等于结束任务。Runtime 生命周期由 App 明确管理，活动会话存在时必须给用户清晰选择。
- 第一阶段不依赖 LaunchAgent；后台持续运行作为用户主动开启的能力，当前 App-managed Runtime 保留这一生命周期边界。
- API Key、OAuth token 与其他秘密迁移到 **Keychain**；一般设置存入 Application Support，项目授权使用 security-scoped bookmarks。
- 初期继续保留 `pi-web` CLI 和 Web UI 作为迁移、自动化与诊断兼容层，但不再是产品默认入口。
- 当前本地版本不使用 Developer ID、Hardened Runtime、Notarization、Sparkle 或 Mac App Store sandbox；它通过未签名 `.app`、manifest/hash 与本机 smoke 交付和验证。

这不是“给网页套一个窗口”。当前用户路径应是：复制经过验证的未签名 `Pi Agent.app` 到 `Applications`、打开 Pi Agent、选择项目、创建会话。用户不需要安装 npm 包、理解端口、配置 LaunchAgent、修复 `node-pty` 权限或手动编辑全局 JSON 才能开始工作。DMG、签名和 Gatekeeper 分发只在用户重新授权后另行设计。

Pi Runtime 的嵌入位置已经形成单独的研究与架构决策：[macOS 原生客户端与 Pi Runtime 融合](./macos-pi-runtime-integration.md)。最终选择不是让 Swift 直接链接 Pi SDK，也不是让 Swift 为每个 session 直接控制 `pi --mode rpc`，而是：**App 内随包携带长期 Node Runtime，Runtime 内通过窄 adapter 直接使用 Pi SDK，Swift 只消费版本化 Native Contract；Pi RPC 保留为 Runtime 内的兼容或隔离 driver。**

## 2. 设计基准与开源复用决策

本项目不从空白重新发明 Agent 桌面端，也不把“参考成熟产品”误解成“复制它的技术栈”。产品结构以 Codex 桌面端和 T3 Code 为主要基准，macOS 工程能力优先复用经过验证的原生库和系统框架；任何第三方项目都必须先经过许可证、维护状态、可嵌入边界、性能、辅助功能和签名验证。

### 2.1 总原则

- **参考产品模型，不像素级克隆**：借鉴项目、线程、环境、diff、终端和 Git 操作之间的关系，建立 Pi Agent 自己的视觉和领域模型。
- **复用窄组件，不整仓嫁接**：优先采用有清晰 API 的 Swift Package 或系统 framework，不把另一个完整编辑器塞进 App。
- **原生优先**：能由 SwiftUI、AppKit、Security、ServiceManagement、OSLog、Quick Look 等系统能力稳定完成的边界，不额外引入跨平台壳。
- **Runtime 事实唯一**：会话、终端、Git、文件和 Provider 进程仍由 Agent Runtime 拥有；Swift 客户端只维护可重建的投影。
- **依赖必须可替换**：Terminal、Markdown、SQLite、Keychain 和更新能力都通过项目自己的协议隔离，业务 feature 不直接依赖第三方类型。
- **先 spike 后锁定**：候选依赖只有通过真实长会话、IME、VoiceOver、打包 `.app`、崩溃重连和升级测试后，才从“候选”升级为“采用”。签名分发另有独立验收门槛，当前不作为采用前提。

### 2.2 Codex 桌面端：产品结构基准

[Codex/ChatGPT 桌面产品文档](https://learn.chatgpt.com/docs/app)展示了适合 Agent 工作台的核心模式：项目和长期任务集中在一个桌面工作区，开发者可以在任务上下文里查看文件、review、终端和真实产物；[Local environment](https://learn.chatgpt.com/docs/environments/local-environment)与[Git worktree](https://learn.chatgpt.com/docs/environments/git-worktrees)是一等环境，而不是隐藏的实现细节。

Pi Agent 应借鉴以下产品关系：

- 左侧以 Project 为稳定入口，Thread 是长期任务和上下文，不只是一次聊天记录；
- Thread 明确绑定一个 Environment：当前 checkout、受管 worktree 或远程 Agent Host；
- 对话、工具执行、产物、diff、terminal 和 Git action 位于同一任务上下文；
- review 是开发者细节的一等入口，支持按文件查看、行级反馈、stage/revert/commit/push；
- 集成 terminal 继承当前项目或 worktree 的 cwd，退出窗口不隐式停止任务；
- 从临时 worktree 完成任务后，提供显式 handoff/合并路径，而不是让用户猜分支和目录在哪里。

Codex 桌面端不是本方案的源码来源。本方案只参考官方文档和可观察产品行为，不声称其 App 源码开源，也不推断其内部实现。

### 2.3 T3 Code：控制面与交互基准

[T3 Code](https://t3.codes/)及其 [MIT 开源仓库](https://github.com/pingdotgg/t3code)把产品定义为 agent harness control surface，支持多个 Agent harness，并采用 server runtime + web/desktop/mobile clients 的结构。其桌面应用当前明确是 **Electron**；因此只借鉴交互模型、领域模型和公开源码中的边界，不采用桌面技术栈，也不整仓复制。下面的架构判断以其公开的 [architecture overview](https://github.com/pingdotgg/t3code/blob/main/docs/internals/overview.md) 和本轮只读源码盘点为依据。

对 T3 源码的只读盘点显示，值得吸收的结构是：

- server 拥有 session、workspace、Provider process、terminal、VCS 和 filesystem，client 不直接执行这些副作用；
- contracts 独立，command 与 subscription 都是类型化边界；连接、重试、认证和领域投影属于非视觉 client runtime，View 不构建 transport；
- command receipt 让重试幂等，提交后的 event/projected read model 再通知订阅者；
- Provider driver registry 隔离 Codex、Claude、Cursor、OpenCode 等 harness 差异；
- 每个 turn 通过 checkpoint 捕获前后状态，为 diff、revert 和 review 提供确定边界；
- desktop、web 和 mobile 共享控制面语义，但各自拥有平台层。

这些思想应映射到现有 PI WEB，而不是重写成 T3：

| T3 模式                          | Pi Agent 的落地方式                                                                           |
| -------------------------------- | --------------------------------------------------------------------------------------------- |
| Server owns execution            | 保持现有 session daemon / Agent Runtime 的长期所有权                                          |
| Typed RPC + subscription         | 扩展 Native IPC contract，View 只依赖 `RuntimeClient`                                         |
| Shared non-visual client runtime | Swift 中建立 RuntimeClient、connection supervisor 和 feature stores；不在 View 中重试或拼协议 |
| Idempotent command receipts      | Prompt、stop、approval、Git mutation 使用 idempotency key 和可查询结果                        |
| Provider drivers                 | 用统一 capability/adapter 屏蔽 Pi、OMP 和未来 harness 差异                                    |
| Turn checkpoints                 | 在不破坏当前 Git 语义的前提下增加 turn diff/checkpoint；先做 opt-in spike                     |
| Thread-isolated branch           | 提供“当前 checkout / 新 worktree / 现有 worktree”选项，不默认强迫每个 Thread 新建分支         |

不把 T3 的完整 event sourcing、Effect 技术栈或远程云服务照搬进来。现有 Runtime 已有稳定会话模型；只有 command receipt、顺序、projection 或 checkpoint 能解决已验证的问题时，才逐步引入对应模式。

### 2.4 原生界面翻译规则

T3 官网主界面和 Codex 的共同优点是信息密度高、层级安静、主动作少。Pi Agent 将其翻译成 macOS 原生结构：

```text
Native toolbar
├─ 当前 Thread / Environment
├─ Open / Review / Commit & Push
└─ Inspector / Terminal / New Thread

NavigationSplitView
├─ Sidebar: Project → Environment → Thread
├─ Content: Transcript + inline tools/diff + Composer
└─ Inspector: Changes / Files / Git / Terminal / Context
```

- Sidebar 默认宽度约 `260–320 pt`；主内容最小 `600 pt`；Inspector 默认 `320–460 pt`，窗口不足时变为可切换 inspector，不硬挤三栏。
- Project 可折叠，Thread 显示 running、needs attention、completed、failed 等语义状态；颜色只作辅助，必须同时有图标或文字。
- Toolbar 只放高频全局动作；commit、push、PR、revert 等危险或有前置条件的动作显示明确状态，不用只有图标的神秘按钮。
- Transcript 以内容为主，减少每条消息的大卡片边框；tool、plan、diff 和 changed files 使用 disclosure group 就地展开，完整 review 可进入 Inspector 或独立 window。
- Composer 固定在主内容底部，显示当前 harness、model、thinking/effort、permission、environment 和 branch；高级字段按需展开，不铺满说明文字。
- 使用系统字体和 SF Mono，使用 semantic colors、system materials、separator 与 accent color；不硬编码 T3 的黑色网页皮肤，也不自造一套违背系统设置的窗口控件。
- Dark/Light、Reduce Motion、Increase Contrast、Full Keyboard Access、VoiceOver 和系统文字缩放都必须参与验收。
- 所有主动作同时存在于菜单和 command system；`Cmd+N`、`Cmd+O`、`Cmd+K`、`Cmd+,`、查找、切换 sidebar/inspector 等遵循 macOS 习惯。

领域层级固定为：

```text
Project
└─ Environment (local checkout | managed worktree | remote)
   └─ Thread
      ├─ Turns / transcript
      ├─ Artifacts / changed files / review
      ├─ Terminals
      └─ Git actions
```

Thread 必须显示自己绑定的 Environment 和 branch。切换 Thread 不隐式更改另一个 Thread 的 cwd、branch、permission 或 terminal。

### 2.5 开源复用矩阵

状态含义：**采用**表示进入实现时计划直接依赖；**Phase 0 候选**表示必须 spike 后才能锁定；**借鉴**表示阅读设计或源码但不链接进产品；**不采用**表示当前方案明确排除。

| 项目/能力                                                                                             | 许可证                       | 状态                 | 用途与边界                                                                                                                                                         |
| ----------------------------------------------------------------------------------------------------- | ---------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [SwiftUI / AppKit / Security / ServiceManagement / OSLog](https://developer.apple.com/documentation/) | Apple SDK                    | 采用                 | 窗口、菜单、Keychain、Login Item、日志、权限等平台边界；优先于同功能包装库                                                                                         |
| [Sparkle 2](https://github.com/sparkle-project/Sparkle)                                               | 宽松许可证，含第三方 notices | 当前不采用           | 当前明确不做签名、公证、DMG 或自动更新；未来若恢复签名分发，再以 active-session gate、checkpoint、Runtime/helper 协调和回滚验证为前提重新 spike                    |
| [GRDB.swift](https://github.com/groue/GRDB.swift)                                                     | MIT                          | 采用                 | 只保存 App 自己的 bookmark metadata、window state、UI cache 和 migration journal；不与 Runtime 并发写同一数据库                                                    |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)                                               | MIT                          | **已采用（1.11.2）** | AppKit `TerminalView` 和 VT emulation；只接 Runtime 的 byte stream，不接管 PTY process；1.11.2 固定版本避免当前 CommandLineTools 缺少 `metal` 时的 shader 构建阻塞 |
| [Ghostty / libghostty](https://github.com/ghostty-org/ghostty)                                        | MIT                          | Phase 0 对照         | 高性能 terminal engine/Metal 参考；`libghostty-vt` 可嵌入但 API 仍变化，只有 SwiftTerm 不达标时才评估 pin commit + C bridge                                        |
| [Textual](https://github.com/gonzalezreal/textual)                                                    | MIT                          | Phase 0 首选         | 原生 selection、code block、table、accessibility-friendly rich text；用长 transcript 和流式更新验证后再采用                                                        |
| [swift-markdown](https://github.com/swiftlang/swift-markdown)                                         | Apache-2.0                   | Phase 0 候选         | 需要可控 GFM AST 时作为解析层；renderer 仍由本项目或 Textual 提供                                                                                                  |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)                                       | MIT                          | 不新引入             | 当前已进入 maintenance mode；只作为历史参考，不作为新 App 的长期基座                                                                                               |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess)                                  | MIT                          | Phase 0 候选         | 若多 account、access group 和错误处理显著简化，可在自有 `SecretStore` 协议后采用；少量操作优先直接包装 Security framework                                          |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen)                                                     | MIT                          | Phase 0 候选         | 减少 `pbxproj` 冲突；必须验证 app/helper/tests/capabilities/signing，不为生成器牺牲 Xcode 可维护性                                                                 |
| [swift-log](https://github.com/apple/swift-log)                                                       | Apache-2.0                   | 按需                 | 跨 Swift package 需要统一 facade 时采用；单 App 日志优先 OSLog，不为抽象而抽象                                                                                     |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser)                               | Apache-2.0                   | 按需                 | 仅在新增 Swift diagnostics/helper CLI 时使用；不影响 App GUI                                                                                                       |
| [swift-collections](https://github.com/apple/swift-collections)                                       | Apache-2.0                   | 按需                 | transcript/terminal 确实需要 Deque 或有界 buffer 时使用；标准库足够时不引入                                                                                        |
| [CodeEdit](https://github.com/CodeEditApp/CodeEdit)                                                   | MIT                          | 借鉴                 | 研究原生 split view、preferences、terminal hosting、Git/workspace 和 UI tests；项目仍标注未推荐生产使用，不整仓依赖                                                |
| [syncthing-macos](https://github.com/syncthing/syncthing-macos)                                       | MIT                          | 借鉴                 | 研究原生 App 管理 bundled daemon、登录启动、状态菜单和 Sparkle 的真实生命周期                                                                                      |
| [T3 Code](https://github.com/pingdotgg/t3code)                                                        | MIT                          | 借鉴                 | 研究 Thread/Environment/Provider/command/subscription/checkpoint 模型；不采用 Electron UI 和整仓依赖                                                               |
| Codex 桌面端                                                                                          | 非本方案开源依赖             | 产品基准             | 只参考官方产品行为；不复制或声称拥有其内部实现                                                                                                                     |
| Electron / Tauri / WKWebView UI                                                                       | —                            | 不采用               | 与“彻底 macOS 原生产品界面”目标冲突；兼容 Web UI 只能作为独立旧入口                                                                                                |
| Sentry 或默认遥测                                                                                     | —                            | 不默认采用           | 未经用户授权不引入网络遥测；本地诊断先满足问题定位                                                                                                                 |

### 2.6 Terminal 选型结论

不自研完整 VT parser、terminal state machine 或字体栅格化系统。Phase 0 建立统一 `TerminalSurface` 协议，同时做以下顺序的验证：

1. **SwiftTerm 首选 spike**：最快得到 AppKit-native terminal，验证 Unicode/grapheme、IME、selection、search、true color、mouse、resize、hyperlink 和 reconnect。
2. **libghostty 对照 spike**：当 SwiftTerm 在性能、现代控制序列或 renderer 上未达门槛时，验证 `libghostty-vt` + 自有 AppKit/Metal surface；必须 pin 精确 commit，因为其 API 尚未稳定发版。
3. **CodeEdit/Ghostty 只作集成参考**：研究 responder chain、菜单、字体、Metal 和 accessibility，不复制完整 App。

无论使用哪个 renderer，PTY process、cwd、环境变量、输出持久化和 reconnect token 都由 Runtime 持有。终端库不得自行 `fork` 一个与 Runtime 无关的 shell，也不得让关闭 Swift View 终止 PTY。

### 2.7 Transcript 与 Markdown 选型结论

`MarkdownUI` 已进入维护模式，不再列为首选。Phase 0 以 `Textual` 为第一候选，以 `swift-markdown` + 薄渲染层为可控回退：

- 只增量更新正在 stream 的 message block，不因每个 token 重建完整 transcript；
- stable message 可解析并缓存 attributed representation；
- code block、table、list、link、selection、copy、VoiceOver 和大文本必须使用真实 Agent 输出验收；
- 图片和附件加载经过 URL policy，不让 Markdown 任意读取本地文件或自动请求远程 tracking URL；
- 如果 Textual 的当前早期版本不满足性能或 API 稳定性，就隔离在 `MessageRenderer` 后 pin 版本，保留替换路径。

### 2.8 原生基础设施取舍

- **Keychain**：业务只看 `SecretStore` 协议。先用 Apple Security framework 实现最小版本；只有 KeychainAccess spike 能证明减少多 account/access group 错误且不扩大 secret surface 时才采用。
- **SQLite**：GRDB 只管理 App-owned SQLite。Runtime session 真相继续由 Runtime 持有，Swift 和 Node 不得同时写同一数据库文件。
- **工程生成**：XcodeGen 需要在真实 app、helper、UITests、SPM、entitlements 和 signing 上验证。若生成结果不稳定，就提交标准 `.xcodeproj`。
- **日志**：App 侧默认 OSLog，Runtime 保持结构化日志并共享 correlation ID。只有多 package backend 注入确有收益时再加 swift-log。
- **登录启动**：直接使用 ServiceManagement 的现代 API；不引入 LaunchAtLogin wrapper 作为核心边界。
- **更新**：当前不引入 Sparkle 或任何自动更新机制。未来若进入已签名分发，再以 Sparkle 2 为候选；届时 Sparkle delegate 必须经过 Runtime 活动会话 gate，且 App、helper 与 bundled Runtime 必须作为一个不可拆分的发布单元更新。

### 2.9 许可证与供应链规则

引入任何第三方源码或 package 前必须执行：

1. 记录仓库 canonical URL、精确版本/tag/commit、SPDX、上游 release 和调研日期；
2. 检查直接依赖与传递依赖，不仅看仓库首页 badge；
3. 将必须保留的 copyright、license 和 third-party notice 放入 App 的 Acknowledgements 与发布 artifact；
4. SwiftPM 使用受审查的固定版本并提交 `Package.resolved`；不在 release build 拉取 floating branch；
5. bundled Node、native module、Swift package 和外部 binary 都进入 runtime manifest/SBOM，记录 hash 与架构；
6. release 构建禁止下载未锁定脚本或二进制；所有 native artifact 在组装前做来源和 hash 校验；若未来恢复签名，再增加签名前校验；
7. 复制 T3、CodeEdit 等 MIT 项目的具体代码时保留 attribution，并单独 code review；仅参考思想时不伪装成代码依赖；
8. Apache-2.0 包保留 LICENSE/NOTICE，并检查是否触发额外 NOTICE 传递；
9. Sparkle 自身及其 vendored components 的 notice 一并保留，不能只写“MIT”；
10. 每次大版本升级重新跑 license、API、签名、性能和 accessibility 验证。

当前 unsigned build 会把 Swift Package notices 复制到
`Pi Agent.app/Contents/Resources/THIRD_PARTY_NOTICES.md`，并从**实际安装**的
Runtime production closure 生成两份可复算 artifact：

- `AgentRuntime/runtime-sbom.cdx.json`：CycloneDX 1.5 inventory，包含 bundled Node
  的 SHA-256、每个实际安装 npm component 的版本、SPDX expression、lock integrity 和
  distribution URL；未安装的 platform-optional package 不会被伪报为已发布。
- `AgentRuntime/runtime-third-party-notices.json`：每个 component 在 bundle 内的
  package path、可用 LICENSE/NOTICE/COPYING 文件，以及明确的 `not-bundled-by-package`
  缺口清单。

`verify-app.sh` 重新从 bundle 中的 lock、package metadata 与 Node binary 生成同一份
inventory；任一依赖、license 元数据、license 文件、Node 版本或 hash 漂移都会使本地
artifact 验证失败。该 audit 不把上游未随 npm tarball 提供完整 license 文本的条目误称为
已附随 notice；这些条目必须在引入新 release artifact 前由人工 license review 处理。

### 2.10 Phase 0 依赖 spikes

| Spike                    | 候选                                 | 必须回答的问题                                                             | 退出证据                                                              |
| ------------------------ | ------------------------------------ | -------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Terminal                 | SwiftTerm vs libghostty              | IME、VoiceOver、selection、`Cmd+C`、大输出、Metal/CPU、reconnect 是否达标  | 打包 `.app` 中连接真实 Runtime PTY 的录屏、指标和测试；签名版另行复核 |
| Transcript               | Textual vs swift-markdown            | 10k+ message、stream delta、代码块/表格、selection、link policy、VoiceOver | 性能基线、内存曲线、snapshot/UI tests                                 |
| Keychain                 | Security framework vs KeychainAccess | 多 Provider/account、更新、删除、access group、错误映射和 redaction        | fake + real Keychain integration tests，诊断无 secret                 |
| Persistence              | GRDB                                 | migration、WAL、backup、observation 是否满足 App-owned state               | schema/migration tests，证明不与 Runtime 共写                         |
| Project                  | XcodeGen vs checked-in xcodeproj     | helper、UITests、SPM、capabilities、签名是否可重复                         | clean clone 一条命令生成/构建，diff 稳定                              |
| Update（未来签名分发后） | Sparkle 2                            | active session、helper/runtime version、rollback、appcast 安全             | 签名旧版到新版升级演练和失败回滚；当前不执行                          |

每个 spike 最终产出 ADR：选择、拒绝项、许可证、版本 pin、性能数据、辅助功能结果、回滚路径。没有证据时保留“候选”，不能因为 GitHub star 数或截图好看就宣布采用。

## 3. 为什么保留现有 Runtime，而不是全部用 Swift 重写

“原生应用”描述的是产品交互、系统集成和交付边界，不等于每一行内部逻辑都必须使用 Swift。当前仓库已有大量经过测试的核心能力：

- Pi 与 OMP 双 Runtime；
- 会话创建、恢复、流式事件、排队、压缩和中止；
- 长期运行的 session daemon 所有权模型；
- PTY 终端、Git、文件、工作区和附件；
- Provider 认证、模型与 thinking level；
- 会话归档、未读、通知和树状导航；
- Pi Package 与插件行为；
- 远程机器与能力协商协议。

这些能力依赖 Node、Pi SDK、OMP RPC 和 `node-pty`。第一阶段全部重写会同时引入会话兼容、事件顺序、终端语义、Provider 登录和插件生态等高风险回归，而且无法复用现有 1800 余项测试。

因此采用明确的分层：

```text
原生产品层：SwiftUI / AppKit / Keychain / Notifications（未来签名分发时再评估 Sparkle）
                          ↓ typed IPC
Agent Runtime：TypeScript / Node / Pi SDK / OMP RPC / node-pty
                          ↓
用户工作区、Git、模型 Provider、Pi/OMP 配置与会话文件
```

Runtime 是 App 的内部引擎，不是需要用户管理的第二个产品。未来只有当某个 Runtime 模块接口稳定、迁移收益明确且拥有等价测试时，才逐个评估 Swift 或 Rust 实现；不把语言重写作为原生 App 上线的前置条件。

## 4. 产品范围

### 4.1 第一版必须具备

- 原生项目、工作区和会话导航；
- Pi/OMP Runtime 选择与可用性状态；
- 创建、恢复、停止、归档和删除会话；
- 流式显示用户消息、Assistant 消息、thinking 和工具调用；
- Prompt 编辑器、附件、模型与 thinking level；
- 文件列表、文件预览、Git diff 和变更概览；
- 可交互终端；
- Provider 登录和认证状态；
- 原生通用设置、Runtime 设置、快捷键与诊断；
- 系统通知、Dock badge、菜单命令和标准窗口恢复；
- 从现有 PI WEB 数据中无损迁移；
- 可复制的未签名 `.app` 安装、保留数据的卸载/迁移和诊断；签名、公证和应用内更新不在当前范围；
- 崩溃后重新连接仍在运行的 Runtime；
- Runtime 异常退出后的可解释恢复，不丢失已持久化会话。

### 4.2 第一版明确不做

- 不使用 WKWebView 承载现有 Web UI；
- 不为了进入 Mac App Store 而牺牲 PTY、插件、工作区或任意项目目录访问；
- 不在第一版重写 Pi SDK、OMP RPC、Git 或 PTY 引擎；
- 不默认暴露局域网 HTTP 服务；
- 不默认启用开机启动或后台常驻；
- 不立即删除现有 CLI、Web UI、远程协议或配置文件兼容层；
- 不在迁移期间改变 Pi 自己的会话文件格式；
- 不允许原生 UI 绕过 Runtime 直接修改 Runtime 拥有的活动会话状态。

### 4.3 远程机器策略

第一版以单 Mac 体验为交付门槛，但保留协议上的 `machineId` 和能力协商，不把数据模型退化成“永远只有本机”。远程机器入口可以隐藏在实验设置中，待本机体验稳定后再恢复为正式功能。

最终模型是：

- 本机：Pi Agent.app 直接连接内嵌 Runtime；
- 远端：Pi Agent.app 连接受认证的轻量 Agent Host；
- Web UI：仅作为可选远程兼容客户端，不再决定核心模型。

## 5. 目标架构

```text
Pi Agent.app
├─ SwiftUI App lifecycle
├─ AppKit integration
│  ├─ windows / menus / commands
│  ├─ notifications / Dock / status item
│  ├─ file panels / security-scoped bookmarks
│  └─ NSApplication termination coordination
├─ Feature modules
│  ├─ Projects & Workspaces
│  ├─ Sessions & Transcript
│  ├─ Composer & Attachments
│  ├─ Files & Git
│  ├─ Terminal
│  ├─ Authentication
│  └─ Settings & Diagnostics
├─ Native stores
│  ├─ AppState projection
│  ├─ Window/navigation state
│  └─ durable UI preferences
├─ RuntimeClient
│  ├─ command RPC
│  ├─ event stream
│  ├─ capability negotiation
│  └─ reconnect / epoch handling
└─ RuntimeSupervisor
   ├─ validates bundled runtime manifest/hash
   ├─ starts one runtime per user session
   ├─ owns socket and process lifecycle
   ├─ captures structured logs
   └─ coordinates update / shutdown
                    ↓ Unix domain socket
Bundled Agent Runtime
├─ existing session runtime ownership
├─ PiSessionService
├─ OmpSessionService
├─ TerminalService / node-pty
├─ Project / Workspace / Git / Files
├─ Auth / Provider integration
├─ persistence / archive / unread / notifications
└─ optional compatibility HTTP adapter
```

### 5.1 所有权规则

每类状态必须只有一个最终所有者：

| 状态                         | 所有者                                 | 原因                                           |
| ---------------------------- | -------------------------------------- | ---------------------------------------------- |
| 活动会话、队列、stream、终端 | Agent Runtime                          | App 重启或窗口关闭不能破坏运行中的任务         |
| 项目和工作区登记             | Agent Runtime                          | CLI、兼容 Web UI 与原生 App 必须看到同一份数据 |
| Provider secret              | Keychain，由 Runtime 通过受限桥读取    | 不把秘密复制到 UI 状态或日志                   |
| 非秘密的全局 Runtime 配置    | Application Support 下的版本化配置     | 便于迁移、备份和诊断                           |
| 项目级核心配置               | `<project>/.pi-web/config.json` 兼容层 | 保持可提交、跨客户端一致                       |
| 窗口、分栏、选中项、主题     | 原生 App                               | 纯 UI 状态不应污染 Runtime                     |
| 会话 UI 投影                 | 原生 App 的缓存，可随时重建            | Runtime 持有真实状态，缓存不可成为事实源       |

## 6. macOS 工程结构

建议在当前仓库新增：

```text
macos/
├─ PiAgent.xcodeproj/
├─ PiAgent/
│  ├─ App/
│  ├─ DesignSystem/
│  ├─ Features/
│  │  ├─ Projects/
│  │  ├─ Sessions/
│  │  ├─ Transcript/
│  │  ├─ Composer/
│  │  ├─ Workspace/
│  │  ├─ Terminal/
│  │  ├─ Authentication/
│  │  └─ Settings/
│  ├─ RuntimeBridge/
│  ├─ Persistence/
│  └─ Platform/
├─ PiAgentTests/
├─ PiAgentUITests/
├─ PiAgentRuntime/                 # exact dependency lock + runtime launcher
└─ Config/
   ├─ Debug.xcconfig
   ├─ Release.xcconfig
   └─ Entitlements.plist

src/nativeApp/
├─ contract/
├─ runtimeEntry.ts
├─ runtimeSupervisorProtocol.ts
└─ migration/

scripts/macos/
├─ build-runtime.mjs
├─ build-app.sh
├─ verify-app.sh
└─ smoke-runtime.sh
```

Swift 代码按 feature 和边界组织，不建立巨型 `AppViewModel`。每个 feature 使用小型 `Observable` store，依赖 `RuntimeClient`、文件授权、通知或 Keychain 时通过协议注入。SwiftUI View 只负责渲染、收集输入和调用 feature action，不直接拼 IPC 请求或读写磁盘。

AppKit 只用于 SwiftUI 当前不适合承担的边界，例如：

- 终止前确认与后台行为；
- 菜单栏、窗口 tabbing 和精细的 responder chain；
- 文档/目录选择器与文件权限；
- Dock、系统通知和服务菜单；
- 终端文本输入、选择和辅助功能需要的低层适配。

## 7. Runtime 打包与启动

### 7.1 打包形态

Release App 内包含：

```text
Pi Agent.app/Contents/
├─ MacOS/Pi Agent
├─ Frameworks/
├─ Resources/
│  ├─ AgentRuntime/
│  │  ├─ node/bin/node + node/lib/
│  │  ├─ dist/
│  │  ├─ node_modules/
│  │  └─ runtime-manifest.json
│  └─ migrations/
└─ Helpers/
```

必须打包固定、已验证的 Node 和 native dependencies，不能在用户首次启动时执行 `npm install`。`node-pty` 必须在 macOS 构建环境中为 `arm64` 和 `x86_64` 分别构建/验证，并由 manifest 纳入对应 artifact。首个版本可以分别生成 Apple Silicon 与 Intel App；只有验证 native module 的 universal2 组合流程后才合并通用包。

`runtime-manifest.json` 至少包含：App 版本、Runtime 版本、协议版本、Node 版本、架构、每个关键资源的 SHA-256。RuntimeSupervisor 启动前验证 manifest、Node 架构/版本、执行权限与每个资源 hash；失败时显示可操作的诊断页面，不尝试联网下载任意脚本修复。

### 7.2 进程模型

第一阶段采用 App-managed child process：

1. App 启动并取得单实例锁；
2. RuntimeSupervisor 检查是否已有相同用户、相同协议的健康 Runtime；
3. 若没有，则创建受限 socket 目录并启动 bundled Runtime；
4. 完成 `hello` / capability / epoch 握手后显示工作区；
5. Runtime 与 App 分别写结构化日志；
6. App 崩溃或窗口关闭时，Runtime 根据明确的 keep-alive lease 决定继续或退出；
7. App 重开时先重连，再决定是否新建 Runtime，绝不盲目启动第二个实例。

关闭窗口不应成为 `SIGTERM` 的同义词。真正退出 App 时，App 先从 Runtime 刷新活动 session 数；如果仍有活动 session，显示三个明确选项：

- **保持 Runtime 并退出**：退出原生 UI，保留正在运行的 bundled Runtime；
- **停止 Runtime 并退出**：先通过 epoch-bound `abort-active-work` receipt 逐一停止实际工作，再停止当前 App 自己启动的 bundled Runtime；绝不触碰显式连接的开发/外部 daemon；
- **取消**：返回应用。

没有活动 session 时，App 会停止自己拥有的 Runtime 后退出。若 health 无法刷新，则保守地展示相同三选项，不在未知状态下静默停止工作。`abort-active-work`、原生 Prompt、New Thread、Import Thread、archive、restore、archived delete、Fork Thread、terminal create/continue、Git stage/unstage/discard/commit/push/revert-head，以及 Pi extension dialog response 都具备同 `commandId` 可回读的 receipt、Runtime epoch、请求指纹冲突保护与 socket-timeout 后只查询 receipt 的语义；不会因未知网络结果而自动执行第二次 mutation。原生 Git push、discard 和 undo latest commit 都先取得 Runtime 的 fresh policy、在 sheet 显式确认。push 只允许当前 branch 推向既有 tracking upstream；latest-commit undo 只为干净的 non-merge `HEAD` 创建反向 commit；discard 只恢复已跟踪且未暂存的 root-worktree 文件。它们都不提供 force、set-upstream、选择 remote/refspec、tag、remote deletion、reset 或任意 commit 操作。Pi extension 的 select/confirm/input/editor 会显示为原生 sheet；Runtime 断开重连后以权威 pending projection 恢复，SDK timeout/Abort、rebind 或 Runtime shutdown 会安全取消。

### 7.3 后台与登录启动

第二阶段使用 ServiceManagement 的现代 Login Item / helper 模型，不直接让用户编辑 LaunchAgent plist。后台能力必须满足：

- 默认关闭；
- 设置页可见当前状态；
- 菜单栏可暂停、打开主窗口或彻底退出；
- helper 与主 App 使用同一版本协议；若未来引入签名 helper，还必须使用同一签名团队；
- 升级时先协调 Runtime checkpoint，再替换 App；
- helper 版本不匹配时拒绝启动新会话，但允许读取诊断信息；
- 卸载说明提供可逆、精确的 helper 注销和数据保留选项。

## 8. Native IPC 协议

### 8.1 传输

本机默认使用 Unix domain socket：

```text
~/Library/Application Support/Pi Agent/Runtime/sessiond.sock
```

目录权限为 `0700`，socket 权限为 `0600`，只能由当前用户访问。Runtime 启动前只会删除同一路径的 stale Unix socket，拒绝替换普通文件、链接、FIFO 或设备；退出清理按 inode identity 执行，不会误删被后续进程替换的路径。协议不依赖浏览器 Cookie、CORS、Host allowlist 或公开 TCP 端口。远程能力使用单独的网络 transport adapter，不能把本机 socket 认证假设复制到网络边界。

第一阶段已经复用当前 Unix socket 上的 HTTP + WebSocket 实现以降低迁移风险。Swift feature 只依赖 `RuntimeClient`、`RuntimeEventStreamClient` 和 `RuntimeTerminalClient` 协议，不让 HTTP 概念渗入 View。当前兼容路径使用 `PI_AGENT_RUNTIME_SOCKET`，未配置时回退到 `~/.pi-web/sessiond.sock`；最终打包 Runtime 的 socket 位置仍按本方案后续的 Application Support 布局收口。session event 连接 `/sessions/:sessionId/events`，加入前读取 `/stream-snapshot`，在同一 Runtime epoch 内按单调 `seq` 去重；terminal 连接 `/terminals/:terminalId/socket`，PTY 仍由 Node `TerminalService` 所有。第二阶段再把本机 transport 收敛为统一的长度前缀 JSON message stream：

```json
{
  "id": "01J...",
  "kind": "request",
  "method": "sessions.prompt",
  "protocolVersion": 1,
  "params": { "sessionId": "...", "text": "..." }
}
```

事件具有单调递增的 Runtime epoch 和 sequence：

```json
{
  "kind": "event",
  "topic": "sessions.events",
  "epoch": "runtime-start-id",
  "sequence": 1842,
  "payload": {}
}
```

App 只在同一 epoch 内按 sequence 去重和补洞；epoch 改变时重新获取 snapshot。断线、超时和未知结果不能自动重放非幂等命令。创建会话、提交 Prompt、归档和删除等命令携带 `idempotencyKey`，直到 Runtime 明确返回终态前保留该 key。

### 8.2 合约生成

当前 `src/shared/apiTypes.ts` 不应由 Swift 人工复制。新增面向 Native App 的小型版本化 contract，并从同一 schema 生成：

- TypeScript 请求、响应和事件类型；
- Swift `Codable` DTO；
- JSON fixture；
- 协议兼容性测试。

不要把内部 Pi SDK 对象直接暴露给 Swift。Runtime 负责投影成稳定、可序列化、与 Provider 无关的 UI contract。新增字段默认向后兼容；删除或改变语义必须提升 protocol major。

### 8.3 错误模型

所有错误至少包含：

- 稳定的 machine-readable code；
- 用户可读摘要；
- 是否可重试；
- 可选恢复动作；
- 不含 secret 的诊断 ID；
- 对应 Runtime epoch。

Swift feature 将错误翻译到最近的用户边界：字段错误留在表单，命令错误留在会话，Runtime 故障进入全局诊断。不能把所有失败都降级成顶部通用横幅。

## 9. 原生界面信息架构

### 9.1 主窗口

使用 `NavigationSplitView` 为基础的三栏结构：

```text
┌─────────────────┬──────────────────────────────┬──────────────────────┐
│ Projects        │ Conversation                 │ Workspace             │
│ Environments    │ native transcript            │ Changes / Files       │
│ Threads         │ tool cards / composer        │ Terminal / Context    │
└─────────────────┴──────────────────────────────┴──────────────────────┘
```

- 左栏：Project → Environment → Thread 层级、Runtime 过滤、搜索与状态；
- 中栏：消息、thinking、工具调用、队列、Prompt、附件和运行控制；
- 右栏：Changes、Files、Git、Terminal、Context；
- Compact 宽度：右栏变为 inspector 或独立 window，不把桌面三栏硬挤成移动网页布局；
- 多窗口：同一 Runtime，可打开不同项目/会话；每个窗口保存自己的 selection；
- 菜单命令：New Session、Open Project、Stop、Archive、Search、Toggle Inspector、Show Terminal；
- `Cmd+,` 打开原生 Settings，`Cmd+K` 打开原生命令面板。

### 9.2 Transcript

- 使用 SwiftUI 列表/滚动容器与可测量的增量渲染，不一次加载完整历史；
- Runtime 提供历史消息与 in-flight stream snapshot，App 用 `seq` 水位保持加入时的一致性；
- 当前切片已用 `assistant.delta`/`message.end` 驱动稳定的 streaming message 更新，不再轮询 messages/status 等待 settle；断线自动重连并重新读取 snapshot；
- 工具调用采用原生 disclosure group 和状态图标；
- 代码、diff 和日志采用原生选择/复制语义；
- Markdown 渲染层必须支持文本选择、链接安全策略、代码块和 VoiceOver；
- 图片使用 Quick Look 或原生预览窗口，不在消息中实现自定义浏览器 lightbox。

### 9.3 Terminal

终端是原生壳最难的 UI 边界。第一版不自研完整 VT parser/state machine，也不通过 WKWebView 嵌入 xterm。当前 vertical slice 已固定采用 SwiftTerm 1.11.2 的 AppKit `TerminalView`；`TerminalSurfaceView` 只把 Node PTY 的 output byte stream feed 给 renderer，并将输入和 resize 发回 `/terminals/:id/socket`。只有 SwiftTerm 后续真实长输出、辅助功能或现代控制序列验收不达门槛时，才验证固定 commit 的 `libghostty-vt` 与薄 AppKit/Metal surface。无论选型如何都必须支持：

- PTY resize、Unicode、宽字符、ANSI color；
- 鼠标选择、复制、粘贴、IME；
- `Cmd+C` 在有选择时复制、无选择时发送中断；
- VoiceOver 的最低可用输出；
- 大量输出的有界缓冲；
- App 重连时恢复 terminal snapshot 或明确标记不可恢复。

PTY 进程仍由 Runtime 拥有；原生 terminal view 只负责输入和渲染，第三方库的 local-process helper 不进入所有权路径。SwiftTerm 阶段 0 spike 已通过真实 PTY smoke；长会话、辅助功能和现代控制序列的完整验收仍需在后续打包/长跑测试中完成。

### 9.4 Settings

Settings 使用原生分区：

- General：默认 Runtime、启动行为、通知、更新通道；
- Agents：Pi/OMP 可执行文件、profile、可用性；
- Providers：登录状态与 Keychain 管理；
- Workspaces：授权目录、外部路径、上传目录；
- Packages：Pi Package 与受信任来源；
- Plugins：启用状态与权限摘要；
- Shortcuts：系统菜单快捷键；
- Diagnostics：版本、协议、Runtime epoch、日志、数据位置和导出诊断。

字段旁只保留影响决策的说明。文件路径使用选择器，枚举使用 Picker，布尔值使用 Toggle；只有高级兼容场景才显示原始配置文件位置。

## 10. 数据、配置与迁移

### 10.1 新目录

```text
~/Library/Application Support/Pi Agent/
├─ config.json
├─ runtime/
├─ projects.json
├─ machines.json
├─ archives/
├─ plugins/
├─ bookmarks.sqlite
└─ migrations.json

~/Library/Caches/Pi Agent/
~/Library/Logs/Pi Agent/
```

Pi 自己的 profile 和 session 文件仍由 Pi/OMP 兼容目录拥有，不能在第一版擅自搬迁。

### 10.2 旧数据来源

迁移器只读发现：

- `$PI_WEB_CONFIG` 或 `~/.config/pi-web/config.json`；
- `$PI_WEB_DATA_DIR` 或 `~/.pi-web`；
- 当前 `projects.json`、`machines.json`、archive、unread 和 plugin state；
- 项目内 `.pi-web/config.json`；
- Pi/OMP profile 位置。

迁移流程：

1. 生成迁移预览，不写入；
2. 显示来源、目标、冲突与不会移动的内容；
3. 用户确认后写入带 schema version 的新目录；
4. 对每个写入结果重新读取并验证；
5. 写入 migration journal；
6. 保留旧目录，不自动删除；
7. 新 App 成功启动并完成 smoke test 后才提供“移到废纸篓”按钮。

迁移必须可重复、可中断、可恢复。发现目标已有数据时不做隐式 merge；提供“使用现有 Pi Agent 数据”“重新预览迁移”或“导出冲突报告”。

### 10.3 Keychain

- 每个 Provider/account 使用稳定 service + account 标识；
- secret 不进入 SwiftUI state dump、UserDefaults、JSON 日志或 crash metadata；
- Runtime 不获得枚举全部秘密的接口，只能按已授权 Provider/account 请求；
- 删除账号时先让 Runtime 停止使用，再删除 Keychain item；
- 导出诊断默认只输出 configured/unavailable 状态；
- 兼容旧 auth 文件时先验证 Provider 支持边界，不能假定所有 Pi auth 都可直接迁入 Keychain。

当前已实现的 `auth.json` 迁移使用 Runtime-owned Keychain `CredentialStore`：原生 UI 只能预览 provider ID、认证类型和冲突状态；明确确认后逐项写入并 readback，`PI_WEB_DATA_DIR/native-auth-migrations.json` 以 `0600` 原子记录不含 secret 的 migration journal。若任一 provider 已在 Keychain 中存在，则拒绝整个迁移而不覆盖。成功后旧文件保持不变；rollback 只删除 journal 确认由本次迁移创建的 Keychain 项。写入和 rollback 都采用 runtime epoch、`commandId` 和 receipt；socket 结果未知时只查询 receipt。真实 provider account 的 E2E、旧文件退休和无法确认 Keychain item 归属的 crash recovery 仍不在当前交付范围。

## 11. 文件系统权限

Pi Agent 需要真实访问项目、Git worktree、终端 cwd 和附件。当前第一版是未签名的本地 `.app` 交付，仍应按最小授权设计；若未来恢复 Developer ID 分发，则在这一权限模型上另行完成签名/Sandbox 验证：

- 用户通过 `NSOpenPanel` 添加项目目录；
- 保存 security-scoped bookmark，并处理 stale bookmark；
- Runtime 只接收当前授权的 resolved path；
- 外部路径按根目录授权，不用全盘访问作为默认方案；
- 访问被撤销或目录移动时显示重新授权流程；
- 不把“配置中存在路径”当成 macOS 已授予访问权限；
- Full Disk Access 仅作为少数受保护目录的人工选择，不在引导中默认要求。

Runtime 的路径安全策略继续负责防止目录穿越、符号链接逃逸和错误工作区；macOS bookmark 是额外授权层，不替代应用内部校验。

## 12. 插件与扩展

现有插件系统包含浏览器 UI contribution，不能原样加载到 SwiftUI。将插件分为：

1. **Runtime extensions**：工具、Provider、命令、主题以外的核心能力；继续由 Runtime 加载；
2. **Native contributions**：未来使用声明式 schema 提供 action、设置和只读 panel model；由 SwiftUI 渲染；
3. **Legacy browser plugins**：只在兼容 Web UI 中运行，不允许向原生 App 注入 JavaScript 或 WebView。

第一版优先支持 core features 和 Pi Package 管理。第三方浏览器 panel 不作为原生首发阻塞项，但 App 必须明确显示“此插件仅支持兼容 Web UI”，不能静默消失。

任何 Runtime extension 仍是以用户权限执行的受信任代码。原生 App 应显示来源、作用域、版本与启用状态；manifest 完整性不能被包装成“所有用户安装插件都可信”。

## 13. 安全模型

主要威胁和控制：

| 威胁                     | 控制                                                                   |
| ------------------------ | ---------------------------------------------------------------------- |
| 其他本机用户连接 Runtime | `0700` 目录、socket owner 校验、每次启动的握手 token                   |
| 恶意网页访问本地 Agent   | 默认无 TCP listener；兼容 Web 服务必须显式开启                         |
| Secret 出现在日志/UI     | Keychain、redaction、类型化 secret boundary                            |
| 被替换的 bundled Runtime | exact dependency lock、manifest hash、Node 架构/版本与启动前完整性检查 |
| 插件取得用户权限         | 明确信任警告、来源/作用域、默认禁用未知 native contribution            |
| 更新中断活动会话         | update coordination、checkpoint、延迟安装                              |
| App 重连造成重复 Prompt  | idempotency key、epoch/sequence、未知结果不盲重试                      |
| 任意路径访问             | bookmark 授权 + Runtime path policy                                    |
| 远程协议复用本机信任     | 本地/远程 transport 与认证完全分离                                     |

## 14. 更新和本地分发

### 14.1 当前本地交付物与未来 release artifact

当前交付物是经过 `verify-app.sh` 验证的未签名 `.app`，其中包含 App、Runtime 和协议 manifest；
不把 npm registry 作为普通用户安装入口。

未来若恢复签名分发，才评估以下 artifact：

- Apple Silicon DMG；
- Intel DMG（只在真实 Intel runner 或机器上验证后发布）；
- 可选 zip 供 Sparkle 更新。

### 14.2 Release pipeline

1. TypeScript `npm run verify`；
2. Swift unit tests 与 UI smoke tests；
3. 构建对应架构的 Runtime 和 native modules；
4. 组装 `.app`；
5. 运行 `verify-app.sh`：manifest hash、Node launcher、Runtime health/hello 与 Swift socket client；
6. 在干净 macOS 用户账户直接运行 `.app`；
7. 验证首次启动、迁移、创建会话、PTY、退出/重连；
8. 仅在这些检查通过后将 artifact 标记为可本地安装。

当前范围没有签名、公证、DMG、Gatekeeper 或 Sparkle 凭据；如果未来重新引入这些能力，必须另开 ADR，而不能把未签名流程误报为可公开分发流程。

### 14.3 未来自动更新行为（当前不实现）

- 检测更新不打断任务；
- 下载完成后，如果存在活动会话，默认“任务完成后提醒”；
- 用户主动立即安装时明确说明 Runtime 会重启；
- 协议兼容时，新 App 可先连接旧 Runtime 完成协调；
- 不兼容时停止创建新命令，先完成 checkpoint，再原子升级；
- 更新失败必须能继续启动上一个完整 App bundle，不能留下半更新 Runtime。

## 15. 可观测性与诊断

Diagnostics 页面至少展示：

- App、Runtime、协议、Node、Pi、OMP 版本；
- Runtime PID、epoch、socket、启动时间和活动会话数；
- 当前数据目录与日志目录；
- Keychain 只显示配置状态；
- 项目 bookmark 是否有效；
- PTY native module/架构检查；
- 最近一次迁移和更新状态；
- “导出诊断包”与“在 Finder 中显示日志”。

诊断包默认移除 token、Prompt 正文、完整环境变量、用户主目录前缀和远程凭据。用户明确勾选后才附加会话或日志正文。

## 16. 测试策略

### 16.1 保留的 Runtime 测试

现有 TypeScript 测试继续覆盖领域逻辑、会话行为、协议投影、Git、路径安全、PTY、迁移与 Provider 边界。原生化不能以删除这些测试换取进度。

### 16.2 新增测试层

- Contract tests：同一 fixture 在 TypeScript 与 Swift 中解码结果一致；
- RuntimeClient tests：断线、epoch 切换、sequence 缺口、超时、未知结果；
- RuntimeSupervisor tests：单实例、异常退出、版本不匹配、manifest/hash 失败；
- Feature store tests：纯 Swift 状态转移与 injected fake client；
- Snapshot tests：关键原生 View 的状态，不依赖真实 Runtime；
- UI tests：首次启动、添加项目、创建会话、发送 Prompt、停止、恢复；
- Migration tests：旧数据、部分迁移、冲突、重试、回滚；
- PTY tests：resize、Unicode、粘贴、中断、大输出；
- Packaging tests：未签名 `.app` 组装、manifest/hash、首次运行、Runtime health/hello、Swift socket client；
- Long-run tests：App 窗口关闭/重开、Runtime 继续、休眠/唤醒、网络变化。

每个阶段都需要真实 `.app` smoke test。只在 Xcode Preview 或 unit test 中通过不能证明打包后的 Runtime、权限和 native module 可用。

## 17. 分阶段实施

### Phase 0：技术验证与冻结边界

本轮已完成的 Phase 0/Phase 1 vertical slice 交付：

- 最小 SwiftUI App；
- Unix socket health/hello、HTTP contract 和 WebSocket transport；
- SwiftTerm 1.11.2 原生 terminal surface（真实 PTY output/input/resize/reconnect smoke）；
- TypeScript/Swift contract fixture 与 native contract checks；
- 未签名 `.app` 组装、exact Runtime dependency lock、manifest/hash 与本机验证脚本。

bundled Runtime、Node 动态库、Pi SDK production dependency closure、`node-pty`、dependency inventory、runtime manifest、App 自动启动与 Swift socket smoke 已交付。原生 Inspector 现已通过 Runtime-owned contract 提供项目文件浏览、文本预览、受支持图片格式的受限预览（上限 10 MB）、新建文本文件、编辑保存、移动/重命名和二次确认删除；所有 mutation 带 `commandId`、runtime epoch 和可回读 receipt，Swift 不直接写 checkout。图片预览由 Runtime 先做 path/MIME/大小校验，再把 bounded base64 payload 交给 Swift/AppKit，不把 workspace URL 或文件读取权限给 UI。真实 bundled smoke 会在自建临时授权项目中验证写入、相同 receipt 重试、读取、移动和删除。Textual/Markdown renderer、消息附件预览、review/checkpoint、完整 workspace 与自动更新仍是后续交付。

当前切片退出证据：在本机 Apple Silicon 上，未签名 `.app` artifact 已验证；验证器完成所有 bundle resources 的 hash 检查，启动内部 Node Runtime，检查 `/health`、`/runtime/hello` 和 idempotent abort receipt，并由 Swift ContractCheck 读取真实 session projection。App 退出时会 refresh active-session health、先 abort actual work，并仅管理自己拥有的 child Runtime；窗口关闭后后台入口、干净账户安装与远程能力仍是后续门槛。

### Phase 1：原生单机 MVP

原生侧边栏现在有 App-owned 的 bookmark-backed Project Library：项目是稳定的顶级实体，当前项目的 Thread 只显示在它的 `Threads` 分组下。目录显示路径只是帮助用户识别 bookmark 的元数据，不会被当作 Runtime 权限；切换项目会停止旧投影/terminal reader，并让 Runtime 重新执行 `authorize-project`。旧 PI WEB 项目的候选预览、逐项重新授权、migration journal 与 rollback 将在这层之上交付，不能通过复制旧 JSON 假装继承 macOS 路径授权。

当前已交付候选预览与逐项重新授权：bundled Runtime 仅读取旧 `projects.json` 的项目名、绝对路径与创建时间，并通过私有 socket 交给 Settings。用户必须在 Finder 选择**完全相同**的目录后，App 才创建新的 native bookmark；候选数据本身不授予路径权限，也不会自动打开项目。迁移 journal、readback 和“只移除本次新增 bookmark”的 rollback 仍是后续门槛。

交付（当前已落地的子集）：项目目录、Project → Thread 会话列表、活动/Archived 分组、聊天、Prompt、Pi Runtime、事件驱动 transcript、SwiftTerm terminal、Pi extension 原生 dialog、Provider 登录 sheet、基础设置和诊断。原生菜单的 `Cmd+N` 可新开窗口，`Cmd+Shift+N` 新建 Thread：每扇窗口拥有独立的项目、Thread selection、transcript、terminal、inspector 与 project bookmark store，但共同使用同一条 Runtime connection/supervisor；因此不会重复启动 Pi Runtime，关闭或切换一扇窗口不会打断其他窗口的任务。会话可在原生侧边栏 Import、Fork、归档、恢复；Import 使用 macOS 文件选择器选择 JSONL，再让 Pi SDK 复制并切换到 imported session，Fork 则先展示 Runtime 投影的 user-message 候选项，再让 Pi SDK 执行真实 session replacement。永久删除只对 Archived 会话开放且要求二次确认。Composer 可由系统文件选择器添加最多 16 个 PNG/JPEG/GIF/WebP 图片；每个在交给 Runtime 前限制为 Pi 的 4.5 MB inline 上限，Runtime 在 receipt 建立前再次校验。Pi SDK 的持久化 message image content 经 Native Contract 回到 transcript，Swift 仅渲染 socket payload，不取得 workspace 文件 URL。右侧 inspector 已提供 Runtime-owned Git status/diff、逐文件 stage/unstage、原生 commit sheet、Thread-owned checkpoint/review，以及受限的原生 push：Runtime 先复核当前 branch 的 tracking upstream、ahead/behind，Swift 再显示确认 sheet；push 本身不接收 remote/branch/refspec/force 参数。Swift 不直接运行 Git，socket 未知结果只回读 receipt，Git hooks 不会被绕过。checkpoint 以 `0600` 私有文件原子保存当前 Git status 与有明确 `truncated` 标识的 staged/unstaged diff，Swift 只能回看，不能由 checkpoint 执行 restore/revert，也不把它伪装成 Git ref。Inspector 同时通过 Runtime-owned、project-capability 约束的 file tree/file contract 浏览目录并预览文本、受支持图片格式的 10 MB 以内预览，并可新建 UTF-8 文本文件、编辑保存、移动/重命名和二次确认删除；新建与移动默认拒绝覆盖已有文件，所有文件 mutation 也在未知 socket 结果时只查询同一 receipt。图片仍由 Runtime 读取并以 bounded payload 交给 AppKit，Swift 不直接读写 checkout；relative path、目录穿越和 symlink escape 都在 Runtime 路径边界拒绝。Pi extension 的 select/confirm/input/editor 通过 Runtime-owned pending projection 显示为原生 Swift sheet，不会让 SDK callback 穿透到 App；Provider OAuth/API-key flow 同样由 Runtime auth state machine 驱动，Swift 只渲染状态、打开系统浏览器并回传用户输入；session event stream 打开/关闭事件驱动 refresh，重连后会重读 pending 状态。当前不提供 reset/revert、由 checkpoint 触发的恢复、子模块内部暂存、通用文件附件/文件夹投递、OMP 完整投影或完整 workspace projection。Runtime 继续使用现有 socket HTTP/WS transport，Swift feature 只依赖 `RuntimeClient` 及其事件/terminal/Git/workspace/extension-interaction capability 协议。

退出门槛：在不打开浏览器的情况下完成日常单机工作，并由 App 自己管理 Runtime 生命周期；当前切片已证明现有会话可读取、Prompt 可提交且事件/terminal 可重连，bundled Runtime 已达到本机门槛，完整 workspace 仍未达到该门槛。

### Phase 2：生命周期与 macOS 集成

已交付子集：security-scoped project bookmark；Runtime 的 hello/health 兼容握手；跨实例 launch lock；退出前 active-session health refresh；`abort-active-work`、原生 Prompt、New Thread、Import Thread、archive、restore、archived delete、Fork Thread、terminal create/continue、Git stage/unstage/discard/commit/push/revert-head 的 epoch-bound command receipt；活动 session 的保持 Runtime/停止自有 Runtime/取消三选项；外部 daemon 永不被 App quit 停止。

已交付的 non-sandbox project boundary：bundled Runtime 启动时获得仅在 child environment 中传递的 token；原生客户端先执行 epoch-bound `authorize-project` receipt，再读取 project session；Runtime 对其他请求要求 token，并通过 canonical `realpath` root/descendant allow-list 拒绝未授权 cwd、sibling-prefix 和 symlink escape。Swift 显示授权状态，未授权时不创建 thread、prompt 或 terminal。它是同用户的逻辑能力边界，不是 sandbox security scope。

已交付的活动任务通知：用户在 Settings 主动开启后，App 才请求 macOS 通知权限并在每个已授权项目订阅专用通知流。Runtime 只广播 Pi extension 明确写入的 bounded notification inbox；native App 不会从 transcript、tool output、prompt 或 provider payload 推导通知内容。首连先把现有 inbox 条目标记为已见，之后以 `daemonInstanceId + project + session + notification id` 做有界去重；App 不活跃时才显示 macOS alert，多窗口共享同一个 App-lifetime coordinator，不会因重复 WebSocket 或重连重复提醒。通知点击只会选中一个已打开、已授权且 cwd 完全匹配的 Thread，notification `userInfo` 不携带通知正文、credential 或额外 filesystem authority。Login Item 与后台自动启动仍未实现。

待交付：Git reset/revert 与 submodule mutation、Login Item helper，以及 Sandbox 下 project bookmark data 到 RuntimeHost/child Runtime 的真实 capability hand-off。原生菜单栏入口现已交付：关闭所有窗口不停止 Runtime，用户可从菜单栏重新打开窗口或走既有安全退出确认。App-owned Runtime 的 session/terminal socket 断线恢复、App crash 后 Runtime supervisor 重连与 sleep/wake 的一次性权威重同步现已交付；多窗口目前共享唯一 Runtime supervisor，同时保持彼此独立的窗口选择状态，并由 application delegate 向全部打开窗口广播 sleep/wake。外部 daemon 仍只保留自身连接/重连语义，不会由 App 启动或停止。Bundled Runtime 已通过其最小 `Security.framework` helper 注入 Pi SDK 的 `CredentialStore`：每个 provider credential 仅以 Keychain generic-password item 保存，metadata enumeration 不返回 secret，且 Runtime 不把 key 暴露给 SwiftUI/Native Contract。Provider status、OAuth/API-key native flow 与自动 polling 已交付；旧 `auth.json` 已支持 redacted preview、用户确认后的逐项 Keychain 写入/readback、`0600` migration journal 与只删除本次创建 Keychain 项的 rollback，source file 不会删除。真实 provider E2E、旧 auth 文件退休和 crash 后来源无法确定条目的自动清理仍未交付，不得误报为全量迁移完成。

退出门槛：活动任务不会因关窗口、App UI 崩溃、睡眠/唤醒而无提示终止；所有后台状态都有可见入口。

### Phase 3：分发与迁移

交付：可复制的未签名 `.app`、旧 PI WEB 迁移向导、诊断包、卸载/保留数据路径。当前已交付原生“Export Redacted Support Report”：用户选定输出位置后，App 导出可分享的 JSON，内容只含 App/Runtime version、health/hello、socket 描述、当前项目授权状态和 provider 是否配置的元数据；不包含 prompt、transcript、workspace 内容、terminal 输出、credential 或 capability token。完整旧数据迁移向导和卸载/保留数据 UX 仍待交付。签名、公证、DMG 和 Sparkle 明确不在当前范围内。

退出门槛：干净用户账户可完成安装、迁移、更新和卸载；无需 npm、手动 chmod 或 plist 操作。

### Phase 4：协议收口与远程能力

交付：本机专用 IPC、远程 Agent Host、认证、能力协商、旧 Web UI 降级策略、legacy browser plugin 提示。

退出门槛：本机 transport 无公开端口；远程 transport 有独立威胁模型和端到端验证。

### Phase 5：旧产品收口

只有满足以下条件才执行：

- 原生 App 覆盖核心单机行为；
- 两个稳定版本完成迁移验证；
- CLI/远程用户有明确兼容路径；
- 发布、回滚和数据恢复完成演练；
- telemetry 或人工回访确认用户不依赖即将移除的路径。

此时再将 README 和产品名从 PI WEB 主叙事切换为 Pi Agent，并决定哪些 Web/API 代码删除、哪些保留为 Agent Host。

## 18. 迁移期间的仓库规则

- 原生化开发在当前仓库进行，避免 Runtime 与 App 合约跨仓库漂移；
- `README.md` 在原生 MVP 可安装前仍描述当前可用的 PI WEB，不提前宣传未交付行为；
- 本方案是 prospective architecture，不修改当前配置事实；
- 用户可见行为通过 Changeset 记录；纯规划文档不进入 npm release notes；
- 修改 `src/server/sessiond.ts`、Runtime ownership 或 daemon-only 路径时，继续要求手动重启当前 session daemon；
- 每次迁移保持兼容 adapter，不在同一个提交中同时替换 UI、transport 和数据格式；
- Web UI 和原生 App 必须通过同一 Runtime contract 观察事实，不各自实现一套会话规则。

## 19. 主要风险与处理

| 风险                                  | 处理                                                                                           |
| ------------------------------------- | ---------------------------------------------------------------------------------------------- |
| SwiftUI transcript 在长会话中性能不足 | Phase 0 用真实长 transcript 和流式更新压测，必要处使用 AppKit-backed view                      |
| 原生 terminal 复杂度过高              | SwiftTerm/libghostty 对照 spike 和退出门槛；不自研完整 VT，不接受 WKWebView/xterm 作为正式回退 |
| bundled Node / node-pty 打包失败      | 构建期固定依赖、逐架构 artifact、manifest/hash 和干净机验证；未来签名时再增加嵌套签名验证      |
| App 退出误杀任务                      | Runtime lease、活动会话查询和明确退出三选项                                                    |
| Swift/TS 类型漂移                     | schema codegen + shared fixtures + protocol compatibility tests                                |
| Keychain 与 Pi auth 模型不一致        | 先做 bridge 与支持矩阵，不批量删除旧 auth 文件                                                 |
| macOS 权限导致工作区不可访问          | bookmark 状态可视化、重新授权和 Runtime 二次路径校验                                           |
| 同时维护 Web 与 Native 成本过高       | 共享 Runtime contract；Web 进入兼容维护，不并行演进两套产品特性                                |
| 远程能力拖慢本机 MVP                  | 保留数据模型和协议边界，隐藏入口，Phase 4 再交付                                               |
| 自动更新中断 Agent                    | 下载与安装分离、活动会话 gate、checkpoint 和回滚 App bundle                                    |

## 20. 关键 ADR 清单

进入实现前必须分别写短 ADR 并完成真实 spike：

1. 最低支持 macOS 版本；
2. SwiftTerm 与 libghostty 的 terminal 选择和版本 pin；
3. bundled Node 的构建、架构和 manifest 验证方式；未来若恢复签名分发，再单独决定签名方式；
4. 本机 IPC 第一阶段复用与最终 framing；
5. schema 到 Swift/TypeScript 的生成工具；
6. Runtime keep-alive 和 App 终止状态机；
7. Keychain 与现有 Pi/OMP credential 的桥接边界；
8. bookmarks 和 Runtime 路径授权传递；
9. 未来签名分发时的 Sparkle 更新、helper 更新和 active-session gate；
10. Textual、swift-markdown 与 transcript 增量渲染边界；
11. XcodeGen 或 checked-in Xcode project；
12. legacy Web UI、CLI 和 browser plugin 的支持周期。
13. Pi SDK adapter、bundled Node Runtime 与 RPC fallback 的边界；详细决策见 [macOS 原生客户端与 Pi Runtime 融合](./macos-pi-runtime-integration.md)。

ADR 必须记录选择、拒绝方案、证据、回滚路径和需要复核的假设，不能只写最终结论。

## 21. 最终验收标准

只有同时满足以下条件，产品才可以称为“macOS 原生 Pi Agent”：

- 产品主窗口无 WebView、Electron 或浏览器依赖；
- 本地复制的未签名 `.app` 无需 npm 即可启动真实 Pi/OMP 会话；
- 项目、会话、聊天、工具调用、Git、文件和终端都有原生交互；
- 关闭窗口、App 重连、休眠/唤醒不会无提示终止活动任务；
- secret 使用 Keychain，项目目录使用可解释的授权模型；
- 没有默认 localhost 控制端口；
- App、Runtime、native module 均由 exact lock、manifest、SHA-256、架构检查和真实 smoke 验证；
- 更新不会在未知状态下重复命令或破坏活动会话；
- 旧 PI WEB 数据迁移有预览、验证、journal 和回滚；
- 干净机器安装、迁移、工作、升级和卸载均通过端到端验证；
- 当前 Web/CLI 用户有明确兼容和退出周期。

## 22. 推荐的第一个实现切片

第一个实现切片中的原生窗口、health/session contract、事件驱动 transcript、SwiftTerm terminal、bundled Runtime 与 App quit ownership 协调已在本轮完成并通过本机 smoke；完整 workspace、agent graceful-abort、后台入口和远程能力仍是下一轮，不把当前 prototype 宣称为完整产品。

第一个切片严格限制为一个 vertical slice：

1. 创建 SwiftUI `Pi Agent.app`；
2. App bundle 内嵌固定 Node 和最小 Runtime；
3. Runtime 提供 `hello`、`health`、`projects.list`、`sessions.list`、`sessions.prompt` 与 session event；
4. Swift 显示项目、会话和流式 transcript；
5. 以 SwiftTerm 为首选加入原生 terminal prototype，并保留 `TerminalSurface` 替换边界；
6. 实现 App 关闭窗口后重连同一 Runtime；
7. 生成未签名的 Apple Silicon `.app` 并在干净账户 smoke test。

这个切片不做完整设置、不做远程、不做插件 UI、不改旧数据格式。它验证整个方案最危险的五条链路：App 打包、Runtime 完整性、IPC、流式会话和 native terminal。通过后再扩展功能；未通过时能以最低成本更换 IPC 或 terminal 技术选择。
