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
| **更新日期** | 2026-09-18（C58 ask_user） |
| **当前阶段** | ▶️ **真实模型端到端跑通（C46）+ Git 引擎（C47–C54）+ JS 执行宿主 + `todo_write` + `ask_user`（C55–C58）** —— **1262 包测试全绿**。整项目未完工 |
| **当前里程碑** | ✅ **M0 出口标准·云端版（C46）** —— 真实模型（`gpt-5.5`）自主完成「读 → 改 → 复读确认」，途中经审批门与崩溃恢复校验。⚠️ 此前「C45 云推理被账户拒绝」是**选题错误造成的假结论** |
| **已完成里程碑** | ✅ M0 全部（…→**258**）→ ✅ M1-1…M1-15（→877）→ ✅ M1-16…M1-23（→1032）→ ✅ **M1-24 模拟器冒烟** → ✅ **M1-25 交接 macOS** → ✅ **M1-26 RuneStore 跑绿（C39）** → ✅ **M1-27 RuneNet（C41）** → ✅ **M2-2 真实运行时接线（C45）** → ✅ **M0 云端出口验收（C46）** → ✅ **M3-1 Git 引擎（C47–C54）** → 🔨 **M3-2 执行宿主（C55/C56 JS 已通；WASM/CPython 待做）+ M2-3 交互工具（C57 todo / C58 ask_user）** |
| **阻塞项** | **云推理阻塞已解除（C46）**。仍缺：真机签名 + iOS 27 SDK、执行宿主（CPython/WASM/JSC）、Git 引擎、MCP、记忆检索/L3 压缩 —— 见 [docs/19 §5](docs/19-真实运行时与验收.md#5-距离整个项目完成的剩余项) |
| **本机可验证范围** | ✅ **全部 11 个包**（含 GRDB / RuneStore）＋ **iOS App 构建与 .ipa 打包**（xcodebuild + xcodegen 已装）<br>✅ 可以交互式调试了（断点 / 模拟器 / Instruments）<br>❌ 真机签名装机仍需 Apple ID（免费 7 天） |

### 进度条

```
设计文档 / M0 地基   ████████████████████ 100%   ✅ 出口验收已达成
M1 内核与 App 接线 ✅ C45；**真实云端推理已打通（C46）** —— 真实模型驱动工具循环跑通
M2 UI 首版与系统扩展  ✅ C42；iOS 27 / 相机语音 / 生产后台与模型仍需验收
M4 端侧+记忆 / M5 上架准备   ░░░░░░░░░░░░░░░░░░░░░   0%
```

### 🎯 M0 出口标准达成情况（docs/14 §2）

| 验收项 | 结果 |
|---|---|
| 模型自主完成"读 → 改 → 跑测试" | ✅ 工具顺序 `grep_search → read_file → apply_patch → run_tests`，bug 真被修好 |
| 中途被杀后正确恢复 | ✅ **对 0..23（场景）/ 0..40（单元）每一个切断点**验证：恢复后文件状态与基线**完全一致**，且**补丁只实际改动一次** |
| 非幂等不自动重做 · 日志可校验 | ✅ 结果未知时进 `awaitingApproval` 并明说"是否已生效无法确定"；✅ 哈希链逐条衔接（`previousHash == 上一条.hash`），场景测试逐条 `verifyHash()` |

### 包结构现状

**包结构**：Kernel **1167** / Net **24** / Store **14** / Core **24** / **Bench 20** / Tools **7** / UI **6** 测试，共 **1262**。Core 有真实运行时、Tools 有 PDF/OCR/CSV、Bench 有 JS 宿主、Store schema v2 含原子检查点；其余 4 包（Context/Gateway/MCP/VM）仍是骨架。11 包可构建。
---

## 3. 环境事实（本机 = **macOS**，C39 起）

| 项 | 值 |
|---|---|
| 工作目录 | `/Users/chuzu/Desktop/rune-src`（**纯 ASCII**，不再需要 junction） |
| **构建 / 测试** | ⭐ `swift build --package-path Packages/<包>` · `swift test --package-path Packages/<包>` —— **秒级，直接可用** |
| 全部包 + 审计 | `bash Tools/ci.sh all`（或 `build`/`test`/`audit`/`ios`/`ipa`/`kernel`） |
| Swift / Xcode | Swift **6.3.3**（arm64-apple-macosx26.0）· **Xcode 26.6** · iOS SDK **26.5** |
| 已装工具 | `xcodegen` 2.46 · `gh` 2.101（均 `brew install`）· python3 3.11 · 模拟器 iOS 26.5 / 17.4 |
| git | ✅ 历史已恢复（本轮基线 `30869b6`）· ⚠️ **`core.fileMode=false` 在本机是必须的**（见 T57）· `.gitattributes` 强制 LF（**补丁引擎的换行保真测试依赖这一点**） |
| **CI** | <https://github.com/Sakura-Lhy0409/rune> · ✅ **C40 API 实测 `pull/push/admin=true`**；未执行推送，分支保护另行检查 |
| **待外部条件** | 真机签名/设备 · iOS 27 SDK · PinAI 实际可用文本模型线路（现有 Key 可生图，3 个文本型号被上游拒绝） |

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

| 09-18 | C41 采用异步 URLSession + 同步 ModelTransport 桥接；网关等待点可注入；下一步先做 RuneCore 最小接线 | 保留已测内核接口，同时禁止主线程阻塞；先验证真实 IO/逐步落盘，再扩展平台执行器。出口按 origin 限定且拒绝跨源重定向 |
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
| C33 | ✅ **出站请求构建 + 协议体检（抓到一个致命 bug）**（1001） | `RequestBuilder.swift` | ⭐⭐ 第一次把「历史 → 真正发出去的请求」这一段建起来，当场抓到：**`.start` 从来没把目标写进 `state.messages`** —— 模型根本不知道要干什么，而且三家协议都要求 `messages` **至少一条**，「只有 system」的请求**发都发不出去**（整个 App 一行都跑不了）。⚠️ 工具顺序**由构建器排序定死**（`Dictionary` 迭代序跨进程不稳 → 指纹与 Prompt Cache 全失效，而用户多付的钱**不会有任何报错**）；⚠️ 体检给三种**不同改法**，只报错不给路等于没诊断；⚠️ **失败关闭**：体检不过就不返回请求 |
| C34 | ✅ **线路级验证：真编码 → 真解字节 → 又抓出 3 个真 bug**（1018） | `WireLevelTests.swift` · `ProviderError.classify` | ⭐⭐ 建了「线路级假模型」（只换掉网络，两头都是真实实现），第一次跑就抓到：① ⚠️ **三个解码器把所有中途错误一律标成 `.transient`** → 401/402/403 被**反复重试**，更糟的是**余额不足不算失败**（用户钱包空了 Agent 却报成功）→ 修法：`ProviderError.classify` 作唯一分类入口；② ⚠️ `PolicyEngine` 读真实时钟 → 冻结时钟的测试**静默失去全部授权**，还把原因**误报成「不在授权范围内」**（**T53**）；③ ⚠️ Anthropic 错误体**没有状态码**只有 `type` → 必须有一张映射表。⚠️ 它还暴露**前面几组测试是假绿**：授权被拒后工具**一次都没执行**，而它们只断言了「有配对结果」（补记的空结果也满足） |
| C35 | ✅⭐ **模型调用客户端：网关那一层真的被接上了**（1032） | `ModelClient.swift` | ⭐⭐⭐ 修的是**最大的一次「声明式子系统」**：`GatewayRouter.route`/`RetryPolicy.decide`/`Degradation.plan`/`HealthTracker.record*` 在 `Sources/` 里**零调用点** —— 913 行有测试的代码没有任何东西会执行它。于是真实行为是：**不路由、不重试（一次 429 就打死这一轮）、不记健康、不降级、不去重**。修法是给它**唯一执行入口** `ModelClient`；⚠️ 传输层抽象成**同步协议** `ModelTransport`，于是整条链路在没有网络、没有 macOS 的条件下也能被完整验证（真正的 URLSession 实现留给 `RuneNet`）；⚠️ 鉴权真值只从 `credentials`（Keychain）来，**配置里只有 `keyRef`**。**通用教训见 T54：新增任何一层「能力」时先问「谁调它？」** |
| C36 | ✅⭐ **首次 CI 全绿：macOS 上真的产出可侧载的 .ipa** | `.github/workflows/` · `VFS.swift` · 仓库 <https://github.com/Sakura-Lhy0409/rune> | ⭐`kernel` 在 ubuntu + macOS 上都跑通了 `Package.swift`（**它此前从未被真正的 SwiftPM 解析过**），`ios` 的「App 构建与打包」产出了 1.8MB 的 `Rune-unsigned.ipa`（`Payload/Rune.app/{Rune,Info.plist,PkgInfo}`，结构正确、可直接 Sideloadly 签名）；⚠️ **首次 CI 抓到两个真 bug**：① VFS 快照回滚在 macOS 上**根本没生效**（Linux/Windows 通过）—— `restore` 自己切字符串算相对路径，而 macOS 上同一目录有 `/var/…` 与 `/private/var/…` 两种写法，切出垃圾，`try?` 又把错误**完全吞掉**（回滚「成功」了却一个字没变）；改成 `subpathsOfDirectory` + 一律 `try`；② `ios.yml` 打包那步 `ls` 多写一个 `..`；⚠️ 修 VFS 那条时**先把断言改成会打印实际值**才拿到真相 —— 「某某 != 某某」这种失败信息只能靠猜 |
| C37 | ✅ **模拟器冒烟测试真的跑起来了**（并修掉挡路的三处） | `.github/workflows/ios.yml` · `Apps/Rune/{project.yml,UITests}` | ⭐ 从「跑不到」到「**App 在真 iOS 模拟器上完整跑通内核**」：dump 出来的界面证明 **4 次工具调用 · 20 条事件 · 哈希链校验通过**，步骤 `list_dir → read_file → edit_file（创建检查点）→ read_file`，工作区面板指着真实的 `Documents/RuneDemo`；⚠️ 三处修复：① destination **不能写死机型**（`name=iPhone 16` 撞上镜像换机型）→ 运行时挑可用的 iPhone 并打印选中项；② **测试 target 也要 Info.plist**（`GENERATE_INFOPLIST_FILE: YES`，Xcode 报错里就推荐了）；③ UI 测试的 dump 辅助函数要 `@MainActor` 且**不能用 `map(\.label)`**（主线程隔离属性不能取 key path）；⚠️ 唯一还失败的断言是「工作区面板要显示被改的那一行」—— 面板只列文件名、不显示内容（§6 的第一步就是修它） |
| C38 | ✅⭐ **「没有 Mac」这条流水线端到端全绿**（含模拟器 UI 验证） | `Apps/Rune/Sources/RuneApp.swift` · `.github/workflows/ios.yml` | ⭐⭐ `kernel`（ubuntu + macos + 零依赖审计）、`ios`（包测试 + **出 .ipa**）、**`模拟器冒烟测试`** 三个 job 全绿，后者证明 **App 在真模拟器上跑通内核**（时间轴 · 哈希链通过 · 工作区显示磁盘真实内容，含 Agent 改的那一行）。⚠️ 那条断言原来失败，根因不在内核而在 UI：内容放在**默认折叠的 `DisclosureGroup`** 里，而**折叠区的文字不在辅助功能树里**；⚠️ 同时把该 job 从 `continue-on-error` 改成**阻塞**；⚠️ 诊断细节在 `.xcresult` 里（Windows 读不了）→ 主动 `print` 到 stdout（T56） |
| C39 | ✅⭐ **macOS 环境接管 + `RuneStore` 真的跑绿了**（1040 测试） | `Packages/RuneStore/Sources/RuneStore/EventStore.swift` · `Tests/…/EventStoreTests.swift` · `docs/12` · `RuneKernel/Event.swift` | ⭐⭐ 交接文档 §5 悬着的那件事**做完了**：`RuneStore` 编译通过、**8/8 测试绿**，并当场抓出两个真 bug：① ⚠️⚠️ **事件表主键写成单列 `seq` → 开第二个会话直接 `UNIQUE constraint failed: event.seq`**。根因是**文档与内核不符**：`docs/12` 写 `seq` 全局单调、主键单列，而内核 `EventLog` 是**每会话一个实例**、序号 `events.count + 1`（**全部消费方**——`verify()` 定锚点、`EventProjector.lastSequence`、`turn.lastCheckpointSeq`——都按会话内序号读它）。**对的是内核，过时的是文档**；改法：主键改 `(session_id, seq)`、`docs/12` 与 `RuntimeEvent.sequence` 注释同步改正（⚠️ SQLite 的 `INTEGER PRIMARY KEY` 是 rowid 别名**不能加列**，必须用表级 `PRIMARY KEY (...)`）② ⚠️ **篡改检测测试是假绿**：它 `replacingOccurrences(of: "/workspace/1.md")`，而 `JSONEncoder` 默认把 `/` 转义成 `\/`（**T45**）→ 磁盘字节里一次都匹配不到 → UPDATE 改 0 行 → 链照样"通过"。改法：改一个**不含 `/`** 的字段让两件事解耦，并补两条守卫（`tampered != json`、`db.changesCount == 1`）；⚠️ 顺带把断言从"不 OK"收紧到"必须恰好是 `.tampered` 且 `firstBadSequence == 2`"（只断言"不 OK"的话判成 `brokenLink` 也过，而那是另一种损坏）。两条都做过**破坏性验证**：还原原始主键 → `chainsArePerSession` 变红；让篡改空转 → 篡改测试变红。③ ⚠️⚠️ **顺带发现两个「守门人」在迁移那一刻静默下岗**：`Tools/lint_quotes.py` 与 `Tools/check_ci.py` **只挂在 Windows 专用的 `Tools/rune.ps1` 上**（`PROJECT_STATE` 里「已接入 CI」是假的）—— 一个没人再跑的检查，与一个一直在通过的检查**看起来完全一样**（T54 的又一次应验）。引号体检本身还带一个只在「先跑过一次 iOS 构建」后才暴露的崩溃：`Apps/**/*.swift` 会匹配到 **目录** `…/checkouts/GRDB.swift`（`**` 可匹配零段）→ `IsADirectoryError`；同时它虚报「检查了 86 个文件」（实为 565，其中 479 个是 GRDB 第三方源码）。修法：`is_file()` 过滤 + 排除构建产物，**并把两个检查都挂进 `Tools/ci.sh audit`** —— CI 的审计 job 跑的就是它，本地与 CI 从此改一处两边生效 |
| C40 | ✅ **项目接线与 macOS 开发基线复核** | [docs/18](docs/18-macOS开发基线与项目现状.md) | 11 包 / 1040 包测试 / 1 模拟器冒烟 / Release IPA 通过；更正 README、GitHub 权限和 Windows 入口残留；App 仍用脚本模型与内存日志 |
| C41 | ✅ **RuneNet 真实 HTTP/SSE 传输**（1067 包测试） | `RuneNet/NetworkPolicy.swift` · `URLSessionModelTransport.swift` · [docs/06 §15](docs/06-模型网关与中转站.md#15-实现回写runenet-第一片c41) | 24 项真实网络/策略测试；同步桥接 + 异步取消；同源重定向与内存限额；ModelClient 实际退避、保留已分类错误；TSan 无竞争；审计落库/Keychain/App 接线待做 |

| C42 | ✅ **原生 UI 与系统扩展首版** | [UI 实现与验收](docs/design/ui-implementation.md) | 1072 包测试 / 9 UI 流程通过；系统灵动岛紧凑/展开实测；本地审阅/撤销/编辑/持久化；目标/Runebook/渠道/快捷操作；iOS 27 SDK 与真机硬件未验收 |
| C43 | ✅ **PinAI 生图图标接入** | [图标与提示词](docs/design/icon-brief.md) | 已核对模型 ID gpt-image-2.5-flare；生成浅色/深色玻璃符文，导出 1024 RGB、无透明像素，60px 检查与 Xcode 图标构建通过；原图保留 |
| C45 | ✅ **App → 真实运行时 → 工具 → 数据库闭环** | [docs/19](docs/19-真实运行时与验收.md) | 1101 包测试 / 10 UI 通过；原子落盘、审批恢复、预算预留、18 工具、系统后台接口；⚠️ 当时记的「真实 PinAI 文本请求被拒」是**假结论**，见 C46 |
| C46 | ✅⭐ **真实云端推理打通 —— M0 出口标准在真实模型下达成** | `RuneValidation/main.swift` · `.env.pinai`（已忽略） | ⭐⭐ **项目第一次由真实模型端到端驱动 Rune**：`gpt-5.5` 收到目标 → 调 `read_file`/`edit_file` → **审批门生效**（`awaitingApproval`）→ 自动批准后真的改盘 → 复读确认 → 事件落盘、重开库验链通过，输出 `LIVE_VALIDATION_PASSED`。⚠️⚠️ **C45 的阻塞结论是错的，错在选题**（详见 T62）。⚠️ 验收脚本同时加固：上游 503 抖动改为**重开干净会话重试**（只对瞬时错误），真失败照样红 |
| C47 | ✅ **Git 引擎地基 1/4：纯 Swift 的 zlib/DEFLATE 解压** | `Inflate.swift` · `InflateTests` · `Tools/make_inflate_fixtures.py` | 解锁 14 个 `git_*` 工具的第一步：iOS 无 fork/exec ⇒ **没有系统 git**，必须自己读懂 `.git`，而每个 git 对象都是 zlib 压缩的。全量 RFC 1950/1951（stored/固定/动态 Huffman）。⚠️ 三处刻意「啰嗦」都被破坏性验证逼过：① **游程复制必须逐字节**（`distance < length` 时源区间与目标重叠，语义是边写边读）—— 改成批量切片**直接越界崩**；② **必须有输出上限**（34 字节能解出 10000 字节，压缩比 1000:1；无上限时 iOS jetsam 会杀掉整个 App，T38 同类）—— 去掉后炸弹测试变红；③ LEN/NLEN 必须互反、距离不得越窗。损坏**分类报出**（头/截断/校验和/块类型/码长/距离/超限），不写「解压失败」。夹具由真实 zlib 生成入库，测试纯数据驱动 |
| C48 | ✅ **Git 引擎地基 2/4：SHA-1 与对象寻址** | `SHA1.swift` · `SHA1Tests` | ⚠️ 项目别处用 SHA-256（事件链，防篡改），但 **Git 的对象 ID 是 SHA-1** —— 仓库格式的一部分，不是我们的选择（立场同 SHA256：只做校验与寻址，不做加密）。本轮真正的产出是把**寻址规则**钉进测试：`ID = SHA1("<type> <bytelen>\0" + 正文)`，**不是** `SHA1(正文)`。少一个 NUL / 长度按字符数算 / 漏掉正文末尾换行，都会得到另一个**看起来完全正常**的 40 位串，而它在仓库里永远找不到。真值全来自真实 git（已导出夹具，测试不依赖本机装 git）：blob `94954abd…`、空 blob `e69de29b…`、真实 commit `745d8ddc…`；并显式断言反例 `SHA1(裸内容)==58853e8a…` 防止被「顺手简化」 |
| C49 | ✅ **Git 引擎地基 3/4：对象库读取 + tree/commit 解析** | `GitObjects.swift` · `GitObjectsTests` | 打通「字节 → 可用历史」：读松散对象、**按 ID 校验**、解析 tree/commit、解析 HEAD 与分支引用。⚠️ 三处「看起来正常但完全错」的格式细节各有一条测试钉着：① tree 里 **mode↔name 是空格、name↔SHA 是 NUL**；② SHA-1 是**原始 20 字节**不是 40 字符；③ commit 正文末尾换行也算进哈希。⚠️ **必须校验 ID**（`.git` 字节可能被改过；不校验就会拿着「ID 说 A、内容说 B」继续算，diff/log 全错且不报错）+ 校验头部长度（截断的唯一信号）。损坏**分类报出**（不是仓库/对象不存在/损坏/哈希不符/引用不存在/空仓库）。⚠️ 本轮抓到并修掉自己一个真 bug：`branches()` 用字符串替换算相对路径 → 在 macOS 临时目录返回 **`/privatemain`**（同一目录有 `/var` 与 `/private/var` 两种写法）—— 正是 **T55**；改为按 pathComponents 分段，破坏性验证：改回去测试立刻红 |
| C50 | ✅ **修复：Git 夹具被当成嵌套仓库（只在 clone 后才暴露）** | `Fixtures/loose-dotgit/` | ⚠️ 夹具目录里带 `.git` ⇒ git 识别成**嵌套仓库**，索引只记一个 gitlink 占位 —— **本地一切正常（文件就在磁盘上），CI 全新 clone 会拿到空目录，25 个 Git 测试全挂**。修法：夹具里那层目录改名成 `git`，测试拷贝时才改名回 `.git`。判据：`git ls-files -s \| awk '$1=="160000"'` 必须为空。⚠️ 教训：**「本地绿」证明不了「clone 之后还绿」** |
| C51 | ✅ **Git 引擎 4/4：packfile + delta 解析** | `Packfile.swift` · `PackfileTests` | ⚠️ **不能跳的一片**：`git clone` 下来的对象**几乎全在** `.pack` 里，只支持松散对象的话 `git_log` 在真实仓库上直接报「对象不存在」。实现 `.idx` v2（fanout + 有序 SHA + 偏移 + 大偏移表）、变长对象头、`ofs-delta`（负偏移 MBZ）/`ref-delta`、delta 指令流，**按需读取**（绝不把整个 pack 解进内存，T38）。⚠️ 四处「错一字节就全错」：① `ofs-delta` 变长负偏移**每步 +1**（破坏性验证：去掉 → 4 条测试红，报「不是合法 zlib 流」）② **delta 类型继承基对象**（delta 只描述「怎么改字节」；写死成 blob → delta 化的 tree 变 blob，被「哈希==ID」断言抓到）③ 拷贝 size 全 0 表示 **65536** ④ delta 链**必须有深度上限**（循环链会打爆栈）。最硬的断言：**全部 23 个对象**还原后重算 `SHA1("<type> <len>\0"+正文)` 必须等于索引里的 ID —— 一次覆盖 pack 头/zlib 边界/delta/类型继承整条链路 |
| C52 | ✅ **Git 读取路径：index + 三方状态 + revision + 历史** | `GitIndex.swift` · `GitWorktree.swift` · `GitHistory.swift` · `GitStatusTests` | `git_status`/`git_diff`/`git_log`/`git_show` 的数据面。⚠️ 核心是**三方比较**（HEAD ↔ index ↔ 工作区）：「文件被改了」与「改动已暂存」是两件独立的事，**分不清模型就会重复 add 或以为已提交**（夹具刻意造成三方各不相同，逐条钉死）。⚠️ 三处「不猜」：缩写 SHA **有歧义必须拒**（取第一个只在某个仓库某天给出错误提交，最难归因）；不认识的 revision 语法明确拒绝；根提交上 `HEAD~2` 报错而不是「就是它自己」。⚠️ 抓到自己一个真 bug（**T55 变体**）：扫描工作区时对文件也调 `resolvingSymlinksInPath()`，于是 `link.md -> README.md` 的相对路径被算成 `README.md` —— 链接自己消失还覆盖了真 README，`git_status` 报 ` D link.md`。**解析软链只该用于判断「在不在仓库里」，不能用于得出「它叫什么名字」**。另：判断文件类型不能用 `url.resourceValues`（会跟随链接），要用 `attributesOfItem` |
| C53 | ✅ **统一 diff 渲染：自研行级 LCS + hunk 折叠** | `GitDiff.swift` · `GitDiffTests` | ⚠️ 两个刻意选择：**自己算 LCS**（零依赖承诺，只需行级不需 Myers 完整优化）；**给模型统一 diff 文本**而非自定义 JSON（它见过几十亿行统一 diff，先验远强于任何自定义结构）。⚠️ 钉住四件事：① **`@@` 行号必须精确**（模型照着它定位改文件，偏一行就**静默改错地方**）—— 专门测了「两处远隔 → 两个独立 hunk，各自行号正确」② **空侧起始行号按 git 约定写 0**（新文件 `@@ -0,0`；写 1 时文本「看起来没错」但任何按 git 约定解析的工具都会算偏一行 —— 这条是我写错被测试抓出来的）③ **CRLF 必须先归一化**（Swift 把 `\r\n` 当单个字素簇，不归一化则整文件被当成一行 → diff 变整文件替换，T8）④ **大文件降级必须明说**（LCS 是 O(n·m)，3000×3000 就 36MB；静默降级比降级本身更糟）。判据只有一处实现，生产消费共用 |
| C54 | ✅⭐ **Git 只读工具接通模型** | `GitTools.swift` · `GitToolsTests` · `RuneCore/GitWorkspaceResolver` | 引擎到**模型可见能力**的最后一段：`git_status`/`git_diff`/`git_log`/`git_show` 接进 `AgentRuntime`。⚠️ ① **只接只读四个**（写操作风险级 modifying/dangerous，要单独的审批语义，不顺手加）② **错误返回 `.failure` 结果而非抛异常**（抛出去模型看不到原因与建议，只会换个参数再试，白烧 token）③ `staged` 决定比哪两侧（搞反会让模型提交错东西）。⚠️ **`GitWorkspaceResolver` 这道门**：`ModelWorkspace` 禁止模型碰 `.git`，而 Git 工具就是要读 `.git` —— 看似冲突实则不冲突（**入口不同**：文件工具拿任意路径必须挡，Git 工具拿仓库根自己去读）。解析器仍拒绝任何含 `.git`/`.rune`/`.ssh` **段**的路径（含中间段，防 `foo/.git/config`），并有测试往 `.git/config` 放假 token 断言它绝不进事件。⚠️ 接线测试**从 AgentRuntime 真的发一次调用**，断言模型收到的不是「未知工具」—— 项目在「模块全绿但没被调用」上栽过**四次** |
| C55 | ✅ **JS 执行宿主（JavaScriptCore）—— 并诚实处理「杀不掉死循环」这个平台限制** | `RuneBench/JavaScriptHost.swift` · `JavaScriptHostTests` | 继 Git 之后的下一块平台能力。选 JSC 而非 CPython 的理由很实际：**JSC 是 iOS 自带的**（零包体代价），CPython 要背 1–2GB。⚠️ 放在 `RuneBench` 而非 `RuneKernel`：零依赖审计**禁止**内核 import `JavaScriptCore`（内核要能在 ubuntu 构建）。⚠️⚠️ **本层最需要说清的是它做不到什么**：设计文档写着"资源限额与强杀"，但 **JSC 没有公开的中断 API**（`JSContextGroupSetExecutionTimeLimit` 既不在公开头文件、**也不在动态库导出符号里**，已实测）—— 而用私有 API 会撞 App Store 红线（docs/11 的 2.5.2）。**所以没做「假装能强杀」的设计**，改成三层可兑现的防线：① **隔离**（每次执行独立 `JSVirtualMachine` + 独立线程，上一次的全局变量看不到）② **配额**（墙钟/输出字节/栈深）③ **挂死检测 + 拒绝**（超时即标"中毒"，后续调用直接拒绝并如实告知）—— 这比"继续接调用、每次再挂一个线程"安全得多，后者在手机上表现为 App 越来越卡直到被 jetsam 杀掉（T38）。⚠️ 抓到自己一个真 bug：结果值里的 `"undefined"` 被当成"没有值"过滤掉，于是 **`typeof fetch` 的结果在输出里消失** —— 「值是 undefined」与「根本没有值」是两件事 |
| C56 | ✅ **`run_javascript` 工具接线**（229 → 见 §2 计数） | `RuneBench/JavaScriptToolExecutor.swift` · `AgentRuntime` 路由 | 上轮落地的宿主这一步才真正"存在"。⚠️ 分两片提交（上片只动 RuneBench、本片动 Bench+Core），任何一半坏了都能一眼定位。要点：`timeout_sec` **收窄到 60 秒上限并说明被收窄**（静默收窄会让模型以为参数没生效、反复加大数值）；宿主中毒时**拒绝并说清原因**（别让模型以为"这次代码写错了"而反复重试）；大输出复用内核同一个 `OutputBudget` 走制品。⚠️⚠️ **主要收获是一个假绿测试（连错两版断言）→ 完整记录见 T63**：判据必须是**工具结果的 `status`**，不是「有没有发生过某件事」，也不是查输出文本（`argsPreview` 会回显参数）。破坏性验证（摘掉路由）现在能抓住 → 3 条红。⚠️ 另修上轮自己写的真问题：`GitToolExecutor` 兜底 `catch` 只报「失败了」、没给下一步 → 补上可执行建议 |
| C57 | ✅ **`todo_write`：补上一个「声明了但没接上」的洞**（1245 测试） | `Todo.swift` · `TodoList` · `AgentRuntime.syncTodos` | `Context` 里**早就有** `.openTodos` 角色与 `openTodosPresent` 自检（含「⚠️ 有未完成 todo 却没进上下文」的警告），但 `TurnState` **从来没有 todos 字段**、素材池里也永远不会出现 `openTodos` —— **那条自检永远不可能触发**（T48/T49/T54 同源）。补上 `TodoItem`/`TodoList`/`TodoWriteToolExecutor`，并写回状态 + 随检查点持久化。⚠️ 四个刻意设计：① `todos` **可选**而非 `[TodoItem] = []`（旧状态 JSON 没这个键，非可选会让 `Codable` 解码任何历史状态时抛错 = 旧会话全恢复不了，有测试守）；② **同时最多一条 `in_progress` 是硬拒绝**而非警告（两条同时进行中时模型实际没在做任何一个，而「不跑偏」正是这工具的存在理由）；③ **渲染逐字节确定**（一变就换请求指纹、Cache 失效，用户只从账单发现）；④ 工具**不改 TurnState**，写回由运行时统一做 |
| C58 | ✅ **`ask_user`：补上第六个「声明了但没接上」的洞**（1262 测试） | `UserQuestion.swift` · `TurnRunner` 派发相位拦截 · `RuntimeAction.answer` | 盘出来的是**第六个**同源缺陷（完整枚举见 T65）：契约、`awaitingUser` 状态、`.askUser` 动作、`askUser` 恢复动作四处齐备，**但没有一行代码会进入那个状态**。⚠️ 关键设计：它**不是普通工具而是挂起** —— 由 `TurnRunner` 在**派发相位、策略判定之前**拦截（执行器只能返回结果、改不了 TurnState；放在策略前是因为"问用户"本身就是交互，**再叠一张审批卡要去点两次**）。⚠️ **挂起前必须先补配对结果**（T18：漏了后续所有请求 400，且报错与真实原因不沾边；破坏性验证过）。⚠️ **回答的信任级是 `.userInstruction`**（真实的人说的话可以驱动危险动作；降级成 `runtimeGuidance` 会让 Agent 收到回答却不敢执行）—— 反面同样重要：**绝不能把这个级别用在运行时自己写的话上**（T20）。⚠️ 新增事件 kind `userInputRequested`，与 `toolApprovalRequested` **分开**（冷启动分诊时前者重放审批卡、后者重放问题）。⚠️ **废话问题硬拒绝且不挂起**（"要不要我继续"这类把决定权推回用户却没给新信息，原来只是文档提示、模型经常不听） |
---

## 6. 下一步
**主线现状**：C46 打通真实云端推理；**C47–C54 把 Git 引擎从零做到了「模型可用」** —— iOS 无 fork/exec ⇒ 没有系统 git，Rune 自己读 `.git`（zlib inflate → SHA-1/对象寻址 → 松散对象 + packfile/delta → index/三方状态/revision/历史 → 统一 diff → 四个只读工具接通 AgentRuntime）。⚠️ **下一步**：git 写操作（add/commit，需审批语义）、执行宿主（CPython/WASM/JSC）、MCP、记忆检索/L3 压缩与真机验收，**不可把本轮当成全项目完成**。
### ⭐ macOS 环境已经接管（C39）：**秒级反馈回来了，不用再靠推 CI 猜**

| 事情 | 命令 |
|---|---|
| 构建 / 测试某个包 | `swift build --package-path Packages/RuneKernel` · `swift test --package-path …` |
| 全部包 + 审计 | `bash Tools/ci.sh all`（或 `build`/`test`/`audit`/`ios`/`ipa`/`kernel`） |
| 生成工程 / 构建 App / 打 ipa | `xcodegen generate`（在 `Apps/Rune`）· `bash Tools/ci.sh ios` · `bash Tools/ci.sh ipa` |

✅ **本机实测**：11 包全部构建通过（测试数以 §2 为准）· Net 可用 iOS Simulator SDK 交叉编译 · App Release 构建 + IPA 通过（见 docs/18/19）。
⚠️ `Tools/rune.ps1` 是 **Windows 专用**，macOS 上**不要用**。

**⚠️ 仍未验证的风险点**（不是「已完成」）：
① **L3 压缩**只有「该压到哪一级 + 产物格式 + 解析」，运行时那一次**付费调用**还没接；② **Workflow 的 JSC 宿主**已就绪（C55 `JavaScriptHost`），但**脚本 → DAG 的编译层**还没接；
③ 工具 **87 个注册 / 25 个已实现**（文件检索 15 + 文档 3 + Git 只读 4 + JS + todo + ask_user）；剩余最大一块是 **Git 写操作**、WASM/CPython 宿主、网络工具壳、iOS 原生（相册/日历/定位…）； ④ **真实渠道**仍需各压一次（C46 已用 `gpt-5.5` 跑通端到端，但多渠道兼容矩阵未验；⚠️ 旧的「PinAI 账户被拒」结论已被 C46 推翻 —— 那是**按模型逐个拒绝**，不是封账户）。

`RuneKernel`（51 源文件 / 1154 测试）覆盖：值类型与协议、补丁、检索、渠道网关、成本熔断、结构化压缩、出站构建与体检、模型调用客户端、策略引擎、Turn 循环与崩溃恢复、波次调度、计划/审批/目标、修正性重试与协议不变式、上下文装配、86 工具契约、技能库、Workflow、VFS、自研 shell、沙箱层 —— **并有端到端场景测试证明它们拼得起来**。

**仓库**：<https://github.com/Sakura-Lhy0409/rune>（公开；macOS 运行器对公开仓库免费）。
✅ 仓库 API 权限 `pull/push/admin=true`（C40 复核）；C46 起已多次推送并跑绿 CI。

**实现顺序**：Store/Net/UI/图标 ✅ → RuneCore 接线 ✅ → Git 引擎 ✅ → **JS 宿主 ✅ C55** → `run_javascript` 接线 → Git 写操作（需审批）→ WASM/CPython 宿主 → MCP → 记忆检索/L3 压缩 → 真机验收。

## 7. 已知陷阱（不要重复踩）

### 7.1 本机环境陷阱（E1–E8 全是 **Windows 时期**的坑，macOS 上不复现；保留给以后在 Windows 上接手的人）

| # | 陷阱 | 现象 | 解法 |
|---|---|---|---|
| E1 | **`swift build` / `swift test` 静默失败** | 只输出 "Building for debugging…" 然后 exit 1，无错误 | **用 `Tools/rune.ps1`**（见 §3） |
| E2 | **路径含中文导致 swiftc 打不开文件** | `error opening input file 'D:\??Ŀ\ios??agent\…'` | **走 ASCII junction**；脚本已自动处理；生成 .bat 时用 `chcp 65001` + UTF-8 |
| E3 | **`link.exe` 不在 PATH** | manifest 编译失败 | 所有 swiftc 调用都要先 `call vcvars64.bat`（脚本已处理） |
| E4/E5 | **本机跑测试 exe 的两个坑** | 报 `0xC0000135`（静默退出 = STATUS_DLL_NOT_FOUND）／`Testing.__swiftPMEntryPoint` **两个重载**报 ambiguous | PATH 必须含 **Swift Runtimes\6.3.3\usr\bin** 与 **Testing-6.3.3\usr\bin64**（是 `bin64`，不是 `x86_64`）；入口要显式类型标注 `let code: CInt = await ...` |
| E7/E8 | `data as [UInt8]` 跨平台不可靠（用 `data.withUnsafeBytes { update($0) }`）· 内联管道看编译输出会**超时**（`pwsh … \| Select-String` 120s 无输出，实际在编译） | 前者报 `cannot convert value of type 'Data' to type '[UInt8]'`；后者命令超时 exit 1 | 前者改用 `withUnsafeBytes`；后者改成 `\| Out-File $env:TEMP\x.log` 再读，或 `run_in_background: true` |

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
| **T57** | ⚠️ **从 Windows 拷过来的源码目录没有 `.git`，且 git 会把「权限位差异」报成「594 个文件被修改」**：① 目录是打包拷来的 → `git status` 直接 `not a git repository`，**续接机制依赖的提交历史一夜之间没了**；② 补上 `.git` 之后，Windows 打包丢掉了可执行位，而 APFS 上 `core.filemode=true` → 594 个文件全被报成 `100644 → 100755`（内容一个字没变）。**此时任何 `git checkout .` / `git stash` 都会把工作区改动一起抹掉** | ① 缺历史就 `git clone` 一份，比对 `diff -rq`（排除 `.git`/`.build`）确认内容一致后把 `.git` 拷进工作目录 —— **先比对再拷**；② 用 `git diff --stat` 分辨「内容变了」还是「只有 mode 变了」（后者是 `0 insertions(+), 0 deletions(-)`）：纯权限位差异用 `git config core.fileMode false` 修，**不要**用 checkout 修。⚠️ 判据：`git status` 说全改了、而 `diff -rq` 说没差别 —— **先查 `.gitattributes`/`core.autocrlf`/`fileMode`，别急着 checkout**（本项目补丁引擎的换行保真测试依赖 LF，误 checkout 会静默毁掉那组夹具） |
| **T58** | ⚠️ **`swift build` 卡在 `Fetching <依赖>` 上十几分钟、0 字节进展，看起来像"环境坏了"**：`swift build` 首次解析 GRDB 时会做 `git clone --mirror`（要拉**全部**历史，比 `--depth 1` 重得多），在国内网络下可能**长时间无输出**。⚠️ 误判成"卡死"而杀掉它，就会进入"每次都从头重来"的循环 | ① 先验证网络本身没问题：`git clone --depth 1 <同一个 URL>` 能成就说明**不是网**；② 看真实进度 **不要看 stdout**（SwiftPM 只打印一行 `Fetching …` 就不动了），去看缓存目录大小：`du -sh ~/Library/Caches/org.swift.swiftpm/repositories/<pkg>-*` —— 它在涨就是在下载（本次观察到 50M → 229M 后完成）；③ 只有**确认真的不涨**才杀掉重来。⚠️ 通用教训：**"没有输出"不等于"没有进展"**，给长任务找一个可观测的进度指标（文件大小/进程 IO）再决定要不要杀 |
| **T59** | ⚠️ **守门人自己被构建产物绊倒，而且方式是「崩溃」不是「误报」**：`Tools/lint_quotes.py` 用 `Apps/**/*.swift` 找文件，而 **`**` 可以匹配零个路径段** —— 于是它匹配到 `Apps/Rune/build/SourcePackages/checkouts/GRDB.swift` 这个**目录**（依赖 checkout 目录恰好以 `.swift` 结尾），传给 `read_text()` 直接 `IsADirectoryError` 崩。⚠️ **触发条件是「先跑过一次 iOS 构建」**，所以它在一台从没构建过的机器上**永远是绿的** —— 这类"只在特定顺序下才暴露"的缺陷，跑一次测试是发现不了的 | ① glob 的结果一律先 `is_file()` 过滤（**"匹配到了"不等于"是个文件"**）；② 同时排除构建产物（`.build/`、`Apps/Rune/build/`）—— 否则"检查了 N 个文件"会从 **86** 变成 **565**，其中 479 个是 GRDB 第三方源码：**数字变成谎话比崩溃更隐蔽**（你会以为它一直在替你看着那些文件）；③ 通用教训：**一个检查工具的可信度，取决于它检查的东西是不是它声称的那些** —— CI 里每个守门脚本都该问一句「你现在到底在看什么？」。⚠️ 与 T48/T49/T54 同源：**"看起来在守"与"真的在守"是两件事** |
| **T60** | ⚠️ **`.gitignore` 不支持行尾注释，而写成行尾注释时它不报错、只是永远匹配不到**：`Apps/Rune/Info.plist          # 由 project.yml 的 info: 段生成` —— 整行（含 `#` 与后面的中文）都被当成模式，那条规则**形同虚设**，而它看上去"已经写了"。后果：XcodeGen 生成的 `Info.plist` 会被 `git add .` 悄悄收进仓库（生成物入库 → 下次生成冲突） | 注释**独占一行**（`.gitattributes` 同理）。⚠️ 判据不是"把 .gitignore 读一遍"，而是**实测**：`git check-ignore -v <路径>` **打出匹配到的行号**才算真的生效 —— C39 就是靠它发现这条规则一直没生效 |
| **T61** | SwiftPM 消费包缓存可能仍引用依赖包已删除的 Placeholder.swift → missing inputs | 对报错的消费包运行 `swift package --package-path Packages/<包> clean` 后重建；只清构建缓存，不恢复占位代码。见 C41 日志 |
| **T62** | ⚠️⚠️ **「外部依赖被拒」这类阻塞，最危险的失败模式是「抽样选错了样本」**：C45 只试了 **1 个**模型（`gpt-5.4-mini`）被拒，就写下"上游账户拒绝，真实云推理无法验收"并当作**阻塞项**传给下一轮。真相是上游**按模型逐个拒绝**（`not supported when using Codex with a ChatGPT account`），同一账户下 `gpt-5.5`/`gpt-5.6`/`gpt-6-astra` **两个端点都 HTTP 200**。⚠️ 代价极大：一个不存在的阻塞项让整条主线**停摆**，而它写在续接文档里，后来者会**直接相信、不再复测** | ① 判定"外部服务不可用"前，**样本量必须 ≥ 可见项数**（`GET /models` 里每一个都试）—— 本次列表 17 个模型只试 1 个就下结论，是**方法错误**不是运气差；② 阻塞项必须写**证据边界**（"我试了哪几个、各报什么错"），不写"账户被拒"这种无法反驳的结论；③ 接手继承来的阻塞项时，**第一件事是复现它**而不是绕开它 —— C46 几分钟就推翻了它。⚠️ 与 T48/T49/T54/T59/T60 同源（"看起来堵住"≠"真的堵住"），但**这一条代价最大**：别的只是少一层保护，这条让整个项目停住 |
| **T63** | ⚠️⚠️ **一个「在成功与失败两种状态下都为真」的断言，比没有断言更危险**：C56 的接线测试连错两版 —— ① 第一版断言「`toolCallFinished` 恰好一条」，但**工具失败时也会发这个事件**（失败是另一个 kind，而"执行过一次"两者都满足）→ 把工具路由**整个摘掉**（模型收到"未知工具"）时，断言**照样绿**；② 第二版改成查输出文本里的关键字 → **仍然假绿**，因为 `argsPreview` 里**回显了模型传的参数**，那个字符串在"真的执行了"和"根本没接上"两种状态下都出现。⚠️ 它比"没有断言"更危险：**它看着像在检查**，于是没人再去手工验一遍 | ① 接线/可达性断言的判据必须是**可观测的行为差异**（工具结果的 `status`、发了几枪、打到哪个 URL），不是"有没有发生过某件事"；② **写完断言立刻做破坏性验证**：把被检查的那条路径摘掉，看它**是否真的变红** —— 本次就是这么连抓两版假绿的；③ 参数回显（`argsPreview`）**不是证据**，它证明"请求发出去了"，不证明"被谁处理了"。⚠️ 与 T54（零调用点）同源但形态不同：T54 是"没人调"，T63 是"检查调用的手段自己不会失败" |
| **T64** | ⚠️ **新建文件的权限可能是 `0600`（`umask 077` 漏进来），本机看不出来、换个环境就"莫名失败"**：C57 新建的 `Todo.swift` 权限是 `-rw-------`，而同目录其他文件是 `644`。本机一切正常（**我就是文件属主**），但别的用户/CI 环境读不到 —— 症状是"文件明明在，构建却报 `cannot find type 'X' in scope`"，而**报错指向的是使用处、不是缺失的文件**，排查方向会被彻底带偏。更迷惑的是它**时有时无**：`.build` 缓存陈旧时才暴露，单包构建又"成功" | ① 新建文件后核一次权限：`find Packages Apps Tools docs -type f ! -perm -o=r`（必须为空）；② ⚠️ **排障时先清缓存再判断**：本次 `ci.sh` 报 Context/Gateway/MCP/VM 构建失败、而单包构建成功 —— 根因是**陈旧的 `.build`**（新增源文件后消费包缓存不一致）。`rm -rf Packages/*/.build` 后一次通过，**而那正是 CI 的路径**（干净 clone 没有缓存）；③ 通用判据：**"单包能过、整体不能过"** 与 **"本机能过、CI 不能过"** 都优先怀疑环境/缓存，而不是代码 |
| **T65** | ⚠️⚠️ **「声明了但没接上」已经出现第六次 —— 这是一个系统性缺陷，不是六次意外**：T48（规则表）· T49（安全闸门）· T54（整个网关子系统）· T59（守门脚本）· C57（todo）· C58（`ask_user` 的 `awaitingUser` 状态）。到第六次模式已经很清楚了：**本项目倾向于先把「声明层」写得很完整（契约/状态/事件类型/注释），而把「接线层」留到后面** —— 于是每个子系统单看都「完成了」，合起来却没有任何东西会执行它。`ask_user` 尤其典型：契约、`awaitingUser`（已进 `isStable`）、`.askUser` 动作、`askUser` 恢复动作**四处都「支持提问」，但没有一行代码会进入那个状态** | ① 把「调用点普查」变成**每次改动的固定动作**：新增任何契约/状态/事件时，当场 grep 一次"谁读它"（`ModelClient` 之于网关就是这么补上的）；② **反向盘点**：定期对 `TurnStatus` / `EventKind` / `PinnedRole` / `ApprovalPolicy` 这些**枚举**逐个问"哪个值从来没人设置过" —— 枚举里的死值是这类缺陷最好的探针（本次就是靠"`awaitingUser` 没人进入"找到的）；③ ⚠️ **端到端测试必须断言状态真的变了**，不能只断言"有配对结果/发过事件"（T63 是同一教训的另一面）；④ 这个形状在本项目出现了六次，**新增子系统时默认假设"我忘了接线"，而不是"我写完了"** |
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
本机构建    macOS 用 bash Tools/ci.sh 或 swift build/test；Tools/rune.ps1 仅用于 Windows。
成本        每一次模型调用**之前**必须查成本上限；每一轮都必须落 costRecorded。上限存在 TurnState 里（用户中途改过的是它）
```

## 9. 文件地图

```
/Users/chuzu/Desktop/rune-src/
├─ PROJECT_STATE.md          ⭐ 本文件（最先读）
├─ README.md                 设计文档入口
├─ .github/workflows/        ⭐ kernel.yml（Linux+macOS）/ ios.yml（Mac 构建 + 出未签名 ipa）
├─ Apps/Rune/                SwiftUI 产品界面 + Widgets / ShareExtension / Shared + UI 测试
├─ Tools/  ci.sh(本机唯一入口) · check_ci.py · lint_quotes.py · check_docs.py · rune.ps1(Windows 专用，勿用)
├─ docs/
│  ├─ 进度日志.md            ⭐ 追加式时间线（细节都在这）
│  ├─ 17-交接文档（macOS）.md  ⭐ **迁移到 macOS 时先读它**（命令行、未完成态、坑、检查单）
│  └─ 01 … 16 + 附录A/B      设计文档（01 产品定位 … 16 无 Mac 路径）/ 渠道事实表 / 技术选型核实表
├─ research/                 取证材料（465 份，非交付物，**刻意入库**）
└─ Packages/
   ├─ RuneKernel/   ✅ 零依赖核心（41 源文件 / 1032 测试全绿；Tests 31 个）
   ├─ RuneStore/    🔨 GRDB 依赖（唯一非零依赖包）· event 表落盘，第一片 8 测试绿（C39）
   └─ RuneNet/RuneUI/ ✅ 首片；Rune{VM,Bench,Gateway,Context,Core,Tools,MCP}/ ⬜ 骨架
```

**文件清单不用背**：`ls Packages/RuneKernel/Sources/RuneKernel/` 一秒就有；本文件只保留「做过什么」与「别踩什么」。

## 10. 里程碑验收标准（摘录自 [14](docs/14-工程路线图与测试策略.md)）

| 里程碑 | 出口标准 |
|---|---|
| **M0 / M1** | 模型能自主完成"修一个简单的失败单测"并在中途被杀后正确恢复（**✅ C46 已在真实模型下达成**）/ 3 名内测用户各完成 5 个真实任务，完成率 ≥70% |
| **M2 / M3** | S1 场景（CI 抢救→应用→提交）3 次点击内完成 / 切换任意两家渠道成功率差异 <15% |
| **M4 / M5** | 飞行模式下完成"改函数 + 跑测试 + 写 commit" / 注入套件 0 越权 + 性能基准达标 + 审核材料齐备 |
