# 附录 A · 渠道、模型与协议事实表

> **用途**：这是 [06 模型网关](06-模型网关与中转站.md) 与 [附录 B 技术选型核实表](附录B-技术选型核实表.md) 的事实底座。写适配器时直接照这张表实现，不要凭记忆。
> **时效**：核对于 **2026-09**。模型阵容与价格变动频繁，**实现时必须把价格表做成可远程/可手动更新的配置，不写死在代码里**。
> **标记**：`[不确定]` = 未从官方文档确认。

---

## 1. 协议族与端点

| 协议族 | 端点 | 鉴权头 | 流式形态 |
|---|---|---|---|
| OpenAI **Responses**（官方推荐给新项目） | `POST {base}/v1/responses` | `Authorization: Bearer` + 可选 `OpenAI-Organization` / `OpenAI-Project` / `X-Client-Request-Id` | 语义化事件 SSE：`response.created` / `response.output_item.added` / `response.output_text.delta` / `response.function_call_arguments.delta` / `response.completed|failed|incomplete` / `error` |
| OpenAI Chat Completions（仍受支持） | `POST {base}/v1/chat/completions` | 同上 | `choices[0].delta` 增量 |
| Anthropic Messages | `POST {base}/v1/messages`（计数：`/v1/messages/count_tokens`） | `x-api-key` + `anthropic-version: 2023-06-01` + `anthropic-beta`（可选） | 命名事件：`message_start` / `content_block_start` / `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop` / `ping` / `error` |
| Gemini（经典 REST） | `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse` | `x-goog-api-key` 或 `?key=` | SSE（parts 流） |
| Gemini **Interactions**（新） | `POST {base}/v1beta/interactions`（`?alt=sse`） | 同上 | `step.start` / `step.delta`（`thought_summary`、`thought_signature`）/ `interaction.completed` |
| Ollama（局域网） | 原生 `POST http://host:11434/api/chat`（**NDJSON，不是 SSE**）；兼容 `/v1/chat/completions`、`/v1/responses`、`/v1/models`、`/v1/embeddings` | 默认无 | NDJSON 逐行 |
| LM Studio（局域网） | `http://host:1234/v1/…`（含 `/v1/messages` Anthropic 风格） | 可选 | SSE |

### 1.1 必须注意的三条协议级事实

1. **OpenAI 给推理型 Agent 的硬约束**：自 GPT-5.4 起，Chat Completions **不支持** `reasoning_effort` 非 `none` 时的工具调用。**做推理 Agent 必须走 `/v1/responses`。** 这直接决定 Rune 的 OpenAI 适配器以 Responses 为主路径。
2. **状态化上移**：Responses 默认 `store:true`，可用 `previous_response_id` 续接（注意：**不携带 `instructions`**，且历史 input token **仍会计费**）；Gemini Interactions 用 `previous_interaction_id`。客户端职责从"维护完整 transcript"变成"维护 id 与租约"。
3. **没有任何厂商提供官方的幂等键**：`X-Client-Request-Id` 明确只是追踪 id，不是去重令牌（[OpenAI 文档](https://platform.openai.com/docs/guides/streaming-responses)）。重试安全只能靠"复用状态化 id + 依赖缓存让重放变便宜 + 本地记账去重"。**[06 §8.3 的设计据此修正]**

---

## 2. 各厂商模型与关键参数（2026-09）

### 2.1 OpenAI

| 模型 | 上下文 | 输出上限 | 价格（输入/缓存读/缓存写/输出，每百万 token） |
|---|---|---|---|
| `gpt-6-astra` | 1,050,000 | 128k | $10 / $1 / $12.5 / $50 |
| `gpt-5.6-sol` | 1,050,000 | — | $4 / $0.40 / — / $20 |
| 编码向 | — | — | `gpt-5.3-codex`、`gpt-5.2-codex`、`gpt-5.6-cyber` |

- 推理档位：Astra `low/medium/high/xhigh/max`；5.6 Sol `none/low/medium/high/xhigh/max`
- `reasoning.summary: "auto"` 才会返回思维摘要 `reasoning.summary[].summary_text`（否则不返回）
- 无状态（ZDR）场景：reasoning items 含 `encrypted_content`，**必须原样回传**；`include:["reasoning.encrypted_content"]` 仅为旧版兼容
- 并行工具调用**默认开启**；`parallel_tool_calls:false` 可关闭；`tool_choice` 支持 `auto/required/none/{type,name}/allowed_tools`；`strict:true`（Responses 会自动规范化 schema 到 strict，失败时回退 `strict:false`；Chat Completions 默认非 strict）
- **输入超过 272K token 时按 2× 输入 / 1.5× 输出计费**
- 内置服务端工具：`web_search`、`file_search`、`image_generation`、`code_interpreter`、`hosted_shell`、`apply_patch`、`skills`、`computer_use`、`mcp`、`tool_search`

### 2.2 Anthropic

| 模型 | 上下文 | 输出 | 价格（入/出） | 备注 |
|---|---|---|---|---|
| `claude-fable-5-1` | 1M | 128k | $10 / $50 | 自适应思考常开；缓存读仅 **0.025×** |
| `claude-opus-5` | — | — | $5 / $25 | |
| `claude-sonnet-5` | — | — | $2 / $10 | |
| `claude-haiku-4-5-20251001` | 200K | — | — | 仅支持手动扩展思考 |

- 默认 effort 为 `high`；思考配置：`thinking:{type:"adaptive", display:"summarized"|"omitted"(默认)|"updates"(beta)}`
- **手动 `{type:"enabled", budget_tokens:N}` 在 4.6 起弃用，4.7+ 直接 400** → 必须用自适应模式
- `thinking` / `redacted_thinking` 块**必须原样回传**（含不透明 `signature`）；**改思考配置或 effort 会使缓存断点失效**
- 强制工具选择（`tool_choice` 指定具体 tool）**与手动扩展思考不兼容**，在 Fable 5.1 / Mythos 5.1 上会 400 → 用 `auto` + 严格 schema
- 4.7+ 的 tokenizer 比早期模型**多算约 30% token**
- 服务端工具：`tool_search`（regex/bm25）、`code_execution`、`web_search`/`web_fetch`（与 code execution 同时用时免费）、MCP connector（`mcp_servers:[{type:"url",…}]`）
- 关键 beta 头：`context-management-2025-06-27`（含 `clear_tool_uses_20250919`、`clear_thinking_20251015`、`compact_20260112`）、`mcp-client-2025-11-20`、`files-api-2025-04-14`、`agent-memory-2026-07-22`（与 `managed-agents-2026-04-01` **互斥，同时发会 400**）

### 2.3 Gemini

- 当前稳定：`gemini-3.8-flash`；另有 `3.7-flash` / `3.6-flash` / `3.5-flash` / `3.5-flash-lite` / `gemini-3.1-pro-preview` / `2.5-pro|flash`
- 思考控制：`thinking_level: low|medium|high`；思考 token 按全额计费
- `thought` parts 携带**不透明 `thoughtSignature`，必须原样回传**，否则报 "Request has at least one thought signature missing"
- 缓存：2.5+ **默认隐式缓存**（自动省钱，读 `usage.total_cached_tokens`）；显式缓存 `POST /v1beta/cachedContents`（**Interactions API 不支持显式缓存**）

### 2.4 DeepSeek

- Base URL：OpenAI 格式 `https://api.deepseek.com`；**Anthropic 格式 `https://api.deepseek.com/anthropic`**；beta `/beta`
- 模型（2026-09 官方模型表）：`deepseek-flash`（V4.1-Flash）、`deepseek-v4-pro`（V4-Pro-0813）；**1M 上下文 / 384k 最大输出**；旧别名 `deepseek-v4-flash*` 仍接受
  - ⚠️ **`deepseek-chat` / `deepseek-reasoner` 已不在模型表中** `[不确定是否仍被路由]` → **Rune 的默认路由不能写死这两个名字，必须做模型发现 + 用户可改**
- 思考默认开启（effort `high`）：OpenAI 路径 `{"thinking":{"type":"enabled"|"disabled"}}` + `reasoning_effort low/high/max`；Anthropic 路径 `output_config.effort`；Responses 路径 `reasoning.effort none/low/high/max`。effort 映射：`minimal→low`、`medium→high`、`xhigh→high`、`ultra→max`
- **`reasoning_content` 回传规则（关键）**：请求里带 `tools` 时，**历史每一轮的 `reasoning_content` 都必须回传，否则 400**；不带 `tools` 时会被忽略
- 思考模式下 `temperature`/`presence_penalty`/`frequency_penalty` 被静默忽略；`top_p` 下限 0.95
- 缓存：**全自动、尽力而为、无任何控制**（按请求边界持久化 + 公共前缀检测 + 固定 token 间隔）；几小时到几天内清除；usage 字段 `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`
- 价格（每 1M，峰值/低谷）：flash 命中 $0.006/$0.003，未命中 $0.30/$0.15，输出 $1.20/$0.60；v4-pro 命中 $0.044/$0.022，未命中 $1.32/$0.66，输出 $3.96/$1.98。低谷 = 5 折，峰值时段为 UTC 周一至周五 01:00–04:00 与 06:00–10:00
- 并发上限：flash 2,500 / v4-pro 500（超出 429）；`user_id` 参数能带来 **KVCache 隔离**（正则 `[a-zA-Z0-9\-_]+`，≤512）
- 严格模式为 beta（`/beta` + 每 function `strict:true`）；Chat Completions **不能在对话中插入工具调用** → 用 `/messages` 或 `/responses`
- Responses 流式**没有 `data: [DONE]`**
- **Anthropic 兼容层降级清单**：`claude-opus*`→v4-pro、`claude-sonnet*/haiku*`→flash；**`cache_control` 被忽略**、`thinking.budget_tokens` 被忽略、`disable_parallel_tool_use` 被忽略、`redacted_thinking`/`mcp_servers`/`container` 被忽略；图片仅支持 base64/url/file
- FIM beta：`POST /beta/completions`（`prompt` + `suffix`，≤4K，仅非思考模式）

### 2.5 其他厂商端点与坑

| 厂商 | Base URL | 协议 | 坑 |
|---|---|---|---|
| Qwen / DashScope | `https://{WorkspaceId}.<region>.maas.aliyuncs.com/compatible-mode/v1`（美区 `https://dashscope-us.aliyuncs.com/compatible-mode/v1`；旧 `dashscope.aliyuncs.com` / `-intl`） | OpenAI 兼容 | key 按区域划分；workspace 域名是新推荐 |
| Moonshot Kimi | 国际 `https://api.moonshot.ai/v1`／国内 `https://api.moonshot.cn/v1` | OpenAI 兼容 | `GET /v1/models` 可用；`reasoning_content` + `reasoning_effort`；另有需经 `extra_body` 的专有 `thinking` 字段；assistant 消息上的 `"partial": true` 字段。⚠️ **其 Anthropic 兼容端点 `https://api.moonshot.cn/anthropic` 无法确认** `[不确定]` |
| Zhipu GLM | `https://api.z.ai/api/paas/v4/chat/completions` | OpenAI 兼容 | **路径不是 `/v1`**；另有 JWT `generate_token` 流程；国内镜像 `open.bigmodel.cn` `[不确定路径]` |
| MiniMax | 国际 `https://api.minimax.io/v1`（**已核实**）／国内 `https://api.minimax.cn/v1`；Anthropic 兼容 `https://api.minimax.io/anthropic`；原生 `POST /v1/text/chatcompletion_v2` | OpenAI 兼容 | ⚠️ **思考链有第三种形态**：默认思考开启（`thinking:{type:"adaptive"|"disabled"}`，但 M2.x 实际无法关闭）；传 `reasoning_split:true`（需经 `extra_body`）后，CoT 从内联 `<think>…</think>` 切换为独立的 `reasoning_content` + `reasoning_details` 字段，**跨轮必须完整保留** |
| 豆包 / Volcengine Ark | `https://ark.cn-beijing.volces.com/api/v3` | OpenAI 兼容 | **用 endpoint-id 当模型名**；站点纯 JS，路径仅由第三方配置佐证 `[不确定]` |
| 腾讯混元 | `https://api.hunyuan.cloud.tencent.com/v1` | OpenAI 兼容 | 旧的 TC3 签名接口 `hunyuan.tencentcloudapi.com` **不是** OpenAI 兼容；⚠️ **原生域名本身有歧义**（文档的域名行写 `hunyuan.ai.tencentcloudapi.com`，而同一页所有示例用 `Host: hunyuan.tencentcloudapi.com`）→ **必须允许用户覆盖 host**。原生签名是 TC3-HMAC-SHA256（`X-TC-Action: ChatCompletions`、`X-TC-Version: 2023-09-01`，SSE 增量在 `Choices[n].Delta`，默认 5 个并发会话）。**移动端网关只应支持 OpenAI 兼容的那个 host** |
| 百度 ERNIE | `https://qianfan.baidubce.com/v2/chat/completions` | OpenAI 兼容 | `Authorization: Bearer bce-v3/ALTAK-…` |
| xAI Grok | `https://api.x.ai/v1` | OpenAI 兼容 + `/v1/responses`（含 `/responses/compact`） | — |
| Mistral | `https://api.mistral.ai/v1` | OpenAI 兼容 | — |
| Groq | `https://api.groq.com/openai/v1` | OpenAI 兼容 + `/responses` | **前缀是 `/openai/v1`** |
| Together | `https://api.together.ai/v1` | OpenAI 兼容 | 另有 `api-inference.together.ai/v2` `[不确定]` |
| Fireworks | `https://api.fireworks.ai/inference/v1` | OpenAI 兼容 | 非 `/v1` 前缀 |
| Cerebras | `https://api.cerebras.ai/v1` `[不确定]` | OpenAI 兼容 | — |
| vLLM（自建） | 自定 | OpenAI 兼容 + Anthropic Messages + gRPC | `--api-key` 可选；`/tokenize` 可精确计数 `[不确定]` |

---

### 2.6 三个必须数据驱动的映射（不要硬编码）

**① 思考链字段命名 —— 单一最大的归一化风险**

| 字段形态 | 谁在用 |
|---|---|
| `reasoning_content` | Kimi、Z.ai、百度、xAI、Fireworks、阿里、DeepSeek、以及 MiniMax（开启 split 后） |
| `reasoning` | Groq（配 `include_reasoning:true`，与 `reasoning_format` **互斥**）；Together（**视模型而定**，可能是 `reasoning` 也可能是 `reasoning_content`） |
| `reasoning_details` | MiniMax |
| 内联 `<think>…</think>` | 未开启 split 的 MiniMax、部分 Fireworks 模型 |
| Anthropic blocks + `signature` | Anthropic；DeepSeek 的 Anthropic 兼容层 |
| Gemini `thought` parts + `thoughtSignature` | Gemini / Interactions API |

**规则**：内部统一归一到一种通道，但**回传时必须还原成该厂商的原始字段**（[§4.2](#42-思考链回传矩阵写错就报错)）。

**② 鉴权形态（决定适配器结构）**

| 形态 | 覆盖 |
|---|---|
| `Authorization: Bearer` | **除下列之外的全部** |
| `x-api-key` + `anthropic-version` | Anthropic |
| `x-goog-api-key` 或 `?key=` | Gemini |
| `?access_token=` 查询参数 | 百度旧接口（30 天 OAuth，从 `aip.baidubce.com/oauth/2.0/token` 获取） |
| TC3-HMAC-SHA256 | 腾讯原生（不推荐支持） |
| **前缀限定的 key** | ⚠️ vLLM 的 `--api-key` / `VLLM_API_KEY` **只保护 `/v1`、`/v2`、`/inference` 前缀，`/invocations` 不受保护** |
| "required but ignored" | Ollama 本地 OpenAI 兼容端点（云端 `https://ollama.com/v1` 需要真 key） |

**③ 推理参数的厂商私有旋钮**

| 厂商 | 私有参数 |
|---|---|
| 百度千帆 v2 | `thinking_budget`、`thinking_strategy: short_think|chain_of_draft`、`reasoning_effort`（其中 `low`/`medium` 会**塌缩为 `high`**） |
| DeepSeek | `{"thinking":{"type":"enabled"|"disabled"}}` + `reasoning_effort low/high/max`；effort 映射 `minimal→low`、`medium→high`、`xhigh→high`、`ultra→max` |
| 豆包 Ark | `thinking`、`reasoning_effort`、`service_tier`、`stream_options`、`parallel_tool_calls`、`max_completion_tokens` |
| xAI | `max_tokens` 已弃用 → `max_completion_tokens`；缓存连续性由 **`x-grok-conv-id` 头**决定；加密 CoT 用 `include:["reasoning.encrypted_content"]`；**单请求工具数 ≤ 350**；`GET /v1/models` 返回价格 |
| 豆包 Ark（模型名） | ⚠️ `model` 既接受 Model ID 也接受 **Endpoint ID（`ep-…`）** → **网关不能拿 `/v1/models` 去校验用户填的模型名** |

### 2.7 缓存与精确计数的更多事实

| 项 | 事实 |
|---|---|
| **Groq** | **自动 prompt caching，不额外收费**，文档口径 **命中输入省 50%**，用量见 `usage.prompt_tokens_details.cached_tokens`；并且**是少数会发真实限流头**的厂商（`retry-after`、`x-ratelimit-limit|remaining-requests|tokens`），与 xAI 并列 |
| Mistral / Cerebras | 接受 `prompt_cache_key`；Cerebras 还接受 `Content-Type: application/vnd.msgpack` |
| Zhipu | 暴露 `/api/paas/v4/tokenizer`（**可精确计数**） |
| Volcengine Ark | 有独立的**上下文缓存**产品 |
| **精确计数端点**（比预期多） | vLLM：`/tokenize`、`/detokenize`、`/tokenizer_info`；Zhipu：`/api/paas/v4/tokenizer`；Ollama / LM Studio：本地可精确分词 |
| LM Studio | 0.4.0+ 支持可选 API token 鉴权；同时提供 Anthropic `/v1/messages` 与原生 `/api/v1/chat`（含 load/unload） |



这是"支持中转站"这件事的落地依据。四类主流实现的行为差异必须被适配器识别。

### 3.1 one-api

- 暴露"标准 OpenAI 格式"，客户端把 `base_url` 指向部署地址，用 `sk-` 形式的访问令牌
- **`Authorization: Bearer ONE_API_KEY-CHANNEL_ID` 可指定渠道**（调试与排障时有用）
- 令牌额度与账户余额分离；额度 = 分组倍率 × 模型倍率 × (prompt + completion × 倍率)
- 支持流式；**非流式响应带真实 usage**（流式常缺）
- 强制 Gemini 安全设置为 `BLOCK-NONE`，`GEMINI_VERSION=v1`
- `/v1/responses` 支持情况 `[不确定]`

### 3.2 new-api

- 同时提供 OpenAI **Responses**、Claude **Messages**、Google **Gemini** 端点，另有 Rerank
- 协议转换：OpenAI Compatible ⇄ Claude Messages、OpenAI → Gemini、Gemini → OpenAI（**仅文本，函数调用不支持**）；OpenAI Compatible ⇄ Responses "开发中"
- 对 OpenAI/Azure/DeepSeek/Claude/Qwen 提供**缓存计费统计**
- Gemini 的 reasoning effort 通过在模型名后追加 `-low|-medium|-high` 表达
- **`STREAM_SCANNER_MAX_BUFFER_MB` 默认 64** → 大 base64 载荷会打断流（图片任务要注意）

### 3.3 uni-api

- 端点覆盖最全：`/v1/chat/completions`、`/v1/responses`、`/v1/messages`、`/v1/embeddings`、`/v1/models`、`/v1/images/generations`、`/v1/audio/*`、`/v1/moderations`、`/v1/search`
- 别名映射写成 `{upstream_model}: {alias}`；模型名后缀 `-search` / `-think-N` 注入工具与思考
- key 权限用通配符（如 `gemini/*`）
- 调度策略：`fixed_priority | round_robin | weighted_round_robin | lottery | random`；`AUTO_RETRY`；`cooldown_period` 默认 300s
- 每模型 `model_price`（$/M token）；`timeout_policy` 可分别设 `connect|write|pool|first_byte|idle|total`
- **`keepalive_interval` 会发 SSE 注释行 `: keepalive`** → 客户端解析器必须忽略注释行（很多实现会在这里崩）
- 上游 `base_url` 必须以 `/v1/chat/completions` 或 `/v1/responses` 结尾
- `/v1/responses` 支持用 `X-Uni-API-Provider:` 头指定上游

### 3.4 OpenRouter

- 模型 slug 形如 `vendor/model`；`:nitro` = 吞吐排序 + 优先层资格，`:floor` = 价格排序 + flex 层
- 请求体 `provider:{order, allow_fallbacks, only, ignore, sort:price|throughput|latency, partition, quantizations, max_price, data_collection, zdr, require_parameters}`
- **usage 现在总是返回**（旧的 `usage:{include:true}` / `stream_options.include_usage` 已废弃为 no-op），含 `cost`、`cost_details.upstream_inference_cost`、`prompt_tokens_details.cached_tokens`、`cache_write_tokens`、`completion_tokens_details.reasoning_tokens`
- 限额查询：`GET /api/v1/key`（`limit_remaining`、`usage_daily`、`byok_usage*`）；`X-RateLimit-*` + `Retry-After`；**402 = 余额不足**
- 错误：403 是 guardrail/moderation（`error.metadata`）；**流中途的错误以 `chat.completion.chunk` 且顶层带 `error` 对象、`finish_reason:"error"` 的形式到达**（客户端必须识别这个形状，否则会当成正常文本）；Responses API 会把多种内部错误折叠成 `server_error` + 顶层 `error_type`
- BYOK：自带 key 会**先于** `order` 列表被尝试且不可重排；BYOK 花费默认不计入 guardrail/工作区预算（除 `include_byok_in_budgets:true`）

### 3.5 客户端必须处理的通用中转问题

| 问题 | 处理 |
|---|---|
| 自定义 base URL + 任意额外头 | 配置模型支持 `extraHeaders`（[06 §6.1](06-模型网关与中转站.md)） |
| `/v1/models` 缺失或返回 HTML | 回退到随包模型目录 + 允许自由文本录入模型名 |
| 别名 → 真实模型映射 | 本地维护映射表并向用户展示"你选的 X 实际是 Y" |
| token 计数与本地不一致 | 同时展示"渠道返回的 usage"与"本地估算"，以渠道为准计费 |
| 中转一般**不发** `x-ratelimit-*` 头 `[不确定]` | 不要依赖限流头；用退避 + 熔断 |
| SSE 注释行 / 心跳 | 解析器必须容忍 `: keepalive`、空行、非标准字段 |
| 流式缺 usage 或缺 `[DONE]` | 用"连接正常关闭"作为结束；usage 用本地 tokenizer 估算并标注 `isEstimated` |
| **Cloudflare JS 挑战** | `URLSession` **无法**通过 JS 挑战；需要 `WKWebView` 中间页获取 `cf_clearance` cookie 再交给 URLSession（实现为一个显式的"渠道登录"流程） |
| 自签证书 | 需 `URLSessionDelegate` 信任处理 + 证书指纹固定（[09 §6](09-安全与隐私威胁模型.md)） |
| 明文 HTTP | ATS 例外在 Info.plist 中**按域名静态声明**，用户动态输入的 `http://` 主机只能靠 `NSAllowsArbitraryLoads` 或 `NSAllowsLocalNetworking` 覆盖 → **这是安全与可配置性的冲突点，必须用"用户显式开启不安全连接开关"来换取** |

### 3.6 中转站风险画像（写进 UI 提示的原文依据）

- 中转站以**明文持有上游 key**，并能看到**全部 prompt 与响应**（记录/泄露风险）
- **静默替换模型**是普遍现象
- 企业账号转售违反上游厂商条款
- 运营方可能消失（退款纠纷）
- SSE 可能被缓冲或改写（usage 缺失、`[DONE]` 缺失）
- 上表的具体事件断言 `[不确定]`，UI 文案应表述为"存在此类风险"而非指控具体服务

---

## 4. 客户端工程要点（照抄这一节实现）

### 4.1 三种工具调用流形态

| 形态 | 累积键 | 终结信号 |
|---|---|---|
| (a) OpenAI Responses | `response.function_call_arguments.delta`，按 `output_index` + `item_id` | `response.function_call_arguments.done` 携带完整 `arguments` |
| (b) Chat Completions（含 DeepSeek / 绝大多数中转） | `choices[0].delta.tool_calls[i].index` + `.function.arguments` 分片；`id`/`name` 仅首个分片 | `finish_reason == "tool_calls"` |
| (c) Anthropic | `content_block_start`(index) → 多个 `content_block_delta{type:"input_json_delta", partial_json}` → `content_block_stop` | `content_block_stop` |
| (d) Gemini | 每个 chunk 给完整 `functionCall` part（不流式拼装）`[不确定是否支持部分参数流]` | chunk 中携带完整 args |

> Anthropic 文档明确提示：API 可能"一次吐一个完整的 key/value"，因此**工具调用中途会出现长时间停顿**——UI 上要有"正在构造参数"的进度反馈，不能看起来像卡死。

### 4.2 思考链回传矩阵（写错就报错）

| 厂商 | 回传规则 |
|---|---|
| Anthropic | 保留**每一个** `thinking` / `redacted_thinking` 块及其 `signature`，按原顺序原样回传；**不要只按 `type=="thinking"` 过滤** |
| DeepSeek | 只要请求里有 `tools`，历史每轮的 `reasoning_content` 都必须回传，否则 400 |
| OpenAI | `store:false` 时必须回传 `encrypted_content` |
| Gemini | 必须按原顺序回传 thought parts 与 `thoughtSignature` |

### 4.3 断流恢复：没有字节级续传

**没有任何厂商为流式响应提供 `Last-Event-ID` 式续传** `[不确定]`。工程上的正确设计是：

> **"按重发历史来恢复"，而不是"按字节续传"。**

| 厂商 | 可用的恢复手段 |
|---|---|
| OpenAI | `background:true` 的 response + 按 id 回取；`previous_response_id`；`X-Client-Request-Id`（仅用于客服排查） |
| Anthropic | 无续传；重发整个 turn（因为 prompt cache 让重放很便宜） |
| DeepSeek Responses | 截断时以 `response.incomplete` 终结 |
| OpenRouter | 流中途 error chunk 即结束 → 重新请求 |

**且在重发之前，先用 [10 §2.2](10-后台执行与可靠性.md) 的三步落盘协议判断"这一步到底做没做"**——这是唯一能避免重复副作用的手段。

### 4.4 token 计数

| 厂商 | 手段 |
|---|---|
| Anthropic | 精确：`POST /v1/messages/count_tokens` |
| OpenAI | 随包 tiktoken 系列编码器（o200k_base 时代）；**新模型视为近似值** `[不确定]` |
| DeepSeek | 未找到官方 tokenizer 文档 `[不确定]` → 近似 + 与返回 usage 校准 |
| Gemini | 仅有本地近似 `[不确定]` |
| 局域网自建（Ollama/LM Studio/vLLM） | 可服务端精确计数 |
| 中转 | **一律以渠道返回的 usage 为准**，本地估算仅作交叉校验 |

### 4.5 限流与错误分类

| 渠道 | 信号 | 处理 |
|---|---|---|
| OpenAI | `x-ratelimit-*`、`Retry-After`、429 `rate_limit_error`/`slow_down`/`credit_balance_exhausted`、503 `service_unavailable_error`/`server_is_overloaded` | 退避重试 / 换渠道；余额类错误提示用户充值 |
| Anthropic | 429 `rate_limit_error`、529 `overloaded_error`、`retry-after`；官方 SDK 2 次退避重试 | 同上 |
| DeepSeek | 并发超限 429 | 降低并发（`maxConcurrent` 配置） |
| OpenRouter | 402 余额、429 限流、503；guardrail 403 带 `error.metadata` | 402 → 提示充值；403 → 内容策略问题，不重试 |
| 中转 | **假设什么都不能依赖** | 退避 + 本地熔断 + 健康标记 |

**必须区分三类**：① 限流/过载（可重试）② 鉴权/余额（需用户动作）③ 流被截断（结果不完整，需重发或标记）——混淆它们会导致"用户看到莫名失败"。

---

## 5. 2026 年的新机会（客户端可以少做很多事）

这一节同时是 [02 §7 增量创新清单](02-竞品拆解与融合设计.md) 的补充：**模型厂商现在把很多工具搬到了自己服务端**。

| 能力 | 谁提供 | Rune 的取舍 |
|---|---|---|
| 网页搜索 / 抓取 | OpenAI `web_search`、Anthropic `web_search_20260209`/`web_fetch_20260209` | **默认用本地实现**（可控、可审计、出口策略生效）；服务端搜索作为"用户显式选择的加速项" |
| 代码执行 | OpenAI `code_interpreter` / `hosted_shell`、Anthropic `code_execution` | **默认关闭**。理由：与"端侧执行"定位冲突（[01 铁律 1](01-产品定义与愿景.md)）。仅在用户显式同意"把这段计算交给厂商沙箱"时启用，并在会话中明确标注"本步骤在远端执行" |
| 结构化补丁 | OpenAI `apply_patch` | 不用（我们有自己的原生 `apply_patch`，且必须可回滚） |
| 工具检索 | OpenAI `tool_search`、Anthropic `tool_search` | 可用（减少工具爆炸），但需评估其检索质量与本地索引的一致性 |
| MCP | OpenAI / Anthropic 均原生支持 | **这是重要机会**：MCP 成为事实上的插件 ABI。但注意中转站通常会剥掉 `mcp_servers`（DeepSeek 明确忽略） |
| 服务端状态 | OpenAI `previous_response_id` / Conversations API / background mode；Gemini `previous_interaction_id` | 谨慎使用：它把上下文托管给厂商，与隐私主张冲突。**默认关闭**，仅作为"超长会话"的可选加速 |
| 服务端压缩 | Anthropic `compact_20260112` beta | 可作为 [07 §5](07-上下文与记忆引擎.md) 压缩的备选（省钱），但本地压缩优先（可控 + 无外发） |

**一条必须写进产品原则的裁决**：

> 凡是"把用户内容发到第三方服务器去处理"的能力（服务端代码执行、服务端文件搜索、服务端状态托管），**一律默认关闭**，且开启时必须让用户在界面上看到"这一步的数据离开了你的设备"。
> 端侧执行是 Rune 的立身之本，不能因为"厂商提供了更方便的接口"就悄悄放弃。

---

## 6. 价格与模型表的维护策略

由于模型阵容与价格变化极快（本附录核对时已有 2026 年新阵容），实现上：

1. **价格表与模型目录做成可更新的配置文件**（随 App 更新的内置版本 + 用户可手动覆盖），**不硬编码在 Swift 代码里**。
2. 渠道探测（[06 §6.2](06-模型网关与中转站.md)）自动拉取模型列表与上下文窗口。
3. 本地维护的"官方价格表"只用于**估算**；实际计费以渠道返回的 usage × 用户配置价格为准，界面标注 `≈`。
4. 每次发版更新内置价格表，并在设置页显示"价格表版本：2026-09"。

---

**相关文档**：[06 模型网关与中转站](06-模型网关与中转站.md) · [附录 B 技术选型核实表](附录B-技术选型核实表.md) · [13 端侧模型与性能预算](13-端侧模型与性能预算.md)
