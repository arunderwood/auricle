# Digest: Agent SDK type reference — round 2, assistant 1

## ⚠ RELIABILITY WARNING — READ BEFORE USING THIS DIGEST

This assistant's type extractions conflict with a primary source the lead read first-hand
(https://code.claude.com/docs/en/agent-sdk/cost-tracking, digest `usage-cost-r1-lead.md`).
Where they conflict, the cost-tracking page wins: it is a narrative page with worked code
examples naming fields explicitly, and it links directly to the type anchors this assistant
claims to have read.

Specific extraction failures identified:

- **It reported `SDKResultMessage` as `{type, tool_use_id, content, is_error}`.** That is the
  shape of a *tool result content block*, not the session result message. The assistant
  flagged its own suspicion. Its extraction is rejected.
- **It reported `ModelUsage` as snake_case `{input_tokens, output_tokens,
  cache_creation_input_tokens, cache_read_input_tokens}` with "no cost breakdown, no model
  ID".** The cost-tracking page's worked example reads `usage.costUSD`, `usage.inputTokens`,
  `usage.outputTokens`, `usage.cacheReadInputTokens`, `usage.cacheCreationInputTokens` from
  `modelUsage` entries — camelCase, with cost — and describes `modelUsage` as "a map of model
  name to per-model token counts and cost". The assistant appears to have conflated
  `ModelUsage` with the Anthropic API's `Usage` type. Its extraction is rejected.
- **It reported Python `ResultMessage` as carrying `cost: CostInfo`, `terminal_reason`,
  `turn_number`.** The cost-tracking page names `total_cost_usd` and `model_usage` on Python's
  `ResultMessage`. Rejected pending first-hand check.
- **It returned UNVERIFIABLE on whether caching is automatic and on a caching disable
  mechanism.** Both are answered explicitly on the cost-tracking page, which it did not fetch.
  Its UNVERIFIABLE here is an artifact of incomplete search, not genuine doc silence — and
  must NOT be reported as doc silence.

Nothing in this digest is promoted to the report without independent confirmation.

## Items retained (each still requiring first-hand confirmation)

| # | Claim | Status |
|---|---|---|
| T1 | `SDKUserMessage`'s content block type union includes `"document"` alongside `"text"`, `"image"`, `"tool_result"` — i.e. the input type may permit a document block. | UNCONFIRMED — load-bearing for Q2, and this assistant's type extraction is demonstrably unreliable. Lead must verify first-hand. |
| T2 | Neither `ModelUsage` nor `NonNullableUsage` declares a thinking/reasoning token field. | UNCONFIRMED but CONVERGENT with the lead's independent absence finding (U11). Needs first-hand confirmation before a verdict. |
| T3 | The assistant-message content block union shown contains `"text" | "thinking" | "tool_use"` and shows NO `citations` field. | UNCONFIRMED — same reliability caveat. Load-bearing for Q2's output half. |
| T4 | `SDKAssistantMessage` carries an optional `model?: string`. | UNCONFIRMED; convergent with `system/init` reporting the model (headless.md). |

## Items retained as reliable (registry primary source, not type extraction)

| # | Claim | Source | Confidence |
|---|---|---|---|
| T5 | `claude-agent-sdk` on PyPI is at version **0.2.153**, last updated **2026-09-15** — one day before access. | https://pypi.org/project/claude-agent-sdk/ | high — package registry is a primary source for its own version |
| T6 | The npm page for `@anthropic-ai/claude-agent-sdk` returned **403 Forbidden** to automated fetch; the npm version is unverified. | https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk | high (the failure itself is the observation) |

## Methodological note for the record

This assistant hit its fetch budget having spent calls on doc-map and llms.txt index pages and
on two blocked registries. It is a worked example of the technical pack's own warning: an
UNVERIFIABLE returned by an assistant that ran out of budget is not the same finding as an
UNVERIFIABLE returned after an exhaustive search. Only the latter belongs in a verdict table.
