# 11 · App Store 合规与分发

> **摘要**：一个"在手机上读写用户文件、跑脚本、连第三方模型 API"的 App，要穿过五条窄门：**2.5.2 + ADPLA §3.3.1(B)（不得下载并执行代码）**、**4.2/4.3（最低功能性）**、**1.2（UGC：AI 对话已被明确纳入！）**、**3.1.1（内购）**、**5.1.2(i)（第三方 AI 披露）**。
> 关键结论有三条，全部来自实证核实（见 [附录 B](附录B-技术选型核实表.md)）：
> ① **"随包解释器 + 随包编译器 + 用户自己的代码"已被反复验证可行**（a-Shell 甚至在 App Store 里自带 clang 与 WASM SDK）；
> ② **风险不在"能不能跑用户代码"，而在"有没有任何一条路径能下载代码"** —— 二进制里**存在**这样的能力就可能被引用，哪怕从未被调用；
> ③ **2026 年最可能的拒审理由其实是 1.2（AI 对话的举报/屏蔽/过滤）**，而不是 2.5.2。

---

## 1. Guideline 2.5.2 与 ADPLA §3.3.1(B)——真正决定生死的两条

### 1.1 原文（必须逐字理解）

**App Review Guidelines 2.5.2**（[原文](https://developer.apple.com/app-store/review/guidelines/)）：

> "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps. Educational apps designed to teach, develop, or allow students to test executable code may, in limited circumstances, download code provided that such code is not used for other purposes…"

**Apple Developer Program License Agreement §3.3.1(B)**（Apple 在 2026 年整治中**明确引用**的就是这一条，[原文](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)）：

> "Except as set forth in the next paragraph, an Application may not download or install executable code. **Interpreted code may be downloaded to an Application but only so long as such code:**
> (a) **does not change the primary purpose of the Application** by providing features or functionality that are inconsistent with the intended and advertised purpose of the Application
> (b) does not bypass signing, sandbox, or other security features of the OS; and
> (c) for Applications distributed on the App Store, **does not create a store or storefront for other Applications.**"

紧接着的"next paragraph"是**编程环境豁免**：面向编程学习的 App 可以下载并运行可执行代码，条件是①可执行代码占可视面积 ≤80%、②有醒目的"你正在编程环境"提示、③不含代码商店、④源码对用户完全可查看可编辑（不得包含预编译库/框架）。

### 1.2 对 Rune 的含义（三条硬结论）

| # | 结论 | 工程动作 |
|---|---|---|
| **C1** | **判定的核心是"primary purpose"（主要用途）**。Rune 的**对外宣称用途就是本地执行工程任务**，因此"跑用户自己写的脚本"**不构成** "changed primary purpose"。 | 产品定位、App Store 文案、审核说明三者必须**一致地把"本地执行"写在明面上**。绝不能一边宣称"AI 聊天助手"、一边在下面跑脚本——那才真的踩线。 |
| **C2** | **"解释型代码可以下载"是有条件的，但 Rune 干脆不要这条路。** ADPLA 允许下载解释型代码，条件是它不改变主要用途、不绕过安全机制、不建商店。技术上我们可以合规地做"从我们的库下载纯 Python 包"，但**收益远小于风险**。 | **App Store 轨：零网络代码获取路径。** 运行时、标准库、内置包全部随包；用户脚本只能来自用户在设备上创建或在工作区放置的文件。 |
| **C3** | **"二进制里存在这个能力"本身就可能被引用，哪怕从未被调用。** | **机械式清理**（见 §2.3）：不含远程 bundle 加载器、不含 `eval`/`Function` 构造器驱动的远程脚本执行、WebView 不加载远程脚本。**死代码也算风险。** |

### 1.3 逐条对齐表（提交审核时直接给审核员看）

| 条款关切 | Rune 的设计 | 可验证证据 |
|---|---|---|
| 不得读写容器外数据 | 所有文件访问经 VFS，仅挂载**用户通过系统文件选择器显式授权**的目录（security-scoped bookmark） | 设置页列出全部已授权目录；未授权时任何写入尝试都被拒绝 |
| 不得下载代码 | 无任何网络代码获取路径 | **断网全功能可用**（除模型推理）可现场演示 |
| 解释型代码不得改变主要用途 | 脚本只处理数据，无法新增界面/工具/交互；Skill 与 Workflow 是声明式文本，不装载二进制 | Skill 格式为纯文本；Workflow 在受限 JS 沙箱内，无 `fetch`、无文件、无定时器 |
| 不得建代码商店 | 无插件市场、无二进制分发 | Skill 库是本地文本目录，可导出为文件分享但不能"安装远程包" |
| 不绕过系统安全 | 沙箱为纯用户态解释器，无越权能力 | 沙箱逃逸测试套件（[14 §6.4](14-工程路线图与测试策略.md)） |

### 1.4 编程环境豁免：知道它存在，但**不要依赖它**

豁免条款要求"可执行代码占可视面积 ≤80%"且"有醒目的编程环境提示"——这意味着产品 UI 得像 Pythonista（一屏几乎全是编辑器/终端）。
**Rune 是卡片式任务助手，不满足这个形态，也不应该为了套豁免而扭曲产品。** 我们靠的是 §1.2 的 C1（primary purpose 一致）而不是这个豁免。

---

## 2. 先例：路已经有人走通了（这是最有力的论据）

以下是**今日仍在架**的 App（核实于 2026-09，详见 [附录 B §3](附录B-技术选型核实表.md)）：

| App | 它做了什么（关键点） | 对 Rune 的意义 |
|---|---|---|
| **a-Shell** | **仍在架，近期仍在更新**。本地 Unix 终端；**自带 clang/clang++ 22.1.0 + WASI-libc，用户可把 C/C++ 编译成 WASM 并执行**；**内置两个 WASM 解释器（wasm3、wasmkit）**；另含 Python 3.13、Lua、Perl、JS、TeX Live、ffmpeg、git、rsync | ⭐ **最重要的先例**：App Store 允许"随包编译器 + 随包 WASM 运行时 + 用户编译自己的代码并执行"。这让 Rune 的 WASM 沙箱路线**从"高风险尝试"变为"已验证模式"** |
| **Pyto** | Python 3.10 + **C/C++ 编译器** + 终端 + wasm3 | 同上，再次验证 |
| **Carnets** | Python 3.13，"完全独立运行，无需联网"；pip **仅限纯 Python 包** | 验证"内置包 + 限制二进制扩展"的合规说法与产品话术 |
| **Pythonista** | Python 3.10 脚本环境；**公开声明"不支持安装/下载以 C/C++ 编译的模块"** | 提供了**合规边界的公开表述范本**：把"不支持下载编译型模块"写进产品说明，反而更安全 |
| **Scriptable** | JavaScriptCore 自动化 | 证明 JSC 路线合规（JSC 是系统框架，不是下载代码） |
| **Working Copy** | 完整 Git 客户端；**其 Repository Agent 可跑在 Apple Private Cloud Compute 上，无需 API key、无需订阅**，额度用尽后回落到用户自配的 AI 服务 | ⭐ 证明两件事：① "客户端 + AI Agent"形态可上架；② **PCC 对第三方 App 开放**（见 [13](13-端侧模型与性能预算.md)） |
| **iSH Shell** | x86 模拟 + Alpine | 2020 年曾被以 2.5.2 通知下架，**上诉后 Apple 当日道歉并撤回** | 说明**申诉有效**，也说明 2.5.2 的执行存在波动 |
| 大量 LLM 客户端 | 下载模型权重、本地推理 | 证明"下载权重**数据**"≠"下载可执行代码" |
| **Geeps: AI Chat BYOK** | BYOK；支持 OpenAI/Anthropic/Google/**OpenRouter**/自定义 OpenAI 兼容端点/本地模型；一次性 IAP（明示"非订阅"） | ⭐ **BYOK + 自定义端点 + 中转站**的合规先例，直接支撑 [06](06-模型网关与中转站.md) 的设计 |

**审核说明的第一句就应该是这个类比**：

> Rune works like a-Shell, Pyto, or Working Copy: every interpreter and compiler ships inside the app bundle, and they only run code the user writes on-device or places in their own workspace folder. The app never downloads code.

---

## 3. 2025–2026 的收紧：必须规避的形态

### 3.1 已知事实（核实过的时间线）

| 时间 | 事件 |
|---|---|
| 2025-12 | Apple 开始**阻止** vibe-coding 类应用 **Replit 与 Vibecode 的更新更新**，引用 2.5.2 |
| 2026-03-26 | Apple 以 2.5.2 **下架 Anything（Anythng）**，且是**两次**（中间曾恢复） |
| 2026-04 | Anything 团队公开：**"四种不同的技术方案，每一种都针对他们提出的要求设计，全部被拒"**；连"把预览搬到浏览器里"的提交也被拒。随后转向云端 + 桌面伴侣 |
| 2026-06 | Apple 更新指南，**4.3(b) 更严**（针对"不为 App Store 增加价值"的应用）；同时 2.5.2 文本未变 |

**Apple 的公开立场**（对媒体）：不是反对 vibe coding 本身，而是反对违反 2.5.2 与开发者协议——**尤其是"通过生成并运行代码来改变 App 自身行为、绕开审核"**。Apple 明确表示对"帮助用户构建其他 App"的应用没有意见。

**方向判断：继续收紧，不是放松。** 没有任何 Apple 文件为"代码生成型 Agent"设立 AI 专项豁免（任何此类说法均无依据）。

### 3.2 高风险形态 vs Rune 的处理

| 高风险形态 | Rune |
|---|---|
| 在 App 内生成新的 iOS App 并运行/安装/预览 | **完全不涉及** |
| 通过下载脚本动态新增 App 功能 | **完全不涉及**（无网络代码路径） |
| 自更新/自修改行为（generating and running code that changes the app's own behavior） | **完全不涉及**。Rune 的脚本只处理数据，Agent 循环本身是编译进包里的固定代码 |
| 应用内插件/代码市场 | **不做** |
| 用 WebView 加载远程页面提供核心功能 | **不做**（核心功能全部原生 + 本地） |
| **二进制中含远程代码加载器（哪怕死代码）** | **机械式清除**（见 §3.3） |
| 套审核员检测开关隐藏功能 | **不做**。要么这个构建干净，要么不上架 |

### 3.3 机械式清理清单（写进 CI 检查）

```
禁止出现在受审构建中的符号/调用（含死代码、注释掉的代码、未使用的 Pod/SPM 依赖）：
  [ ] 任何从 URL 下载并 eval/执行内容的路径
  [ ] JSContext 中把远程字符串作为脚本源（JSContext.evaluateScript(remoteString)）
  [ ] WKWebView 加载远程 JS 注入（WKUserScript(source: remote)）
  [ ] 远程 bundle / 热更新 SDK（CodePush、EAS Update 等价物）
  [ ] eval / Function 构造器 用于执行非本地内容
  [ ] 从网络拉取 .py / .js / .wasm / .dylib / .so 并执行
  [ ] 任何"插件安装"UI 入口
允许（且明确合法）：
  [x] 从网络下载“数据”：模型权重（safetensors/GGUF）、CSV/JSON/图片、纯文本配置
  [x] 远程功能开关（只开关已随包发布的功能，不引入新功能）
  [x] 随包分发的解释器/编译器执行用户自有内容
```

**做法**：在 CI 里加一个静态检查任务（符号扫描 + 依赖清单 diff），**任何一个新增的远程执行相关符号都会阻断合并**。这不是形式主义——Apple 的实现是"看二进制里有没有这个能力"。

---

## 4. Guideline 1.2（UGC）——2026 年最可能的拒审理由

### 4.1 为什么这跟 AI Agent 有关

**2026-02-06 的指南修订把"随机/匿名聊天"明确纳入 Guideline 1.2（用户生成内容）**。1.2 要求四项强制机制：

| # | 要求 | Rune 的动作 |
|---|---|---|
| 1 | **过滤**不良内容 | **必须在二进制内实现过滤**（上游模型厂商的过滤器**不能**替代本要求）。实现：本地敏感词/模式过滤 + 端侧分类模型 + 输出前拦截 + 记录 |
| 2 | **举报**机制（且要及时响应） | 每条 AI 回复的**长按菜单里有"举报"**（审核员就是这么找的），举报落到本地队列 + 可选上传（用户同意才上传） |
| 3 | **屏蔽**滥用的对应方 | 在纯 AI 对话场景里，"对应方"是**人格/模型身份**。Rune 提供"屏蔽该渠道/该模型/该人格"的入口 |
| 4 | **公开联系方式** | 支持邮箱必须**在 App Store Connect 有效 + 在 App 内可见**（设置页） |

### 4.2 一项容易漏掉的平衡

Rune 是**专业工具**，不是社交产品。因此：
- 举报/屏蔽 UI 要存在且易找到，但**不要喧宾夺主**（放在长按菜单与设置页，而不是主界面横幅）
- 过滤策略要**避免误伤代码**（例如代码里出现敏感词是常态）→ 过滤只作用于**面向人的自然语言输出**，不作用于代码块与文件内容，并在设置页给出开关与说明
- 这一步做不实，是 2026 年最可能的拒审点，**优先级高于 2.5.2 的所有防御**

---

## 5. Guideline 3.1.1 —— BYOK 的合规边界（结论清晰）

| 场景 | 是否合规 | 依据 |
|---|---|---|
| 用户用自己的 API Key 调第三方模型 | ✅ **合规，无需 IAP** | 我们不卖任何东西；用户与服务商的关系是用户的。（先例：Geeps BYOK 在架，支持 OpenRouter 与自定义端点） |
| 一次性买断 App / 解锁高级功能 | ✅ 走 IAP（非消耗型） | 标准做法 |
| **我们代售推理额度、自营中转、加价转卖 key** | ❌ **必须走 IAP** | 属于"用数字服务解锁 App 内功能"，正落 3.1.1 |
| 引导用户去外部购买额度 | ⚠️ 分法域 | 美国店面：3.1.1(a) 已明确**不需要** External Purchase Link 权限即可放置链接；非美国店面：**默认不做任何引导** |
| 企业/B2B 定制（3.1.3(c)） | ⚠️ 受限路径 | 不作为主路径 |

**Rune 的默认选择：纯 BYOK + 一次性买断。不卖额度、不运营中转、不做外部购买引导。** 这条路径下 3.1.1 风险接近零。

**关于中转站**：**Apple 没有针对模型中转的条款，也不像在管这件事**（Geeps 在架且明示支持 OpenRouter、Cloudflare AI Gateway、LiteLLM、自建实例）。风险在上游厂商侧（OpenRouter 条款明确禁止"转售模型 API 访问权"），**不在 Apple 侧**。
但两条会引起 Apple 关注的边界：① 如果我们自己卖中转访问权 → 走 IAP；② 不能把中转端点包装成"我们自己的 AI 服务"，且必须**点名模型提供方**（绝不能暗示是 Apple Intelligence）。

---

## 6. Guideline 5.1.1 / 5.1.2 与隐私（含 2026 新规）

### 6.1 5.1.2(i) 现在点名了第三方 AI（原文）

> "You must clearly disclose where personal data will be shared with third parties, **including with third-party AI**, and **obtain explicit permission** before doing so."

**对我们的直接影响**：仅"告知"不够，**必须获得显式许可**。因此 [09 §7](09-安全与隐私威胁模型.md) 的"发送预览"从"可选的透明功能"升级为**首次使用每个渠道时的强制许可步骤**：

```
首次向 Anthropic 发送内容前：
┌── 需要你的许可 ─────────────────────────────┐
│ Rune 将把你的内容发送给第三方 AI 服务：        │
│   Anthropic（api.anthropic.com）            │
│                                            │
│ 本次将发送：1,847 tokens                     │
│   ├ 你的消息、文件 src/money.py               │
│   └ 已脱敏 2 处（手机号、内网域名）            │
│                                            │
│ 该服务的数据政策：API 默认不用于训练（官方声明）│
│                                            │
│ [查看完整内容]   [不同意]   [同意并记住此渠道]  │
└────────────────────────────────────────────┘
```
许可状态按渠道记录并可在设置里逐条撤销。

### 6.2 隐私标签：端侧处理不是"收集"

Apple 的隐私定义中：**"仅在设备上处理的数据不属于'收集'，无需申报。"** 这是"端侧执行"定位的又一个直接红利 —— 用端侧模型完成的任务完全不需要出现在隐私标签里。

需要申报的只有：**我们或第三方伙伴传输到设备外并保留**的数据（例如用户配置的第三方模型渠道的 prompt）。

### 6.3 年龄分级（2026 的新要求）

- 分级体系为 4+/9+/**13+/16+/18+**；问卷新增了"App 内控制、能力、医疗健康、暴力主题"等项
- Apple 明确要求把"**包括 AI 助手与聊天机器人功能**"一并计入敏感内容频率评估；**截止 2026-01-31，未更新的应用更新会被阻止**
- 没有独立的"AI"描述符 → AI 风险归入 Mature Themes / Medical / UGC / Messaging-Chat / Unrestricted Web Access
- **Rune 的分级判断**：一个能读写用户文件、联网检索、执行代码的工具，配合 AI 对话 → 现实分级应为 **16+**（含"不受限的网页访问"与"用户生成内容"），并在问卷中如实勾选

### 6.4 HIG 的生成式 AI 指引（虽非条款，但审核会引用）

| 指引 | 我们的落地 |
|---|---|
| **绝不能让用户误以为在与人交互或看人类创作的内容** | 所有 AI 产出**必须**有明确标识；不使用真人头像/人名；卡片上标注模型与"AI 生成" |
| 服务端处理要透明 | 发送前展示将要分享的内容（已升级为强制许可，见 6.1） |
| 使用个人信息前先获许可 | 相册/通讯录/健康等的每次访问都走系统授权 + 用途说明 |
| 输出可能有错，要提示 | 产物卡片带"已验证/未验证"标签（[04 §12.2](04-Agent运行时核心.md)） |
| **执行不可逆或有问题的操作前要征得同意** | 危险动作清单 + 生物识别（[04 §12.3](04-Agent运行时核心.md)） |

**另外**：DPLA §3.3.11(A) 规定使用 **Foundation Models Framework** 需遵守其 Acceptable Use Requirements 并**维持合理的内容护栏**。→ 接入 Apple FM 时必须实现在 §4.1 的过滤与举报机制。

---

## 7. 分发路径：现实版（重点：Enterprise 不可行，EU 替代分发无收益）

| 路径 | 规模 | 能力增益 | 结论 |
|---|---|---|---|
| **App Store** | 无限 | 基准 | ✅ 主渠道 |
| **TestFlight** | 外部 **10,000** / 内部 100，最多 100 个构建，**每个构建 90 天** | 无（**TestFlight 构建同样要审核，2.5.2 同样适用**） | ✅ 内测与灰度 |
| **Ad Hoc** | **每个产品族每会员年 100 台设备**（需 UDID） | 略宽（可开 Full 轨特性开关） | ✅ 核心用户 |
| **Xcode 自签** | 免费账号：10 个 App ID / **7 天**过期 / 3 台设备 / 每设备 3 个 App；付费账号：1 年 | ⭐ **唯一能拿到 JIT 的路径**（调试器附加式 sideload） | ✅ **极客用户的"Full 轨"** |
| **企业开发者计划** | $299/年，需 100+ 员工、法人实体、D-U-N-S、仅限员工 | — | ❌ **对外分发属直接违约**（2019 年 Facebook/Google 企业证书被吊销即此原因）。**不作为方案** |
| **EU 替代市场 / 网页分发**（2026-10-01 起统一条款） | 需满足若干门槛之一（如全球首年 100 万次安装、$100 万备用信用证等），**无需 EU 实体** | **零运行时能力增益**，且**失去 AIP**、需缴 **5% Core Technology Commission** | ⚠️ 仅在"App Store 路径彻底关闭"时作为备份 |
| **日本 / 巴西** | 日本已随 iOS 26.2 开放替代市场（同 5% CTC）；巴西有第三方市场但未见 Apple 制度页 | 同上 | ⚠️ 后续评估 |

### 7.1 关于 JIT：不要指望

- **iOS 不存在通用 JIT 权限**：`com.apple.security.cs.allow-jit` 是 **macOS Hardened Runtime 专属**，iOS 无对应 entitlement
- 唯一官方 JIT 通道是**浏览器引擎 entitlement**（要求仅在 EU 分发 + 通过 ~90% Web Platform Tests / 80% Test262）→ **只有浏览器能拿，Agent 拿不到**
- 现实中的 JIT 只有一条：**调试器附加式 sideload**（需要一次性桌面配置）
- **结论：Rune 必须按"无 JIT"设计。** 这与 [05](05-工具系统与执行沙箱.md) 的"解释器 + 原生工具优先"完全一致，**不是妥协，而是既定架构**

### 7.2 修正后的双轨策略

| | **App Store 轨** | **Full 轨（Xcode 自签 / Ad Hoc）** |
|---|---|---|
| 分发 | App Store + TestFlight | 用户自己签名（提供开源构建脚本 + 一键配置文档） |
| 运行时 | 随包 WASM 解释器 + **可选随包 WASM 编译器**（a-Shell 先例已验证） | 同左 |
| 从用户配置的索引获取纯 Python 包 | ❌ 关闭（零网络代码路径） | ✅ 可选开启 |
| JIT | ❌ 无（不存在） | ⚠️ 仅调试器附加式 sideload 场景，且**不作为设计前提** |
| 局域网/自签证书/明文 HTTP | 需用户显式开启不安全连接 | 放宽 |
| 后台自动化 | 保守（后台预算默认关闭） | 可开启自动续跑 |
| 开发者审计面板 | ❌ | ✅ |

> **重要修正**：原方案把 Full 轨寄托在"企业分发或 EU 替代市场"上。核实后这两条都站不住：**企业分发是违约**，**EU 替代分发不带来任何运行时能力增益**。
> **唯一真正可用的 Full 轨是"用户自己用 Xcode 签名"。** 因此**必须在 1.0 之前就准备好开源构建脚本与详细文档**——它既是合规绕行，也是最强的信任证明（"你可以自己编译，验证我们没后门"）。

---

## 8. 审核材料：决定过审率的关键工作

### 8.1 Review Notes 模板（英文，提交时填写）

```
=== What Rune is ===
Rune is an on-device AI assistant for engineering and data tasks. It reads and edits files in a
folder the user explicitly picks, runs scripts locally, and calls LLM APIs using the user's own
API keys. The advertised purpose of the app IS local code execution for the user's own work.

=== Local code execution (Guideline 2.5.2 / ADPLA 3.3.1(B)) ===
All interpreters and compilers (CPython compiled to WebAssembly, a JavaScript engine) ship INSIDE
the app bundle. The app NEVER downloads code, scripts, plugins, or executables from any server.
There is no code path in the app that fetches and executes remote content — verified by static
analysis and by the fact that the app is fully functional in Airplane Mode (except LLM inference).
The interpreters execute only content the user creates on-device, or files the user places in
their own workspace folder. This is the same model as a-Shell, Pyto, Pythonista and Working Copy.
Scripts operate on data only; they cannot add features, UI, or new capabilities to the app.

=== No account, no backend ===
No sign-up, no account. We operate no server that processes user data. On-device inference
(Apple Foundation Models) is used by default.

=== Third-party model APIs (Guidelines 5.1.2(i), HIG Generative AI) ===
Rune is a client for model providers the user chooses; the user supplies their own API key.
Before the FIRST request to any provider, the app shows exactly what will be sent and requires
explicit permission, which can be revoked per provider in Settings. Every AI-generated result is
labeled with the provider/model name. The app never implies Apple Intelligence is the source.

=== User-generated content safeguards (Guideline 1.2) ===
- Report: long-press any AI message -> "Report", with a local queue and a documented response
  process (support@<domain>).
- Block: the counterparty is the model/persona; Settings -> Providers offers per-provider and
  per-model blocking.
- Filter: objectionable-content filtering is implemented IN THE BINARY (not delegated to the
  upstream provider). Settings -> Content Filter lets the user review and adjust it; code blocks
  and file contents are excluded from filtering by design.
- Contact: support@<domain> is shown in Settings -> About and is valid in App Store Connect.

=== Demo steps for review (no account or key required) ===
1. Launch -> tap "Try the sample project" (a small bundled git repository).
2. Type: "Look at this project and write a README for it."
3. The ON-DEVICE model handles it; you will see it read files, write a file, and produce a diff
   card. Tap a file card to inspect and revert changes.
4. Settings -> Runtimes lists every bundled runtime, compiler and library with versions.
5. To test a cloud provider: Settings -> Models -> add any OpenAI-compatible base URL + your key.

=== What the app does NOT do ===
- Does not generate, install, or preview iOS apps.
- Does not download or execute code from the internet.
- Does not modify its own features or behavior at runtime.
- Does not provide a plugin/app marketplace.
- Does not sell or resell model inference.
```

### 8.2 随审核提交的材料

- [ ] 上述 Review Notes（**不能空泛，2.1 空说明是高频拒审原因**）
- [ ] **内置示例项目**（随包小型 Git 仓库，含一个待修 bug 与一个测试）→ 审核员无需账号即可跑通完整流程
- [ ] 90 秒演示视频：选目录 → 语音下任务 → 端侧执行 → diff 卡片 → 回滚
- [ ] 设置页的"运行时与许可"页（列出全部内置运行时/编译器/库 + 版本 + 许可证）
- [ ] 权限用途说明逐条写实（`NS*UsageDescription`）
- [ ] 内容过滤与举报的用户可见说明
- [ ] 隐私清单 `PrivacyInfo.xcprivacy` + required-reason API 代码与 App Privacy 问卷**三者一致**
- [ ] 截图与实际构建一致（iOS 26 的 Liquid Glass 视觉也要对得上）

### 8.3 常见拒审理由与应对

| 理由 | 应对 |
|---|---|
| 2.5.2 下载/执行代码 | 提交 §1.3 对齐表 + 断网演示 + 运行时清单；**申诉有效**（iSH 先例：通知→申诉→当日撤回）。若仍被拒 → 提交"仅原生工具"构建（把 WASM 沙箱降为 Full 轨能力） |
| **1.2 UGC（未提供举报/屏蔽/过滤）** | 补齐四项机制（**2026 年最高频**） |
| 4.2 最低功能性 | 演示无 Key 状态下的完整能力（端侧模型 + 内置示例项目） |
| 4.3(b) 不增加价值 | 强调独特性：本地执行引擎、端侧推理、移动原生交互 |
| 5.1.1(v) 缺账号删除 | 我们无账号；仍需在隐私页说明"无账号 + 一键清空" |
| 5.1.2(i) 未披露第三方 AI | 强制许可流程 + 每渠道提示 + 标签一致 |
| 2.3 截图与构建不符 | 发版前重新截图（含 iOS 26 外观） |
| 2.1 审核说明空泛 | 用上面的模板，写明具体 UI 路径 |

---

## 9. 持续合规：变成工程流程而不是一次性工作

| 检查项 | 触发 | 责任 |
|---|---|---|
| 新增任何"网络 → 执行"路径 | 每个 PR（CI 静态检查） | 架构评审（**否决项**） |
| 二进制中是否出现远程执行相关符号 | 每次构建（CI 符号扫描） | 工程 |
| 内容过滤/举报/屏蔽是否仍可用 | 每次发版（UI 测试） | QA |
| 第三方 AI 显式许可流程是否完好 | 每次发版 | QA |
| 新增渠道的数据政策文案 | 每次新增渠道 | 产品 |
| 内置运行时清单与许可证 | 每次升级运行时 | 工程 |
| Review Notes 与功能同步 | 每次发版 | 产品 |
| 示例项目可跑通（审核首条路径） | 每次发版 | QA |
| 年龄分级问卷是否需要因新 AI 功能调整 | 每次发版 | 产品 |

---

## 10. 长期判断

1. **"端侧执行"在合规上是优势**：端侧处理的数据不算"收集"（无需进隐私标签）；App 不提供算力服务（不触发 3.1.1 的核心争议）；用户数据不出设备（5.1.2 压力最小）。
2. **最大风险不是 2.5.2 而是自修改行为**。Apple 明确说过：帮助用户构建东西可以，**改变 App 自身行为不行**。Rune 的架构天然规避这一点（Agent 循环是编译进包的固定代码，脚本只处理数据）——**这个边界必须在任何新功能评审中被反复确认。**
3. **可自签是终极保险**，且必须在 1.0 之前就绪。
4. **产品叙事必须与合规叙事一致**：我们不是"用手机做 App 的工具"，而是"在手机上完成工程与数据任务的助手"。文案、UI、审核说明三者统一，是过审率最高的做法。

---

**上一篇**：[10 后台执行与可靠性](10-后台执行与可靠性.md) · **下一篇**：[12 数据模型与持久化](12-数据模型与持久化.md)
