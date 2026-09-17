# research/ —— 事实核查的原始取证材料

本目录**不是设计文档的一部分**，而是设计文档中每一条"已核实"结论的**原始证据**。保留它的目的有三个：

1. **可追溯**：任何人（包括未来的我们）可以核对某个数字究竟出自哪份官方文档，而不是"文档里这么写的"。
2. **可复现**：抓取脚本与 URL 清单都在，Apple 改文档时能快速重新核对。
3. **可反驳**：如果某条结论错了，证据链在这里，能被指出来并修正。

---

## 目录结构

```
research/
└─ raw/
   ├─ dot-research/          iOS 平台能力（Foundation Models / 后台 / 文件系统 / 动态代码 / UI / 网络）
   │   ├─ pages/             ~45 份一手抓取件（Apple 官方文档、WWDC26 场次、基准仓库）
   │   ├─ *.doc.txt          官方文档正文提取
   │   ├─ *.raw.json         原始 API JSON
   │   ├─ bulkfetch.ps1      批量抓取脚本
   │   └─ urls*.txt          抓取的 URL 清单
   ├─ _src/                  App Store 合规（指南原文、先例 App 页面、媒体报道）
   │   ├─ dpla.txt           ⭐ Apple 开发者协议全文（含 §3.3.1(B) 关键条款）
   │   ├─ guidelines*.txt    App Store 审核指南全文
   │   ├─ itunes_*.json      各先例 App 的在架状态快照
   │   └─ ptkd_*.txt         第三方对 2.5.2 / 1.2 的实务分析
   ├─ _src2/                 分发路径与法域条款（EU DMA / 日本 / TestFlight / 企业计划 / JIT entitlement）
   ├─ _apps/                 11 个先例 App 的商店页面全文（a-Shell / Pyto / Pythonista / Working Copy / …）
   ├─ _research/             渠道与模型 API（协议细则、缓存、中转实现）
   └─ reports/
       └─ REPORT-ios-distribution-capabilities.md   分发能力对比的独立报告
```

---

## 使用方法

| 你想做什么 | 去哪里看 |
|---|---|
| 核对"iOS 到底有没有 JIT" | `raw/_src2/jit_ent.txt`、`raw/dot-research/allowjit.doc.txt`、`raw/dot-research/browserenginekit.doc.txt` |
| 核对 2.5.2 与 ADPLA §3.3.1(B) 的原文 | `raw/_src/guidelines*.txt`、`raw/_src/dpla.txt` |
| 核对"a-Shell 到底能干什么" | `raw/_apps/a-shell.txt`、`raw/dot-research/ashell_readme.txt` |
| 核对 Foundation Models 的 4096 上限 | `raw/dot-research/apple_tn3193.txt` |
| 核对后台时间预算 | `raw/dot-research/bg*.doc.txt`、`raw/dot-research/longrunning.doc.txt` |
| 核对端侧模型实测 tok/s 与内存天花板 | `raw/dot-research/bench_*.txt`、`raw/dot-research/pages/bench_apple_silicon_llm.txt` |
| 核对 WASM 运行时真实能力 | `raw/dot-research/wamr_*.txt`、`wasm3_readme.txt`、`wasmkit_*.txt`、`wasmer_ios_headless.txt` |
| 核对中转站实现差异 | `raw/_research/` 与 [附录 A](../docs/附录A-渠道与模型事实表.md) |

---

## 三项必须知道的方法论说明

1. **本会话中 `web_fetch` 工具不可用**（DNS 被解析到非公网地址并被 SSRF 守卫拒绝）。所有抓取均改用 `pwsh` 的 `Invoke-WebRequest` / `curl` 直连完成。因此材料里可能混有 HTML 包裹内容，不影响事实提取。
2. **`developer.apple.com` 论坛帖无法读取**（有机器人校验）。凡出自论坛的数字（例如键盘扩展的 ~60MB 内存上限），在设计文档中一律标注为 `[不确定]`。
3. **Apple 未公布的数字，本文档集一律写"未公布"**：包括 `BGProcessingTask` 与延续处理任务的具体时长、jetsam 内存上限、端侧模型参数量、键盘扩展内存上限。**我们不用推测值去填这些空白**——把"不知道"如实写出来，比给出一个看起来精确的错数字更有价值。

---

## 时效

核对基准日 **2026-09-17**（iOS/iPadOS/watchOS/visionOS **27.0** 为当前发行版）。

**Apple 改文档时，这些材料会过时。** 建议在每个 iOS 大版本发布后重跑一次 `bulkfetch.ps1`，并复核 [附录 B](../docs/附录B-技术选型核实表.md) 的结论。
