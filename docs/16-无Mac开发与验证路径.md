# 16 · 没有 Mac 怎么开发和验证这个项目

> **摘要**：结论是**可以**，而且不是歪门邪道 —— 路径是
> **GitHub Actions 的 macOS 运行器负责"编译与测试"，Windows 上的 Sideloadly 负责"签名与装机"**。
> 这条路上唯一真正做不到的是**交互式**调试（Xcode 断点、Instruments、模拟器里手动点）。
> 本文把每一步能验证什么、不能验证什么、成本多少，以及**第一次跑会踩到什么**都写清楚。

---

## 1. 先说不能做的（免得抱错期望）

| 想做的事 | 没有 Mac 能不能做 | 说明 |
|---|---|---|
| 编译 iOS App（SwiftUI / UIKit / AVFoundation） | ✅ **能**（在 CI 的 macOS 运行器上） | 需要真正的 macOS，但不必是你的机器 |
| 跑 XCTest / swift-testing 单元测试 | ✅ **能** | CI 上跑，结果与日志可下载 |
| 在 iOS 模拟器上跑 UI 测试、截图 | ✅ **能**（非交互） | `xcodebuild test` 支持；截图作为产物上传 |
| 把 App 装到自己的 iPhone 上 | ✅ **能** | Windows 上用 Sideloadly/SideStore 签名装机 |
| **交互式**调试（断点、变量查看） | ❌ **不能** | 这是唯一的硬缺口 |
| Instruments 性能剖析 / 内存图 | ❌ **不能** | 只能靠自埋点导出数据再看 |
| 手动在模拟器里点来点去 | ❌ **不能** | 只能靠 UI 测试脚本驱动 + 截图产物 |
| 依赖 Apple 私有/新 API 的即时试错 | ⚠️ 很慢 | 每次试错都是一次 CI 往返（几分钟） |

**所以工作方式的改变是**：从"改一行、按一下运行"变成
**"写测试 → 推代码 → 看 CI 报告"**。这在本项目里恰好是可行的，因为
`docs/14` 的测试策略本来就是"以测试与回放夹具为准，而不是以手工点击为准"。

---

## 2. 三层路径

```
┌── 层 1：纯逻辑（RuneKernel）────────────── GitHub Actions · ubuntu-latest ──┐
│  swift test —— 不需要 macOS                                             │
│  ⭐ 顺带证明"RuneKernel 零 Apple 依赖"这句话是真的                        │
└──────────────────────────────────────────────────────────────────────────┘
┌── 层 2：平台代码（Store/VFS/Bench/Tools/Core/UI）── GitHub Actions · macos ─┐
│  swift build + swift test（真的 Apple SDK）                               │
│  xcodebuild 生成并构建 App、跑模拟器测试、截图产物                          │
└──────────────────────────────────────────────────────────────────────────┘
┌── 层 3：装机（你的 iPhone）────────────── Windows · Sideloadly ────────────┐
│  下载 CI 产出的**未签名 .ipa** → 用 Apple ID 签名 → USB 安装                │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.1 层 1：Linux 上跑内核

`RuneKernel` 是**零依赖**的（只 Foundation + 标准库），所以它能在 `ubuntu-latest` 上构建与测试。
这不只是省钱 —— 它把一句**架构承诺变成了 CI 断言**：

> "RuneKernel 不得 import 任何 Apple 专属框架" ——
> 只要有人在里面写了 `import CryptoKit` 或 `import UIKit`，Linux 那一条就会红。

而这句话在本项目里是硬要求：`CryptoKit` 是 Apple 专有的（所以我们自己实现了 SHA-256），
`swift-crypto` 是外部依赖（会破坏零依赖）。**CI 是唯一能自动守住它地方。**

### 2.2 层 2：macOS 运行器上构建平台代码

- 公开仓库：macOS 运行器**免费**（GitHub 对公开仓库的 Actions 不计费）。
- 私有仓库：macOS 运行器按**倍率**扣分钟数（macOS 的倍率高于 Linux，具体数字见
  [GitHub 的计费说明](https://docs.github.com/en/billing/manual/apps/github-actions)，
  2025-12 与 2026-01 各有一次价格调整，**以官方页面为准**）。
  → **把仓库设为公开**是最省事的做法，本项目也适合公开（见 `docs/15` 的 Q4：核心闭源、工具与技能开源）。

- iOS App 需要 `.xcodeproj`，而 SwiftPM **产不出 iOS .app**。
  所以用 [**XcodeGen**](https://github.com/yonaskolb/XcodeGen)：仓库里只放 `project.yml`（人写的 YAML），
  运行器上一条命令生成 `.xcodeproj`。这样**不需要在仓库里塞一个二进制工程文件**，
  也就不会出现"改冲突改到 project.pbxproj 里去了"这种经典事故。

### 2.3 层 3：Windows 上装机

iOS 上的 App 必须被签名才能安装。**签名不需要 Mac**：

| 工具 | 平台 | 说明 |
|---|---|---|
| [**Sideloadly**](https://sideloadly.io/) | Windows / macOS | 用你的 Apple ID 对 IPA 重签名并经 USB 安装 |
| [**SideStore**](https://sidestore.io/) / AltStore | iPhone 上 | 装在手机上的签名器，配合电脑端一次配对后可无线续签 |
| Xcode | ❌ | 不需要 |

**免费 Apple ID 的限制**（这些是 Apple 的规则，不是工具的限制）：

| 限制 | 值 |
|---|---|
| 签名有效期 | **7 天**（到期 App 打不开，需要重签） |
| 同时安装 | **3 个** App |
| 每 7 天可注册的 App ID | 10 个 |

⚠️ **7 天这一条对"每天用"的 Agent 是不可接受的** —— 你会在地铁上打开它，然后发现"App 已失效"。

**$99/年的 Apple Developer Program 会去掉这三条限制**（签名有效期变成 1 年），
并且打开 **TestFlight** —— 那是一条**完全不需要电脑**的分发路径：
CI 用 App Store Connect API Key 直接上传构建 → 你在 iPhone 的 TestFlight App 里点安装。

> **建议的路线**：先用免费 Apple ID + Sideloadly 把"能装上、能跑"验证掉（这一步零成本），
> 确认方向对之后，再决定要不要花 $99 换成 TestFlight（免重签）。

---

## 3. 成本对照

| 方案 | 成本 | 能交互调试 | 装机方式 |
|---|---|---|---|
| **GitHub Actions + Sideloadly**（本方案） | **$0** | ❌ | 7 天重签 |
| 同上 + Apple Developer Program | $99/年 | ❌ | TestFlight，1 年 |
| 二手 Mac mini（M1，8G） | 约 ¥2000–3000 | ✅ | Xcode 直装 |
| MacinCloud / MacStadium 等云 Mac | 按小时/月计费（**具体价格需自行核实**） | ✅（远程桌面） | 远程 Xcode |
| 借用/公司 Mac | $0 | ✅ | Xcode 直装 |

> **如果这个项目要认真做下去，一台二手 M1 Mac mini 是性价比最高的一步。**
> 但**在买到之前，本文的 CI 路径足以把项目推进到"能在手机上跑"**。

---

## 4. 第一次跑会踩到什么（提前说，省你时间）

1. **CI 第一次失败是正常的**。`Packages/Rune*` 的 `Package.swift` 是在 Windows 上手写的，
   **从未被真正的 SwiftPM 解析过**（本机 SwiftPM 的子进程执行层是坏的，见 `PROJECT_STATE §3 E1`）。
   第一次跑 CI 就是在**验证这些 manifest**，有错很正常。
2. **XcodeGen 的 `project.yml` 也可能要改一两轮**（bundle id、部署目标、Info.plist 键）。
3. **模拟器测试很慢**（一次几分钟），而且 `macos-latest` 的 Xcode 版本会随 GitHub 更新 ——
   **要固定 Xcode 版本**（`xcode-select -s`），否则某天它自己升级了、构建突然挂了。
4. **未签名 IPA 的构造方式**：`xcodebuild build` 时加 `CODE_SIGNING_ALLOWED=NO`，
   然后把 `.app` 放进 `Payload/` 再 zip 成 `.ipa`。这是 sideload 工作流的标准做法
   （Sideloadly 会自己重签，所以带的签名必须是"没有签名"而不是"签错了"）。
5. **`Info.plist` 里的权限描述必须写全**（相册、相机、日历、定位、麦克风…），
   少一个就是**运行时崩溃**，而且只在真机上崩、模拟器不崩。

---

## 5. 本项目的具体落地

已加入仓库的 CI：

| 文件 | 运行器 | 做什么 |
|---|---|---|
| `.github/workflows/kernel.yml` | `ubuntu-latest` **和** `macos-latest` | 构建 + 测试 `RuneKernel`（两个平台都过，证明零依赖承诺） |
| `.github/workflows/ios.yml` | `macos-latest` | 构建全部包 → XcodeGen 生成工程 → 构建 App → 模拟器测试 → 产出未签名 `.ipa` |

本地（Windows）仍然用 `Tools/rune.ps1`（唯一可用的构建入口，见 `PROJECT_STATE §3`）。

**你要做的三步**：
1. 在 GitHub 上建一个**公开**仓库，把本仓库推上去；
2. 打开 Actions 页，等 `kernel` 那条绿（它会告诉你 `Package.swift` 有没有问题）；
3. 等 `ios` 那条把 `.ipa` 作为产物传上去 → 下载 → 用 Sideloadly 装到手机上。

---

## 6. 与 §1 那张表的呼应：哪些验证**永久**留在 CI

即使将来有了 Mac，下面这些也应该**留在 CI**，而不是靠人记得跑：

- `RuneKernel` 的 Linux 构建（守住"零 Apple 依赖"）
- `RuneKernel` 的 822 项测试（跨平台一致）
- 模拟器上的 UI 冒烟测试 + 截图（人不会每次都手动点一遍，CI 会）
- 未签名 IPA 的产出（保证"随时可以装机"这条链不烂掉）

**能自动化验证的东西不要留给人。** 这条在手机上尤其重要：
真机上的失败（权限描述缺失、后台被挂起、内存被杀）**只有装上去才会发现**，
而 CI 能保证"装上去的那一版"至少是通过了全部自动化检查的那一版。
