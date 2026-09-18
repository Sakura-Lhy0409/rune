# 18 · macOS 开发基线与项目现状

> 核验时间：2026-09-18（本机 CST；对应洛杉矶 2026-09-17）。代码基线：`30869b6`。
> 依据：仓库设计与交接文档、SwiftPM 依赖声明、核心实现及调用点、实际构建和测试结果。
> 本文记录本地已验证的能力；设计目标与研究材料不视为已经实现的产品功能。
> **后续进展**：本文保留 C40 的接管快照。C41 已实现 RuneNet 第一片，最新能力和待接线项见 [网关文档 §15](06-模型网关与中转站.md#15-实现回写runenet-第一片c41) 与 [PROJECT_STATE](../PROJECT_STATE.md)。

## 1. 项目目标与工程边界

Rune（符文）是 iPhone/iPad 上的通用 Agent。推理由用户配置的模型服务提供，工具执行、文件操作、运行时状态与存储在设备内完成。产品已决定采用一次性买断与 BYOK，并支持自定义渠道/中转站。

开发时需要保留这些约定：核心保持零外部依赖；工具文件访问走 VFS；权限按路径和能力范围判定；写权限不自动包含删除；不可信内容不能升级为用户授权；成本用整数微美元；有副作用的步骤按意图、执行、结果分开记录；非幂等操作的未知结果需要用户决定。

源码、注释、UI 文案以中文说明，代码标识符用英文。改动先查 [PROJECT_STATE](../PROJECT_STATE.md)，避免重做已落地的组件。

## 2. 模块现状

| 模块 | 已存在的实现 | 尚缺的连接或能力 |
|---|---|---|
| RuneKernel | 41 个源文件；运行时、规划、审批、目标、工作流、上下文、成本、协议适配、路由、VFS、补丁、搜索、shell/沙箱策略 | 属于可测试的核心逻辑，不意味着全部平台执行器已存在 |
| RuneStore | GRDB 事件表、迁移、事件往返、按会话序号和哈希串链 | 会话/Turn/Goal 投影表、检查点落盘、检索索引、App 接线 |
| RuneNet | 包声明与实现清单 | URLSession 传输、连接生命周期、取消、实际退避、出口策略 |
| RuneGateway | 包骨架；协议/路由纯逻辑目前在 Kernel | 平台网关、凭据读取与上层装配 |
| RuneContext | 包骨架；装配/压缩纯逻辑目前在 Kernel | 持久化记忆、检索与 L3 模型调用 |
| RuneBench | 包骨架；真实 FS/内存 VFS 已在 Kernel | 用户目录书签、持久化制品和快照、CPython 宿主 |
| RuneVM | 包骨架 | WasmKit 执行器和资源限制落实 |
| RuneTools | 包骨架；文件/搜索执行器已在 Kernel | 执行、网络、iOS 原生工具 |
| RuneCore | 包骨架 | 异步编排、逐步落盘、模型接入、生命周期和恢复 |
| RuneMCP | 包骨架 | MCP 客户端/服务端 |
| RuneUI | 包骨架；最小 UI 暂在 Apps/Rune | 会话、审批、Diff、语音与移动端交互 |
| Apps/Rune | SwiftUI 演示、真实文件操作、时间轴、UI 冒烟测试 | 用户输入与真实模型、生产存储、完整产品界面 |

11 个包中，9 个仍仅有骨架。构建全部通过不等于这些模块已经实现。

`LocalToolExecutor` 实际有 **15 个工具分支**：历史文档中的 14 个文件/检索工具，另有 `read_artifact` 制品读取。不要把旧的「14/86」直接当成今天的完整执行器统计。

## 3. 当前真实调用链

```text
RuneApp → RootView → RuneEngine.runDemo（MainActor，同步）
                         ├─ ScriptedModel（固定的工具调用）
                         ├─ TurnRunner.run
                         │    ├─ ToolRegistry / PolicyEngine / ToolScheduler
                         │    └─ LocalToolExecutor → FileManagerVFS
                         │                            └─ Documents/RuneDemo
                         └─ 运行结束后写入内存 EventLog → 校验 → RunReport → UI

RuneEventStore（磁盘）        尚未被 App 调用
ModelClient / RequestBuilder 尚未被 App 调用
```

演示中的文件确实写入磁盘；事件日志仍是内存对象，制品使用 `InMemoryArtifactStore`。App 在整个 Turn 跑完后才收集事件，不是每一步先持久化意图再执行。内核恢复测试已经覆盖逻辑断点，**App 被系统杀掉后冷启动恢复**仍需单独落地和验收。

## 4. 下一阶段最需要注意的接线边界

1. **复用 SSEParser**：`RuneKernel/StreamParsing.swift` 已处理字节增量、UTF-8 分片、心跳和帧结束。`RuneNet` 的清单仍写「实现解析器」，实际应复用已有解析器，补网络传输。
2. **同步边界需要明确处理**：`ModelTransport.send` 返回完整 `Data`，`TurnRunner.Dependencies.modelEvents` 返回事件数组；当前 App 引擎在 MainActor 上同步调用。接 URLSession 时必须设计异步、取消与界面事件消费，不能在主线程等待整段网络响应。
3. **请求检查要真正接入**：`RequestBuilder` 已有出站检查，但 App 尚未使用；`ModelClient` 直接编码传入的 `ChatRequest`。真实发送路径需要确保经过出站检查。
4. **退避决策尚无计时执行**：`ModelClient` 在重试分支直接 `continue`，注释把等待交给传输/调度层。接网时要落实等待、取消以及 Retry-After，避免即时连发。
5. **去重尚无响应重放**：当前命中只返回空事件与 `wasDeduplicated`，上层还要提供缓存结果重放，不能把它当成已有完整答案。
6. **落盘必须处于副作用之前**：以 `TurnRunner.step` 为边界保存事件与恢复状态，再推进执行；不能把演示中的事后收集方式直接用于生产。
7. **平台执行器尚未引入**：当前唯一远程 SwiftPM 依赖是 GRDB（本机解析到 7.11.1）。CPython/WasmKit/JSC 宿主属于待开发功能，不是安装桌面 Python/Node 就能获得的 iOS 能力。

## 5. 当前 macOS 环境

| 项目 | 实测结果 |
|---|---|
| 主机 | Darwin 25.6.0，Apple Silicon arm64 |
| Xcode | 26.6（17F113） |
| Developer 目录 | `/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.3.3，arm64-apple-macosx26.0 |
| iOS SDK / 本次模拟器运行时 | 26.5 / 26.5 |
| XcodeGen / GitHub CLI | 2.46.0 / 2.101.0 |
| Python / PyYAML | 3.11.9 / 6.0.3 |
| SwiftPM 外部依赖 | GRDB.swift 7.11.1；已解析并构建 |
| Git 权限位 | `core.fileMode=false`，保留 Windows 迁移后的既有设置 |
| GitHub 仓库权限 | API 返回 `pull/push/admin=true`；此前「只有 pull」的状态已过时 |

当前构建、审计、模拟器和 IPA 打包所需依赖已经齐全，本轮无需安装额外软件。Node/npm/Docker 不属于现有工程的构建依赖。

工作开始时已有 4 份未跟踪 `Package.resolved`（Context/Core/Store/UI），原样保留；生成的 Xcode 工程、构建缓存和 IPA 按既有 gitignore 管理。

仓库权限查询不等于已执行推送，也不验证分支保护规则。本轮没有提交或推送。

## 6. 验证结果与复现

| 检查 | 结果 |
|---|---|
| `bash Tools/ci.sh all` | 退出 0；11 包构建通过 |
| RuneKernel | 1032 项测试、144 个 suite 通过 |
| RuneStore | 8 项测试、3 个 suite 通过 |
| 审计 | 核心依赖、文档链接、中文引号、CI YAML 结构全部通过，未跳过 Python 检查 |
| iPhone 17 Pro / iOS 26.5 UI 冒烟 | 1 项测试通过：启动、运行、事件链校验、真实文件修改可见 |
| `bash Tools/ci.sh ipa` | Release 构建成功；未签名 IPA 1,852,049 字节，ZIP 完整性通过 |

从仓库根目录执行：

```bash
bash Tools/ci.sh all
xcodegen generate --spec Apps/Rune/project.yml
xcrun simctl list devices available
xcodebuild test \
  -project Apps/Rune/Rune.xcodeproj -scheme Rune \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO \
  -derivedDataPath Apps/Rune/build \
  CODE_SIGNING_ALLOWED=NO
bash Tools/ci.sh ipa
```

模拟器名称和版本以本机 `simctl list` 为准。当前工程最低 iOS 18，已安装的 iOS 17.4 模拟器不能用于此工程。

本轮日志放在本机 `/tmp/rune-environment-check/`（临时目录，不承诺长期保留）：`all.log`、`simulator.log`、`ipa.log`，以及 `Smoke-20260918-122811.xcresult`。产物为 `Apps/Rune/Rune-unsigned.ipa`。

## 7. 后续验收顺序

先完成 RuneNet，并通过本地可控 HTTP/SSE 传输测试验证分片、取消、超时、重定向出口和重试；随后由 RuneCore 把真实模型、逐步持久化与 App 生命周期接起来。第一条产品验收链应是：用户输入 → 模型调用工具 → 文件实际改变 → 中途退出 → 重新启动后安全恢复。

真实渠道联调需要用户配置 API key；真机安装需要配置 Apple 签名。这两项尚未验证。UI 完整化、其余执行器、后台续跑、记忆和 MCP 按既有路线逐层推进。
