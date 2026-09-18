# PROJECT_STATE —— Rune 开发续接文档

> ⚠️ **这是整个项目最重要的文件。任何新会话、任何 Agent、任何人类协作者的第一件事就是读完它。**
> **它必须始终保持在 300 行以内**（够短才读得完）。详细历史放 [`docs/进度日志.md`](docs/进度日志.md)，本文件只保留"现在在哪、接下来做什么、别重复踩什么坑"。

---

## 0. 更新协议（硬性要求，不可跳过）

| 时机 | 必须做的事 |
|---|---|
| **每完成一个可验证的里程碑**（能 build + 能 test 通过） | ① 更新 §2 状态快照 ② 更新 §5 已完成 ③ 在 `docs/进度日志.md` 追加一条 |
| **每次做出新技术决策 / 踩到坑** | 决策写进 §4（含理由）、坑写进 §8（现象 + 原因 + 解法） |
| **每个新会话开始 / 上下文快到上限** | 先读本文档 → 再读 §6 下一步 → 然后动手。**不要从零重新探索代码库**；动手前把脑子里还没落盘的东西先写下来 |

**反向纪律：动手前先查 §5 与 §9；§5 里有的东西不要再实现一遍。别相信"我记得做过了" —— 去查。**

## 1. 项目一句话

**Rune（符文）**：完全在 iPhone/iPad 本地运行的通用 Agent。模型可走云端 API（BYOK，含中转站），但**工具循环、文件系统、代码执行、Git、检索、记忆全部在设备上完成**，没有任何远端执行路径。完整设计见 [`docs/`](docs/)（19 份文档，已完成）。**当前正在把设计变成代码。**

---

## 2. 状态快照

| 项 | 值 |
|---|---|
| **更新日期** | 2026-09-18（按 CI/git 时间戳；更早的日志条目误写成 09-19） |
| **当前阶段** | ⭐ **CI 全线打通（Linux + macOS + 真出 .ipa）→ 进入「接真实 IO」阶段** |
| **当前里程碑** | ✅ **M1-23 首次 CI 全绿：macOS 上真的构建出可侧载的 .ipa**（1032 测试 + CI 验证）—— 下一步见 §6 |
| **已完成里程碑** | ✅ M0 全部（…→**258 出口验收达成**）→ ✅ M1-1 ToolScheduler（282）→ ✅ M1-2 协议适配器（328）→ ✅ M1-3 波次调度（341）→ ✅ M1-4 计划与审批（379）→ ✅ M1-5 GoalEngine（405）→ ✅ M1-6 修正性重试（447）→ ✅ M1-7 上下文装配器（487）→ ✅ M1-8 工具注册表（540）→ ✅ M1-9 技能库 + 场景测试（608）→ ✅ M1-10 Workflow 引擎（657）→ ✅ M1-11 VFS 层（705）→ ✅ M1-12 自研 shell 解释器（775）→ ✅ M1-13 沙箱层（877）→ ✅ M1-14 无 Mac 开发路径（CI + 装机 + 最小 App）→ ✅ M1-15 文件与检索工具（C28，877）→ ✅ **M1-16 渠道网关（C29，912）** → ✅ **M1-17 按协议族分组历史（C30，934）** → ✅ **M1-18 成本账本与熔断（C31，947）** → ✅ **M1-19 结构化压缩（C32，978）** → ✅ **M1-20 出站构建与体检（C33，1001）** → ✅ **M1-21 线路级验证（C34，1018）** → ✅ **M1-22 网关接线（C35，1032）** → ✅ **M1-23 CI 首次全绿并产出 .ipa（C36）** |
| **阻塞项** | 无（**CI 已通，不再需要人工推仓**） |
| **本机可验证范围** | ✅ 平台无关的 Swift 代码（Kernel / 补丁 / 检索 / 网关 / 策略 / **Turn 循环**）<br>❌ iOS 专属（UI / Live Activity / Core ML / VFS 真实文件系统 / 沙箱 / GRDB / JSC）—— 需 macOS |

### 进度条

```
设计文档 / M0 地基   ████████████████████ 100%   ✅ 出口验收已达成
M1 可用内核   ████████████████████  99%   ← 内核 41 源文件 / 1032 测试全绿，**只差真实 IO 与 UI（都要 macOS）**
M2 移动体验 / M3 多渠道      ░░░░░░░░░░░░░░░░░░░░░   0%
M4 端侧+记忆 / M5 上架准备   ░░░░░░░░░░░░░░░░░░░░░   0%
```

### 🎯 M0 出口标准达成情况（docs/14 §2）

| 验收项 | 结果 |
|---|---|
| 模型自主完成"读 → 改 → 跑测试" | ✅ 工具顺序 `grep_search → read_file → apply_patch → run_tests`，bug 真被修好 |
| 中途被杀后正确恢复 | ✅ **对 0..23（场景）/ 0..40（单元）每一个切断点**验证：恢复后文件状态与基线**完全一致**，且**补丁只实际改动一次** |
| 非幂等不自动重做 · 日志可校验 | ✅ 结果未知时进 `awaitingApproval` 并明说"是否已生效无法确定"；✅ 哈希链逐条衔接（`previousHash == 上一条.hash`），场景测试逐条 `verifyHash()` |

### 包结构现状

**包结构**：`RuneKernel` ✅ **41 源文件 / 1032 测试**（本机可测）；`RuneNet` `RuneStore` `RuneVM` `RuneBench` `RuneGateway` `RuneContext` `RuneCore` `RuneTools` `RuneMCP` `RuneUI` ⬜ 骨架（`Package.swift` + 实现清单）。

---

## 3. 环境事实（本机，**这些坑已经踩过，别再踩**）

| 项 | 值 |
|---|---|
| 工作目录（真实） | `D:\项目\ios平台agent` —— **含中文** |
| **ASCII junction** | ⭐ `C:\Users\MSI-NB\rune-ws` → 指向上面那个真实目录（`mklink /J`） |
| **构建命令** | ⭐ `pwsh -NoProfile -File Tools\rune.ps1 build RuneKernel`<br>`pwsh -NoProfile -File Tools\rune.ps1 test RuneKernel` |
| Swift 工具链 | ✅ **6.3.3 for Windows**（`x86_64-unknown-windows-msvc`），满足 WasmKit 的 Swift 6.3 要求 |
| MSVC | VS 2022 Build Tools，**必须经 `vcvars64.bat` 激活**（`link.exe` 不在 PATH）。脚本已处理 |
| 本机工具 | python ✅（`Tools/*.py` 用它）· **bash ✅**（git 自带，`Tools/ci.sh` 可本机跑）· ninja ❌ · CPU 32 核 |
| git | ✅ `core.autocrlf=false` + `.gitattributes` 强制 LF（**补丁引擎的换行保真测试依赖这一点**） |
| **CI（⭐ 现在这是主要的验证通道）** | <https://github.com/Sakura-Lhy0409/rune> · `gh` 已登录（`repo`+`workflow`）· **推 main 即触发** · kernel ✅ / ios ✅（含 .ipa 产物） |
| **不能做的事** | 本机无法构建 iOS App、无模拟器、无法验证 SwiftUI / Live Activity / AVFoundation / Core ML（**这些一律走 CI**） |

**⚠️ `swift build` / `swift test` 在本机不可用**（症状：调 swiftc 时**静默退出、零错误信息**；已排除中文路径、工具链、管道、ASCII junction）—— **本机一律走 `Tools/rune.ps1`**。CI 上标准 SwiftPM 完全正常（`Package.swift` 已被真正解析过）。

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
| D1/D2 | ✅ 设计文档集（`docs/01`–`16` + 附录，19 份）+ 事实取证归档（`research/` 465 份） | 内部链接已校验；事实均带出处；research 刻意入库 |
| C1/C2 | ✅ 续接机制 + 构建/测试闭环 | `PROJECT_STATE.md`、`docs/进度日志.md`、`Tools/rune.ps1` | ⚠️ `swift build/test` 在本机不可用（E1） |
| C3 | ✅ `RuneKernel` 零依赖核心（9 文件 / 85 测试） | `JSONValue` `SHA256` `Trust` `Content` `Tool` `Capability` `Errors` `Plan` `Event` | ⚠️ CryptoKit 是 Apple 专有 → **自实现 SHA-256**；⚠️ `canonicalString` 键序稳定才有指纹去重；⚠️ `VFSPath` 的 `..` 逃逸必须拒；⚠️ **写不蕴含删**；⚠️ 事件哈希链使篡改可检测 |
| C4/C5 | ✅ 补丁引擎（37）+ 检索子系统（50）：`TextPatch` `GlobMatcher` `IgnoreRules` `GrepEngine` | ⚠️ **CRLF 是单个字素簇**（T8/T9）；⚠️ 匹配多处**必须拒绝**、绝不猜；⚠️ 一个 hunk 失败 → 整次不落地；诊断必须可执行 |
| C6 | ✅ 10 个包骨架 | `Packages/Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/` | 依赖声明已校验；占位文件里放的是实现清单 |
| C7/C8 | ✅ 网关纯逻辑（40）+ `PolicyEngine`（37）：`ToolCallAssembler` `ProviderQuirks` `PolicyEngine` | ⚠️ `JSONRepair` **修不好就返回 nil**（交给修正性重试）；⚠️ 并行 index 交错；⚠️ 诊断要写回结构体（T15） |
| C9 | ✅ **最小 Turn 循环（M0 出口达成）**（258 测试） | `TurnRunner.swift` | ⚠️ **步进式**（一次推进一件事）；⚠️ **三步落盘协议**（写意图→执行→写事实）；⚠️ `wasRestored` 必须由运行时**显式**置位 |
| C10/C11 | ✅ 运行时/存储/App 层设计（`docs/10`–`15`）+ 协议适配器（328 测试）：`ProtocolEncoders` `ProtocolDecoders` `StreamParsing` | ⚠️ DeepSeek reasoning 回传按**请求**判定（不是按消息）；⚠️ Gemini 的 `finishReason` 会单独成帧 —— 漏了会**静默丢工具调用** |
| C12/C13 | ✅ 波次调度（341）+ `PlanEngine`（379）：`ToolScheduler` `PlanEngine` | ⚠️ **检查点以波次为单位**；⚠️ 多路径**全部查、取最严**；⚠️ 多个悬空意图**整批**问；⚠️ 按计划**声明的路径**授权；⚠️ 网络出口**不预授权** |
| C14 | ✅ `ApprovalBroker` | `ApprovalBroker.swift` | ⚠️ 超时 = **拒绝**（失败关闭）；⚠️「全部允许」先全量校验再应用；⚠️「记住选择」**缺省必须自动提取路径**，否则退化成整个工具的白名单 |
| C15 | ✅ `GoalEngine`（405 测试） | `GoalEngine.swift` | ⚠️ 受阻需同一条件连续 3 轮；⚠️ **无进展**与受阻是**两个独立计数**；⚠️ 预算/电量门禁**只拦自动续跑**，不拦用户手动发起 |
| C16/C17 | ✅ 修正性重试策略层 + 对话历史协议不变式：`Correction` | ⚠️ 编码器**只发 `summary`** → 建议与候选必须拼进去（T17）；⚠️ 按**根因**分桶；⚠️ 逐字重复立刻止损；⚠️「模型改不了」的错误不记账；⚠️ 运行时引导语 ≠ 用户指令（T20） |
| C18 | ✅ 上下文预算制装配器 + L1 裁剪（487 测试） | `Context.swift` | ⚠️ 中文 token **1 字符 ≈ 1**（用 `/4` 估会低估 4 倍 → 撑爆窗口 / 账单失控，T22）；⚠️ 装配器**永不自己花钱**（L3 只报告不执行，T23）；⚠️ 渲染顺序与块内排序必须**确定性**，否则 Prompt Cache 永不命中；⚠️ 缺「当前目标 / 最近失败」**不许发出去**；⚠️ 输出预留 ≥10% 不可挤占 |
| C19 | ✅ 工具注册表（86 个工具契约）+ 校验器 + 按档可见性（540 测试） | `ToolRegistry.swift` | ⚠️ 声明写错**不报错，只静默少一层保护** → 17 条校验规则把它变成测试失败；⚠️ `pathParameters` **必须声明全**（「声明了但不全」更危险，T26）；⚠️ 路径参数命名要避开 `target`/`source` 这类歧义词；⚠️ 执行类工具输出必须走制品；⚠️ 审批的真正防线是**作用域**不是弹窗 |
| C20/C21 | ✅ 技能库 + 渐进式披露（608）+ 端到端场景测试 `ScenarioTests`：`Skill` `SkillLibrary` | ⚠️ **L1 正文永不自动加载**（API 上就不提供「取全部正文」）；⚠️ 中文 L0 成本是英文的 ~2 倍（设计文档的 15 token 是英文尺子 → 实测改 40，T29）；⚠️ token 预算必须把标题行算进去；⚠️ 技能只能**申请**权限、且必须在加载正文**之前**就位；12 个内置技能各带验证清单；⚠️ **是端到端场景测试挖出两个致命 bug**（审批死循环 T30、`.dispatching` 越界崩 App T31）—— **单模块测试全绿也照不出来**，所以"拼得起来"必须单独有权重 |
| C22/C23 | ✅ Workflow 引擎（657）+ VFS 层（705）：``Workflow`` ``VFS`` | ⚠️ Workflow 引擎**不执行任何东西**（只回答"下一步跑哪些"）；⚠️ `pipeline` 无屏障靠**深度降序**调度；⚠️ VFS **两份实现跑同一套 conformance 断言**（已抓到多处不一致）；⚠️ **读出来必须能原样写回去**（切片曾丢掉末尾换行 → 每次往返都在改文件）；⚠️ 文件名**大小写不敏感**才是 iOS 的真实坑（T34）；⚠️ `verify` 类兜底要在 `.reasoning` 入口**无条件**做（T18） |
| C24/C25 | ✅ 自研 shell 解释器 + 沙箱层：`Shell` `Sandbox` | ⚠️ **"不支持什么"比"支持什么"更重要** —— 每条不支持的语法都要给**可执行的替代**（否则模型只是换个写法再试，来回烧 token）；⚠️ **裸 `$VAR` 必须被拒**（放过去会得到静默的错误答案：命令收到字面量 `$HOME`，然后以看不懂的方式失败；双引号里也一样，T36）；⚠️ **管道中间环节的 stdout 不算可见输出**（否则模型会看到 `hello` 与 `HELLO`，以为跑了两遍，T37）；⚠️ 默认**失败即停且 `;` 也不例外**，但 `||` 后面那条必须照跑 |
| C26 | ✅ 事件日志与投影：`EventLog` | ⚠️ **唯一真相源**：哈希链 + 定期锚点（锚点必须存在 Keychain 等 **Agent 够不到**的地方，否则是自证清白）；⚠️ 三种损坏**分别**报出来（内容被改 / 衔接断了 / 记录被删）—— 用户看到这三句话的感受完全不同；⚠️ **增量投影 == 全量重放**（这条一破，缓存视图与真相就分叉，而分叉后没有东西能告诉你哪个对）；⚠️ **冷启动分诊**：链坏了就什么都不自动做；有外部副作用的必须问用户；僵尸(>24h)只标记中断不自动续跑 |
| C27 | ✅ **无 Mac 开发与验证路径**（`docs/16`）：`.github/workflows/` · `Tools/ci.sh` · `check_ci.py` · `lint_quotes.py` · `Apps/Rune/` | ⭐ GH Actions 的 macOS 运行器负责编译测试，Windows 的 Sideloadly 负责签名装机；⚠️ Linux 那条**把「零 Apple 依赖」变成 CI 断言**；⚠️ 免费 Apple ID 签名只有 7 天（$99/年去掉限制并开 TestFlight）；⚠️ **交互式调试永久做不到** —— 工作方式变成「写测试 → 推 CI → 看报告」 |
| C28 | ✅ **文件与检索工具的真实实现**（877 测试） | `ToolHandlers.swift` · `LocalToolExecutor` | ⭐ 14 个工具（list/read/write/edit/apply_patch/delete/move/copy/stat/mkdir/glob/grep/outline/hash）**真的能干活了**，且因为走 VFS 而**能在本机完整验证**；⚠️ **先按 schema 校验再动手**（否则参数写错的 delete 会先删再报错）；⚠️ `apply_patch` 一处失败则**一个文件都不改**；⚠️ 大输出**必须给制品句柄**，否则"截断"等于"丢数据" |
| C29 | ✅ **渠道网关：多渠道路由 / 降级 / 重试 / 去重 / 中转站**（912 测试） | `Gateway.swift` · `GatewayRouterTests` | ⭐ 用户最关心的两件事（**接入主流模型** + **支持中转站**）在这一层闭环，三条硬规则各有测试守着：① **禁止静默降级**（`DegradationPlan.isVisibleToUser` 永远是 true；思考链支持变了还必须**重建上下文**、窗口变小必须**压缩**）② **`verify` 必须换模型**（同模型自我验证 ≈ 没验证）③ **敏感项目里中转/局域网渠道直接不进候选**（并解释原因，而不是"用了再提醒"）；⚠️ 鉴权**只存 `keyRef`**（配置可随手复制、编码进 JSON 也不泄密，泄密面缩到 Keychain 一处）；⚠️ 被排除的候选**必须带原因**（"为什么没用那个渠道"是用户第一疑问），但**解析不到的别名不算拒绝**（没配那个渠道是正常的，别刷屏）；⚠️ 429 退避 3 次、5xx 只 2 次就换渠道、**配置问题一次都不重试**（重试只会让用户反复看到失败） |
| C30 | ✅ **按协议族分组历史 —— 修掉 3 个「用户第一次用就会炸」的错**（934 测试） | `HistoryGrouping.swift` | ⭐ ① **多工具结果的分组属于协议、不属于运行时**（OpenAI 要求每个结果各自一条、Anthropic/Gemini 要求合成一条，Gemini 相邻同角色直接 `INVALID_ARGUMENT`）② Gemini 的 `functionResponse.name` 从硬编码 `"tool"` 改成**从配对的 toolCall 里找回真名** ③ Anthropic 失败的工具结果补上 `is_error: true`（不补的话「权限被拒」在模型看来与一次成功输出无异）；⚠️ **合并必须先丢空条目再合并**（空条目会成为假的角色隔断：`[user, 空, user]` 过滤后反而变成相邻同角色）；⚠️ **合并永不提权**（信任级取更保守的，否则运行时的引导语会因合并获得「用户授权」身份） |
| C31 | ✅ **成本账本与熔断 —— 上限真的会拦住钱**（947 测试） | `TurnRunner` · `Event` · `CostLedgerTests` | ⭐ 修的是一个**整块「声明了但从不生效」的安全闸门**：`Config.maxCostMicroUSD` 声明过、有默认值、**从没被读过**；`Dependencies.costOfRound` 能注入、**从没被调用过**；`TurnStatus.pausedBudget` 是**永远到不了的状态**；`BudgetWarning`/`TurnPaused`/`TurnResumed` 三个事件**从没被发出过**；`TurnProjection.costMicroUSD` 三个字段**从没被填过**。界面写着「上限 $0.30」，而那行代码对行为没有任何影响 —— 保护**看起来在**，其实不在；⚠️ 修法：① 成本检查放在**调用之前**（烧完再查叫账单不叫熔断）② 账本进**事件日志**（`costRecorded`）并喂给投影，崩溃恢复后「花了多少」不会归零 ③ 上限存**状态**里（`costCeilingMicroUSD`），否则用户点「提高上限」下一轮卡片又弹（同 T30 死循环） ④ 熔断给的是**可执行的三选一**，不是一句「超预算了」⑤ `raiseBudget` 只能从 `.pausedBudget` 进入（不能拿钱包撬开审批） |
| C32 | ✅ **结构化压缩 —— 保住可执行性，不是写散文**（978 测试） | `Compaction.swift` · `CompactionTests` | ⭐ 按 docs/07 §5 把「压缩」做成**结构化摘要**（目标 / 带证据的事实 / 决定 / 制品 / 未完成 / **失败路径** / 不可信来源）：⚠️ 散文摘要丢的是**可执行性** —— 模型读完只知道「大概发生过什么」，于是会把已经失败过的路再走一遍；`rejected_paths` 因此必须渲染成「**不要再试**」的**指令**而不只是一条记录；⚠️ 事实没有证据就**不可用**（编出来的断言会在压缩后继续被当成事实用）；不可信内容必须带出处并被边界标记包住（否则压缩这一步把提示注入的防线拆了）；⚠️ 渲染必须**逐字节确定**（缓存命中率直接决定用户付多少钱）；⚠️ 选级别遵守「**能端侧压就端侧压**」—— 端侧可用时即使装配器建议 L3 也走端侧，因为手机上的钱是用户自己的；估不出成本就**不擅自花钱**，先用结构性裁剪顶着；⚠️ **压缩永不删除事件**（摘要用 `sourceRange` 记住自己覆盖了哪一段） |
| C33 | ✅ **出站请求构建 + 协议体检（顺带修掉一个致命 bug）**（1001 测试） | `RequestBuilder.swift` · `RequestBuilderTests` | ⭐⭐ 第一次把「历史 → 真正发出去的请求」这一段建起来，它当场抓到：**`.start` 从来没有把目标写进 `state.messages`，只发了一条事件** —— 于是模型根本不知道要干什么，而且三家协议都要求 `messages`/`contents` **至少有一条**，「只有 system、没有 messages」的请求**发都发不出去**（整个 App 一行都跑不了）；⚠️ 根因是这一层此前**不存在**：谁来编请求、工具按什么顺序放、发之前检查什么，没有任何地方回答；⚠️ **工具顺序由构建器排序定死**（`Dictionary` 迭代顺序**跨进程不稳定** → 顺序一变请求指纹与 Prompt Cache 全失效，而用户为此多付的钱**不会有任何报错**）；⚠️ 体检给出的是**三种不同的改法**（结果没记 → 去补记；记了但没紧跟 → 挪回调用后面；多出来的 → 对应关系串了），只报错不给路的诊断等于没诊断；⚠️ **失败关闭**：体检不过就**不返回**请求，而不是「发出去试试」 |
| C34 | ✅ **线路级验证：真的编码 → 真的解字节 → 又抓出 3 个真 bug**（1018 测试） | `WireLevelTests.swift` · `ProviderError.classify` | ⭐⭐ 建了一条「线路级假模型」：`历史 → RequestBuilder → RequestEncoder →（脚本化 SSE 字节）→ SSEParser → StreamDecoder → [ModelEvent]`，只把网络换掉，两头全是真实实现。它第一次跑就抓出三个 bug：① **三个解码器把所有中途错误一律写成 `.transient`** —— 而它是「值得重试」：401/402/403 会被**反复重试**，更糟的是**余额不足不算失败**，用户钱包空了 Agent 却报了个成功（修法：`ProviderError.classify` 作唯一分类入口 + `userFacing` 给出下一步）；② **`PolicyEngine.evaluate` 与四个 `authorize*` 都默认读真实时钟** → 过期判定不确定，冻结时钟的测试会**静默失去全部授权**，还把原因误报成「不在授权范围内」（诊断骗人）；③ **Anthropic 的错误体没有状态码**（只有 `type`）→ 不映射就只能一律当可重试，于是「密钥错了」与「服务过载」被当成同一件事；⚠️ 它还暴露了**前面几组测试是「假绿」**：授权被拒后工具**一次都没执行**，而它们只断言了「有配对结果」—— 补记的空结果也满足那一条 |
| C35 | ✅ **模型调用客户端：网关那一层真的被接上了**（1032 测试） | `ModelClient.swift` · `ModelClientTests` | ⭐⭐⭐ 修的是**目前最大的一次「声明式子系统」**：`GatewayRouter.route` / `RetryPolicy.decide` / `Degradation.plan` / `HealthTracker.record*` 在 `Sources/` 里**零调用点** —— 913 行有测试的代码没有任何东西会执行它。于是 Rune 的真实行为是：**不路由、不重试（一次 429 就把这一轮打死）、不记健康（挂掉的渠道永远留着）、不降级、不去重**；⚠️ 修法是给它**唯一执行入口** `ModelClient`（路由 → 去重 → 编码 → 发送 → 解码 → 按 `RetryPolicy` 决定 → 记健康 → 生成**可见的**降级说明）；⚠️ 传输层抽象成**同步协议** `ModelTransport`，于是整条链路能在没有网络、没有 macOS 的条件下被完整验证（脚本化传输返回真实字节），真正的 URLSession 实现留给 `RuneNet`；⚠️ 鉴权真值只从 `credentials`（Keychain）来，**配置里只有引用**，所以日志里永远不会有密钥；⚠️ 顺带记一条**测试纪律**：`#expect` **不中断执行**，断言之后还要用下标就必须先 `guard` —— 否则越界会让整个测试进程崩掉（Windows 上表现成 `0xC000001D`，看起来像环境问题，不是一条干净的失败） |
| C36 | ✅⭐ **首次 CI 全绿：macOS 上真的产出可侧载的 .ipa** | `.github/workflows/` · `VFS.swift` · 仓库 <https://github.com/Sakura-Lhy0409/rune> | ⭐⭐ 这是「没有 Mac 也能做 iPhone App」从**计划**变成**事实**的一步：`kernel` 在 ubuntu + macOS 上都跑通了 `Package.swift`（**它此前从未被真正的 SwiftPM 解析过**），`ios` 的「App 构建与打包」产出了 1.8MB 的 `Rune-unsigned.ipa`（`Payload/Rune.app/{Rune,Info.plist,PkgInfo}`，结构正确、可直接 Sideloadly 签名）；⚠️ **首次 CI 抓到两个真 bug**：① VFS 快照回滚在 macOS 上**根本没生效**（Linux/Windows 通过）—— `restore` 自己切字符串算相对路径，而 macOS 上同一目录有 `/var/…` 与 `/private/var/…` 两种写法，切出垃圾，`try?` 又把错误**完全吞掉**（回滚「成功」了却一个字没变）；改成 `subpathsOfDirectory` + 一律 `try`；② `ios.yml` 打包那步 `ls` 多写一个 `..`；⚠️ 修 VFS 那条时**先把断言改成会打印实际值**才拿到真相 —— 「某某 != 某某」这种失败信息只能靠猜 |
| C37 | ✅ **模拟器冒烟测试真的跑起来了**（并修掉挡路的三处） | `.github/workflows/ios.yml` · `Apps/Rune/{project.yml,UITests}` | ⭐ 从「跑不到」到「**App 在真 iOS 模拟器上完整跑通内核**」：dump 出来的界面证明 **4 次工具调用 · 20 条事件 · 哈希链校验通过**，步骤 `list_dir → read_file → edit_file（创建检查点）→ read_file`，工作区面板指着真实的 `Documents/RuneDemo`；⚠️ 三处修复：① destination **不能写死机型**（`name=iPhone 16` 撞上镜像换机型）→ 运行时挑可用的 iPhone 并打印选中项；② **测试 target 也要 Info.plist**（`GENERATE_INFOPLIST_FILE: YES`，Xcode 报错里就推荐了）；③ UI 测试的 dump 辅助函数要 `@MainActor` 且**不能用 `map(\.label)`**（主线程隔离属性不能取 key path）；⚠️ 唯一还失败的断言是「工作区面板要显示被改的那一行」—— 面板只列文件名、不显示内容（§6 的第一步就是修它） |
| C38 | ✅⭐ **「没有 Mac」这条流水线端到端全绿**（含模拟器 UI 验证） | `Apps/Rune/Sources/RuneApp.swift` · `.github/workflows/ios.yml` | ⭐⭐ 三个 job 全绿：`kernel`（ubuntu + macos + 零依赖审计）、`ios`（包构建测试 + **App 打包出 .ipa**）、**`模拟器冒烟测试`** —— 后者证明 **App 在真 iOS 模拟器上完整跑通内核**：启动 → 点运行 → 时间轴出现 → 哈希链校验通过 → 工作区面板显示磁盘真实内容，**含 Agent 改掉的那一行**。⚠️ 最后那条断言原来一直失败，根因不是内核而是 UI：文件内容被放在**默认折叠的 `DisclosureGroup`** 里，而**折叠区的文字不在辅助功能树里** —— 既让测试看不见，也让「磁盘上的真实内容」这个标题名不副实；改成直接显示内容预览（短文件给全文）后转绿；⚠️ 同时把这条 job 从 `continue-on-error` 改成**阻塞**：只会「报告失败」的测试拦不住任何回归 |

---

## 6. 下一步

### ⭐ CI 已经通了：**Linux 与 macOS 上全绿，并且真的产出了 .ipa**（C36）

**仓库**：<https://github.com/Sakura-Lhy0409/rune>（公开；macOS 运行器对公开仓库免费）
**首次 CI（2026-09-18）**：`kernel` ✅（ubuntu + macos + 零依赖审计）、`ios` ✅ —— 「App 构建与打包」**真的产出可侧载的 `Rune-unsigned.ipa`**（1.8MB，`Payload/Rune.app/{Rune,Info.plist,PkgInfo}`）。「没有 Mac 也能做出能装机的 App」**已经跑通一次**，不再是计划。

**首次 CI 抓到两个真 bug 并已修掉**（VFS 快照回滚在 macOS 上根本没生效 · `ios.yml` 的 `ls` 多一个 `..`）—— 细节见 C36。⚠️ 这说明 CI 的价值**不是"跑一遍测试"，是让"从来没被跑过的路径"没法继续躲着**。

**⚠️ 仍未验证的风险点**（不是「已完成」）：
① **L3 压缩**只有「该压到哪一级 + 产物格式 + 解析」，运行时那一次**付费调用**还没接；
② **Workflow 的 JSC 宿主不存在**（脚本 → DAG 的编译层）；
③ 86 个工具里**14 个已实现**（C28）；其余 72 个分三类：执行（CPython/JSC/WASM）、网络（URLSession + 出口代理）、iOS 原生（相册/日历/定位…）；
（多工具结果的分组 → **C30**；请求真的编得出去 → **C33/C34 已用真实字节验过**；⚠️ **真实渠道**仍要各压一次。）

`RuneKernel` 有 **41 个源文件、1032 项测试**，覆盖：值类型与协议、补丁引擎、检索、
**渠道网关（路由 / 降级 / 重试 / 去重 / 按协议族分组历史）**、**成本账本与熔断**、**结构化压缩**、
**出站请求构建与协议体检**、**模型调用客户端（五个策略真的生效）**、策略引擎、
Turn 循环与崩溃恢复、波次调度、计划引擎、审批代理、目标引擎、修正性重试与协议不变式、
上下文预算制装配、86 个工具契约、技能与渐进式披露、Workflow 批处理编排、
**VFS（真实文件系统 + 内存两份实现）**、**自研 shell 解释器**、**沙箱层**。
**并且有一条端到端场景测试证明它们拼得起来。**

**⭐ 路线 A（现在的正路）—— 见 [`docs/16`](docs/16-无Mac开发与验证路径.md)**

> **用户没有 macOS 机器**，而这件事**已经有解且已经跑通**：GH Actions 的 **macOS 运行器负责编译测试并产出 .ipa**，
> Windows 上的 **Sideloadly 负责签名装机**。唯一真正做不到的是**交互式**调试（断点 / Instruments / 手动点模拟器）
> → 工作方式就是「写测试 → 推 CI → 看报告」。
> ⚠️ 免费 Apple ID 签名只有 **7 天**（$99/年去掉限制并开 TestFlight）。
> `gh` 已登录（账号 `Sakura-Lhy0409`，含 `repo` + `workflow` scope），**推代码 = 跑 CI**，不需要再问。

**路线 B（纯逻辑收尾，价值低）**：检索融合（RRF）、MCP 编解码、cassette 回放夹具。
**路线 A 的实现顺序**：`RuneStore`（GRDB + 事件落盘）→ `RuneNet`（URLSession + SSE + 出口代理）→ `RuneBench`（VFS 落地 + bookmark + CPython 垫片）→ `RuneTools`（86 个工具）→ `RuneCore`（接真实 IO）→ `RuneUI`（docs/08 那套交互）。**每层都要带测试**，因为验证只能走 CI。

## 7. 已知陷阱（不要重复踩）

### 7.1 本机环境陷阱

| # | 陷阱 | 现象 | 解法 |
|---|---|---|---|
| E1 | **`swift build` / `swift test` 静默失败** | 只输出 "Building for debugging…" 然后 exit 1，无错误 | **用 `Tools/rune.ps1`**（见 §3） |
| E2 | **路径含中文导致 swiftc 打不开文件** | `error opening input file 'D:\??Ŀ\ios??agent\…'` | **走 ASCII junction**；脚本已自动处理；生成 .bat 时用 `chcp 65001` + UTF-8 |
| E3 | **`link.exe` 不在 PATH** | manifest 编译失败 | 所有 swiftc 调用都要先 `call vcvars64.bat`（脚本已处理） |
| E4/E5 | **本机跑测试 exe 的两个坑** | 报 `0xC0000135`（静默退出 = STATUS_DLL_NOT_FOUND）／`Testing.__swiftPMEntryPoint` **两个重载**报 ambiguous | PATH 必须含 **Swift Runtimes\6.3.3\usr\bin** 与 **Testing-6.3.3\usr\bin64**（是 `bin64`，不是 `x86_64`）；入口要显式类型标注 `let code: CInt = await ...` |
| E7 | `data as [UInt8]` 在跨平台下不可靠 | `cannot convert value of type 'Data' to type '[UInt8]'` | 用 `data.withUnsafeBytes { update($0) }` |
| E8 | 内联管道看编译输出会**超时**（`pwsh ... \| Select-String` 120s 无输出） | 命令超时、exit 1，但实际在编译 | 改成 `\| Out-File $env:TEMP\x.log` 再读，或 `run_in_background: true` |

### 7.2 项目本身的陷阱（来自设计文档核实）

| # | 陷阱 | 解法 |
|---|---|---|
| T1–T3 | iOS **无 fork/exec** → 走自研解释器/原生命令表；**FTS5 的 unicode61 静默丢弃 CJK** → 用 CJK 分词器或 `trigram`；security-scoped bookmark 的 stop **必须配对**（RAII 包装） |
| T4–T5 | **不要把 git worktree 放 iCloud Drive**（FileProvider 会损坏 `.git`）；Apple FM 端侧窗口只有 **4096 token** → 端侧只做反射 |
| T6–T7 | 二进制里**存在**"远程代码加载"能力就可能被审核引用 → CI 加符号扫描；`json` 键序不稳会破坏指纹去重 → 一律走 `JSONValue.canonicalString()` |
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
| **T39** | ⚠️ 来源分级的**降级路径不能变成「因为隔离做不到就直接放行」** | 模型生成的 Python 请求 → 改走 WASM；WASM 不可用时降级到 CPython，但**确认必须留着** |
| **T40** | ⚠️ `EventLog.verify()` 里 `events[startIndex]` 在**锚点正好覆盖到最后一条**时越界 → 进程崩（`Fatal error: Index out of range`），表现成"测试跑到一半没了、退出码是个奇怪的 `0xC000001D`" | 边界要显式处理（"锚点之后没有新事件"是合法状态）；⚠️ **Windows 上 swift-testing 崩掉时给的不是 exit 1** —— 别把它误判成环境问题 |
| **T41** | ⚠️ PowerShell 函数里 `& python x.py` 的输出**会变成函数返回值** → `(Invoke-Lint) -ne 0` 拿一个数组去比 0，**永远为真**、每次都判失败 | 加 `\| Out-Host`，或把输出捕获到变量、只返回退出码 |
| **T42** | ⚠️ 中文文案里手打 ASCII 引号会**提前闭合字符串字面量**，而编译器报的是 `expected ',' separator` / `cannot find ... in scope` —— 与真实原因毫不相干。本项目为此浪费过 5+ 次编译往返 | 中文引号一律 `「」`；`Tools/lint_quotes.py` 已接入 `rune.ps1`，编译前几十毫秒就指到行。⚠️ 判据是**「中文出现在字符串与注释之外」**——"数引号"是错的（那行引号数是偶数，数不出来） |
| **T43** | ⚠️ 工具名幻觉的兜底用「**最长公共前缀**」太弱：`reed_file` 与 `read_file` 前缀只有 `re`（2）够不到阈值 4 → 模型打错一个字母得不到任何提示，只能再猜 | 改用**编辑距离**（拼写错误正是它的强项），公共前缀降级为同距离时的排序依据 |
| **T44** | ⚠️ 工具参数词汇与引擎词汇不一致时会**静默退化**：工具的 `output_mode: "count"` 直接喂给 `GrepQuery.OutputMode(rawValue:)` → 落到 `?? .matches`，于是"只要计数"变成"返回全部匹配" | 两边词汇不一致就写**显式映射函数**，别依赖 `rawValue` 恰好同名 |
| **T45** | ⚠️ Foundation 的 `JSONEncoder` **默认把 `/` 转义成 `\/`**（`URL`、路径、`keychain://` 里全是 `/`）→ `contains("keychain://relay")` 这类断言**永远为假**，于是"配置里到底有没有把密钥带出去"这个安全检查沦为**摆设**（写成 `#expect(!json.contains(...))` 时更糟：它永远为真，**假装检查过了**） | 比对前 `replacingOccurrences(of: "\\/", with: "/")`，或设 `outputFormatting = .withoutEscapingSlashes`。**更硬的判据是查结构而不是查字符串**：断言"只有 `keyRef` 字段、没有任何像密钥的串" + 编解码往返相等 |
| **T46** | ⚠️ **三家对「多工具结果」的要求是相反的**（OpenAI 每个结果各自一条 `tool` 消息；Anthropic/Gemini 必须合成一条，Gemini 相邻同角色直接 `INVALID_ARGUMENT`）。而运行时的历史是「一个结果一条 `.tool` 消息」——让运行时去迁就某一家，另外两家就错 | **分组规则属于协议，不属于运行时**：编码期按 `MessageGrouping.applying(协议族, to:)` 处理。⚠️ 别指望「服务端会替我合并」——Gemini 那条**用户第一次用就会炸**，而它只要写测试就能提前抓到 |
| **T47** | ⚠️ 编码器里的**占位值**：`functionResponse.name` 与 OpenAI `requiresToolResultName` 都曾写死成字面量 `"tool"` —— 那是一个**不存在的函数名**。宽松端点静默通过、严格端点报「函数响应与调用不匹配」，而它偏偏只在那一小撮端点上暴露，是最难联调的一类错 | 真值能从历史里找回来就别用占位：`ToolResult` 只带 `callID`，名字要用 `MessageGrouping.toolNames(in:)` 从配对的 `toolCall` 里查。**占位只能作为「查不到时的最后兜底」**，且必须写清它为什么存在 |
| **T48** | ⚠️ **声明式的规则表如果只有测试引用、编码器不经过它，那它是文档不是契约**：`HistoryGrouping.forFamily` 一度没人调用，编码器各自无条件 `merge` —— 于是「表里写不合并」与「实际行为」是两回事，**而规则表那几条断言照样全绿**（它们在测表，不在测行为）。破坏性验证时才暴露：把表改坏，行为测试一条都没红 | 给规则表一个**唯一执行入口**（`MessageGrouping.applying`），编码器只走它。⚠️ 与 T26 是同一类病（「看上去是对的」比「明显是错的」更危险）：**判断这类问题的唯一办法是故意破坏它，看有没有测试变红** |
| **T49** | ⚠️ **一整块安全闸门可以只以「声明」的形式存在**：上限常量、可注入的依赖、专用状态、三个事件、投影字段 —— 全都写好了、编译通过、注释齐全，而**没有任何一行代码读它**。它比「没有这个功能」更危险：设置页会显示「上限 $0.30」，于是用户以为被保护着。⚠️ 还有一个特征信号：**消费端接好了、生产端没接**（`EventProjector` 会处理 `TurnPaused`，却没有任何地方**发**它） | 判据是**grep 它该读的那个标识符**：如果它只出现在自己的声明与初始化里，那就没接上。更硬的判据是**破坏性验证**：把闸门改成永不触发，看有没有测试变红（本轮：25 条断言变红）。⚠️ 与 T48 同源 —— 本项目已经在这上面栽过两次，新增任何「上限/阈值/白名单」时先问：**谁读它？** |
| **T50** | ⚠️ **「只输出 JSON」是一句模型经常不听的指令**：它会包 ``` 围栏、前后加寒暄，还会在说明里写**占位对象**（「下面这种 `{}` 是空对象：真正的在下面」）。只认纯 JSON 的解析路径于是 **100% 失败** —— 而表现得像「模型不会做这件事」，不是像「我们的解析器太窄」 | 解析器必须 ① 先把 JSON **抠出来**（括号配平要**感知字符串与转义**，否则含 `if (a) { b }` 的字符串会在中间就以为配平）② **只抠第一块不够** —— 诱饵 `{}` 也是合法 JSON，所以要由调用方**按形状挑**（「第一个带 `goal` 的对象」）。⚠️ 修完要回归一条：纯 JSON **不能**被判成「修过」，否则「模型给的参数有多不准」这个统计就废了 |
| **T51** | ⚠️⚠️ **「病史」的中间态本来就不合法，所以校验只能长在「要发出去的那一刻」**：三步落盘协议（写意图 → 执行 → 写事实）保证了一个窗口 —— 模型刚给出 `tool_calls`、结果还没写出来的那一瞬，历史里就是「调用没有配对结果」。若把「每个 tool_call 必须有结果」当成**每一步**的前置条件去断言/拦截，运行时会被**判死** | 闸门长在 `RequestBuilder`（唯一的发送路径），**不是**长在状态机的每一步上。写测试时也要注意：**只在 `.reasoning`（下一步就会调模型）的状态上体检** —— 「每一步都体检」写出来的第一版就因为这个原因红了。⚠️ 推论：任何「历史级」的不变式，都要先问清楚**它在哪个时间点才必须成立** |
| **T52** | ⚠️⚠️ **把「值得重试」当兜底分类，等于把「谁来处理」这一整套设计抹掉**：三个流式解码器原来都写 `kind: .transient`，于是 **401（密钥错）/ 402（余额不足）/ 403 全都被重试**；而更坏的是运行时只判 `!isRetryable` 才决定要不要失败 —— **余额不足于是不算失败**，Agent 继续往下跑并报了个「成功」，用户在账单上才发现 | 分类必须看**状态码**（`ProviderError.classify` 是唯一入口），面向用户的话要说清「怎么了 + 下一步做什么」。⚠️ Anthropic 的错误体**没有状态码**、只有 `type` → 必须有一张 `type → status` 映射表，否则只能一律 transient。⚠️ 通用教训：**兜底分支要选最保守的那一个**。`.transient` 看着无害，实际含义是「继续花钱重试」—— 兜底选它，等于把决定权交给运气 |
| **T53** | ⚠️ **时钟没注入 = 授权静默失效，理由还是骗人的**：`CapabilityToken.isExpired(asOf:)` 与 `authorizeFile` 等的 `asOf` 默认 `Date()`，`PolicyEngine.evaluate` 也没收 `now` —— 于是把时钟冻结在过去的测试**全部授权都会失败**，而报出来的原因是「不在本次授权范围内」（真实原因是过期）。排查代价很高：现象是「工具一次都没被执行」，看起来像策略引擎或工具实现坏了 | 凡是**读时钟做判定**的地方都要收 `now`（`evaluate(_:context:now:)` 已补），并且**先判过期再判范围** —— 两者给用户的下一步完全不同。⚠️ 推论：发现一个「默认 `Date()`」就发现了一个**不确定性入口**，也是「测试假绿」的常见来源 |
| **T54** | ⚠️⚠️ **一个完整的子系统可以只以「声明 + 测试」的形式存在**：913 行、几十项测试、注释齐全、每条规则都「验证过」—— 而 `GatewayRouter.route` / `RetryPolicy.decide` / `Degradation.plan` / `HealthTracker.record*` 在 `Sources/` 里**零调用点**。这类缺陷的可怕之处在于**测试全绿反而加强了错觉**：测试在测模块自己的行为，从没测过「它被调用」 | ① 每个模块要有**唯一执行入口**，规则表/策略只能从那里经过（`ModelClient` 之于网关）；② 定期做一次**调用点普查**：对每个公开入口 grep 一次「它在本文件之外出现过吗」——本次就是靠这一招一次性挖出五个（路由/重试/降级/健康/去重）；③ 端到端测试必须断言**可观测的行为变化**（发了几枪、打到哪个 URL、健康是否被摘掉），而不只是「结果对」。⚠️ 与 T48/T49 同源，本项目已经栽过三次 —— **新增任何一层「能力」时先问：谁调它？** |
| **T55** | ⚠️ **平台差异最会藏的地方是「同一个目录的两种写法」**：macOS 上 `/var/…` 与 `/private/var/…` 指同一个目录（临时目录真实位置在 `/private/var` 下），于是任何「用字符串切前缀算相对路径」的代码在 macOS 上会切出垃圾，而在 Linux/Windows 上**一路正常** | 相对路径**交给文件系统给**（`subpathsOfDirectory`），不要自己切字符串。⚠️ 更狠的是：**`try?` 会把这类错误变成静默的成功** —— 一个「看起来回滚了、其实一个字没变」的回滚比直接报错危险得多。判据：凡是「失败也没关系」的地方都要问一句「失败了用户会以为发生了什么」 |
| **T56** | ⚠️ **UI 测试的失败细节默认是「读不到」的**：`xcodebuild test` 把断言消息、界面层级、截图都塞进 `.xcresult` bundle，而那个格式在 **Windows 上读不了** —— 没有 Mac 的开发路径下，等于每次失败都只能猜 | **主动把要诊断的东西 `print` 到 stdout**（CI 日志能读）：界面上有哪些文字、哪些按钮、导航栏标识符。本次就是靠这个一眼看出「面板只列文件名、不显示内容」。⚠️ 与「断言失败信息必须带实际值」同源：**可观测性要在写代码时就设计进去** |

---

## 8. 硬约束速查（写代码前先看这一节）

```
执行        ❌ fork/exec/posix_spawn   ❌ JIT   ❌ dlopen 下载的 dylib
文件        ✅ 仅容器内 + 用户显式授权的目录（security-scoped bookmark）。⚠️ iOS 文件名**大小写不敏感**（T34）
后台        ⏱ BGAppRefresh 30s · 静默推送 30s/每小时2-3条 · 延续处理任务"数分钟或更久" · Live Activity ≤12h
端侧模型    4096 token/会话（含指令与工具 schema）· 建议工具 ≤3-5 个 · 内存实测约 3.1GB（6GB 机型）
存储        ❌ unicode61 分词   ✅ CJK tokenizer / trigram   ⚠️ sqlite-vec 需静态注册   ⚠️ 文件名**大小写不敏感**(T34)
体积        内嵌 CPython ⇒ App 约 1-2GB（不可优化，只能接受）
审核        2.5.2 + ADPLA §3.3.1(B) · 1.2（过滤必须在二进制内）· 5.1.2(i)（第三方 AI 需显式许可）
本机构建    必须走 Tools\rune.ps1；swift build/test 不可用。⚠️ 用 Out-File 看编译输出（内联 Select-String 会超时）
成本        每一次模型调用**之前**必须查成本上限；每一轮都必须落 costRecorded。上限存在 TurnState 里（用户中途改过的是它）
```

---
## 9. 文件地图

```
D:\项目\ios平台agent\          （构建时请用 C:\Users\MSI-NB\rune-ws）
├─ PROJECT_STATE.md          ⭐ 本文件（最先读）
├─ README.md                 设计文档入口
├─ .github/workflows/        ⭐ kernel.yml（Linux+macOS）/ ios.yml（Mac 构建 + 出未签名 ipa）
├─ Apps/Rune/                iOS App（XcodeGen project.yml + SwiftUI 源码 + UI 冒烟测试）
├─ Tools/  rune.ps1(本机唯一入口) · ci.sh(与 CI 同一套检查) · check_ci.py · lint_quotes.py · check_docs.py
├─ docs/
│  ├─ 进度日志.md            ⭐ 追加式时间线（细节都在这）
│  └─ 01 … 16 + 附录A/B      设计文档（01 产品定位 … 16 无 Mac 路径）/ 渠道事实表 / 技术选型核实表
├─ research/                 取证材料（465 份，非交付物，**刻意入库**）
└─ Packages/
   ├─ RuneKernel/            ✅ 零依赖核心（41 源文件 / 1032 测试全绿；Sources 41 个 .swift、Tests 31 个）
   └─ Rune{Net,Store,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/   ⬜ 骨架（含实现清单）
```

**`RuneKernel` 源文件一览**（40 个 .swift）：
| 分组 | 文件 |
|---|---|
| 值类型与安全 | `JSONValue` `SHA256` `Trust` `Content` `Tool` `Capability` `Errors` |
| 编辑与检索 | `TextPatch` `GlobMatcher` `IgnoreRules` `GrepEngine` |
| 文件系统与执行 | `VFS` `Shell` `Sandbox` `ToolHandlers` |
| 协议与组装 | `ChatRequest` `StreamParsing` `ProtocolEncoders` `ProtocolDecoders` `ToolCallAssembler` `ProviderQuirks` `HistoryGrouping` `RequestBuilder` |
| 渠道网关 | `Gateway`（渠道配置 / 路由 / 降级 / 重试 / 去重）`ModelClient`（**唯一的执行入口**：路由 → 编码 → 发送 → 解码 → 重试 → 降级 → 记账） |
| 运行时 | `TurnRunner` `ToolScheduler` `PolicyEngine` `Plan` `Event` `Correction` `Context` `Compaction` `ToolRegistry` `EventLog` |
| 编排 | `PlanEngine` `ApprovalBroker` `GoalEngine` `Skill` `SkillLibrary` `Workflow` |

**测试文件**（31 个 / 1032 项）：`JSONAndHashing` `Security` `RuntimeModel` `Patch` `Search` `Gateway` `GatewayRouter` `Policy` `TurnRunner` `ToolScheduler` `Protocol` `HistoryGrouping` `Planning` `GoalEngine` `Correction` `Context` `ToolRegistry` `Skill` `Workflow` `VFS` `Shell` `Sandbox` `EventLog` `Scenario` `ToolHandlers` `CostLedger` `Compaction` `RequestBuilder` `WireLevel` `ModelClient`
## 10. 里程碑验收标准（摘录自 [14](docs/14-工程路线图与测试策略.md)）

| 里程碑 | 出口标准 |
|---|---|
| **M0 / M1** | 模型能自主完成"修一个简单的失败单测"并在中途被杀后正确恢复 / 3 名内测用户各完成 5 个真实任务，完成率 ≥70% |
| **M2 / M3** | S1 场景（CI 抢救→应用→提交）3 次点击内完成 / 切换任意两家渠道成功率差异 <15% |
| **M4 / M5** | 飞行模式下完成"改函数 + 跑测试 + 写 commit" / 注入套件 0 越权 + 性能基准达标 + 审核材料齐备 |
