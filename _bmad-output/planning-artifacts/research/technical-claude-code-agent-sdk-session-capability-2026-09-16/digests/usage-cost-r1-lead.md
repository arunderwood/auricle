# Digest: Usage metadata, cost, caching control — round 1, lead (first-hand)

Sources, both Anthropic official, accessed 2026-09-16:
- https://code.claude.com/docs/en/agent-sdk/cost-tracking  ("Track cost and usage")
- https://code.claude.com/docs/en/headless  ("Run Claude Code programmatically")

No publication dates shown; both reference Claude Code versions up to v2.1.265 and Agent SDK TS v0.3.239 / Py v0.2.144, so they are current to at least those releases.

## U-group: usage metadata (Q1)

**U1 — Three granularities are documented explicitly.** Direct quote, cost-tracking: "**`query()` call:** one invocation of the SDK's `query()` function... Each call produces one `result` message at the end, except in streaming input mode, where one `query()` call carries multiple user turns and each turn emits its own `result` message. **Step:** a single request/response cycle within a `query()` call. Each step produces assistant messages with token usage. **Session:** a series of `query()` calls linked by a session ID."

**U2 — Per-model-call (step) usage IS exposed on assistant messages.** Direct quote: "In TypeScript, each assistant message contains a nested `BetaMessage` (accessed via `message.message`) with an `id` and a `usage` object with token counts (`input_tokens`, `output_tokens`). In Python, the `AssistantMessage` dataclass exposes the same data directly via `message.usage` and `message.message_id`."

**U3 — Per-step `output_tokens` IS NOT USABLE.** This is the sharpest caveat on the page, in a Warning block: "The deduplicated per-step values are accurate for input and cache tokens. Per-step `output_tokens` is a placeholder, so read output tokens from the result message." Explained: "Claude Code builds each assistant message from the usage the API reported when the response began, so the message's `output_tokens` is only the count the API had reported at `message_start`, before the response was generated. One API response can produce several assistant messages, and every one of them carries that same placeholder."

**U4 — Parallel tool calls require deduplication by message id.** Direct quote: "When Claude uses multiple tools in one turn, all messages in that turn share the same ID, so deduplicate by ID to avoid double-counting."

**U5 — Result message carries the authoritative per-call totals.** Fields named on the page: `total_cost_usd`, `usage`, `modelUsage` (TS) / `model_usage` (Py), `duration_api_ms`, `subtype`, `session_id`, `permission_denials`, `structured_output`.

**U6 — `modelUsage` is keyed by model and carries a per-model breakdown.** Direct quote: "The result message includes `modelUsage`, a map of model name to per-model token counts and cost." The documented example reads these fields per entry: `costUSD`, `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`. Plus `costBasis`: "Each entry's `costBasis` says which price table priced that model's latest request: `list` for list price, `managed` for a `modelPricing` table, or `unknown` when neither matched the model ID. The field requires Claude Code v2.1.246 or later."

**U7 — The model actually used is recoverable** as the key of the `modelUsage` map, and separately from the `system/init` stream event, which "reports session metadata including the model, tools, MCP servers, and loaded plugins" (headless.md).

**U8 — Subagent accounting differs by field.** Documented table: `usage` EXCLUDES subagent tokens ("Counts only the top-level agent loop"); `total_cost_usd` and `modelUsage` INCLUDE them. Direct quote: "Use `modelUsage`... for whole-tree token accounting; the `usage` field undercounts as soon as nesting occurs."

**U9 — Cost figures are client-side estimates, and the docs say not to make financial decisions from them.** Direct quote from the page's Warning block: "The `total_cost_usd` and `costUSD` fields are client-side estimates, not authoritative billing data. The SDK computes them locally from a price table bundled at build time, unless a `modelPricing` table is in effect. They can drift from what you are actually billed when: pricing changes; the installed SDK version does not recognize a model; billing rules apply that the client cannot model." And: "Use these fields for development insight and approximate budgeting. For authoritative billing, use the Usage and Cost API or the Usage page in the Claude Console. **Do not bill end users or trigger financial decisions from these fields.**"

**U10 — One billing rule IS modeled client-side.** Direct quote: "When a response's `usage` reports `inference_geo: \"us\"`, the SDK multiplies the list price of that response's tokens by 1.1."

**U11 — No thinking/reasoning token field appears anywhere on this page.** The page enumerates the usage object as `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`. NOT an exhaustive type listing — the page defers to the TS `Usage` type reference. Absence flagged for round-2 confirmation against the declared type. DO NOT report a verdict on thinking tokens from this page alone.

**U12 — A host-settable spend ceiling exists.** Direct quote: "`maxBudgetUsd` (TypeScript) or `max_budget_usd` (Python) is compared against the same running total". Corresponding result subtype `error_max_budget_usd`; on that subtype "`usage` leaves out the response that crossed the budget, while `total_cost_usd` and `modelUsage` include it." Note this ceiling is enforced against the same client-side estimate covered by U9.

**U13 — Crash case.** An `error_during_execution` result after a session crash "may carry zeroed `usage`, `total_cost_usd`, and `modelUsage`"; the docs give a documented recovery procedure from earlier messages.

**U14 — CLI surface mirrors it.** Direct quote, headless.md: "With `--output-format json`, the response payload includes `total_cost_usd` and a per-model cost breakdown, so scripted callers can track spend per invocation without consulting the usage dashboard. Both figures are client-side estimates and can differ from your actual bill." And: "The last line of the stream is a `result` message with the final response text, cost, and session metadata."

## C-group: prompt caching (Q4)

**C1 — Caching is automatic and the docs state the host does not configure it.** Direct quote, cost-tracking: "The Agent SDK automatically uses prompt caching to reduce costs on repeated content. **You do not need to configure caching yourself.**"

**C2 — The host's caching control is TTL-bucket-level, not per-content-block.** Documented controls, all env-var / settings level:
- `ENABLE_PROMPT_CACHING_1H` — "asks for the 1-hour TTL on every request in both buckets"
- `CLAUDE_CODE_PROMPT_CACHE_TTL` env var or `promptCacheTtl` setting — main conversation bucket, takes `5m` or `1h`
- `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` env var or `subagentPromptCacheTtl` setting — everything else
Two buckets are documented: "Your own turns fall in the main conversation TTL bucket, together with the helpers Claude Code runs inline with them. The requests Claude Code makes outside that conversation, such as subagents, have a separate TTL control." No per-content-block placement appears on this page.

**C3 — Cache hits ARE observable.** Direct quote: "`cache_creation_input_tokens`: tokens used to create new cache entries (charged at a higher rate than standard input tokens). `cache_read_input_tokens`: tokens read from existing cache entries (charged at a reduced rate)."

**C4 — Default TTL depends on the billing mode.** Direct quote: "Cache entries for your own turns use a 5-minute TTL by default when you authenticate with an API key or run on Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry, or Claude Platform on AWS." And: "On a Claude subscription within your plan's included usage, you get the 1-hour TTL on your own turns... without setting this variable, and Claude Code drops those turns to the 5-minute TTL once you're drawing on usage credits."

## S-group: structured output, CLI surface (Q3)

**S1 — CLI structured output CONFIRMED.** Direct quote, headless.md: "To get output conforming to a specific schema, use `--output-format json` with `--json-schema` and a JSON Schema definition. The response includes metadata about the request (session ID, usage, etc.) with the structured output in the `structured_output` field."

**S2 — Schema validation is enforced at the CLI boundary.** Direct quote: "If the value isn't a valid JSON Schema, `claude` exits with `Error: --json-schema is not a valid JSON Schema` followed by the validator's diagnostic."

**S3 — `format` keyword is accepted but NOT enforced.** Direct quote: "Claude Code accepts schemas that use the `format` keyword, such as `\"format\": \"email\"`, but treats `format` as an annotation and doesn't enforce it."

## A-group: auth / billing corroboration (Q5, second source)

**A1 — Bare mode is API-key-only; second source for the billing digest's B6.** Direct quotes, headless.md: "Set `ANTHROPIC_API_KEY` before running it, because bare mode doesn't use your subscription login." / "In bare mode, Claude Code never reads OAuth credentials or the system keychain. For the Anthropic API, set `ANTHROPIC_API_KEY` in the environment... or supply an `apiKeyHelper` in the `--settings` JSON."

**A2 — Bare mode is the recommended scripted mode.** Direct quote: "`--bare` is the recommended mode for scripted and SDK calls, and will become the default for `-p` in a future release."

## Leads worth chasing

- The declared `Usage` type at /docs/en/agent-sdk/typescript#usage — the only place that can settle U11 (thinking tokens) definitively. Routed to round-2 assistant.
- `modelPricing` setting (/docs/en/settings-reference#modelpricing) — lets a host supply its own price table, which changes what `costUSD` means. Not chased further; noted.
- Usage and Cost API (platform.claude.com/docs/en/build-with-claude/usage-cost-api) — named by the docs as the authoritative alternative to the client-side estimate. Not chased; noted as the route to authoritative figures.

## Looked for and could not find

- Any thinking/reasoning-token field on this page (see U11 — deliberately NOT concluded here).
- Any mechanism on either page for placing `cache_control` on a chosen content block.
- Any mention of citations or document content blocks on either page.
