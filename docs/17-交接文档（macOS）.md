# 17 · 交接文档：搬到 macOS 上继续开发

> **这份文档是给"接手的人（或下一个 Agent）"看的**，而且是给**在 macOS 上工作**的那个人看的。
> 读完它 + [`PROJECT_STATE.md`](../PROJECT_STATE.md) + [`docs/进度日志.md`](进度日志.md) 的最近几条，
> 就能无损接上，不需要重新探索代码库。
>
> **日期**：2026-09-18 · **交接时 HEAD**：`a4943a2` · **仓库**：<https://github.com/Sakura-Lhy0409/rune>

---

## 0. 一分钟版本

**Rune（符文）**：完全在 iPhone/iPad 本地运行的通用 Agent。模型走云端 API（BYOK，含中转站），
但**工具循环、文件系统、代码执行、Git、检索、记忆全部在设备上完成，没有任何远端执行路径**。

**现在的状态**：内核（`RuneKernel`，41 个源文件、**1032 项测试**）已经完成并在 CI 上双平台验证；
iOS App 能构建、能打包成可侧载的 `.ipa`、**能在真模拟器上跑通内核**。
`RuneStore`（事件落盘）刚开了第一片。

**你要做的第一件事**：
```bash
git clone https://github.com/Sakura-Lhy0409/rune.git && cd rune
swift build --package-path Packages/RuneKernel
swift test  --package-path Packages/RuneKernel     # 应当 1032 通过
bash Tools/ci.sh all                               # 全部包：构建 + 测试 + 审计
```

---

## 1. 仓库里有什么

```
PROJECT_STATE.md            ⭐ 续接文档（≤300 行，先读它）
README.md                   设计文档入口
docs/01 … 16 + 附录A/B       19 份设计文档（01 产品定位 … 16 无 Mac 路径）
docs/进度日志.md             ⭐ 追加式时间线（40+ 条，细节都在这）
docs/17-交接文档（macOS）.md  ⭐ 本文件
research/                   465 份事实取证件（**故意入库**，不要加 .gitignore）
Packages/
  RuneKernel/               ✅ 零依赖核心（41 源文件 / 1032 测试全绿）
  RuneStore/                🔨 第一片（GRDB + event 表，见 §5）
  Rune{Net,VM,Bench,Gateway,Context,Core,Tools,MCP,UI}/   ⬜ 骨架（占位文件里是实现清单）
Tools/                      rune.ps1(Windows 专用) · ci.sh · check_ci.py · lint_quotes.py · check_docs.py
.github/workflows/          kernel.yml（ubuntu+macos）· ios.yml（macos：包→App→ipa→模拟器）
Apps/Rune/                  XcodeGen project.yml + SwiftUI 源码 + UI 冒烟测试
```

**分支**：`main`。**没有别的分支**，也没有未合并的工作。

---

## 2. 在 macOS 上怎么跑（这一节和 Windows 完全不同，注意）

| 事情 | 命令 |
|---|---|
| 构建某个包 | `swift build --package-path Packages/RuneKernel` |
| 跑测试 | `swift test --package-path Packages/RuneKernel` |
| 全部包 + 审计 | `bash Tools/ci.sh all`（或 `kernel` / `build` / `test` / `audit` / `ios` / `ipa`） |
| 生成 Xcode 工程 | `cd Apps/Rune && xcodegen generate`（`brew install xcodegen`） |
| 构建 App | `bash Tools/ci.sh ios` |
| 打未签名 ipa | `bash Tools/ci.sh ipa` |
| 跑 UI 冒烟测试 | 见 `.github/workflows/ios.yml` 的 `模拟器冒烟测试` job |

⚠️ **`Tools/rune.ps1` 是 Windows 专用的**（因为本机 SwiftPM 的子进程执行层坏了才存在）。
在 macOS 上**不要用它**，用标准 `swift build/test`。
⚠️ **两个平台的测试数量应当都是 1032**（RuneKernel）。数字对不上就是有问题。

**在 macOS 上你终于可以做的事**（这是迁移的全部意义）：
- `swift test` 秒级反馈，不再是"推 CI 等 5 分钟"
- **交互式调试**：断点、Instruments、直接在模拟器里点
- 直接 `xcodebuild` 迭代 UI，不用靠 dump 猜界面长什么样
- 真机调试（`xcodebuild -destination 'platform=iOS,id=<设备>'`）

---

## 3. 已经验证过的事实（**不要重新验证，别重复劳动**）

### 3.1 CI 是绿的（2026-09-18）
| job | 结果 | 意义 |
|---|---|---|
| `kernel` / ubuntu-latest | ✅ | 零 Apple 依赖这条**架构承诺**是可自动守住的 |
| `kernel` / macos-latest | ✅ | 标准 SwiftPM + 1032 测试 |
| `kernel` / 零依赖审计 | ✅ | 没有外部依赖、没有 Apple 框架、没有 `Process` |
| `ios` / 包构建与测试 | ✅ | 全部 11 个包在 macOS 上构建 |
| `ios` / App 构建与打包 | ✅ | **产出可侧载的 `Rune-unsigned.ipa`**（1.8MB） |
| `ios` / 模拟器冒烟测试 | ✅ | **App 在真模拟器上跑通内核**（见 3.2） |

### 3.2 App 在真 iOS 模拟器上跑通了内核（这是"真的能干活"的证据）
UI 测试 dump 出来的界面内容（CI 日志里）：
```
· 4 次工具调用            · 链校验通过            · 20 条事件 · 哈希链校验通过
· ToolCallRequested · list_dir   → 工具完成 · list_dir
· ToolCallRequested · read_file  → 工具完成 · read_file
· ToolCallRequested · edit_file  → 工具完成 · edit_file   · 创建检查点
· ToolCallRequested · read_file  → 工具完成 · read_file
· 工作区（磁盘上的真实内容）· /…/Documents/RuneDemo · README.md · notes.md
```

### 3.3 内核里已经做完并测试过的东西（**别重做**）
值类型与安全 · 补丁引擎 · 检索 · **渠道网关（路由/降级/重试/去重/按协议族分组历史）** ·
**成本账本与熔断** · **结构化压缩** · **出站请求构建与协议体检** · **模型调用客户端** ·
策略引擎 · Turn 循环与崩溃恢复 · 波次调度 · 计划引擎 · 审批代理 · 目标引擎 ·
修正性重试与协议不变式 · 上下文预算制装配 · 86 个工具契约 · 技能库与渐进式披露 ·
Workflow 编排 · VFS（真实 FS + 内存两份实现）· 自研 shell 解释器 · 沙箱层。

**逐条细节在 [`PROJECT_STATE.md`](../PROJECT_STATE.md) §5 与 [`docs/进度日志.md`](进度日志.md)。**

---

## 4. 还没做 / 没验证的（**这才是你的工作清单**）

| # | 事项 | 状态 |
|---|---|---|
| ① | **`RuneStore` 第一片**（GRDB + event 表 + 迁移 + 落盘/读回/验链） | 🔨 **代码写完但尚未在 CI 上跑绿** —— 见 §5，这是第一件该做的事 |
| ② | `RuneStore` 其余：投影表（session/turn/goal）、检查点/VFS 快照表、FTS5（**必须 CJK 分词器或 trigram，绝不用 unicode61**） | ⬜ |
| ③ | `RuneNet`：URLSession + SSE + 出口代理。**`ModelClient` 已经把传输抽象成同步协议 `ModelTransport`**，你只需要实现一个 URLSession 版本并接上 | ⬜ |
| ④ | `RuneBench`：VFS 落地 + security-scoped bookmark + CPython 垫片 | ⬜ |
| ⑤ | `RuneTools`：**72 个工具没实现**（执行类 CPython/JSC/WASM、网络类、iOS 原生类） | ⬜ |
| ⑥ | `RuneCore`：把上面接起来，替换 `Apps/Rune/Sources/RuneEngine.swift` 里的 `ScriptedModel` | ⬜ |
| ⑦ | `RuneUI`：docs/08 那套交互（现在是能跑通链路的最小界面） | ⬜ |
| ⑧ | **L3 压缩的付费调用**：决策 + 产物格式 + 解析都就位，运行时那一次调用没接 | ⬜ |
| ⑨ | **Workflow 的 JSC 宿主**（脚本 → DAG 的编译层） | ⬜ |
| ⑩ | 真实渠道压测：多工具结果的分组、错误分类、重试，**要用真 API key 各压一次** | ⬜ |

---

## 5. ⚠️ 交接时的"未完成态"（请先读这一节）

**`RuneStore` 的第一片代码已写完并推送，但还没在 CI 上跑绿。** 具体状态：

- `Packages/RuneStore/Package.swift` 已加上 **GRDB 7.x** 依赖与测试 target；
  **CI 已确认 GRDB 能解析并编译**（这是最不确定的一步，已经过了）。
- `Sources/RuneStore/EventStore.swift`（`RuneEventStore`）：event 表 + 手写 `user_version` 迁移 +
  落盘/读回/验链 + `lastHash` 锚点支持。
- `Tests/RuneStoreTests/EventStoreTests.swift`：9 项测试（往返无损、链仍校验、按会话串链、
  关开文件事件还在、篡改可检测、迁移幂等、按 kind/turn 检索）。
- 交接前修掉的三类编译错误：`EventKind` 名字写错两处、GRDB 7 的 `Row` 取值要 `as?`。
  **最后一处修复（`a4943a2`）还没等到 CI 结果就交接了。**

**你接手后的第一个动作**：
```bash
swift build --package-path Packages/RuneStore   # 或
swift test  --package-path Packages/RuneStore
```
按报错修即可 —— 大概率只剩零星的 API 名字/类型问题，**设计已经定好，不要重写**。

**这一片有两个刻意的决定，别当成 bug 改掉**：
1. event 表多了一列 `envelope_json`（docs/12 的 DDL 里没有）：
   其余列是为查询/索引服务，而我们要**逐字段无损往返**；
   `RuntimeEvent` 字段全是 `let`、哈希在构造时算好，靠"各列拼回 JSON 再解码"
   会在类型演进时**静默错位**（那种错不报错，只会让恢复出来的事件不是同一条）。
2. v1 **不建 `REFERENCES` 外键**：docs/12 的外键是意图声明，但 `session`/`turn`/`goal`
   三张投影表还不存在，而事件**先于**投影写入 —— 这时打开外键强制，会让"写第一条事件"直接失败。
   等投影表接上再补外键。

**建议的验证顺序**（每步都能本地跑，不用等 CI）：
`RuneStore` 编译 → 测试绿 → 把 `RuneEventStore` 接进 `RuneCore` →
App 里跑一轮之后**杀掉进程再启动**，确认事件还在、链还校验得过（这才是"崩溃恢复"的第一步）。

---

## 6. 那些会咬人的坑（**每条都真实踩过**）

完整清单在 [`PROJECT_STATE.md`](../PROJECT_STATE.md) §7（E1–E9 环境、T1–T56 项目）。
其中在 macOS 上最可能再遇到的：

| 坑 | 一句话 |
|---|---|
| **T45 / T55** | 平台差异最爱藏在"同一个目录的两种写法"里（macOS 上 `/var/…` 与 `/private/var/…` 是同一个目录）。**相对路径交给文件系统给**（`subpathsOfDirectory`），不要自己切字符串 |
| **T55** | **`try?` 会把错误变成静默的成功** —— 一个"看起来回滚了、其实什么都没回滚"的回滚比直接报错危险得多 |
| **T52** | **别把"值得重试"当兜底分类**：401/402/403 被重试，甚至**余额不足不算失败**，Agent 报了个"成功" |
| **T53** | 凡读时钟做判定的地方都要收 `now`；一个默认 `Date()` 就是一个不确定性入口 |
| **T54 / T48 / T49** | **一个完整的子系统可以只以「声明 + 测试」的形式存在**（本项目栽过三次）。新增任何一层能力时先问：**谁调它？** 定期做"调用点普查" |
| **T50** | 「只输出 JSON」是模型经常不听的指令；解析器要先**抠出** JSON，而且**只抠第一块不够**（诱饵 `{}` 也是合法 JSON） |
| **T56** | UI 测试的失败细节默认**读不到**（都在 `.xcresult`）；主动把界面文字 `print` 到日志 |
| **T34** | **iOS 文件名大小写不敏感**（APFS）；反过来 NFC/NFD 在 Swift+APFS 上**基本不是问题** |
| **T22** | 中文 token ≈ **1 字符/token**，用 `/4` 估会低估 4 倍 |
| **T18** | assistant 里每个 `tool_call` 都必须有配对结果且**紧跟其后**，否则**后续所有请求 400** |

**两条工程纪律**（比任何单条坑都重要）：
1. **改完就故意破坏它，看有没有测试变红。** 不会失败的检查等于装饰。
   本项目每次这么做都抓到了真问题（最近一次：把"重试/换渠道"砍掉 → 8 条断言变红）。
2. **断言失败信息里必须有实际值。** 「某某 != 某某」这种失败会让人只能靠猜 ——
   macOS 上那个 VFS bug 就是先把断言改成打印实际值才拿到真相的。

---

## 7. 不可动摇的三条铁律（来自产品的定义，不要为了省事绕过去）

1. **完全端侧执行**：工具循环、文件系统、代码执行、Git、检索、记忆全在设备上。
   **不存在任何远端执行路径**。模型只负责"想"，不负责"做"。
2. **模型可插拔**：必须支持官方直连、官方云、**第三方中转站**、局域网自建、端侧模型。
   中转站是中文开发者刚需 → 做成一等公民，但**风险必须透明**（服务方可见你的全部内容）。
3. **手机不是降级版**：体验要超过桌面 Agent。三条硬规则各有测试守着：
   **禁止静默降级** · **`verify` 必须与执行用不同模型** · **敏感项目里中转渠道不进候选**。

---

## 8. 还有哪些"不敢算完成"的地方（诚实清单）

- **没有任何真实渠道的联调**：所有协议验证都是"真实编码 + 真实解字节 + 脚本化响应"。
  三家（OpenAI/Anthropic/Gemini）各自都有只在真实服务端才会暴露的细节，**必须各压一次**。
- **72 / 86 个工具没实现**。
- **`RuneStore` 只有事件表**（没有投影、检查点表、FTS5）。
- **UI 是最小可跑界面**，不是 docs/08 那套交互。
- **App Store 合规**（审核、CPython 内嵌、体积 1–2GB）全部未验证。
- 免费 Apple ID 签名只有 **7 天**（$99/年去掉限制并开 TestFlight）。

---

## 9. 语言与风格约定（请保持一致）

- **文档、注释、UI 文案用中文；代码标识符用英文。**
- ⚠️ **中文引号一律 `「」`**：手打 ASCII `"` 会截断 Swift 字符串字面量，
  而编译器报的是 `expected ',' separator` 这类**与真实原因毫不相干**的错误（T28/T42）。
  `Tools/lint_quotes.py` 会在编译前几十毫秒指到行（`rune.ps1` 与 CI 都已接入）。
- 注释要写**为什么**，不要复述代码在做什么。特别是"这里为什么不能用更直觉的写法"。
- 测试名用中文，并且要说明**这条测试守的是什么**（失败时它能告诉你该改哪儿）。
- 提交信息：中文，说清"发现→根因→改法"，不要只写"fix bug"。

---

## 10. 交接检查单

- [ ] `git clone` 并确认 HEAD 是 `a4943a2` 或更晚
- [ ] `swift test --package-path Packages/RuneKernel` → **1032 通过**
- [ ] `bash Tools/ci.sh all` → 全部包构建通过
- [ ] `swift test --package-path Packages/RuneStore` → 把它修绿（§5）
- [ ] 在 Xcode 里打开 `Apps/Rune`（先 `xcodegen generate`），**跑一次模拟器**
- [ ] 读 `PROJECT_STATE.md` §5（做过了什么）与 §6（下一步）
- [ ] 挑一件 §4 里的事开始做，**做完就更新 `PROJECT_STATE.md` 与 `docs/进度日志.md`**
