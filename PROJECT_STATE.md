# PROJECT_STATE —— Rune 开发续接文档

> ⚠️ **这是整个项目最重要的文件。任何新会话、任何 Agent、任何人类协作者的第一件事就是读完它。**
> **它必须始终保持在 300 行以内**（够短才读得完）。详细历史放 [`docs/进度日志.md`](docs/进度日志.md)，本文件只保留"现在在哪、接下来做什么、别重复踩什么坑"。

---

## 0. 更新协议（硬性要求，不可跳过）

| 时机 | 必须做的事 |
|---|---|
| **每完成一个可验证的里程碑**（能 build + 能 test 通过） | ① 更新 §2 状态快照 ② 更新 §5 已完成 ③ 在 `docs/进度日志.md` 追加一条 |
| **每次感觉上下文快到上限 / 准备长时间工作之前** | **先更新本文档**，把"脑子里有但还没落盘的东西"全部写下来 |
| **每次做出新的技术决策** | 写进 §4（含理由），避免下一轮重新讨论 |
| **每次踩到坑** | 写进 §8（现象 + 原因 + 解法），避免重复踩 |
| **每个新会话开始** | 先读本文档 → 再读 §7 下一步 → 然后动手。**不要从零重新探索代码库。** |

**反向纪律：动手前先查 §5 与 §10；§5 里有的东西不要再实现一遍。**

---

## 1. 项目一句话

**Rune（符文）**：完全在 iPhone/iPad 本地运行的通用 Agent。模型可走云端 API（BYOK，含中转站），但**工具循环、文件系统、代码执行、Git、检索、记忆全部在设备上完成**，没有任何远端执行路径。
完整设计见 [`docs/`](docs/)（18 份文档，已完成）。**当前正在把设计变成代码。**

---

## 2. 状态快照

| 项 | 值 |
|---|---|
| **更新日期** | 2026-09-17 |
| **当前阶段** | **M0 已完成 ✅ → 进入 M1 可用内核** |
| **当前里程碑** | M1-2：协议适配器（请求序列化 + SSE/NDJSON 解析 → ModelEvent） |
| **上一个完成的里程碑** | ✅ **M1-1：ToolScheduler**（并行分桶 + 冲突检测 + 预算）（282 测试全绿） |
| **已完成里程碑** | ✅ M0 全部（85→122→172→212→249→**258 出口验收达成**）→ ✅ **M1-1 ToolScheduler（282）** |
| **阻塞项** | 无 |
| **本机可验证范围** | ✅ 平台无关的 Swift 代码（Kernel / 补丁 / 检索 / 网关 / 策略 / **Turn 循环**）<br>❌ iOS 专属（UI / Live Activity / Core ML / VFS 真实文件系统 / 沙箱 / GRDB / JSC）—— 需 macOS |

### 进度条

```
设计文档      ████████████████████ 100%
M0 地基       ████████████████████ 100%   ✅ 出口验收已达成
M1 可用内核   ████░░░░░░░░░░░░░░░░░  20%   ← 当前
M2 移动体验   ░░░░░░░░░░░░░░░░░░░░░   0%
M3 多渠道     ░░░░░░░░░░░░░░░░░░░░░   0%
M4 端侧+记忆  ░░░░░░░░░░░░░░░░░░░░░   0%
M5 上架准备   ░░░░░░░░░░░░░░░░░░░░░   0%
```

### 🎯 M0 出口标准达成情况（docs/14 §2）

> 原文：「在测试壳里，模型能自主完成"修一个简单的失败单测"，并在中途被杀后正确恢复。」

| 验收项 | 结果 |
|---|---|
| 模型自主完成"读 → 改 → 跑测试" | ✅ 工具顺序 `grep_search → read_file → apply_patch → run_tests`，bug 真被修好 |
| 中途被杀后正确恢复 | ✅ **对 0..40 每一个切断点**验证：恢复后最终文件状态与基线**完全一致**，且**补丁只实际改动一次**（无重复副作用） |
| 非幂等操作不自动重做 | ✅ 结果未知时进入 `awaitingApproval`，明确告知"是否已生效无法确定" |
| 事件日志完整可校验 | ✅ 哈希链逐条衔接（`previousHash == 上一条.hash`） |

### 包结构现状

| 包 | 状态 | 本机可测 |
|---|---|---|
| `RuneKernel` | ✅ **18 个源文件 / 282 测试** | ✅ |
| `RuneNet` `RuneStore` `RuneVM` `RuneBench` `RuneGateway` `RuneContext` `RuneCore` `RuneTools` `RuneMCP` `RuneUI` | ⬜ 骨架已建（`Package.swift` + 带实现清单的占位文件） | 部分 |

---

## 3. 环境事实（本机，**这些坑已经踩过，别再踩**）

| 项 | 值 |
|---|---|
| 工作目录（真实） | `D:\项目\ios平台agent` —— **含中文** |
| **ASCII junction** | ⭐ `C:\Users\MSI-NB\rune-ws` → 指向上面那个真实目录（`mklink /J`） |
| **构建命令** | ⭐ `pwsh -NoProfile -File Tools\rune.ps1 build RuneKernel`<br>`pwsh -NoProfile -File Tools\rune.ps1 test RuneKernel` |
| Swift 工具链 | ✅ **6.3.3 for Windows**（`x86_64-unknown-windows-msvc`），满足 WasmKit 的 Swift 6.3 要求 |
| MSVC | VS 2022 Build Tools，**必须经 `vcvars64.bat` 激活**（`link.exe` 不在 PATH）。脚本已处理 |
| python / node / cmake | ✅ 可用；ninja ❌ 未装（wasm 构建时才需要） |
| git | ✅ 已初始化（首次提交 `fee5338`）。`core.autocrlf=false` + `.gitattributes` 强制 LF（**补丁引擎的换行保真测试依赖这一点**）。`research/` 标记为 `-text -diff` 且**故意提交**（它是证据链） |
| CPU | 32 核 |
| **不能做的事** | 无法构建 iOS App、无模拟器、无法验证 SwiftUI / Live Activity / AVFoundation / Core ML |

### ⚠️ `swift build` / `swift test` 在本机**不可用**

**症状**：能加载 manifest、能生成构建图，但在真正调用 swiftc 编译目标时**静默退出（exit 1，无任何错误信息）**。
**已排除的原因**：中文路径、工具链损坏、管道被禁、batch mode、索引库、`--use-integrated-swift-driver`、ASCII junction。
**结论**：SwiftPM 在本环境的**子进程执行层**有问题，**与我们写的代码无关**（同一条 swiftc 命令手动执行完全成功）。
**对策**：`Tools/rune.ps1` 自己用 swiftc 驱动构建与测试（RuneKernel 零依赖，因此很简单）。
**在 macOS 上开发时可改回标准 `swift build` / `swift test`；本机请一律走 `rune.ps1`。**

---

## 4. 已确定的决策（不要重新讨论）

### 4.1 用户已拍板的产品决策

| 编号 | 决策 |
|---|---|
| **Q19** | App Store 版**包含**原生 CPython（接受 1–2GB 体积；只用 On-Demand Resources 剥离纯数据） |
| **Q15** | 接受"模型生成的 Python 在 CPython 中执行"，但必须配**来源分级 + 全 API 包裹 + 红队验证** |
| **Q2** | 商业模式：**一次性买断 + 纯 BYOK**（不卖额度、不运营中转、不做外部购买引导） |
| **Q16** | 内容过滤只作用于**面向人的自然语言输出**（代码块与文件内容豁免） |
| **Q17** | Diff 视图：1.0 做简化版，1.1 再自研完整版 |
| **Q18** | `.rune/libs` 用户自带库路径**固定为公开约定** |
| **Q20** | **预置"移除下载能力"降级开关**（应对审核波动） |
| 约定 | 文档/注释/UI 文案用中文；代码标识符用英文 |

### 4.2 开发中做出的技术决策（含理由）

| 日期 | 决策 | 理由 |
|---|---|---|
| 09-17 | `RuneKernel` 保持**零依赖**（只用 Foundation + 标准库），并**自己实现 SHA-256** | CryptoKit 是 Apple 专属、swift-crypto 是外部依赖，都会破坏"核心可在任意平台测试"。SHA-256 仅用于完整性校验与指纹，不用于加密（加密走 Keychain/Secure Enclave） |
| 09-17 | 用 **swift-testing**（`import Testing`）而非 XCTest | Swift 6.x 内置、跨平台一致、本机可跑 |
| 09-17 | 自研 `JSONValue`（手写解析器）而不用 `JSONSerialization` | 需要①Int/Double 区分（大整数丢精度）②带偏移量的可诊断错误③深度限制④**确定性序列化（键排序）**——后者是请求指纹去重与幂等的前提 |
| 09-17 | 金额一律用**整数微美元** | 浮点累加会漂移，而用户对账单极其敏感（有测试守护：累加 1000 次仍精确） |
| 09-17 | **写权限不蕴含删除权限** | 删除的破坏性远大于写入，不能因为"能写"就"能删"。`fsWrite` 蕴含读，但不蕴含 delete；delete 必须显式授权 |
| 09-17 | 错误模型按"**谁来处理**"分类（transient/budget/capability/approval/sandbox/model/fatal/userAbort） | 分类的唯一目的是决定：自动重试 / 暂停存检查点 / 直接拒绝 / 请求审批 / 让模型自我修正 / 引导修复 / 静默 |
| 09-17 | 事件 payload 用 `JSONValue` 而非强类型 | **新增事件类型不需要改表结构** —— 这是事件溯源在移动端的关键工程优势（schema 演进成本极低） |
| 09-17 | **读 `/sys` 不需要能力令牌** | `/sys` 是运行时自己暴露的元数据（版本、设备能力、限额、已授予能力清单），不是用户数据。模型需要它来判断"我还能做什么"，若也要授权就是纯粹的摩擦。**但写 `/sys` 一律拒绝。** |

---

## 5. 已完成清单（✅ = 有验证方式）

| # | 项 | 产出 | 验证 |
|---|---|---|---|
| D1 | ✅ 设计文档集（18 份，6785 行） | `README.md`、`docs/01`–`15`、`docs/附录A/B` | 内部链接校验通过；事实均带出处 |
| D2 | ✅ 事实取证归档 | `research/`（465 份）+ `research/README.md` | — |
| C1 | ✅ 续接机制 | `PROJECT_STATE.md`、`docs/进度日志.md` | 本文件 |
| C2 | ✅ **本机构建/测试闭环** | `Tools/rune.ps1` | `rune.ps1 info` / `build` / `test` 均可用 |
| C3 | ✅ **`RuneKernel` 零依赖核心**（9 个源文件） | `Packages/RuneKernel/Sources/RuneKernel/` | **85 个测试全绿** |
| C3.1 | ├ `JSONValue` + 手写 JSON 解析器 | `JSONValue.swift` | 解析/转义/代理对/canonical 确定性/错误偏移/深度限制/Codable 往返 |
| C3.2 | ├ `SHA256` + 指纹（请求/执行/事件链） | `SHA256.swift` | NIST 向量、流式=一次性、指纹顺序无关 |
| C3.3 | ├ 信任模型与污点传播 | `Trust.swift` | 指令性判定、污点标记、人类专属区 |
| C3.4 | ├ 内容块 / 消息 / 制品 / 用量 / 成本 | `Content.swift` | 工厂方法、成本整数累加、估算标记 |
| C3.5 | ├ 工具规格 / 错误 / 全部工具名常量 | `Tool.swift` | 自我修正性判定、schema 序列化、风险分级 |
| C3.6 | ├ `VFSPath` + 出口规则 + 能力令牌 | `Capability.swift` | **`..` 逃逸拒绝、组件级 `isWithin`、域名后缀点边界、令牌过期、写不蕴含删** |
| C3.7 | ├ 统一错误模型 | `Errors.swift` | 静默性判定、熔断三选一、沙箱中文提示 |
| C3.8 | ├ 计划 / 目标（含阻塞纪律） | `Plan.swift` | **偏离判定（改目标/新增危险步骤/超支 150%）、连续 3 轮才可标阻塞** |
| C3.9 | └ 事件与哈希链 | `Event.swift` | **篡改可检测、键序无关、Codable 往返** |
| C4 | ✅ **`apply_patch` 补丁引擎 + `edit_file` 引擎** | `TextPatch.swift` | **37 项新测试**（累计 122 全绿） |
| C4.1 | ├ 双格式解析：Rune 原生 + **标准 unified diff** | 同上 | 相对路径、`a/`/`b/` 前缀、`/dev/null` 语义、`\ No newline`、元数据行 |
| C4.2 | ├ 四级模糊匹配 + 唯一性强制 | 同上 | 行尾空白 / 缩进 / 全部空白；**匹配多处必须拒绝并给出全部候选行号** |
| C4.3 | ├ **原子性**（失败即整体不落地） | 同上 | 一个 hunk 失败 → 其他文件也不改 |
| C4.4 | ├ 换行保真（CRLF / LF / 无末行换行） | 同上 | 三向测试；替换文本的换行风格跟随目标文件 |
| C4.5 | ├ 诊断可执行（供模型自我修正） | 同上 | 找不到 → 给最近位置；歧义 → 给全部候选；重叠 → 提示合并 |
| C4.6 | └ `TextEdit.replaceUnique` | 同上 | 唯一才替换；多处/找不到都拒绝（**绝不悄悄全改**） |
| C5 | ✅ **检索子系统** | `GlobMatcher.swift` · `IgnoreRules.swift` · `GrepEngine.swift` | **50 项新测试**（累计 172 全绿） |
| C5.1 | ├ `GlobPattern`（通配匹配） | `GlobMatcher.swift` | `**` 跨层、`?`、`[a-z]`/`[!x]`、`{a,b}`、锚定、目录专用、**默认大小写不敏感** |
| C5.2 | ├ `IgnoreRules`（gitignore 语义） | `IgnoreRules.swift` | 注释/空行、`!` 取反、**最后匹配胜出**、祖先级联忽略、**内置默认清单**、带得出"是哪条规则" |
| C5.3 | ├ `PathFilter`（两层忽略 + include/exclude） | 同上 | 项目规则一律生效；**内置默认在显式 include 时让位** |
| C5.4 | └ `GrepEngine`（搜索核心） | `GrepEngine.swift` | 字面量/正则、整词、**字面量预筛**、二进制跳过、上下文行、三种输出模式、**预算截断且如实告知**、确定性排序、中文定位 |
| C6 | ✅ **10 个包的骨架** | `Packages/Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/` | 每个含正确的 `Package.swift`（依赖声明已校验）+ 带**实现清单**的占位文件 |
| C7 | ✅ **网关纯逻辑** | `ToolCallAssembler.swift` · `ProviderQuirks.swift` | **40 项新测试**（累计 212 全绿） |
| C7.1 | ├ `JSONRepair`（修复模型给的坏 JSON） | 同上 | 截断/未闭合/尾逗号/悬空键/尾转义/中文标点；**修不好返回 nil**（交由修正性重试） |
| C7.2 | ├ `ToolCallAssembler`（分片拼装） | 同上 | 四种协议形态；**并行 index 交错**；7 种脏情况；**绝不重复产出**；诊断可观测 |
| C7.3 | ├ `ProviderQuirks`（渠道差异声明） | `ProviderQuirks.swift` | 协议族 / 思考链字段 / **回传策略** / 缓存风格 / 流式用量 / 坑清单（UI 可展示） |
| C7.4 | └ `CostCalculator`（缓存经济学） | 同上 | 缓存读 0.1× / 写 1.25× / 低谷折扣 / 长上下文倍率 / **省下多少钱**（正反馈） |
| C8 | ✅ **`PolicyEngine` 策略引擎** | `PolicyEngine.swift` | **37 项新测试**（累计 249 全绿） |
| C8.1 | ├ `TrustDial`（信任刻度盘五档） | 同上 | 能力边界递增、**每档自带"允许做什么"说明**、人类专属 |
| C8.2 | ├ `ApprovalRequirement`（审批分级） | 同上 | 无需/内联/一键/看细节/生物识别/生物识别+确认词；**哪些可"记住"** |
| C8.3 | ├ `HumanOnlyZoneDetector` | 同上 | 凭据/策略/审计/信任档/哈希锚点；**任何信任档都拒绝写**；拒绝说明可执行 |
| C8.4 | ├ `EgressGuard`（SSRF 防护） | 同上 | 私有网段（含 **169.254.169.254 云元数据**）/ scheme 白名单 / **重定向链逐跳校验** |
| C8.5 | └ `PolicyEngine.evaluate`（六层判定） | 同上 | 人类专属区 → 信任档 → 能力令牌 → SSRF → **污点** → 风险分级审批 |
| C9 | ✅ **最小 Turn 循环（M0 出口验收达成）** | `TurnRunner.swift` | **9 项验收测试**（累计 258 全绿） |
| C9.1 | ├ `TurnStatus` / `TurnState` / `StepRecord` / `Checkpoint` / `PendingToolIntent` | 同上 | 全部 Codable（可持久化）；状态可判定"是否稳定可挂起" |
| C9.2 | ├ **步进式状态机**（`step()` 推进恰好一件事） | 同上 | 任意两步之间被杀都能恢复；`start → reasoning → dispatching → executing → …` |
| C9.3 | ├ **三步落盘协议**（写意图 → 执行 → 写事实） | 同上 | 恢复时按幂等性决定"重做"或"问用户" |
| C9.4 | ├ **显式恢复标记** `wasRestored` | 同上 | ⚠️ 仅凭状态无法区分"正常下一步"与"崩溃残留"，必须由运行时显式告知 |
| C9.5 | ├ 预算熔断（轮次 / 工具数 / 成本） | 同上 | **在调用之前**检查，而不是烧完钱之后 |
| C9.6 | ├ 工具名幻觉兜底 + 可执行错误回灌 | 同上 | 相似度不足时**不猜**（宁可不给建议，也不要给错建议） |
| C9.7 | └ 路径提取 → 策略引擎 | 同上 | ⚠️ 不做这一步，能力令牌的**路径级授权形同虚设** |
| C10 | ✅ **`ToolScheduler` 工具调度器** | `ToolScheduler.swift` | **22 项新测试**（累计 282 全绿） |
| C10.1 | ├ 分波（wave）：波内并行、波间串行 | 同上 | 只读并行；serialPerPath 保守串行；xclusive 单独成波 |
| C10.2 | ├ **路径冲突检测**（含多文件补丁的全部路径） | 同上 | ⚠️ 只取第一个路径就漏检；目录与其子文件也算冲突 |
| C10.3 | ├ ⚠️ **执行类工具与写操作冲突** | 同上 | 边跑 un_tests 边 pply_patch → 测试读到半成品 → **假失败** |
| C10.4 | ├ 审批项批量摘出 | 同上 | 手机上一次弹一个审批是灾难；审批不阻塞只读操作 |
| C10.5 | ├ 预算延后（不静默丢弃） | 同上 | 超出单轮上限的调用进 deferred 并在诊断里说明 |
| C10.6 | └ 不重排模型给出的顺序 | 同上 | 模型有时依赖"先建目录再写文件" |

---

## 6. 进行中

| 项 | 状态 | 备注 |
|---|---|---|
| M1-2 协议适配器 | 🚧 即将开始 | 请求序列化 + SSE/NDJSON 解析 → ModelEvent（本机可测） |
| M1-3 计划与审批 | ⬜ 未开始 | PlanEngine + ApprovalBroker |
| M1-4 Goal 引擎 | ⬜ 未开始 | 跨轮推进 + 阻塞纪律 |

---

## 7. 下一步（M1 可用内核）

**M1 的目标（docs/14）**：完整 AgentRuntime（计划、并行调度、预算、修正性重试）+ 工具集扩到 25 个 + 审批机制 + SwiftUI 最小可用。
**在 Windows 上能做的**（按优先级）：

### 立即（M1-2，纯逻辑、本机可测，**M3 的地基**）
1. **协议适配器**（`RuneGateway` 的核心）：
   - 请求侧：归一化 `ChatRequest` → OpenAI Chat / OpenAI Responses / Anthropic Messages / Gemini 四种请求体
   - 响应侧：四种 SSE 事件流 + Ollama NDJSON → 归一化 `ModelEvent`
   - **思考链回传**：按 `ProviderQuirks.reasoningReplay` 决定是否回传（写错直接 400）
   - **缓存断点规划**：层 1+2 字节稳定 + Anthropic 最多 4 个断点 + OpenAI 必须显式打点
   - 全部用**录制的真实响应**做夹具（docs/06 §13.1 的 cassette 清单：10 类必测样本）
2. **把 `ToolScheduler` 接进 `TurnRunner`**：目前 runner 是逐个调度的，应改为按波次调度
   （并在事件里记录波次结构，供 UI 显示"3 个只读操作并行中"）。

### 随后（M1-3 / M1-4）
3. **`PlanEngine` + `ApprovalBroker`**：计划生成、偏离检测（`Plan.requiresUserConfirmation` 已就位）、
   审批请求的批量与"记住选择"。
4. **`GoalEngine`**：跨轮推进 + 阻塞纪律（`Goal` 类型已就位，缺驱动器）。

### 需要 macOS 才能做（不要在 Windows 上浪费时间）
6. `RuneStore`（GRDB + 迁移 + 哈希链落盘）—— ⚠️ FTS5 必须用 CJK 分词器或 `trigram`
7. `RuneNet`（真实 URLSession + SSE 传输 + 出口代理）
8. `RuneBench`（VFS 真实文件系统映射 + security-scoped bookmark + 原生 CPython 集成）
9. `RuneVM`（WasmKit 沙箱）
10. 任何 SwiftUI / Live Activity / Core ML

---

## 8. 已知陷阱（不要重复踩）

### 8.1 本机环境陷阱

| # | 陷阱 | 现象 | 解法 |
|---|---|---|---|
| E1 | **`swift build` / `swift test` 静默失败** | 只输出 "Building for debugging…" 然后 exit 1，无错误 | **用 `Tools/rune.ps1`**（见 §3） |
| E2 | **路径含中文导致 swiftc 打不开文件** | `error opening input file 'D:\??Ŀ\ios??agent\…'` | **走 ASCII junction**；脚本已自动处理；生成 .bat 时用 `chcp 65001` + UTF-8 |
| E3 | **`link.exe` 不在 PATH** | manifest 编译失败 | 所有 swiftc 调用都要先 `call vcvars64.bat`（脚本已处理） |
| E4 | **运行测试 exe 报 0xC0000135** | 进程静默退出（STATUS_DLL_NOT_FOUND） | PATH 必须含 **Swift Runtimes\6.3.3\usr\bin** 与 **Testing-6.3.3\usr\bin64**（注意是 `bin64`，不是 `x86_64`——后者只有 .lib） |
| E5 | `Testing.__swiftPMEntryPoint` 有**两个重载** | `ambiguous use of '__swiftPMEntryPoint'` | 用显式类型标注：`let code: CInt = await ...` |
| E6 | 写入 `C:\` 根目录被沙箱拒绝 | `Access is denied` | 临时文件放 `$env:USERPROFILE` 或仓库内 |
| E7 | `data as [UInt8]` 在跨平台下不可靠 | `cannot convert value of type 'Data' to type '[UInt8]'` | 用 `data.withUnsafeBytes { update($0) }` |

### 8.2 项目本身的陷阱（来自设计文档核实）

| # | 陷阱 | 解法 |
|---|---|---|
| T1 | iOS **无 fork/exec** | 一律走自研解释器/原生命令表（[05](docs/05-工具系统与执行沙箱.md)） |
| T2 | **FTS5 的 `unicode61` 静默丢弃 CJK** | 用 CJK 分词器或 `trigram`（[07 §4.1](docs/07-上下文与记忆引擎.md)） |
| T3 | security-scoped bookmark 的 stop **必须配对** | RAII 包装强制配对（[05 §4.2](docs/05-工具系统与执行沙箱.md)） |
| T4 | **不要把 git worktree 放 iCloud Drive** | FileProvider 会损坏 `.git` |
| T5 | Apple FM 端侧窗口只有 **4096 token** | 端侧只做反射（[13 §5](docs/13-端侧模型与性能预算.md)） |
| T6 | 二进制里**存在**"远程代码加载"能力就可能被审核引用 | CI 加符号扫描（[11 §3.3](docs/11-AppStore合规与分发.md)） |
| T7 | `json` 键序不稳定会破坏指纹去重 | 用 `JSONValue.canonicalString()`（已实现并有测试） |
| **T8** | ⚠️ **Swift 把 `"\r\n"` 当作单个 Character（字素簇）**，所以 `components(separatedBy: "\n")` 在 CRLF 文本上**根本不分割**，会把整个文件当成一行 → 所有按行匹配的补丁**静默失败** | **先把 `\r\n` 归一化成 `\n` 再分割**（`LineTable.parse` 已处理，并有 CRLF 测试守护） |
| **T9** | 替换文本的换行风格不跟随目标文件 → 在 CRLF 文件里插进 LF 行，diff 出现整文件噪音 | `TextEdit.normalizeNewlines(_:to:)`（已实现并有测试） |
| **T10** | ⚠️ **Swift 原生字符串 `#"…"#` 的定界符是 `"#`（引号在前）**，写成 `#"a\(#"` 会被认为是**未闭合**（因为 `\(` 后面是 `#` 再 `"`，顺序反了） | 写正则字面量用普通字符串 + 双反斜杠（`"return round\\("`），别用 `#"…"#` 混排转义 |
| **T11** | 测试夹具的字典 key 与虚拟路径不一致 → 读不到文件 → 空结果 → `matches[0]` **越界崩溃** | `GrepFileSource.inMemory` 已把 `src/a.py` 与 `/workspace/src/a.py` 两种 key 归一化；写夹具不必记挂载点前缀 |
| **T12** | 大小写不敏感匹配时手写 `line.lowercased()` 再取下标 → 某些字符 lower 后长度变化会导致**下标错位** | 用 Foundation 的 `range(of:options:.caseInsensitive)`，下标记在原串上（`GrepEngine.countMatches` 已如此） |
| **T13** | ⚠️ `dict[i]?.x = cond ? dict[i]?.x : y` 会触发 **ExclusivityViolation**（同一表达式既读又写同一下标） | 先把旧值取到局部变量，再赋值 |
| **T14** | `#expect(x.contains(where: \.isFatal))` 在测试宏里被当成可能抛错 → 编译失败 | 写 `#expect(x.contains { $0.isFatal })` |
| **T15** | 把诊断信息追加到**局部副本**却忘了写回结构体 → 返回值里有、`allIssues`/`diagnostics` 里没有 | 修 bug 后追加诊断时，务必 `partial.issues = issues` 再写回容器（`ToolCallAssembler.emit` 已如此） |
| **T16** | 尾逗号可能出现在**闭合括号之前**（`{"a":1,}`），只看字符串末尾会漏掉 | 单遍扫描 + 向后跳过空白判断下一个非空白字符是否为 `}`/`]` |

---

## 9. 硬约束速查（写代码前先看这一节）

```
执行        ❌ fork/exec/posix_spawn   ❌ JIT   ❌ dlopen 下载的 dylib
文件        ✅ 仅容器内 + 用户显式授权的目录（security-scoped bookmark）
后台        ⏱ BGAppRefresh 30s · 静默推送 30s/每小时2-3条 · 延续处理任务"数分钟或更久"
            ⏱ Live Activity 最长 12 小时
端侧模型    4096 token/会话（含指令与工具 schema）· 建议工具 ≤3-5 个 · 内存实测约 3.1GB（6GB 机型）
存储        ❌ unicode61 分词   ✅ CJK tokenizer / trigram   ⚠️ sqlite-vec 需静态注册
体积        内嵌 CPython ⇒ App 约 1-2GB（不可优化，只能接受）
审核        2.5.2 + ADPLA §3.3.1(B) · 1.2（过滤必须在二进制内）· 5.1.2(i)（第三方 AI 需显式许可）
本机构建    必须走 Tools\rune.ps1；swift build/test 不可用
```

---

## 10. 文件地图

```
D:\项目\ios平台agent\          （构建时请用 C:\Users\MSI-NB\rune-ws）
├─ PROJECT_STATE.md          ⭐ 本文件（最先读）
├─ README.md                 设计文档入口
├─ Tools/
│  └─ rune.ps1               ⭐ 构建/测试驱动（唯一可用的构建入口）
├─ docs/
│  ├─ 进度日志.md            ⭐ 追加式时间线
│  ├─ 01 … 15                设计文档（01 产品定位 … 15 风险登记册）
│  └─ 附录A / 附录B          渠道事实表 / 技术选型核实表
├─ research/                 取证材料（465 份，非交付物）
└─ Packages/
   ├─ RuneKernel/            ✅ 零依赖核心（**249 测试全绿**）
   │  ├─ Package.swift       （仅供 macOS 使用；本机走 rune.ps1）
   │  ├─ Sources/RuneKernel/
   │  │   ├─ JSONValue.swift      手写 JSON 解析 + 确定性序列化
   │  │   ├─ SHA256.swift         纯 Swift SHA-256 + 三种指纹
   │  │   ├─ Trust.swift          信任级 / 污点 / 人类专属区
   │  │   ├─ Content.swift        消息/内容块/制品/用量/成本/流式事件
   │  │   ├─ Tool.swift           工具规格/schema/错误/全部工具名常量
   │  │   ├─ Capability.swift     VFSPath（安全边界）/ 出口规则 / 能力令牌
   │  │   ├─ Errors.swift         统一错误模型
   │  │   ├─ Plan.swift           结构化计划 + Goal 阻塞纪律
   │  │   ├─ Event.swift          事件枚举 + 信封 + 哈希链
   │  │   ├─ TextPatch.swift      ⭐ 补丁引擎
   │  │   ├─ GlobMatcher.swift    ⭐ 通配匹配
   │  │   ├─ IgnoreRules.swift    ⭐ gitignore 语义 + 两层 PathFilter
   │  │   ├─ GrepEngine.swift     ⭐ 搜索核心（预筛 / 二进制跳过 / 预算截断）
   │  │   ├─ ToolCallAssembler.swift ⭐ 流式工具调用拼装 + JSON 修复
   │  │   ├─ ProviderQuirks.swift    ⭐ 渠道差异声明 + 价格与成本计算
   │  │   └─ PolicyEngine.swift      ⭐ 信任刻度盘 + 审批分级 + SSRF + 人类专属区
   │  └─ Tests/RuneKernelTests/
   │      ├─ JSONAndHashingTests.swift
   │      ├─ SecurityTests.swift
   │      ├─ RuntimeModelTests.swift
   │      ├─ PatchTests.swift         37 项补丁引擎测试
   │      ├─ SearchTests.swift        50 项检索测试
   │      ├─ GatewayTests.swift       40 项网关测试
   │      └─ PolicyTests.swift        37 项策略引擎测试
   └─ Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/   ⬜ 骨架（含实现清单）
```

---

## 11. 里程碑验收标准（摘录自 [14](docs/14-工程路线图与测试策略.md)）

| 里程碑 | 出口标准 |
|---|---|
| **M0** | 在测试壳里，模型能自主完成"修一个简单的失败单测"，并在中途被杀后正确恢复 |
| **M1** | 3 名内测用户各完成 5 个真实任务，完成率 ≥70%，无需看文档 |
| **M2** | S1 场景（CI 抢救→应用→提交）能在 3 次点击内完成 |
| **M3** | 切换任意两家渠道，同一任务成功率差异 <15% |
| **M4** | 飞行模式下完成"改函数 + 跑测试 + 写 commit"全流程 |
| **M5** | 注入套件 0 越权 + 性能基准全达标 + 审核材料齐备 |



