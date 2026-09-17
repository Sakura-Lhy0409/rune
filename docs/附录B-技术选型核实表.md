# 附录 B · 技术选型核实表

> **用途**：设计文档里的每一条平台约束都应该能追溯到这里。**凡是 Apple 未公布的数字，本表一律写"未公布"，绝不编造。**
> **基线**：核实于 **2026-09-17**；当前发行版为 **iOS / iPadOS / macOS / watchOS / visionOS 27.0**。
> **标记**：`[不确定]` = 未能从官方来源确认；`[未公布]` = Apple 明确没有公开该数值。

---

## 1. Foundation Models（端侧模型）

| 项 | 事实 | 溯源 |
|---|---|---|
| 框架引入 | iOS 26.0；watchOS 27.0 起支持 | [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) |
| 端侧模型版本 | 存在三代：26.0–26.3 / 26.4 / 27.0 | 同上 |
| 会话 API | `LanguageModelSession(model:tools:instructions:)`、`(model:tools:transcript:)`、`(model:dynamicInstructions:history:)`、`streamResponse` / `ResponseStream`、`isResponding` | 同上 |
| 可用性查询 | `SystemLanguageModel.default.availability` → `.available` / `.unavailable(.deviceNotEligible / .modelNotReady)`；`.supportedLanguages` | 同上 |
| **上下文窗口** | ⭐ **4096 token / 会话**。**Instructions、全部提示、工具 schema 及其输入输出、`@Generable` 的 schema 与响应全部计入** | [TN3193](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) |
| 窗口查询 API | `.contextSize`（iOS 26.4+）、`.tokenCount(for:)` | [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) |
| **工具数建议** | ⭐ **最多 3-5 个** | TN3193 |
| 超限行为 | 抛 `LanguageModelSession.GenerationError.exceededContextWindowSize`，**该会话之后完全无法响应** | TN3193 |
| 系统提示 | **没有 system prompt API**；等价物是 `Instructions`，存在 transcript 里并计入同一 4096 窗口 | TN3193 |
| 结构化生成 | `@Generable` + `@Guide`；**类型会被转成 JSON schema 注入提示，消耗 token**；运行时 schema 用 `DynamicGenerationSchema` | 官方文档 |
| 工具调用 | `protocol Tool<Arguments, Output>: Sendable`，含 `name` / `description` / `call(arguments:)`；**工具定义会被放进提示**；工具须 `Sendable`；链式调用背靠背执行 | [Tool](https://developer.apple.com/documentation/foundationmodels/tool) |
| iOS 27 新增 | `ToolCallingMode`（`.allowed` / `.disallowed` / `.required`；**`.required` 会让模型进入你必须主动退出的 while 循环**）、`DynamicProfile` / `DynamicInstructions` / `historyTransform`、每会话 usage、**Vision 输入**、内置 OCR / 条形码工具、**Spotlight 支持的本地 RAG 检索工具** | [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/)、[242](https://developer.apple.com/videos/play/wwdc2026/242/) |
| 框架开源 | ⭐ iOS 27 起 **Foundation Models 框架已开源**，并定义**开放的 `LanguageModel` 协议**（已有 Core AI / MLX / Anthropic / Google 实现） | WWDC26 相关场次 |
| 设备门槛 | Apple Intelligence 需要 iPhone 16 及以后、iPhone 15 Pro / Pro Max、iPhone Air、iPad mini (A17 Pro)、M 系列 iPad/Mac | [Apple 支持](https://support.apple.com/en-us/121115) |
| 端侧模型存储占用 | **最多 8GB（较新设备 14GB）** | 同上 |
| 参数量 | **Apple 未公布**。第三方分析称 2025 年约 3B、2026 年为 20B 稀疏 MoE（激活 1-4B） | `[不确定]` |

### 1.1 Private Cloud Compute（PCC，第三方可用）

| 项 | 事实 |
|---|---|
| API | `PrivateCloudComputeLanguageModel`（**iOS 27.0+**） |
| 上下文 | **32,000 token** |
| 其他 | 支持推理档位；**无需 API key**；`quotaUsage` 可查配额 |
| **门槛** | 需**托管 entitlement `com.apple.developer.private-cloud-compute` + 资格审批**；**前 200 万次首次下载免费** |
| 性质 | **这是云**（Apple 的云）→ 无网络时不可用；在产品文案中必须如实说明"内容离开设备" |
| 在架先例 | Working Copy 的 Repository Agent："可跑在 Apple Private Cloud Compute 上……无需 API key、无需订阅"，额度用尽后回落到用户自配的 AI 服务 |

**对 Rune 的影响**：把 PCC 做成"用户没配任何渠道时的云端兜底"，但**因为它是托管 entitlement，必须当成可选增强而非默认依赖**（[13 §2](13-端侧模型与性能预算.md)）。

---

## 2. 后台执行（Apple 公布的数字）

| 机制 | 数字/条件 | 溯源 |
|---|---|---|
| **`BGAppRefreshTask`** | **最多 30 秒**，之后必须调 `setTaskCompleted`，否则 App 被终止 | [Choosing Background Strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app) |
| **`BGProcessingTask`** | "可运行数分钟"（**未公布具体秒数**）；**仅在设备空闲时**；**用户一开始使用设备就被终止**；需 Background Modes `processing` | [文档](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask) |
| **⭐ `BGContinuedProcessingTask`**（iOS 26.0 / iPadOS 26.0 新增，watchOS 无） | 由**用户在前台发起**；后台继续 **"数分钟或更久"**（**未公布上限**）；**可用网络与密集 CPU**；GPU 需 `...continued-processing.gpu`；**进度以系统 Live Activity 呈现且用户可取消**；**内存压力下优先杀掉进展低的任务**；从多任务界面强制退出 = **静默取消，无回调** | [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados) |
| **`beginBackgroundTask`** | 有限窗口；读 `backgroundTimeRemaining`；**不调用 `endBackgroundTask(_:)` 会导致 App 被杀** | [UIApplication](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)) |
| **静默推送** | `content-available:1` + `apns-priority:5`；**30 秒**运行时间；**"每小时不要超过 2-3 条"**；**不保证送达**，旧推送被丢弃 | [Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app) |
| **后台 URLSession** | 传输在**独立系统进程**中执行，**可跨挂起与终止存活**；需要 delegate；仅 HTTP/HTTPS；**重定向强制跟随**；上传只能来自文件；**每次恢复/重启后有速率限制器延迟新任务**（回前台重置） | [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) |
| **Live Activity** | **活跃最多 8 小时**，之后锁屏最多再 **4 小时**（合计 **12 小时**）；**超过 160pt 会被截断** | [ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) |
| 背景 ANE | 后台访问 Neural Engine 需 **`com.apple.developer.background-tasks.continued-processing.inference`** —— "系统要求任何后台中的 Neural Engine 访问都需要该 entitlement" | [entitlement 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference) |

### 2.1 由此得出的三条架构结论

1. **不存在"常驻自主循环"**。唯一的合法长跑路径是 `BGContinuedProcessingTask`（前台发起、用户可见、可取消）或保持前台。因此 [10 §3.1](10-后台执行与可靠性.md) 以它为主载体。
2. **锁屏 = 挂起**：Apple 没有为长连接提供豁免，**SSE / WebSocket 在锁屏后必然断开**，唯一合规模式是**回前台重连**。唯一"持续监听"的后台模式是音频/定位/VoIP，受 Guideline 2.5.4 限定用途 —— **Rune 不采用这种取巧手段**。
3. **"进度"是系统资源分配依据**：延续处理任务必须**持续上报真实进度**，否则在内存压力下会**优先被杀**。这直接决定了 [08 §8](08-交互与体验设计.md) 的进度 UI 不是装饰，而是功能。

---

## 3. 文件系统与沙箱

| 项 | 事实 |
|---|---|
| 容器结构 | `Documents`（含 `Documents/Inbox` 用于 "Open in" 副本）、`Library/{Caches, Application Support, Preferences}`、`tmp` |
| 在"文件"App 可见 | 需 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` |
| 容器外访问 | **禁止**（Guideline 2.5.2 明文："may not read or write data outside the designated container area"） |
| 目录授权 | `UIDocumentPickerViewController` 的 open/move 返回 **security-scoped URL**；必须 `startAccessingSecurityScopedResource()`，并保存用 `.withSecurityScope` 创建的 bookmark；**绝不持久化原始 URL** |
| ⚠️ 资源泄漏 | **未配对的 stop 调用会泄漏内核资源，最终导致所有沙箱扩展失效直到 App 重启** → 必须用 RAII 包装强制配对 |
| iCloud Drive | ubiquity container + `NSMetadataQuery`；`NSFilePresenter` **只对"经文件协调器"的改动通知，原始写入不通知** |
| 自定义文件提供者 | `NSFileProviderReplicatedExtension` |
| App Group | 共享容器 + keychain group + IPC，`group.<name>` |
| **目录监听** | **iOS 无 FSEvents、无通用递归监听 API**。可用组合：`NSMetadataQuery` / `NSFilePresenter` / 对合法打开的描述符用 `DispatchSource`。**兜底必须是前台恢复时的全量 mtime+size 比对**（`[不确定]` 仅针对"无 FSEvents"的措辞，结论不变） |

**对 Rune 的影响**：[05 §4.2](05-工具系统与执行沙箱.md) 的"外部变更检测"改成三层组合 + 全量比对兜底；新增"授权目录生命周期"与"授权失效"两行约束。

---

## 4. 动态代码与 JIT（结论：无 JIT，且这条路正确）

| 项 | 事实 |
|---|---|
| Guideline 2.5.2 | "may not … download, install, or execute code which introduces or changes features or functionality of the app"（教育类豁免要求源码**完全可查看可编辑**） |
| Guideline **ADPLA §3.3.1(B)** | 这才是 2026 年整治中 Apple **明确引用**的条款：解释型代码**可以**下载，但需满足 (a) 不改变主要用途 (b) 不绕过签名/沙箱/系统安全 (c) 不构成商店 |
| 编程环境豁免 | 面向编程学习的 App 可下载并运行可执行代码，条件：可执行代码占可视面积 ≤80%、有醒目提示、无代码商店、**不得含预编译库/框架** |
| **判定关键** | **"primary purpose"**；且**二进制里"存在"该能力就可能被引用，哪怕从未被调用** |
| `allow-jit` | **仅 macOS 10.7+ Hardened Runtime**，**iOS 无此 entitlement**（[文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)） |
| iOS 唯一 JIT 通道 | **BrowserEngineCore**（iOS 17.4+）：`be_memory_inline_jit_restrict_rwx_to_rw/rx_with_witness`、`BE_JIT_WRITE_PROTECT_TAG`，**需 Apple 授予的替代浏览器引擎 entitlement，且仅 EU/日本** |
| 2.5.6 | 网页浏览必须使用 WebKit（EU/日本有替代引擎 entitlement） |
| 结论 | 第三方进程**只能跑解释器**；WKWebView 的 JIT 是 WebKit 的，不是我们能控制的。**原生 WASM 解释器可行；JIT 或"下载后 AOT 再 dlopen"不可行** |
| 先例 | **UTM SE** 以无 JIT 的线程化解释器上架（"SE = Slow Edition"） |
| 备注 | Apple 没有单独一份文档写"`mmap(PROT_EXEC)` 会失败"，这属于由 entitlement 与 2.5.2 推出的结论 `[不确定]` |

**对 Rune 的影响**：[05 §3.1](05-工具系统与执行沙箱.md) 的"解释器 + AOT 预编译 + 原生工具兜底"不是妥协，而是**唯一可行且正确的架构**。

---

## 5. 进程、内存与硬件加速

| 项 | 事实 |
|---|---|
| **无 fork/exec** | `Process`（NSTask）标注为 macOS 10.0 + Mac Catalyst **only**；无 `posix_spawn` 可用途径。扩展是系统管理的独立进程 |
| **jetsam 内存上限** | ⭐ **Apple 完全不公布按设备的内存上限** → 用 `os_proc_available_memory()` 运行时查询 |
| `increased-memory-limit` | 仅在部分设备有效，**无保证**；`extended-virtual-addressing` 是另一个独立 entitlement |
| 键盘扩展内存 | 有实测博客称约 **60MB `phys_footprint`** 后静默 jetsam；**非 Apple 公布** `[不确定]` |
| ANE | Core ML 的 `MLComputeUnits`（`.all` / `.cpuAndNeuralEngine`）；**iOS 27 新增 Core AI**（`AIModel` / `AIModelAsset` / `ComputeUnitKind`，CPU/GPU/ANE，支持 CLI AOT 预编译） |
| 后台 ANE | 需 `.continued-processing.inference` entitlement（见 §2） |

**对 Rune 的影响**：[13 §3](13-端侧模型与性能预算.md) 的分档**不用机型白名单、不写死 jetsam 阈值**，改用 `os_proc_available_memory()` + 首次启用时的探针实测，缓存为"本机画像"。

---

## 6. UI 与系统集成

| 项 | 事实 |
|---|---|
| 设计系统 | Liquid Glass（WWDC25 323） |
| **接入 Apple Intelligence / Siri 的唯一路径** | ⭐ **App Intents**。**不存在单独的"注册为 Apple Intelligence App Action"的 API**；intents 会出现在快捷指令、Spotlight、Widget 与 Siri 中 |
| iOS 27 新增 | **App Schemas + domains**（如 `@AppEntity(schema: .messages.message)`）、`IndexedEntity`（系统语义索引）、基于 UserActivity / 视图注解的**屏幕内容感知**、`Transferable` 内容传递、`AppIntentsTesting` |
| 其他可用 | 交互式 Widget、Control Center 控件 / 操作按钮（WidgetKit controls，iOS 18+）、Share/Action 扩展、Core Spotlight（`CSSearchableItem` / `CSSearchableIndex`）、Focus 过滤器（`SetFocusFilterIntent`）、快捷指令 |
| Watch | watchOS 27 通过 **PCC** 获得 Foundation Models；Watch 后台预算未核实 `[不确定]` |

---

## 7. 网络

| 项 | 事实 |
|---|---|
| 流式 | `URLSession.bytes(for:)` → `AsyncBytes` + `.lines`（`AsyncLineSequence`）；**SSE 必须手工解析，系统没有内建 EventSource** |
| 协议 | 支持 HTTP/2 与 HTTP/3（TN3102） |
| 后台会话 | **不能承载长连接流式数据任务**（独立进程、基于文件的传输） |
| 锁屏 | 进程在后台窗口耗尽后被挂起；**Apple 未为长连接提供豁免** → **回前台重连是唯一合规模式** |
| ATS | 例外在 Info.plist **按域名静态声明**；用户运行时输入的 `http://` 主机只能靠 `NSAllowsArbitraryLoads` / `NSAllowsLocalNetworking` 覆盖 |
| Cloudflare 挑战 | `URLSession` 无法通过 JS 挑战 → 需要 `WKWebView` 中间页抓 `cf_clearance` |

---

## 8. 分发：各渠道真实能力对比

| 渠道 | 规模/成本 | **额外运行时能力** | 结论 |
|---|---|---|---|
| **App Store** | 无限，$99/年 | 基准 | 主渠道 |
| **TestFlight** | 外部 **10,000**、内部 100、最多 100 个构建、**每构建 90 天** | **无**（同样要审核，2.5.2 同样适用） | 内测/灰度 |
| **Ad Hoc** | **每产品族每会员年 100 台设备**（需 UDID） | 略宽（可开 Full 轨特性） | 核心用户 |
| **Xcode 自签** | 免费账号：10 个 App ID、**7 天**过期、3 台设备、每设备 3 个 App；付费账号 1 年 | ⭐ **唯一可获得 JIT 的路径**（调试器附加式 sideload，需一次性桌面配置） | **Full 轨的正解** |
| **企业计划** | $299/年；需 **100+ 员工**、法人实体、D-U-N-S、组织域名网站、仅限员工下载 | — | ❌ **对外分发属直接违约**（2019 年 Facebook/Google 企业证书被吊销即因此）。**不作为方案** |
| **EU 替代市场 / 网页分发**（2026-10-01 起统一条款） | 门槛满足其一即可（如全球首年 **100 万次安装**、**$100 万备用信用证**等），**无需 EU 实体** | **零运行时能力增益**；**失去 Apple IAP**；缴 **5% Core Technology Commission**；须过 Notarization（其安全条款仍禁止下载可执行代码与容器外读写） | ⚠️ 仅作备份 |
| **日本 / 巴西** | 日本已随 iOS 26.2 开放替代市场（同 5%）；巴西有第三方市场但无 Apple 制度页 `[不确定]` | 同上 | 后续评估 |

**关键结论**：**"Full 轨"的唯一现实载体是用户自己用 Xcode 签名**（配开源构建脚本 + 文档）。原方案里"企业分发 / EU 替代市场"两条路都站不住。

---

## 9. 合规关键事实摘要

| 条款 | 关键事实 | 溯源 |
|---|---|---|
| 2.5.2 | 自包含；不得容器外读写；不得下载/安装/执行**改变 App 功能**的代码 | ARG |
| **ADPLA §3.3.1(B)** | 解释型代码**可下载**但条件严格；Apple 2026 整治引用此条 | ADPLA（2026-08-18 版） |
| **1.2（2026-02-06 修订）** | **随机/匿名聊天被明确纳入 UGC**；四项强制机制：**过滤（必须在二进制内！）、举报、屏蔽、公开联系方式** | [Apple 新闻](https://developer.apple.com/news/?id=d75yllv4) |
| 3.1.1 | 解锁 App 内功能须 IAP；**BYOK 无需 IAP**（先例：Geeps BYOK）；**自售推理额度须 IAP**；美国店面可放外链（3.1.1(a)） | ARG |
| **5.1.2(i)** | ⭐ 明文要求："**包括与第三方 AI 共享**"时必须清楚披露并**获得显式许可** | ARG |
| App Privacy | **"仅在设备上处理的数据不属于'收集'"**，无需申报 → 端侧推理的合规红利 | [App privacy details](https://developer.apple.com/app-store/app-privacy-details/) |
| 年龄分级 | 4+/9+/**13+/16+/18+**；Apple 要求把"**包括 AI 助手与聊天机器人**"计入敏感内容频率；**2026-01-31 后未更新者更新被阻止** | [9to5Mac](https://9to5mac.com/2025/07/24/apple-notifies-developers-of-new-app-store-age-rating-system/) |
| HIG 生成式 AI | **绝不能让用户误以为在与人类交互**；服务端处理要透明；不可逆操作前要获许可（非条款但审核会引用） | [HIG](https://developer.apple.com/design/human-interface-guidelines/generative-ai) |
| DPLA §3.3.11(A) | 使用 **Foundation Models** 须遵守其 Acceptable Use Requirements 并**维持合理护栏** | ADPLA |
| **整治时间线** | 2025-12 阻止 Replit/Vibecode 更新 → 2026-03-26 下架 Anything（两次）→ 2026-06 收紧 4.3(b)。**方向是收紧** | [9to5Mac 03-30](https://9to5mac.com/2026/03/30/apple-steps-up-crackdown-on-vibe-coding-apps-pulls-anything-from-the-app-store/)、[04-14](https://9to5mac.com/2026/04/14/developers-behind-vibe-coding-app-anything-detail-next-steps-after-months-long-fight-with-apple/)、[TechCrunch](https://techcrunch.com/2026/04/14/how-vibe-coding-app-anything-is-rebuilding-after-getting-booted-from-the-app-store-twice/) |
| 先例 | **a-Shell 仍在架且自带 clang + WASI-libc + wasm3/wasmkit**；Pyto 含 C/C++ 编译器；Pythonista 公开声明"不支持下载编译型模块"；iSH 曾被通知下架但**申诉后当日撤回** | 各家 App Store 页面 |

---

## 10. 在架先例矩阵（这是我们最强的论据）

| App | 本地执行能力 | 状态 |
|---|---|---|
| **a-Shell** | 本地 Unix 终端；**clang/clang++ 22.1.0 + WASI-libc（可编译 C/C++ 到 WASM 并执行）**；**wasm3 + wasmkit 两个 WASM 解释器**；Python 3.13、Lua、Perl、JS、TeX Live 2025、ffmpeg、git、rsync | 在架，近期更新 |
| **Pyto** | Python 3.10 + C/C++ 编译器 + 终端 + wasm3 | 在架 |
| **Carnets** | Python 3.13 + Jupyter，"完全本地运行"；pip 仅纯 Python | 在架 |
| **Pythonista** | Python 3.10 脚本环境；公开声明"不支持下载编译型模块" | 在架 |
| **Scriptable** | JavaScriptCore 自动化 | 在架 |
| **Working Copy** | 完整 Git；**Agent 可跑在 PCC 上** | 在架 |
| **Geeps: AI Chat BYOK** | **BYOK + OpenRouter + 自定义 OpenAI 兼容端点 + 本地模型**；一次性 IAP | 在架 |
| iSH / UTM SE | x86 模拟 / 无 JIT 解释器 | 在架（UTM SE 为 JIT-less 解释器先例） |

---

## 11. 执行运行时与库选型（核实结果）

> 这一节是 [05 工具与沙箱](05-工具系统与执行沙箱.md)、[12 数据模型](12-数据模型与持久化.md)、[08 交互](08-交互与体验设计.md) 的选型依据。评级：**生产可用 / 需自研兜底 / 仅实验 / 不可行**。

### 11.1 WebAssembly 运行时

| 运行时 | 核实事实 | 评级 |
|---|---|---|
| **WasmKit**（纯 Swift，MIT） | ⚠️ **实际最低部署目标为 iOS 18**（README 写 "iOS 12.0+"，但 `Package.swift` 为 `swift-tools-version:6.3` + `platforms: [.macOS(.v15), .iOS(.v18)]`）；Swift 6.2 起随官方工具链分发 WS 工具；支持 Bulk memory / **Fixed-width SIMD** / **Threads & Atomics** / Exception handling / Tail call / **Memory64** / Multi-value；**GC ❌**；**组件模型仍在 main 上开发**；WASI 0.1 "大部分系统调用已实现" | ✅ **生产可用（首选，但 Deployment Target ≥ iOS 18）** |
| **wasm3** | v0.9.x（2022 年后重启发版）；**iOS 为官方平台**；**Fixed-width SIMD = N/A**；README 原文：*"on some platforms (i.e. **iOS** and WebAssembly itself) you can't generate executable code pages in runtime, so JIT is unavailable."* | ✅ 生产可用（兜底） |
| WAMR | iOS 的 CMake 实值为 **AOT 0 / JIT 0 / FAST_JIT 0 / INTERP 1**；**SIMD 标注 "llvm-jit and aot only"** → **iOS 上实际无 SIMD**；**WASI P2 完全未实现**；仍残留 Linux 味（`-ldl`、共享库） | ⚠️ 需自研兜底 |
| Wasmtime | 官方平台文档：iOS "supported but **less well tested**"；Cranelift/Winch **需要运行时生成可执行内存页** → iOS 不可用；Pulley 解释器可用但"性能损失可预期" | ⚠️ 需自研兜底 |
| **Wasmer** | `examples/platform_ios_headless.rs` **整段被 `/* */` 注释掉**，`main()` 是空壳；SwiftyWasmer 已归档 | ❌ **不可行** |

**性能对照**（WasmKit 官方 CoreMark，2020 M1，release）：WasmKit 第 2 代 291 iter/s，wasmi 1321，wasmtime 11527。**现役第 3 代寄存器机比第 2 代快 7.4×（≈2150 iter/s）**，与 wasmi/wasm3 同级；相对 Wasmtime JIT **慢约 5-6×**，相对原生 C 慢一个数量级 `[不确定]`。

### 11.2 WASI userland 的实证：**a-Shell 是最完整的参考实现**

a-Shell（**App Store 在架**）原文能力：

- 内置 `clang` / `clang++` **22.1.0 + WASI-libc**，**把 C/C++ 编译成 wasm 后可直接执行**（"A complete webAssembly SDK is included"）
- 内置 **wasm3 + wasmkit** 两个解释器
- 预编译 WASI 命令（**zip / unzip / xz / ffmpeg**）通过 `pkg install` 获得
- 管道可用：`cmd | wasm prog.wasm`
- 作者原话：**"We have the limitations of WebAssembly: no sockets, no forks."**

⇒ **这直接证明**：① "随包编译器 + 随包 WASM 运行时 + 用户编译自己的代码并执行"是**已上架模式**；② 但 WASM 里没有 socket 也没有 fork → **git 与网络必须走原生**（再次支持原生 libgit2 的决策）。

### 11.3 Python：WASM 是死路，原生是正路

| 方案 | 核实事实 | 评级 |
|---|---|---|
| **CPython-on-WASM** | `python-wasi` README 原文 *"intended for **experimental use only**"*，最后提交 **2024-03**；默认单文件打包 **~150MB**；*"Many tests are currently failing due to the fact that WASI does not have support for **threads, subprocesses, or sockets**"*；无动态链接 | ❌ **死路，不采用** |
| **原生 CPython（XCFramework）** | **PEP 730 已把 iOS 列为支持平台（tier 3）**；`Python-Apple-support` 提供 XCFramework（现存发布线 **3.15-b0 / 3.14-b11 / 3.13-b15 / 3.12-b10 / 3.11-b10 / 3.10-b14**，**iOS 13+、arm64 + 模拟器**；main 分支正在构建 3.15；BeeWare 月度更新活跃至 2026-09）；**Pyto 的二进制即来自该 XCFramework**。⚠️ **官方约束**：iOS 上**没有 `python` 可执行文件、没有 REPL**；且 **App Store 要求所有二进制模块打包成 framework（`.so` 需后处理）** → **动态加载第三方 C 扩展结构性不可行，必须随包预置** | ✅ **生产可用（正路）** |
| a-Shell 的 Python | Python 3.11 + 2000+ frameworks；原文 *"you can install more packages with pip install packagename, but **only if they are pure Python**. The C compiler is not yet able to produce dynamic libraries that could be used by Python."* | ✅ 但**明确无 C 扩展** |
| Pyodide | Emscripten + JS glue，需 JS 宿主；且 **iOS Safari 的 wasm-gc 已损坏** | ⚠️ 仅实验 |
| MicroPython / Chaquopy | 无官方 iOS port / 仅 Android | ❌ 不可行 |

### 11.4 JavaScript

| 事实 | 影响 |
|---|---|
| 第三方 App **无 JIT** → JSC 退化为**仅 LLInt 解释器**（无 Baseline/DFG/FTL）。**有公开实测**：iOS 锁定模式（"仅解释器"的最佳代理）下 Speedometer 3.0 **−32%/−33%**（iPhone 15/16, iOS 18.4）、**JetStream 2 −88%**（156→19）、MotionMark 1.3 −16%、TTI +0.5-0.7s；2022 年 Speedometer 2.0 **−65%**。V8 官方 `--jitless` 在 Speedometer 2.0 上约 **−40%** | ⇒ 设计口径：**解释器模式相对 JIT 慢约 2-8×，基准越偏脚本/正则开销越大**。**不要把热路径放在 JS** |
| **WKWebView 有 JIT（独立 WebContent 进程），但拿不到它的 `JSContext`**（WebKit bug 146416）→ 只能 `evaluateJavaScript`/`postMessage` | 这是第三方 App 唯一的 JIT 通道，且**只能当"黑盒执行器"用** |
| **quickjs-ng**（**v0.16.2，2026-08-20**，活跃、无 JIT、可 SwiftPM 嵌入、可 iOS 构建） | ✅ 生产可用（需要强可控沙箱时用它） |
| **nodejs-mobile**：⚠️ **iOS 上使用 V8**（官方 CHANGELOG："Uses V8 on iOS instead of ChakraCore"）；依赖 **Node 18（2025-04-30 已 EOL）**，上游最后发布 v18.20.4（2024-10），最后提交 2025-11，capawesome fork 亦停在同版本 | ⚠️ 需自研兜底、**长期不可依赖，不随包** |
| pure-JS 工具链：isomorphic-git 需自备 fs/http 插件且有 iOS 故障记录；esbuild-wasm 曾踩 JSC 的 TDZ 性能问题（官方加 `--avoid-tdz`）；tsc/prettier 可跑但无 JIT 下耗时是最大风险 | ⚠️ 建议**预编译 + 缓存**，不实时跑 |

### 11.5 Git

| 方案 | 事实 | 评级 |
|---|---|---|
| **libgit2 原生** | libgit2 v1.9.x 生产可用；自建 XCFramework 有现成参考（`LibGit2-On-iOS` 的构建脚本、`swift-cgit2` 预编译二进制）；Working Copy 自维护 fork | ✅ **生产可用（采用）** |
| SwiftGit2 | 705★，更新缓慢；**push 支持只在第三方 fork 里补上**（`SwiftGit3`） | ⚠️ 需自研兜底 |
| wasm-git | 用 Emscripten（非 wasip1），**必须有 JS 宿主**；**无 iOS 托管案例** | ❌ 不采用 |
| 装 git 二进制 | 无 fork/exec | ❌ 不可行 |
| 凭据 | **GitHub OAuth device flow 可用**（public client 无需 secret）；GitLab device flow 现状 `[不确定]` | ✅ 最省事路径 = **PAT over HTTPS + Keychain** |

### 11.6 本地存储与检索

| 方案 | 事实 | 评级 |
|---|---|---|
| **GRDB 7.x** | 7.0 全面 Swift 6；DatabasePool/WAL、DatabaseMigrator、FTS5 external content、自定义 tokenizer、`bm25()` 排序 | ✅ **首选** |
| SwiftData | 大表内存增长、关系迁移崩溃等公开问题；**无 FTS** | ⚠️ 仅实验 → **不用** |
| ⚠️ **FTS5 中文陷阱** | **`unicode61` 会静默丢弃 CJK 字符** → 中文全文检索返回零结果且不报错。需 CJK tokenizer（如 `simple` 系列）或 **`trigram`** | **必须处理**（[07 §4.1](07-上下文与记忆引擎.md)） |
| sqlite-vec | 仍 0.1.x（曾停更，现恢复）；**ANN(DiskANN) 未完成** → 实为线性扫描；⚠️ **iOS 默认禁用 loadable extension → 必须把 C 源码编进 App 静态注册** | ⚠️ 需自研兜底 |
| ANN 替代 | USearch（SwiftPM 可用）、hnswlib.swift、VecturaKit、Accelerate `BNNS.NearestNeighbors` | ✅ 生产可用 |
| 端侧嵌入 | `NLEmbedding.sentenceEmbedding`（零下载）；`NLContextualEmbedding`（iOS 17+，需下载资产，**模拟器失败**）；Core ML MiniLM-L6（384）；BGE-small-en-v1.5（384）；MLX MiniLM（**有 pooling bug**）。**中文质量 `[不确定]`** | 见 [07 §3.2](07-上下文与记忆引擎.md) |

### 11.7 UI 构件

| 需求 | 选择 | 评级 |
|---|---|---|
| **流式 Markdown** | ⭐ **microsoft/SwiftStreamingMarkdown**（微软官方，**专为 LLM 流式输出设计**） | ✅ 生产可用 |
| Markdown 通用 | swift-markdown（**仅 parser**）；**MarkdownUI 已进维护模式** → 新开发在 **Textual** | ⚠️ 需自研兜底 |
| 代码编辑器 | **CodeEditorView**（纯 SwiftUI，TextKit 2）或 **Runestone**（成熟但 UIKit API，需自写包装） | ✅ 生产可用 |
| 高亮 | HighlightSwift / SwiftSyntaxHighlighter（Highlightr 慢、Splash 已停） | ✅ / ❌ |
| tree-sitter | **SwiftTreeSitter** + 预打包 grammar（`.scm` 查询需自行打包） | ⚠️ 需自研兜底 |
| 终端 | **SwiftTerm**（Xterm/VT100，活跃，有 DocC） | ✅ 生产可用 |
| **Diff 视图** | ⚠️ **不存在成熟的 SwiftUI 并排 diff 组件** → 用 `CollectionDifference`(SE-0240) 自研 | ⚠️ **需自研，预留工时** |

### 11.8 沙箱文件系统分层（照抄 a-Shell 的成熟做法）

a-Shell README 原文：*"In iOS, you cannot write in the `~` directory, only in `~/Documents/`, `~/Library/` and `~/tmp`. Most Unix programs assume the configuration files are in `$HOME`. So a-Shell changes several environment variables so that they point to `~/Documents`."*

| 做法 | 说明 |
|---|---|
| `$HOME` 等环境变量重映射到容器 `Documents` | 让 Unix 程序能正常工作 |
| 配置与包数据放 `Library` | 不暴露给用户 |
| `cd` 永远能回到 `Documents` | 行为可预期 |
| 外部目录用 `pickFolder`（UIDocumentPicker）→ **自动书签**，并配 `bookmark` / `showmarks` / `jump mark` / `cd ~mark` 一组命令 | 用户可管理授权目录 |
| entitlement | `com.apple.security.files.user-selected.read-write`；要出现在「文件」App 需 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` |
| 已知坑 | `startAccessingSecurityScopedResource` 必须配对、书签会失效、文件夹 UTI 选择器异常 |
| ⚠️ **绝不要**把 git worktree + `.git` 放在 iCloud Drive 同步目录 | **FileProvider 会损坏 `.git`**（有实证事故报告） |
| 可参考的开源实现 | `holzschu/a-shell` + **`holzschu/ios_system`**（命令注册为原生代码，**不做 fork/exec**）+ `holzschu/wasi-sdk` |

### 11.10 体积成本（必须写进产品决策，不能事后才发现）

**实测数据（iTunes Lookup API 一手）**：

| App | 版本/更新时间 | **App 体积** | 说明 |
|---|---|---|---|
| **a-Shell** | v2.2.1 / **2026-09-12**（唯一仍在高频更新的参考实现） | **1950 MB** | CPython 3.11 + 因 iOS 动态库规则生成 **2000+ 个 framework** |
| **Pyto** | v19.0.1 / **2024-06-09** | **930.5 MB** | CPython 3.10 同进程 C API；Numpy/Pandas 内置不可更新 |
| **Pythonista 3** | v3.4 / **2023-04-27** | **852.9 MB** | 仍在架但已停更 |

⇒ **结论：内嵌 CPython 的 iOS App ≈ 1 GB 起步；带完整工具链 ≈ 2 GB。**

**这对产品意味着什么（必须写进文档与排期）**：

| 影响 | 说明 |
|---|---|
| **首下转化率** | App Store 大体积应用的下载流失显著；**超过 200MB 的 App 在蜂窝网络下会弹出确认** → 必须准备"Wi-Fi 下载"引导与体积说明 |
| **无法用"下载运行时"规避** | 因为是 **2.5.2**：运行时**必须随包**，不能做成"首次启动下载"（那正是被禁的形态）。**所以体积是不可协商的** |
| **可选降级** | 唯一可选的降级是"**App Store 版不含原生 CPython，只含原生工具 + WasmKit**"（体积可回到数百 MB），CPython 放进 Full 轨 —— **但这会砍掉核心承诺**，必须由产品负责人拍板（[15 Q19](15-风险登记册与开放问题.md)） |
| **可用 On-Demand Resources 的部分** | 只能用于**纯数据**（示例项目、预编译的纯 Python 库集合、模型权重），**不能用于解释器本体** |



### 11.11 明确死路（设计上不要碰）

| 能力 | 结论 | 依据 |
|---|---|---|
| `fork` / `exec` / `posix_spawn` 任意二进制 | **不可行** | `Process` 是 macOS 专属；Apple 论坛明确 |
| JIT / `PROT_EXEC` / `MAP_JIT` | **不可行** | 无 iOS JIT entitlement；JIT 例外仅浏览器引擎且限 EU/JP ⇒ WAMR fast-jit/llvm-jit、Wasmtime Cranelift/Winch、Wasmer singlepass **全灭** |
| `dlopen` 下载的 `.dylib` | **不可行** | 代码签名与库校验拦截（Wasmer iOS 示例被注释掉正是此因） |
| 后台常驻守护进程 | **不可行** | BGTaskScheduler 有时限；`BGContinuedProcessingTask` 仍受限且需前台发起 |
| 原始 socket / tun / VPN | 需 `com.apple.developer.networking.networkextension` | 非默认可用 |
| `ptrace` / `task_for_pid` / `chroot` / `mount` / 未签名二进制 | **不可行** | 越狱专属 |
| EU DMA 替代市场 | 只放开**分发**与浏览器引擎，**不授予 fork/exec 或 JIT** | — |
| WASI P1 内 fork/exec | **规范本身就没有** | a-Shell："no sockets, no forks" |

---

## 12. 被证实 / 被否决 / 被修正的设计

| 设计点 | 结论 | 依据 |
|---|---|---|
| "给模型一个 shell" | ❌ **不可行**（无 fork/exec） | §5 |
| WASM 沙箱跑用户代码 | ✅ **可行且已验证**（a-Shell 更强） | §8、§10 |
| JIT 加速 | ❌ **不存在** | §4 |
| 原生工具优先 + 沙箱兜底 | ✅ **被证实为最优解** | §4、§5 |
| 端侧模型跑完整 Agent 循环 | ❌ **4096 token 装不下** | §1 |
| 端侧做"神经反射" | ✅ 被证实 | §1 |
| 离线 = 确定性运行时 + 端侧分支决策（L2 引导模式） | ✅ **新设计，源自 4096 限制** | §1 |
| "Agent 一直在后台跑" | 需要改写叙事：**前台发起 + 延续处理 + 检查点续跑** | §2 |
| 长任务主载体 = `BGContinuedProcessingTask` | ✅ 新原语，**必须用** | §2 |
| Live Activity 无限常驻 | ⚠️ **上限 12 小时**，需改写设计 | §2 |
| 静默推送可唤醒 Agent | ⚠️ 30 秒 + 每小时 2-3 条 + 不保证送达 → 不可依赖 | §2 |
| SSE 在锁屏后存活 | ❌ **必断**，改为回前台重连 | §2、§7 |
| 企业分发作为 Full 轨 | ❌ **违约**，改为 Xcode 自签 | §8 |
| EU 替代市场带来能力增益 | ❌ **零增益**且失去 IAP | §8 |
| 用"下载解释器"解决包体积 | ❌ 会踩 2.5.2 → 必须随包 | §4、§9 |
| 只靠"告知"满足第三方 AI 披露 | ❌ **必须获得显式许可**（5.1.2(i)） | §9 |
| 内容过滤可交给模型厂商 | ❌ **必须在二进制内实现**（1.2） | §9 |
| PCC 作为默认云端档 | ⚠️ **需托管 entitlement + 资格审批** → 作为可选增强 | §1.1 |
| Foundation Models 作为默认端侧后端 | ✅ 被证实（零体积、零内存、零成本） | §1 |
| Core AI（`.aimodel` + AOT） | ✅ iOS 27 正式路径，应优先于第三方运行时 | §5 |
| 适配开放的 `LanguageModel` 协议 | ✅ 战略机会 | §1 |
| App Intents 是接入 Siri 的路径 | ✅ **且是唯一路径** | §6 |
| **"Python 编译成 WASM 跑"** | ❌ **死路**（150MB、无线程/子进程/socket、实验状态）→ 改为**原生 CPython XCFramework** | §11.3 |
| "随机器一个 shell 给模型" | ❌ 不可行 → 改为**自研命令解释器 + 原生命令表**（`ios_system` 模式） | §11.2、§11.8 |
| WASM 运行时选型 | ✅ **WasmKit 首选**（纯 Swift、iOS 12+、SIMD/线程齐）；wasm3 兜底；**Wasmer 不可行** | §11.1 |
| "git 用 wasm 版" | ❌ 不采用（WASI 无 socket，wasm-git 需 JS 宿主且无 iOS 案例）→ **原生 libgit2** | §11.5 |
| JS 里跑热路径 | ⚠️ 无 JIT（仅 LLInt）→ 热路径必须原生 | §11.4 |
| Node 随包 | ❌ 不随包（iOS 上仍是 JSC 解释器级 + Node 18 EOL） | §11.4 |
| **FTS5 用 `unicode61`** | ❌ **中文会静默失效** → 必须用 CJK tokenizer 或 `trigram` | §11.6 |
| sqlite-vec 直接用 | ⚠️ 需**静态注册**（iOS 禁 loadable extension），且 ANN 未完成 | §11.6 |
| SwiftData 作为主存储 | ❌ 仅实验 + 无 FTS | §11.6 |
| 并排 Diff 组件 | ❌ 没有成熟 SwiftUI 实现 → **自研，需预留工时** | §11.7 |
| 流式 Markdown | ✅ **SwiftStreamingMarkdown**（微软，专为 LLM 流式设计） | §11.7 |
| 把 `.git` 放 iCloud Drive | ❌ **会被 FileProvider 损坏** → 工作区默认本地，UI 明确警告 | §11.8 |
| 端侧模型尺寸承诺 | ⚠️ 收窄为 **≤2-3B Q4（1-2GB 权重）**；≥8B 不承诺 | §11.3、[13 §4.4](13-端侧模型与性能预算.md) |
| Core AI 作为 1.0 依赖 | ⚠️ **不作为**（新框架 + KV 深度墙报告）→ 增强项 | [13 §4.5](13-端侧模型与性能预算.md) |
| 中文在端侧窗口里的实际容量 | ⚠️ 中日韩约 **1 字符/token** → 4096 窗口对中文只有约 2-3 千字 | §1 |

---

## 13. 仍未确认 / 需要实测的清单

| # | 待确认项 | 打算怎么确认 |
|---|---|---|
| 1 | `BGProcessingTask` 与延续处理任务的实际时长（Apple 未公布） | 真机 48 小时埋点观测 |
| 2 | 各机型上的 jetsam 实际内存上限（Apple 未公布） | `os_proc_available_memory()` 采样 + 压力测试（参考实测：6GB 设备约 3.12GB，加 entitlement 约 4.20GB） |
| 3 | 端侧模型 tokens/s 与内存峰值（按机型） | 首次启用时的探针实测，写入"本机画像"（参考实测：MLX Qwen3-0.6B-4bit 158.8 tok/s、Gemma-4-E2B QAT 61.1 tok/s @497MB、Core AI 47.1 tok/s；**600 秒持续生成后 GPU 掉 50-62%、ANE 仅掉 33%**） |
| 4 | 键盘扩展 60MB 上限是否属实 | 真机测试（非 Apple 公布） |
| 5 | **端侧 embedding 的中文质量** | **必测**：用中文语料做 recall@10 评测，否则中文项目语义检索可能几乎不可用 |
| 6 | WASM 解释器的真实性能倍数 | Spike 基准（相对 Wasmtime JIT 慢约 5-6× 为官方 CoreMark 推算） |
| 7 | PCC entitlement 的审批难度与配额 | 尽早提交申请（M-1 期间）；注意有**下载量门槛**与**按 iCloud 账号的每日配额** |
| 8 | 内容过滤的误伤率（对代码场景） | 红队 + 真实会话回放 |
| 9 | App Review 对"随包解释器/编译器"的实际态度（2026 收紧后） | ⭐ **尽早提交一个最小可审版本试探**，不要等到 1.0 |
| 10 | 中转站的 Cloudflare 挑战出现频率 | 实际接入 5-10 个常见中转观测 |
| 11 | `NLContextualEmbedding` 资产下载的成功率与耗时 | 真机多网络条件测试 |
| 12 | MLX MiniLM 的 pooling bug 修复方案 | 自行 patch 或用替代嵌入模型 |
| 13 | Core AI 的 KV 深度墙（有报告 2048 即触发 jetsam） | 真机实测后再决定是否纳入 1.0 |
| 14 | 中文 CJK 分词器在 FTS5 上的性能与召回 | 中文语料基准 |

---

**相关文档**：[附录 A 渠道与模型事实表](附录A-渠道与模型事实表.md) · [11 合规与分发](11-AppStore合规与分发.md) · [10 后台执行](10-后台执行与可靠性.md) · [13 端侧模型](13-端侧模型与性能预算.md) · [05 工具与沙箱](05-工具系统与执行沙箱.md)
