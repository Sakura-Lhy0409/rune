# PROJECT_STATE —— Rune 开发续接文档

> ⚠️ **这是整个项目最重要的文件。任何新会话、任何 Agent、任何人类协作者的第一件事就是读完它。**
> **它必须始终保持在 300 行以内**（够短才读得完）。详细历史放 [`docs/进度日志.md`](docs/进度日志.md)，本文件只保留"现在在哪、接下来做什么、别重复踩什么坑"。

---

## 0. 更新协议（硬性要求，不可跳过）

| 时机 | 必须做的事 |
|---|---|
| **每完成一个可验证的里程碑**（能 build + 能 test 通过） | ① 更新 §2 状态快照 ② 更新 §5 已完成 ③ 在 `docs/进度日志.md` 追加一条 |
| **每次感觉上下文快到上限 / 准备长时间工作之前** | **先更新本文档**，把"脑子里有但还没落盘的东西"全部写下来 |
| **每次做出新技术决策 / 踩到坑** | 决策写进 §4（含理由）、坑写进 §8（现象 + 原因 + 解法） |
| **每个新会话开始** | 先读本文档 → 再读 §6 下一步 → 然后动手。**不要从零重新探索代码库。** |

**反向纪律：动手前先查 §5 与 §9；§5 里有的东西不要再实现一遍。别相信"我记得做过了" —— 去查。**

## 1. 项目一句话

**Rune（符文）**：完全在 iPhone/iPad 本地运行的通用 Agent。模型可走云端 API（BYOK，含中转站），但**工具循环、文件系统、代码执行、Git、检索、记忆全部在设备上完成**，没有任何远端执行路径。
完整设计见 [`docs/`](docs/)（18 份文档，已完成）。**当前正在把设计变成代码。**

---

## 2. 状态快照

| 项 | 值 |
|---|---|
| **更新日期** | 2026-09-18 |
| **当前阶段** | **M0 已完成 ✅ → 进入 M1 可用内核** |
| **当前里程碑** | ✅ **M1-13 沙箱层（输出纪律 / 资源限额 / 来源分级）**（822 测试全绿）—— 下一步见 §7 |
| **上一个完成的里程碑** | ✅ **M1-13：沙箱层（输出纪律 + 资源限额 + 来源分级）—— Windows 可验证的纯逻辑到此收尾**（822 测试全绿） |
| **已完成里程碑** | ✅ M0 全部（…→**258 出口验收达成**）→ ✅ M1-1 ToolScheduler（282）→ ✅ M1-2 协议适配器（328）→ ✅ M1-3 波次调度（341）→ ✅ M1-4 计划与审批（379）→ ✅ M1-5 GoalEngine（405）→ ✅ M1-6 修正性重试（447）→ ✅ M1-7 上下文装配器（487）→ ✅ M1-8 工具注册表（540）→ ✅ M1-9 技能库 + 场景测试（608）→ ✅ M1-10 Workflow 引擎（657）→ ✅ M1-11 VFS 层（705）→ ✅ M1-12 自研 shell 解释器（775）→ ✅ **M1-13 沙箱层（822）** |
| **阻塞项** | 无 |
| **本机可验证范围** | ✅ 平台无关的 Swift 代码（Kernel / 补丁 / 检索 / 网关 / 策略 / **Turn 循环**）<br>❌ iOS 专属（UI / Live Activity / Core ML / VFS 真实文件系统 / 沙箱 / GRDB / JSC）—— 需 macOS |

### 进度条

```
设计文档      ████████████████████ 100%
M0 地基       ████████████████████ 100%   ✅ 出口验收已达成
M1 可用内核   ███████████████████  95%   ← 内核 + VFS 就绪，**只差真实 IO 与 UI（都要 macOS）**
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
| 中途被杀后正确恢复 | ✅ **对 0..23（场景测试）/ 0..40（单元测试）每一个切断点**验证：恢复后最终文件状态与基线**完全一致**，且**补丁只实际改动一次**（无重复副作用） |
| 非幂等操作不自动重做 | ✅ 结果未知时进入 `awaitingApproval`，明确告知"是否已生效无法确定" |
| 事件日志完整可校验 | ✅ 哈希链逐条衔接（`previousHash == 上一条.hash`）；端到端场景测试逐条 `verifyHash()` |

### 包结构现状

**包结构**：`RuneKernel` ✅ **33 源文件 / 775 测试**（本机可测）；`RuneNet` `RuneStore` `RuneVM` `RuneBench` `RuneGateway` `RuneContext` `RuneCore` `RuneTools` `RuneMCP` `RuneUI` ⬜ 骨架（`Package.swift` + 实现清单）。

---

## 3. 环境事实（本机，**这些坑已经踩过，别再踩**）

| 项 | 值 |
|---|---|
| 工作目录（真实） | `D:\项目\ios平台agent` —— **含中文** |
| **ASCII junction** | ⭐ `C:\Users\MSI-NB\rune-ws` → 指向上面那个真实目录（`mklink /J`） |
| **构建命令** | ⭐ `pwsh -NoProfile -File Tools\rune.ps1 build RuneKernel`<br>`pwsh -NoProfile -File Tools\rune.ps1 test RuneKernel` |
| Swift 工具链 | ✅ **6.3.3 for Windows**（`x86_64-unknown-windows-msvc`），满足 WasmKit 的 Swift 6.3 要求 |
| MSVC | VS 2022 Build Tools，**必须经 `vcvars64.bat` 激活**（`link.exe` 不在 PATH）。脚本已处理 |
| python/node/cmake | ✅ 可用；ninja ❌ 未装（wasm 构建时才需要）。CPU 32 核 |
| git | ✅ 已初始化。`core.autocrlf=false` + `.gitattributes` 强制 LF（**补丁引擎的换行保真测试依赖这一点**）。`research/` 标记 `-text -diff` 且**故意提交**（证据链） |
| **不能做的事** | 无法构建 iOS App、无模拟器、无法验证 SwiftUI / Live Activity / AVFoundation / Core ML |

### ⚠️ `swift build` / `swift test` 在本机**不可用**

**症状**：能加载 manifest、能生成构建图，但真正调用 swiftc 编译目标时**静默退出（exit 1，零错误信息）**。
**已排除**：中文路径、工具链损坏、管道被禁、batch mode、索引库、`--use-integrated-swift-driver`、ASCII junction。
**结论**：SwiftPM 在本环境的**子进程执行层**有问题，**与我们写的代码无关**（同一条 swiftc 命令手动执行完全成功）。
**对策**：`Tools/rune.ps1` 自己用 swiftc 驱动构建与测试。**上 macOS 后可改回标准 `swift build/test`；本机一律走 `rune.ps1`。**

---

## 4. 已确定的决策（不要重新讨论）

### 4.1 用户已拍板的产品决策

| 编号 | 决策 |
|---|---|
| **Q19** | App Store 版**包含**原生 CPython（接受 1–2GB 体积；只用 On-Demand Resources 剥离纯数据） |
| **Q15** | 接受"模型生成的 Python 在 CPython 中执行"，但必须配**来源分级 + 全 API 包裹 + 红队验证** |
| **Q2** | 商业模式：**一次性买断 + 纯 BYOK**（不卖额度、不运营中转、不做外部购买引导） |
| **Q16 / Q17** | 内容过滤只作用于**面向人的自然语言输出**（代码块与文件内容豁免）；Diff 视图 1.0 做简化版、1.1 自研完整版 |
| **Q18 / Q20** | `.rune/libs` 用户自带库路径**固定为公开约定**；**预置「移除下载能力」降级开关**（应对审核波动） |
| 约定 | 文档/注释/UI 文案用中文；代码标识符用英文。⚠️ 中文引号一律 `「」`（ASCII `"` 会截断 Swift 字面量，T28） |

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

> 逐条细节见 [`docs/进度日志.md`](docs/进度日志.md)。这里只保留**「做过了、别再做一遍」**这一层信息；
> ⚠️ 标记的是**容易被后人改回去**的关键设计点。

| # | 项 | 产出 | 关键点（⚠️ = 必须保持） |
|---|---|---|---|
| D1 | ✅ 设计文档集（18 份，6785 行） | `README.md`、`docs/01`–`15`、`附录A/B` | 内部链接已校验；事实均带出处 |
| D2 | ✅ 事实取证归档 | `research/`（465 份） | 已 `-text -diff` 标记，**刻意入库** |
| C1/C2 | ✅ 续接机制 + 构建/测试闭环 | `PROJECT_STATE.md`、`docs/进度日志.md`、`Tools/rune.ps1` | ⚠️ `swift build/test` 在本机不可用（E1） |
| C3 | ✅ `RuneKernel` 零依赖核心（9 文件 / 85 测试） | `JSONValue` `SHA256` `Trust` `Content` `Tool` `Capability` `Errors` `Plan` `Event` | ⚠️ CryptoKit 是 Apple 专有 → **自实现 SHA-256**；⚠️ `canonicalString` 键序稳定才有指纹去重；⚠️ `VFSPath` 的 `..` 逃逸必须拒；⚠️ **写不蕴含删**；⚠️ 事件哈希链使篡改可检测 |
| C4 | ✅ 补丁引擎（37 测试） | `TextPatch.swift` | ⚠️ **CRLF 是单个字素簇**（T8/T9）；⚠️ 匹配多处**必须拒绝**、绝不猜；⚠️ 一个 hunk 失败 → 整次不落地；诊断必须可执行 |
| C5 | ✅ 检索子系统（50 测试） | `GlobMatcher` `IgnoreRules` `GrepEngine` | gitignore **最后匹配胜出**；内置默认清单在显式 include 时让位；**预算截断要如实告知** |
| C6 | ✅ 10 个包骨架 | `Packages/Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/` | 依赖声明已校验；占位文件里放的是实现清单 |
| C7 | ✅ 网关纯逻辑（40 测试） | `ToolCallAssembler` `ProviderQuirks` | ⚠️ `JSONRepair` **修不好就返回 nil**（交给修正性重试）；⚠️ 并行 index 交错；⚠️ 诊断要写回结构体（T15） |
| C8 | ✅ `PolicyEngine`（37 测试） | `PolicyEngine.swift` | 六层判定：人类专属区 → 信任档 → 令牌 → SSRF → **污点** → 风险分级；⚠️ SSRF 含云元数据地址与**重定向逐跳**校验 |
| C9 | ✅ **最小 Turn 循环（M0 出口达成）**（258 测试） | `TurnRunner.swift` | ⚠️ **步进式**（一次推进一件事）；⚠️ **三步落盘协议**（写意图→执行→写事实）；⚠️ `wasRestored` 必须由运行时**显式**置位 |
| C10 | ✅ 运行时/存储/App 层设计 | `docs/10`–`15` | — |
| C11 | ✅ 协议适配器（328 测试） | `ProtocolEncoders` `ProtocolDecoders` `StreamParsing` | ⚠️ DeepSeek reasoning 回传按**请求**判定（不是按消息）；⚠️ Gemini 的 `finishReason` 会单独成帧 —— 漏了会**静默丢工具调用** |
| C12 | ✅ 波次调度（341 测试） | `ToolScheduler` + `.dispatching` 边界语义 | ⚠️ **检查点以波次为单位**（波内同时在飞）；⚠️ 多路径**全部查、取最严**；⚠️ 多个悬空意图要**整批**问用户 |
| C13 | ✅ `PlanEngine`（379 测试） | `PlanEngine.swift` | ⚠️ 按计划**声明的路径**精确授权（不是整个工作区）；⚠️ 网络出口**不预授权**；偏离检测：改目标 / 新增危险步骤 / 超支 150% |
| C14 | ✅ `ApprovalBroker` | `ApprovalBroker.swift` | ⚠️ 超时 = **拒绝**（失败关闭）；⚠️「全部允许」先全量校验再应用；⚠️「记住选择」**缺省必须自动提取路径**，否则退化成整个工具的白名单 |
| C15 | ✅ `GoalEngine`（405 测试） | `GoalEngine.swift` | ⚠️ 受阻需同一条件连续 3 轮；⚠️ **无进展**与受阻是**两个独立计数**；⚠️ 预算/电量门禁**只拦自动续跑**，不拦用户手动发起 |
| C16 | ✅ 修正性重试策略层（447 测试） | `Correction.swift` | ⚠️ 编码器**只发 `summary`** → 建议与候选必须拼进去（T17）；⚠️ 按**根因**分桶；⚠️ 逐字重复立刻止损；⚠️「模型改不了」的错误不记账；⚠️ 运行时引导语 ≠ 用户指令（T20） |
| C17 | ✅ 对话历史协议不变式 | `TurnRunner.reapOrphanCalls` | ⚠️ 漏一个配对结果 → 会话**后续全部 400**（T18）；⚠️ 兜底只在 `.reasoning` 入口做；⚠️ 判定读**历史**不是队列；⚠️ 运行时**不能伪造工具调用**（T19） |
| C18 | ✅ 上下文预算制装配器 + L1 裁剪（487 测试） | `Context.swift` | ⚠️ 中文 token **1 字符 ≈ 1**（用 `/4` 估会低估 4 倍 → 撑爆窗口 / 账单失控，T22）；⚠️ 装配器**永不自己花钱**（L3 只报告不执行，T23）；⚠️ 渲染顺序与块内排序必须**确定性**，否则 Prompt Cache 永不命中；⚠️ 缺「当前目标 / 最近失败」**不许发出去**；⚠️ 输出预留 ≥10% 不可挤占 |
| C19 | ✅ 工具注册表（86 个工具契约）+ 校验器 + 按档可见性（540 测试） | `ToolRegistry.swift` | ⚠️ 声明写错**不报错，只静默少一层保护** → 17 条校验规则把它变成测试失败；⚠️ `pathParameters` **必须声明全**（「声明了但不全」更危险，T26）；⚠️ 路径参数命名要避开 `target`/`source` 这类歧义词；⚠️ 执行类工具输出必须走制品；⚠️ 审批的真正防线是**作用域**不是弹窗 |
| C20 | ✅ 技能库 + 渐进式披露（608 测试） | `Skill.swift` `SkillLibrary.swift` | ⚠️ **L1 正文永不自动加载**（API 上就不提供「取全部正文」）；⚠️ 中文 L0 成本是英文的 ~2 倍（设计文档的 15 token 是英文尺子 → 实测改 40，T29）；⚠️ token 预算必须把标题行算进去；⚠️ 技能只能**申请**权限、且必须在加载正文**之前**就位；12 个内置技能各带验证清单 |
| C21 | ✅ 端到端场景测试（定位→读→补丁→跑测试→提交） | `ScenarioTests.swift` | ⭐ **它挖出两个致命 bug**：① `.dispatching` 在「恢复非幂等意图 + 用户批准」后 `removeFirst()` **越界崩 App**（T31）；② **审批路径是死循环** —— `PolicyEngine` 是纯函数，批准后重新派发又算出「需要确认」，于是**任何需要审批的工具永远执行不了**（推送/删除/Shortcuts 全瘫痪）（T30）。修法：`approve` 按相位路由 + `.dispatching` 防御分支 + `approvedFingerprints`（按**指纹**不按 callID，防复用 id 提权） |
| C22 | ✅ Workflow 引擎（657 测试） | `Workflow.swift` | ⚠️ 引擎**不执行任何东西**（只回答"下一步跑哪些"，因此完全确定 + 天然可恢复）；⚠️ `pipeline` 的无屏障语义靠**深度降序**调度（按书写顺序会退化成三级屏障）；⚠️ 上游 `null` **整条链短路**，且 `skipped` 与 `failed` 在三处（状态/汇总/看板）都必须区分；⚠️ **`addSteps` 必须先"重新打开"已 completed 的运行**，否则脚本的第二阶段静默消失（T32）；⚠️ 脚本关键字扫描**不是安全边界**（真正的边界是宿主不暴露那些全局，T33） |
| C23 | ✅ VFS 层（822 测试） | `VFS.swift` | ⚠️ **两份实现跑同一套 conformance 断言** —— 一上来就抓到 4 处不一致（二进制检测/候选提示/回收站语义/末尾换行）；⚠️ **读出来必须能原样写回去**（切片曾丢掉 `endsWithNewline` → 每次往返都在改文件）；⚠️ iOS 真正咬人的是**大小写不敏感**（`README.md` 在 iOS 上就是 `readme.md`，T34）；⚠️ **`==` 在"要比字节形式"的地方是陷阱**（两处静默失效，T35）；⚠️ 快照在手机上很贵，`clonefile` 待 macOS |
| C24 | ✅ 自研 shell 解释器（822 测试） | `Shell.swift` | ⚠️ **"不支持什么"比"支持什么"更重要** —— 每条不支持的语法都要给**可执行的替代**（否则模型只是换个写法再试，来回烧 token）；⚠️ **裸 `$VAR` 必须被拒**（放过去会得到静默的错误答案：命令收到字面量 `$HOME`，然后以看不懂的方式失败；双引号里也一样，T36）；⚠️ **管道中间环节的 stdout 不算可见输出**（否则模型会看到 `hello` 与 `HELLO`，以为跑了两遍，T37）；⚠️ 默认**失败即停且 `;` 也不例外**，但 `||` 后面那条必须照跑 |
| C25 | ✅ 沙箱层（822 测试） | `Sandbox.swift` | ⚠️ **输出纪律只有一份实现**（内联 ≤8KB / 制品 ≤2MB / 更大则**拒绝**并指向"改做法"）；⚠️ 制品说明必须给全 **5W**（多大/多少行/里面有什么/去哪读/怎么读）；⚠️ **超限判定顺序：内存与指令数排在墙钟前面**（墙钟超时往往是它们的结果，先报超时会把真因藏起来）；⚠️ **沙箱内存额度 = 物理内存的 1/4**（3/4 会让 iOS jetsam 杀掉**整个 App**，T38）；⚠️ 来源分级：模型生成 → WASM，做不到则"降级 + 强制确认"而**不是放行**（T39） |

---

## 6. 下一步

### ⚠️ 现状：Windows 上能做的纯逻辑基本做完（822 测试）

**⚠️ 待 macOS 验证的风险点**（未验证，不是"已完成"）：
①「多工具结果在 Anthropic/Gemini 下是**连续同角色消息**，依赖服务端合并」—— 上 macOS 后必须用真实渠道压一次；
② **L3 主模型压缩只有"报告"**（装配器给了候选 id，但"谁去花这笔钱、谁落事件"还没接）；
③ **Workflow 的 JSC 宿主不存在**（脚本 → DAG 的编译层是 macOS 的活）；
④ 86 个工具只有**契约**、没有实现（VFS 已就绪，实现只剩"接线"）。

`RuneKernel` 有 **34 个源文件、822 项测试**，覆盖：值类型与协议、补丁引擎、检索、网关、
策略引擎、Turn 循环与崩溃恢复、波次调度、计划引擎、审批代理、目标引擎、修正性重试与协议不变式、
上下文预算制装配、86 个工具契约、技能与渐进式披露、Workflow 批处理编排、
**VFS（真实文件系统 + 内存两份实现）**、**自研 shell 解释器**。
**并且有一条端到端场景测试证明它们拼得起来。**

**路线 A（推荐）—— 把所有需要 macOS 的部分集中做掉**，按此顺序：
`RuneStore`（GRDB + 事件落盘）→ `RuneNet`（真实 URLSession + SSE + 出口代理）→
`RuneBench`（VFS + security-scoped bookmark + 原生 CPython 垫片）→ `RuneTools`（86 个工具实现）→
`RuneCore`（把 Kernel 接上真实 IO）→ `RuneUI`。⚠️ 不要在 Windows 上做这些 —— 无法验证。

**路线 B（Windows 上还能做的，优先级低于 A）**：C18–C25 已完成。剩下两件**有实质价值**的：
1. ⭐ **事件溯源投影**（`docs/12 §1` 说事件日志是唯一真相源，会话/检查点/成本/审计都要能从事件重建）
   —— **目前最大的空缺**：`RuntimeEvent` 有哈希链，但**没有任何东西从事件重建状态**；
   RuneStore 要写事件、UI 要读投影、会话恢复要靠它。
2. ⭐ **网关路由与降级**（`docs/06`）：多渠道选择、健康探测、失败降级、成本优先、Key 轮换。
3. 较小的：检索融合（RRF）、MCP 编解码、cassette 回放夹具。

**建议**：内核已经能端到端跑通（C21 就是证据）。**再往下的价值断崖式下降 —— 应该上 macOS 走 A。**

---

## 7. 已知陷阱（不要重复踩）

### 7.1 本机环境陷阱

| # | 陷阱 | 现象 | 解法 |
|---|---|---|---|
| E1 | **`swift build` / `swift test` 静默失败** | 只输出 "Building for debugging…" 然后 exit 1，无错误 | **用 `Tools/rune.ps1`**（见 §3） |
| E2 | **路径含中文导致 swiftc 打不开文件** | `error opening input file 'D:\??Ŀ\ios??agent\…'` | **走 ASCII junction**；脚本已自动处理；生成 .bat 时用 `chcp 65001` + UTF-8 |
| E3 | **`link.exe` 不在 PATH** | manifest 编译失败 | 所有 swiftc 调用都要先 `call vcvars64.bat`（脚本已处理） |
| E4 | **运行测试 exe 报 0xC0000135** | 进程静默退出（STATUS_DLL_NOT_FOUND） | PATH 必须含 **Swift Runtimes\6.3.3\usr\bin** 与 **Testing-6.3.3\usr\bin64**（注意是 `bin64`，不是 `x86_64`——后者只有 .lib） |
| E5 | `Testing.__swiftPMEntryPoint` 有**两个重载** | `ambiguous use of '__swiftPMEntryPoint'` | 用显式类型标注：`let code: CInt = await ...` |
| E6 | 写入 `C:\` 根目录被沙箱拒绝 | `Access is denied` | 临时文件放 `$env:USERPROFILE` 或仓库内 |
| E7 | `data as [UInt8]` 在跨平台下不可靠 | `cannot convert value of type 'Data' to type '[UInt8]'` | 用 `data.withUnsafeBytes { update($0) }` |
| E8 | 内联管道看编译输出会**超时**（`pwsh ... \| Select-String` 120s 无输出） | 命令超时、exit 1，但实际在编译 | 改成 `\| Out-File $env:TEMP\x.log` 再读，或 `run_in_background: true` |

### 7.2 项目本身的陷阱（来自设计文档核实）

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
| **T17** | ⚠️ **编码器只发 `ToolResult.summary`**。任何"结构化错误"（建议、候选、字段名）若不拼进 `summary`，就等于**从没存在过** | 回灌内容统一走 `ToolError.modelFacingText`；给错误加字段时先问"它到底会不会被发出去" |
| **T18** | ⚠️ **assistant 里的每个 tool_call 都必须有配对结果**（Anthropic/OpenAI/Gemini 三家一致），否则**后续所有请求 400**，且报错信息与真实原因完全不沾边 | `TurnRunner.reapOrphanCalls` 在 `.reasoning` 入口无条件兜底；判定读**历史**而非队列字段 |
| **T19** | ⚠️ **运行时不能伪造工具调用**（凭空造 `tool_use` 会让会话彻底 400） | "重试"只能靠回灌精确错误；运行时写的话只能是文本 + `.runtimeGuidance` 信任级 |
| **T20** | ⚠️ **运行时写的话不能标成 `.userInstruction`** | 否则运行时可以伪造用户授权驱动危险动作（提权）。用 `.runtimeGuidance`（`canDriveDangerousAction == false`） |
| **T21** | ⚠️ 用**手写枚举**减出"非稳定态"一定会漏（`.interrupted` 就这么漏掉的，导致 `run()` 空转 10000 次） | `canAdvance` 直接定义为 `!status.isStable`；新增状态只需回答"它稳不稳" |
| **T22** | ⚠️ **中文 token ≈ 1 字符/token**（CJK 不在 BPE 合并收益区）。用 `count/4` 估中文会**低估 4 倍** → 装配器以为还有空间、继续往里塞 → 撑爆窗口或账单翻 4 倍 | `TokenEstimator` 按字符类别分开算；非 CJK 取 3.5 字符/token，**宁可略高估** |
| **T23** | ⚠️ 让一个叫"装配"的函数悄悄调模型花钱 —— 调用方以为只是在拼上下文，账单却翻了倍 | 装配器只**报告**需要 L3 压缩 + 候选 id；付费决策留给能落事件、能弹卡片的那一层 |
| **T24** | ⚠️ **模型给的路径绝大多数是相对路径**（`src/a.py`）。用 `VFSPath.parse` 解析相对路径一律失败 → 提取到**空**路径数组 → 策略引擎当成「不涉及路径」→ **路径作用域判定被整条跳过**，越权写入静默放行（还连带让「记住选择」退化成整个工具白名单） | 相对路径必须按工作区根解析（`VFSPath.resolve`）；`CallPaths` 是唯一实现，工具内部不要再写一套 |
| **T25** | ⚠️ 「绝对但挂载点不认识」的路径（`/etc/passwd`）若按相对路径处理，会被悄悄映射成 `/workspace/etc/passwd` —— **被检查的路径 ≠ 工具操作的路径**（混淆代理） | 显式标成 `PathExtraction.outsideMounts`，由运行时**直接拒绝**并给可执行建议 |
| **T26** | ⚠️ **`pathParameters` 声明了但不全**（`git_add` 声明 `["path"]` 却还有 `files: [string]`）→ 静默忽略那些路径。**比完全没声明更危险，因为它看上去是对的** | `validate()` 规则 `undeclaredPathParameter`：schema 里像路径的参数必须全部声明 |
| **T27** | ⚠️ 参数名歧义：`run_build` 的 `target` 是**构建目标名**，但 `target` 在路径键名启发式里 → 会被当成路径解析 | 非路径参数不要叫 `target`/`source`/`to`（改名为 `build_target`） |
| **T28** | ⚠️ 中文文案里手打 ASCII `"` 会**截断 Swift 字符串字面量**，报错却是「expected ',' separator」；在 `#"…"#` 里写出 `"#` 更会直接终止原始字符串 | 中文引号一律 `「」`；`validate()` 的 `asciiQuoteInProse` 规则会在测试里抓住它 |
| **T29** | ⚠️ 设计文档里的 token 预算若来自**英文估算**，直接拿来卡中文会全部「超标」（中文 1 字符 ≈ 1 token，密度是英文的 ~4 倍） | 定预算前先用 `TokenEstimator` 量真实条目；预算要**把标题行与提示行一起算进去**，否则硬预算会超标 |
| **T30** | ⚠️ **纯函数式策略判定 + 不可变状态 = 审批死循环**：批准后重新派发，`approvalRequirement` 算出同样结论 → 卡片无限弹 → **任何需要审批的工具永远执行不了**（推送/删除/Shortcuts 全瘫） | `TurnState.approvedFingerprints` 记住「这一次已批准」；⚠️ 指纹 = callID + 工具名 + **规范化参数**（只按 callID 记会被复用 id 绕过 = 提权） |
| **T31** | ⚠️ 状态机缺防御分支 = **崩溃**：`.dispatching` 无条件 `currentWave.removeFirst()`，而「恢复非幂等意图」那条路径下 `currentWave` 是空的 | 状态机必须是**全函数**：`pendingIntents` 非空时路由到 `.executing`；`approve` 也要按相位路由 |
| **T32** | ⚠️ 编排脚本的第二阶段**静默消失**：第一个 `agent()` 完成时已知步骤全终结 → 运行被标 `completed` → 脚本走到下一阶段再加步骤时被 `status == .running` 守卫挡住，新步骤永远 `pending` | `addSteps` 先把运行**重新打开**（脚本还在执行这件事本身就是证据） |
| **T33** | ⚠️ 把「关键字黑名单」当成安全边界（`this["fet"+"ch"]` 一行就绕过） | 真正的边界是**宿主不暴露那个能力**；扫描只用于可用性提示与纵深防御，注释里必须写清"命中 ≠ 攻击、不命中 ≠ 安全" |
| **T34** | ⚠️ **iOS 上文件名大小写不敏感**：`README.md` 与 `readme.md` 是**同一个文件**（APFS 默认），而 Windows/Linux 上是两个 → 模型"新建"实际是**覆盖**，不可撤销。**反向陷阱**：NFC/NFD 在 Swift+APFS 上**基本不是问题**（Swift `==` 与 APFS 都规范化不敏感）—— 别按错的前提写代码 | 把"文件系统怎么比较文件名"做成**显式可注入**的属性（`FilenameComparison`），并提供 `collidingEntry`：写之前先查有没有只有大小写不同的同名文件 |
| **T35** | ⚠️ **`==` / `contains` / `!=` 在"要比不同字节形式"的地方是陷阱**：Swift 字符串比较按 Unicode 规范等价，所以 `forms.contains(decomposed)` 对 NFC 形式**永远为真** → 备选形式永远加不进列表，兜底逻辑静默失效（一次踩了两处） | 凡是"我要的是不同字节"就按 `Array(s.utf8)` 比；写测试时断言**字节数/字节数组**，不要断言字符串相等 |
| **T36** | ⚠️ shell 里**裸 `$VAR` 不能放过去**：不展开却也不报错 → 命令收到字面量 `$HOME` → 以一种完全看不懂的方式失败。**双引号里同样**（POSIX 会展开，我们不展开） | 词法阶段就拒绝并说明"没有变量"；要字面量 `$` 就用单引号（POSIX 语义：单引号内一切字面） |
| **T37** | ⚠️ **管道中间环节的 stdout 会被当成"可见输出"** → 模型同时看到 `hello` 与 `HELLO`，以为命令跑了两遍，还白占输出预算 | `ShellCommandOutput.isPiped` + `visibleStdout`（中间环节对模型返回空，但仍保留在记录里供排查） |
| **T38** | ⚠️ **沙箱内存额度不能取物理内存的 3/4**：iOS 的 jetsam 会**直接杀掉 App** —— 被拦住的从来不是脚本，是整个 App（连同用户没保存的东西）。**同一条上限在两处各写一遍必然分叉** | `SandboxLimits.memoryCap(onDeviceMemoryMB:)` 取 **1/4**，只有一份实现；`route` 与 `isAchievable` 都调它 |
| **T39** | ⚠️ 来源分级的**降级路径不能变成"因为隔离做不到就直接放行"** | 模型生成的 Python 请求 → 改走 WASM；WASM 不可用时降级到 CPython，但**确认必须留着** |

---

## 8. 硬约束速查（写代码前先看这一节）

```
执行        ❌ fork/exec/posix_spawn   ❌ JIT   ❌ dlopen 下载的 dylib
文件        ✅ 仅容器内 + 用户显式授权的目录（security-scoped bookmark）。⚠️ iOS 文件名**大小写不敏感**（T34）
后台        ⏱ BGAppRefresh 30s · 静默推送 30s/每小时2-3条 · 延续处理任务"数分钟或更久" · Live Activity ≤12h
端侧模型    4096 token/会话（含指令与工具 schema）· 建议工具 ≤3-5 个 · 内存实测约 3.1GB（6GB 机型）
存储        ❌ unicode61 分词   ✅ CJK tokenizer / trigram   ⚠️ sqlite-vec 需静态注册
体积        内嵌 CPython ⇒ App 约 1-2GB（不可优化，只能接受）
审核        2.5.2 + ADPLA §3.3.1(B) · 1.2（过滤必须在二进制内）· 5.1.2(i)（第三方 AI 需显式许可）
本机构建    必须走 Tools\rune.ps1；swift build/test 不可用。⚠️ 用 Out-File 看编译输出（内联 Select-String 会超时）
```

---
## 9. 文件地图

```
D:\项目\ios平台agent\          （构建时请用 C:\Users\MSI-NB\rune-ws）
├─ PROJECT_STATE.md          ⭐ 本文件（最先读）
├─ README.md                 设计文档入口
├─ Tools/rune.ps1            ⭐ 构建/测试驱动（**本机唯一可用**的构建入口）
├─ docs/
│  ├─ 进度日志.md            ⭐ 追加式时间线（细节都在这）
│  ├─ 01 … 15                设计文档（01 产品定位 … 15 风险登记册）
│  └─ 附录A / 附录B          渠道事实表 / 技术选型核实表
├─ research/                 取证材料（465 份，非交付物，**刻意入库**）
└─ Packages/
   ├─ RuneKernel/            ✅ 零依赖核心（34 源文件 / 822 测试全绿）
   │  ├─ Package.swift       仅供 macOS 使用；本机走 rune.ps1
   │  ├─ Sources/RuneKernel/        ← 25 个 .swift（清单见下）
   │  └─ Tests/RuneKernelTests/     ← 13 个 .swift
   └─ Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/   ⬜ 骨架（含实现清单）
```

**`RuneKernel` 源文件一览**（找一个能力在哪，先看这里）：

| 分组 | 文件 |
|---|---|
| 值类型与安全 | `JSONValue` `SHA256` `Trust` `Content` `Tool` `Capability` `Errors` |
| 编辑与检索 | `TextPatch` `GlobMatcher` `IgnoreRules` `GrepEngine` |
| 网关 | `ChatRequest` `StreamParsing` `ProtocolEncoders` `ProtocolDecoders` `ToolCallAssembler` `ProviderQuirks` |
| 运行时 | `TurnRunner` `ToolScheduler` `PolicyEngine` `Plan` `Event` `Correction` `Context` `ToolRegistry` `Skill` `SkillLibrary` `Workflow` `VFS` `Shell` `Sandbox` |
| 编排 | `PlanEngine` `ApprovalBroker` `GoalEngine` |

**测试文件**：`JSONAndHashing` `Security` `RuntimeModel` `Patch` `Search` `Gateway` `Policy`
`TurnRunner` `ToolScheduler` `Protocol` `Planning` `GoalEngine` `Correction` `Context` `ToolRegistry`
---

## 10. 里程碑验收标准（摘录自 [14](docs/14-工程路线图与测试策略.md)）

| 里程碑 | 出口标准 |
|---|---|
| **M0 / M1** | 模型能自主完成"修一个简单的失败单测"并在中途被杀后正确恢复 / 3 名内测用户各完成 5 个真实任务，完成率 ≥70% |
| **M2 / M3** | S1 场景（CI 抢救→应用→提交）3 次点击内完成 / 切换任意两家渠道成功率差异 <15% |
| **M4 / M5** | 飞行模式下完成"改函数 + 跑测试 + 写 commit" / 注入套件 0 越权 + 性能基准达标 + 审核材料齐备 |
