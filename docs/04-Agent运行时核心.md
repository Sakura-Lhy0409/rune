# 04 · Agent 运行时核心

> **摘要**：运行时是整个产品的引擎。它必须同时满足三个互相拉扯的要求：**足够强**（能跑完长任务）、**足够稳**（随时可被系统杀掉再续）、**足够透明**（用户随时知道它在干什么、花了多少、动了什么）。本文定义 Turn 状态机、工具协议、Goal/Job/Workflow/Subagent 四层编排、检查点机制与输出契约。

---

## 1. 一个 Turn 的生命周期

Turn = "用户一次输入所引发的一整段自主工作"。它是**可持久化、可暂停、可恢复、可回滚**的最小工作单元。

```
                    ┌──────────┐
       用户输入 ───▶ │  Intake  │  归一化输入：文本/语音转写/图片/文件/分享/Intent
                    └────┬─────┘
                         ▼
                    ┌──────────┐   需要更多信息？──▶ Clarify（问一个问题，等待，不消耗预算）
                    │  Triage  │
                    └────┬─────┘   纯问答/闲聊？──▶ Answer（单轮直出，不进入工具循环）
                         ▼
                    ┌──────────┐
                    │  Context │  装配上下文：项目指令 + 记忆检索 + 文件切片 + 工具清单
                    └────┬─────┘
                         ▼
                 ┌───────────────┐   若 Trust Dial ≤ 提议档 或 任务复杂
                 │  Plan (可选)  │──────────────────────────▶ 用户批准计划
                 └───────┬───────┘
                         ▼
        ┌────────────▶┌──────────┐
        │             │  Reason  │  调用模型（可多轮）
        │             └────┬─────┘
        │                  ▼
        │            ┌──────────┐   无工具调用 ──▶ Finalize
        │            │ Dispatch │  解析工具调用 → 策略判定 → 审批 → 执行（并行）→ 结果归一化
        │            └────┬─────┘
        │                 ▼
        │            ┌──────────┐
        └── 继续 ◀───│ Observe  │  结果入上下文（制品句柄 + 摘要），更新 Todo，检查预算/熔断
                     └────┬─────┘
                          ▼
                     ┌──────────┐
                     │ Finalize │  产物落盘 + 检查点 + 摘要 + 消耗报告
                     └────┬─────┘
                          ▼
                     ┌──────────┐   未完成且用户允许 ──▶ 存入 Goal 队列，等待续跑
                     │  Settle  │
                     └──────────┘
```

### 1.1 状态机（持久化形态）

```swift
public enum TurnState: String, Codable, Sendable {
    case intake, triage, contextAssembly, awaitingPlanApproval
    case reasoning, awaitingToolApproval, executing, observing
    case awaitingUserInput          // 主动提问（clarify）
    case pausedBudget, pausedOffline, pausedLowPower, pausedByUser
    case finalizing, completed, failed, aborted
}
```

**只有 6 个"稳定可挂起"状态**（`awaitingPlanApproval` / `awaitingToolApproval` / `awaitingUserInput` / 三个 `paused*`）。进程被杀后恢复时，只需从最后一个稳定状态 + 最后一个检查点重放，其余中间态一律**幂等重做**。

### 1.2 幂等性规则（后台续跑的命根子）

| 操作类型 | 幂等策略 |
|---|---|
| 读文件 / 搜索 / 统计 | 天然幂等，直接重做 |
| 调用模型（无工具调用） | 重做，但先检查事件日志里是否已有同 `requestHash` 的响应 → 命中则复用（省钱且避免重复计费） |
| 本地写文件 | 通过 VFS 检查点比对：若目标已是期望内容则跳过；否则重放写入 |
| 沙箱执行 | 重做，但**先查 `execFingerprint(cmd+inputs)`**：若上次已成功且输入未变，复用结果 |
| 网络副作用（POST/推送/下单） | **绝不自动重做**。默认标记为"不可重放"，中断后必须询问用户 |
| Git 推送 / PR 创建 | 同上，且要求显式确认（见 §12 危险动作清单） |

**设计约束：Agent 的绝大多数工具必须是幂等的。** 任何非幂等工具都必须在 `ToolSpec` 里声明 `isIdempotent: false`，运行时据此调整恢复策略。这是"手机 Agent 可被随时打断"能成立的前提。

---

## 2. Triage：先判断该不该开动

很多桌面 Agent 的问题是"什么请求都启动一整套循环"。手机上代价更大（电、钱、等待），所以 Rune 在进入循环前做一次**廉价判定**（优先用端侧小模型，零成本）：

| 判定 | 动作 |
|---|---|
| 纯问答 / 闲聊 / 翻译 / 解释 | `Answer`：单轮直出，不走工具循环，不建 Turn 记录（只在会话里） |
| 需要读文件才能答 | 进入完整循环，但 Plan 可跳过 |
| 多步骤 / 改动型 / 外部副作用 | 完整循环 + **强制 Plan**（除非 Trust Dial ≥ 协作档） |
| 信息不足 | `Clarify`：只问一个最关键的问题（不问一堆） |
| 与已有 Goal 相关 | 挂到该 Goal 下作为一次推进轮次，而不是开新 Turn |
| 危险意图（删库、外发数据、花钱） | 直接进入最严格审批路径 + 明确风险提示 |

Triage 的端侧实现见 [13](13-端侧模型与性能预算.md) §5。

---

## 3. 规划：Plan 是一等公民

### 3.1 计划的数据形态

计划不是一段散文，是**结构化数据**（可勾选、可比较、可回滚）：

```swift
public struct Plan: Sendable, Codable {
    public var id: PlanID
    public var revision: Int
    public var goalSummary: String          // 一句话目标
    public var assumptions: [String]        // 我假设了什么（用户可纠正）
    public var steps: [PlanStep]
    public var risks: [RiskNote]            // 危险动作、不可逆操作、成本预估
    public var estimatedCost: CostEstimate  // token/金额/耗时区间
}

public struct PlanStep: Sendable, Codable, Identifiable {
    public let id: StepID
    public var title: String
    public var kind: StepKind               // .read .analyze .write .execute .network .verify .deliver
    public var toolHints: [String]          // 预计用到哪些工具（用于提前申请权限！）
    public var status: StepStatus           // .pending .running .done .skipped .failed .amended
    public var checkpointID: CheckpointID?
}
```

**两个杀手级细节：**

1. **`toolHints` 用于"提前批量申请权限"**。手机上一次弹一个审批是灾难。计划里一次性列出"接下来要用到：写 `/workspace/src/**`、执行 python、访问 api.github.com"，用户一次批准整包。这是移动端体验能赢桌面的地方。
2. **`estimatedCost` 在批准前就展示**。"这一步大约花 $0.03、2 分钟"——桌面 Agent 几乎都不给，用户因此不敢放手。

### 3.2 计划修正（Plan Revision）

执行中偏离计划是常态。运行时不做"计划一旦批准就不能变"，而是：

- 检测偏离（步骤失败 / 发现新信息 / 工具不可用）→ 生成 `PlanRevision` 事件
- **重大偏离**（改变目标、增加危险的网络副作用、成本超预估 150%）→ 暂停并请求用户确认
- **轻微偏离**（换一个等价的读操作、跳过可选验证）→ 自动继续，但在时间轴上留痕

---

## 4. 工具协议

### 4.1 工具契约

```swift
public struct ToolSpec: Sendable, Codable {
    public let name: String                 // snake_case，跨模型友好
    public let description: String          // 给模型看的：做什么 + 何时用 + 何时不用
    public let inputSchema: JSONSchema      // 严格 schema，运行时校验
    public let concurrency: Concurrency     // .parallelSafe / .serialPerPath / .exclusive
    public let isIdempotent: Bool
    public let riskLevel: RiskLevel         // .safe .modifying .dangerous .irreversible
    public let needsApproval: ApprovalPolicy // .never .perProject .always .biometric
    public let outputShape: OutputShape     // .inline(maxBytes) / .artifact(threshold)
}
```

### 4.2 描述文本的写法规范（直接影响成功率）

每个工具的 `description` 必须回答四个问题，且控制在 120 词内：

```
[name] 做什么（一句话，动词开头）
何时用：<典型场景>；何时不要用：<最常见误用>
关键约束：<路径限制/大小限制/超时/计费>
示例：<一个最小可用的参数示例>
```

> 实测经验：工具描述里"何时不要用"这一条，比任何系统提示词优化都更能降低误调用率。

### 4.3 调度：并行、依赖与预算

```
Dispatch 阶段把本轮所有 tool_call 分桶：
  桶 A（parallelSafe 且无路径冲突）→ 并行执行，并发上限 = min(6, 性能核数×2)
  桶 B（写同一路径 / exclusive）→ 串行，按模型给出的顺序
  桶 C（需要审批）→ 批量提交给 ApprovalBroker，一次展示所有待批项
  桶 D（预算不足）→ 延后到下一轮，或暂停 Turn 存检查点
```

**冲突检测**：桶内任意两个写操作若路径前缀重叠，强制降级为串行。这个检查在 `TurnScheduler` 里做，不依赖模型自觉。

**单轮预算上限**（默认值，用户可调）：

| 项 | 默认 | 说明 |
|---|---|---|
| 单轮最大工具调用数 | 24 | 超过则强制 Finalize 并向用户汇报进展 |
| 单轮最大模型往返 | 16 | 防止无限自我修正 |
| 单轮最长时间（前台） | 10 分钟 | 之后转后台/暂停 |
| 单轮最大成本 | $0.30 | 熔断并暂停 |
| 单工具最长执行 | 120s | 前台；后台作业可更长 |
| 单工具最大输出 | 2MB 进制品，8KB 进上下文 | 超出自动摘要 |

### 4.4 修正性重试（Correction Loop）

模型出错的三类高频情况，运行时**主动救**而不是直接失败：

| 情况 | 运行时动作 |
|---|---|
| 参数不合 schema | 回灌精确校验错误（"参数 `path` 缺失；期望类型 string"），让模型重发。最多 2 次 |
| 工具名幻觉 | 用编辑距离 + 语义匹配给出"你是不是想用 `read_file`？"并附可用工具子集 |
| 工具执行失败但可诊断 | 回灌 `stderr` 尾部 + 退出码 + 环境信息，附提示"如为路径问题，可用 list_dir 确认" |

> 这三条把"长任务成功率"从"看模型运气"变成"看工程质量"。

#### 4.4.1 「重试」的准确定义（**这一条定死，不能含糊**）

**运行时永远不会**把同一个工具调用"再发一次"。三家协议都要求每个 `tool_result`
必须对应一个**真实存在**的 `tool_use` id；运行时凭空造一个"模型发出的调用"，
会让该会话后续**所有**请求 400 —— 而且本地测试完全看不出来。

所以"重试"的含义只有一个：**回灌一条精确到能照着改的错误**，让模型在下一轮自己重发。
运行时的全部价值，在于那条错误写得够不够准。由此推出两条硬要求：

1. **`suggestion` 与 `candidates` 必须进 `ToolResult.summary`**。
   网关只发 `summary`（见 docs/06），所以"结构化错误"里的建议若没被拼进 `summary`，
   就等于从没存在过 —— 修正性重试会退化成"让模型再猜一次"。
2. **运行时写的话只能以文本形式出现**，且来源必须标记为 `.runtimeGuidance`
   （``isInstruction == false``、``canDriveDangerousAction == false``）。
   它能让模型把参数改对，但**永远不能**让一次推送/外发/删除免除审批 ——
   否则运行时就能伪造用户授权，那是提权。

#### 4.4.2 记账与止损

计数按**根因**（`错误种类:工具名`）分桶，而不是按具体参数：
模型路径写错时会**每次试一个不同的错路径**，按路径分桶则每个桶只出现一次，熔断永远不会触发。

| 判定 | 触发条件 | 动作 |
|---|---|---|
| 允许重试 | 同根因失败 ≤ 2 次 | 回灌错误；**第 2 次额外注明"这是最后一次机会"**（模型对明确后果的反应显著更好） |
| 逐字重复 | 参数一字未改又发一遍（按规范化 JSON 比对） | **立刻**上报，不必等计数用完 |
| 机会用尽 | 同根因失败第 3 次 | 上报 |
| 在乱试 | 连续 5 次失败且**每次根因都不同** | 上报（通常是"整个目录找错了"这类判断错误） |
| 不计账 | 越权 / 沙箱 / 网络 / 输出过大 | 交上层处理；**但逐字重复仍然上报**（明知会被拒还原样重发，说明它没在听） |

任何一次成功都清零连续计数，并把该根因的记账**删除** ——
否则一小时内十次互不相关的失败会攒成一次假熔断。

上报不是弹报错框，而是**三选一加一条出口**：定向提示 / 换个完全不同的做法 / 用户自己补参数 /
就在这里停下。用户选了"继续"就给该根因**重新开一份额度**（沿用旧计数会立刻再熔断，等于用户的选择无效）。

#### 4.4.3 协议不变式（**比修正性重试更重要的一条**）

> **在把对话发给模型之前，历史里每一个工具调用都必须有且仅有一个对应结果。**

这不是"顺手做的清理"，而是**通讯层的地基**：漏掉一个，下一次请求就 400，
而报错信息（"roles must alternate" / "tool_call_id not found"）与真正的原因隔着十万八千里。

在手机上这不是边缘情况，是**主路径**：切后台、内存回收、用户插话、预算熔断、审批等待、
修正熔断 —— 每一条早返回路径都可能留下孤儿调用。

因此兜底**只在唯一一处做**：`reasoning` 步骤的入口（那是唯一会调用模型的地方）。
不变式由构造保证，而不是靠十几个分支各自记得处理。
两个实现要点：

* 判定依据必须是**对话历史**，不是 `pendingIntents` / `currentWave` 这些单轮内的临时队列字段
  —— "预算熔断后用户点继续"这条路径进来的新 Turn 只带着历史，队列是空的。
* 补记的结果必须**插在那条助手消息的正后面**，不能统一追加到历史末尾：
  三家协议要求的配对是"相邻"的。

---

## 5. 目标（Goals）跨轮推进

**这是 Rune 最重要的一条差异化能力**：手机上的任务天然会被打断（锁屏、来电话、进地铁、上班）。Goal 让任务在"被打断的世界"里仍能完成。

```swift
public struct Goal: Sendable, Codable {
    public var id: GoalID
    public var objective: String            // 不可变目标（改目标=新建 Goal）
    public var status: GoalStatus           // .active .paused .completed .blocked
    public var roundBudget: Int             // 自动续跑轮次上限
    public var roundsUsed: Int
    public var blockedReason: String?       // 只有同一条件连续 ≥3 轮才允许写
    public var lastCheckpoint: CheckpointID
    public var deliverableSpec: DeliverableSpec?  // 什么算"完成"
}
```

**续跑调度（移动端特化）：**

| 触发时机 | 动作 |
|---|---|
| 用户再次打开 App | 若有 active Goal 且未完成 → 自动续跑一轮（除非用户关掉自动续跑） |
| 静默推送到达 | 尝试申请一段后台时间，能跑多久跑多久，跑完存检查点 |
| BGProcessingTask 被系统调度（充电 + 空闲） | 跑"重活"轮次（大仓库索引、批量测试） |
| 到达用户设定的"工作时间窗" | 本地通知提醒 + 可选自动续跑 |
| 一次 Turn 结束但 Goal 未完成 | 立即评估"能否马上再跑一轮"（预算/电量/网络允许就继续，否则挂起） |

**阻塞判定纪律（继承并强化 DSH 的规则）：**
- 只有**同一具体阻塞条件连续 ≥3 轮**才允许标记 `blocked`。
- 难度大、不确定、还有活可干 —— **都不算阻塞**。
- 标记 blocked 必须给出：具体条件、已尝试的 3 种办法、需要用户做的**一件具体的事**。

**移动端专属规则：**
- Goal 数上限 5（超过强制用户整理），避免"手机里挂着一堆半成品"。
- 每个 Goal 有**电量预算**（如"每天最多消耗 15% 电量"）与**成本预算**。
- Goal 完成时生成一张**成果卡**（产物 + 花费 + 耗时 + 一句话总结），并支持"归档到知识页"。

---

## 6. 子代理（Subagents）与并发

### 6.1 为什么手机上还需要子代理

因为**上下文污染**比内存更致命：一个 Turn 里塞进 30 个文件的全文，模型会开始胡说。子代理的本质是"用独立上下文干脏活，只回传结论"。

### 6.2 移动端实现约束

| 约束 | 实现 |
|---|---|
| 不能是独立进程 | 进程内 Actor，共享内存预算池 |
| 不能被系统单独回收 | 子代理的**状态存在事件日志里**，父运行时被杀后可从子代理最后一个检查点复活 |
| 内存有限 | 子代理默认"轻上下文"：不继承父会话全文，只拿任务描述 + 必要摘要 |
| 并发有限 | 默认并发上限 3（Pro 机型 4）；每个子代理有独立 token 预算 |
| 可观测 | 每个子代理在时间轴上是一条可展开的泳道 |

```swift
public struct SubagentSpec: Sendable, Codable {
    public var role: String                    // explore / implement / verify / review / research
    public var prompt: String
    public var toolAllowlist: [String]?
    public var modelOverride: ModelSelector?   // 例如检索用便宜模型，验证用强模型
    public var contextPolicy: ContextPolicy    // .minimal / .inheritSummary / .inheritFull
    public var budget: SubagentBudget          // tokens, wallClock, toolCalls
    public var outputSchema: JSONSchema?       // 结构化回传，避免散文
}
```

### 6.3 四种子代理角色（内置）

| 角色 | 用途 | 典型模型档位 | 工具白名单 |
|---|---|---|---|
| **Explore** | 只读探查：找文件、找符号、找历史 | 便宜快速 | read/glob/grep/list/git-log |
| **Implement** | 在一个隔离子工作区里写代码 | 强编码模型 | read/write/edit/run/python/git(本地) |
| **Verify** | 独立验证：跑测试、复现 bug、反驳结论 | 强推理 | read/run/python/grep（**禁止写**） |
| **Review** | 以"审查者"视角找问题（对抗性） | 强推理 | read/glob/grep/git-diff |

> **Verify 与 Implement 必须用不同上下文、且 Verify 禁止写**——这是"Agent 自己说自己做对了"这个经典失效模式的唯一解法。

---

## 7. 技能（Skills）与渐进式披露

### 7.1 技能包形态

```
Runes/
└─ flaky-test-triage/
   ├─ RUNE.md            # frontmatter(name, description, when_to_use) + 指令正文
   ├─ policy.toml        # 本技能申请的能力（写路径、出口域名）
   ├─ examples/          # 少样本示例（按需加载）
   ├─ fixtures/          # 测试夹具（例如一个复现用的最小仓库）
   └─ checks/            # 验证清单（"修完必须能跑通 X"）
```

### 7.2 三层加载（省上下文的关键）

| 层级 | 何时加载 | 成本 |
|---|---|---|
| L0 目录 | 每次装配上下文 | 每条 ~15 token（名称 + 一句话 + 何时用） |
| L1 指令正文 | 模型调用 `use_skill(name)` | 通常 300-2000 token |
| L2 示例与夹具 | 模型进一步请求，或运行时判定需要 | 按需 |

**规则：L0 目录条目不得超过 40 条**，超出则按"最近使用 + 语义相关"截断，并在目录里提示"还有 N 个技能可用（用 search_skills 查询）"。

### 7.3 内置技能库（首发 12 个）

`ci-triage` / `pr-review` / `flaky-test-triage` / `sql-migration` / `api-client-gen` / `data-cleaning` / `chart-report` / `i18n-sync` / `dep-upgrade` / `regex-craft` / `incident-first-responder` / `screenshot-to-code`。

**为什么要内置**：手机用户不会写技能。开箱可用的一批高质量技能，是"体验超越桌面 Agent"的最短路径（桌面 Agent 通常要求用户自己配）。

---

## 8. 工作流（Workflow）引擎

### 8.1 定位

Skill 解决"怎么做一件事"，Workflow 解决"一次性跑一大片互相独立的事"。典型场景：**发版前检查**（17 项并行）、**全仓库文档补全**、**批量重构**。

### 8.2 脚本形态（JavaScriptCore 执行）

```javascript
// 用户在 Rune 里保存的一个 Workflow（声明式 + 脚本，无网络/无文件权限，只能调 agent()）
phase("静态检查")
const checks = args.targets            // 来自 UI 的输入
const staticResults = await parallel(checks.map(t => async () => {
  const r = await agent(`对 ${t} 做静态检查：类型错误、lint、死代码。只报事实。`, {
    label: `静态检查 ${t}`,
    schema: { type: "object", properties: {
      target:  { type: "string" },
      issues:  { type: "array", items: { type: "object", properties: {
        file: { type: "string" }, line: { type: "integer" },
        severity: { type: "string", enum: ["error","warn","info"] },
        message: { type: "string" }
      }, required: ["file","severity","message"], additionalProperties: false } },
      clean:   { type: "boolean" }
    }, required: ["target","issues","clean"], additionalProperties: false }
  })
  return r
}))

phase("修复")
const fixed = await pipeline(
  staticResults.filter(Boolean),
  (prev, item) => prev.issues.length === 0 ? null : agent(`修复这些问题：${JSON.stringify(prev.issues)}`, { phase: "修复" }),
  (prev, item) => prev == null ? null : agent(`为上面的修复补测试并运行，报告结果。`, { phase: "验证" })
)

phase("汇总")
return { checked: checks.length, clean: staticResults.filter(r => r?.clean).length, fixed: fixed.filter(Boolean).length }
```

### 8.3 移动端约束

| 约束 | 规则 |
|---|---|
| 内存 | 并发 agent 上限 3；每个子任务的上下文强制 `.minimal` |
| 成本 | 运行前必须给出上界估算（`agents × 平均token × 单价`），用户批准后开跑 |
| 生命周期 | Workflow 是**可恢复的**：每个 `agent()` 完成即写检查点；被系统杀掉后从未完成的那个 agent 继续 |
| 脚本能力 | JSC 宿主只暴露 `phase/log/args/agent/pipeline/parallel`，**无 fetch、无文件、无定时器**（防注入与逃逸） |
| 可观测 | UI 上是分阶段的进度看板：`阶段 2/3 · 7/17 完成 · 已花 $0.12` |

> Workflow 是"手机算力弱"这件事的**反向利用**：正因为并发有限，用户才会认真设计一次跑对，而 Workflow 让这一次跑得足够值。

---

## 9. Hooks（钩子）

### 9.1 声明式钩子（不执行脚本）

```toml
# rune.policy.toml
[[hook]]
on     = "PreToolUse"
match  = { tool = "write_file", path = "**/*.generated.swift" }
action = { type = "deny", reason = "生成文件请改生成器，不要手改" }

[[hook]]
on     = "PreToolUse"
match  = { tool = "shell", command_matches = "rm -rf*" }
action = { type = "confirm", level = "biometric", message = "递归删除，请确认" }

[[hook]]
on     = "PostToolUse"
match  = { tool = "write_file", path = "**/*.swift" }
action = { type = "run_workflow", name = "swift-format-check" }

[[hook]]
on     = "TurnFinalize"
action = { type = "notify", title = "任务完成", body_from = "turn.summary" }

[[hook]]
on     = "PreModelCall"
action = { type = "redact", rules = ["phone", "internal_domain", "env_values"] }
```

### 9.2 可用的生命周期点

`SessionStart` / `TurnStart` / `PreModelCall` / `PostModelCall` / `PreToolUse` / `PostToolUse` / `PlanApproved` / `CheckpointCreated` / `TurnFinalize` / `GoalRoundStart` / `GoalComplete` / `BudgetExceeded` / `AppForeground` / `AppBackground` / `OfflineDetected`。

### 9.3 动作类型（全部是运行时可解释的原子动作）

`deny` / `confirm` / `allow` / `notify` / `log` / `redact` / `run_workflow` / `open_url` / `webhook`（受出口白名单约束）/ `create_goal` / `save_memory` / `snapshot`。

**为什么不做"执行用户脚本"**：一是合规（A4），二是用户无法调试，三是移动端没有适合写钩子脚本的环境。声明式动作覆盖了 90% 的真实需求。

---

## 10. 检查点与时间轴（Time Machine）

### 10.1 检查点的构成

```swift
public struct Checkpoint: Sendable, Codable {
    public let id: CheckpointID
    public let turnID: TurnID
    public let stepID: StepID?
    public let eventSeq: Int64          // 事件日志锚点
    public let vfsSnapshot: SnapshotID? // 文件系统快照（写时复制）
    public let label: String            // 人类可读："应用了 3 处修改"
    public let createdAt: Date
    public let cost: CostDelta
    public let isRestorable: Bool       // 网络副作用之后可能不可完全回滚
}
```

### 10.2 创建时机

| 时机 | 说明 |
|---|---|
| 每个成功修改文件的工具调用之后 | 粒度最细，代价由写时复制保证极低 |
| 每个 Turn 的 Finalize | 会话级锚点 |
| 计划批准的瞬间 | "开始动手"前的干净状态 |
| 用户手动 | 摇一摇 / 按钮："在这里打个标记" |
| 危险操作之前（强制） | `git push` / 删除 / 外发数据前必打 |

### 10.3 用户可见的交互

| 手势/入口 | 行为 |
|---|---|
| 时间轴横向拖动 | 预览任意历史时刻的**文件差异摘要** |
| 点检查点 → `回到这里` | 回滚文件 + 会话上下文到该点（后续事件标记为"已废弃分支"，不删除） |
| 长按 → `从这里分叉` | 保留历史，开一个新分支继续（用于"A 方案不行，试 B 方案"） |
| 双指捏合 | 时间轴缩放：Turn 级 ⇄ 步骤级 ⇄ 工具调用级 |
| 摇一摇 | 撤销上一个检查点（可配置为"撤销上一步文件改动"） |

**回滚的诚实性要求**：如果某检查点之后发生了**不可回滚的副作用**（推送、外发、支付），必须显式提示：

> ⚠️ 此处之后已推送到远程 `origin/main`（提交 `a1b2c3`）。本地可以回到这里，但远程改动需要你手动处理。`[查看如何撤销远程提交]`

---

## 11. MCP 双向

### 11.1 Rune 作为 MCP 客户端

- 传输：HTTP（远程）/ stdio（仅 `Full` 构建，且仅限用户授权目录内的可执行脚本——受 A4 限制，App Store 构建不提供 stdio）
- 连接管理：每个 server 独立 Actor + 健康探测 + 工具命名空间隔离（`mcp__<server>__<tool>`）
- **信任分级**：MCP server 提供的是**不可信能力**。其工具默认 `needsApproval: .always`，直到用户在设置里把它调到"信任"。
- **工具爆炸防护**：一个 server 暴露 200 个工具会毁掉上下文。Rune 强制：单 server 只暴露 Top-N（默认 20），其余通过 `search_mcp_tools` 按需检索。

### 11.2 Rune 作为 MCP 服务端（反向能力，杀手级）

手机独有的能力，桌面永远没有：

| 暴露的工具 | 用途 |
|---|---|
| `phone.camera.capture` | 桌面 Agent 说"拍一下白板"，手机拍照回传 |
| `phone.photos.search` | 按时间/地点/内容检索本机相册 |
| `phone.location.current` | 当前位置（用于"附近的…"类任务） |
| `phone.calendar.*` | 读/写日程（"帮我把这个任务排进周四下午"） |
| `phone.notify` | 推送通知到用户手机（桌面 Agent 的"我干完了"提醒） |
| `phone.clipboard.*` | 剪贴板读写（跨设备粘手） |
| `phone.speech.transcribe` | 端侧语音转写 |
| `rune.run` | **在手机上启动一个 Turn**（"把这个任务丢给我手机上的 Rune 跑"） |

**配对方式**：局域网 mDNS 发现 + 6 位配对码，或通过用户自己的中继（不经过我们的服务器）。**默认关闭，需显式开启**。

---

## 12. 输出契约与诚实性约束

### 12.1 每轮必有产出

`Finalize` 阶段必须产出以下之一，缺一不可：

1. **做了什么**（事实陈述，附证据：文件路径 + 行号 / 命令 + 输出 / 提交 hash）
2. **产出了什么**（产物卡片：diff / 文件 / 报表 / 图 / PR）
3. **花了多少**（token、缓存命中率、金额、耗时、电量）
4. **没做什么 / 不确定什么**（明确的遗留项清单）
5. **建议的下一步**（最多 3 条，可一键执行）

### 12.2 硬性禁止（写入系统提示 + 运行时检查）

| 禁止 | 运行时检查手段 |
|---|---|
| 声称做了实际没做的事 | 交叉核对：声称"已修改 X"必须存在对应的 `write_file` 成功事件 |
| 声称测试通过但没运行 | 声称"测试通过"必须存在 `run_*` 成功事件且退出码为 0 |
| 隐藏失败 | `ToolResult.status != .ok` 时必须在最终输出里出现（若被隐藏，UI 层独立展示失败计数） |
| 把"未验证"说成"已验证" | 产物卡片区分"已验证 / 未验证 / 待人工确认"三态标签 |
| 静默降级模型 | 每次降级必须可见（"因限流，本轮从 Opus 降级到 Sonnet"） |

> 这套约束不是"道德要求"，而是**产品可信度的技术保障**：手机用户看不到终端，只能靠 Agent 自述，因此自述必须可被运行时证伪。

### 12.3 危险动作清单（强制人工确认，不可被策略静默放行）

```
git push / git push --force          → 展示将推送的提交列表 + 影响分支
删除文件（超过 1 个或非临时目录）      → 展示文件清单 + 总大小
修改 .env / 凭据 / CI 配置            → 展示 diff，要求生物识别
对外发送数据（POST 到非白名单域名）    → 展示 payload 摘要 + 目标域名
任何付费/下单/提交表单                → 一律生物识别
安装/信任 MCP server                 → 展示其全部工具与所需权限
修改 trust dial / policy 文件         → 需要生物识别（防止 Agent 提权自己）
```

最后一条尤其重要：**Agent 不能自己给自己提权。** `policy.toml` 与信任刻度盘属于"人类专属区域"，工具层不可写。

---

## 13. 系统提示词架构

系统提示不是一整块，而是**按需拼装的分层结构**（利于缓存命中，见 [06](06-模型网关与中转站.md) §7）：

```
[层 1 · 不变前缀｜可缓存]
  身份与契约：Rune 是什么、输出契约、诚实性约束、危险动作清单
  工具使用总则：先读后写、小步验证、并行只读、失败自我修正

[层 2 · 项目稳定层｜可缓存]
  项目指令（RUNE.md / AGENTS.md / CLAUDE.md 合并结果）
  工作区结构摘要（目录树 top-N + 语言分布 + 构建/测试命令探测结果）
  可用技能目录（L0）
  当前信任刻度盘档位 + 已授予的能力范围

[层 3 · 会话易变层]
  当前 Turn 目标 + 计划 + Todo 状态
  最近的工具结果摘要 + 未解决错误
  记忆检索命中（Top-K 相关片段，带来源与信任标记）

[层 4 · 输入层]
  用户本次输入（含多模态引用）
```

**层 1+2 在同一个会话内保持字节级不变**（这是 Prompt Caching 生效的前提，能省 60-90% 输入成本）。任何"时间戳""随机 id""当前 todo"都必须放在层 3 之后。

---

## 14. 预算、熔断与降级

| 维度 | 默认策略 | 用户可调 |
|---|---|---|
| 单 Turn 成本上限 | $0.30 | ✅ |
| 单日成本上限 | $3.00 | ✅ |
| 单月成本上限 | $30.00 | ✅ |
| 单日电量预算（Agent 部分） | 20% | ✅ |
| 低电量模式 | Agent 自动只跑"必要步骤"，暂停后台续跑 | ✅ |
| 网络降级 | 无网 → 端侧模型；弱网 → 只走非流式短请求 | 自动 |
| 渠道降级 | 主渠道失败 2 次 → 备用渠道（模型能力可能变化，必须提示） | 自动 + 可见 |
| 过热 | 系统热状态 serious/critical → 暂停重活，只保留读操作 | 自动 |
| 长任务熄火保护 | 连续 3 轮无实质进展（无新文件、无新信息）→ 暂停并问用户 | 自动 |

**熔断后的体验**（这是很多人做错的地方）：不要弹一个报错框。而是一张卡片：

> ⏸ **已暂停**：本次任务预计还要花 $0.42，超过了你设的 $0.30 单次上限。
> 已完成：定位根因、生成修复、跑通 12 个测试。
> `[提高上限到 $0.5 继续]` `[只看当前成果]` `[换成便宜模型继续（预计 $0.08）]`

---

## 15. 运行时可观测（对内）

为工程调试保留的通道（`Debug` 构建或开发者模式）：

- **完整事件流导出**（JSONL，可回放到另一台设备）
- **每次模型调用的请求/响应存档**（可选开启，密钥自动脱敏）
- **上下文占用热力图**（哪一层占了多少钱）
- **沙箱遥测**（VM 指令数、内存峰值、系统调用次数）
- **黄金会话回放**：把一个真实会话变成回归测试（见 [14](14-工程路线图与测试策略.md)）

---

**上一篇**：[03 总体架构](03-总体架构.md) · **下一篇**：[05 工具系统与执行沙箱](05-工具系统与执行沙箱.md)
