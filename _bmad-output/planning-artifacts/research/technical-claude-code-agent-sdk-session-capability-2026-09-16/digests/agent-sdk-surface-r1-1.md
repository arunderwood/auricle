# Digest: Agent SDK session surface — round 1, assistant 1

Assistant: claude-code-guide. Accessed 2026-09-16.

## Claims

| # | Claim | Source URL | Confidence | Class |
|---|---|---|---|---|
| A1 | CLI `--output-format json` response payload includes `total_cost_usd` and a per-model cost breakdown; both are described as client-side estimates. | https://code.claude.com/docs/en/headless.md | high (direct quote) | capability |
| A2 | In `--output-format stream-json`, the last line of the stream is a `result` message carrying final response text, cost, and session metadata. | https://code.claude.com/docs/en/headless.md | medium | capability |
| A3 | Interactive `/usage` output shows per-model rows with input, output, cache read, cache write tokens and a dollar figure. | https://code.claude.com/docs/en/costs.md | high | capability |
| A4 | Thinking tokens are billed as output tokens; no separate `thinking_tokens` field found documented in stream-json result messages. | https://code.claude.com/docs/en/costs.md | medium | capability |
| A5 | Citations are a Messages API feature; assistant asserts Agent SDK input surface is a prompt string only and cannot natively accept document blocks with citations enabled. | https://code.claude.com/docs/en/agent-sdk/typescript.md | LOW — see contradiction C1 | capability |
| A6 | Messages API citation location types: `char_location` (start_char_index/end_char_index), `page_location`, `content_block_location`. Character indices are 0-indexed with exclusive end indices. | https://platform.claude.com/docs/en/build-with-claude/citations.md | high (direct quote) | capability |
| A7 | Docs do NOT state whether start_char_index/end_char_index are UTF-8 bytes, UTF-16 code units, codepoints, or graphemes. All doc examples are ASCII-only, which does not disambiguate. | https://platform.claude.com/docs/en/build-with-claude/citations.md | medium — absence claim, needs second reader | capability |
| A8 | Agent SDK structured outputs: `outputFormat: {type: "json_schema", schema}` (TS) / `output_format` (Py); result message carries `structured_output`; subtype `success` or `error_max_structured_output_retries`. CLI equivalent `--json-schema` with `--output-format json`. | https://code.claude.com/docs/en/agent-sdk/structured-outputs.md | high | capability |
| A9 | Agent SDK `query()` options table exposes no `cacheControl`/`cache_control` field; Claude Code "handles prompt caching for you, unless you disable it". | https://code.claude.com/docs/en/prompt-caching.md | medium | capability |
| A10 | Cache hit observability: `cache_creation_input_tokens` and `cache_read_input_tokens` appear in result usage and `/usage`. | https://code.claude.com/docs/en/costs.md | medium | capability |
| A11 | Billing follows an authentication precedence order; ANTHROPIC_API_KEY -> API workspace pay-per-token, CLAUDE_CODE_OAUTH_TOKEN or `/login` OAuth -> Claude subscription. Agent SDK supports both. | https://code.claude.com/docs/en/authentication.md | high | capability |
| A12 | On a subscription, session cost figure "isn't relevant for billing purposes"; total_cost_usd is a client-side estimate under both auth modes. | https://code.claude.com/docs/en/costs.md | high (direct quote) | capability |
| A13 | Bedrock/Vertex/Foundry via CLAUDE_CODE_USE_BEDROCK / _VERTEX / _FOUNDRY env vars; billed to cloud account. | https://code.claude.com/docs/en/authentication.md | medium | capability |

## Contradictions / gaps flagged for round 2

- **C1 (load-bearing).** A5 asserts the session input is "a prompt string only". The same assistant quoted the `query()` signature as `prompt: string | AsyncIterable<SDKUserMessage>`. Whether `SDKUserMessage` can carry a raw `document` content block is the discriminating question for Q2 and was NOT checked against the type reference. Round 2 must read the TypeScript reference type definition.
- **C2.** A2 says the `result` message carries cost "per turn". A `result` message in `--print` mode plausibly fires once per invocation (per session), not per assistant turn. Granularity is the question asked. Round 2 must check whether `assistant` stream-json messages carry the raw API `usage` block, and what `SDKResultMessage` / `ModelUsage` / `NonNullableUsage` actually declare.
- **C3.** A9 is an absence claim from a prose page, not from the options type reference. Needs confirmation against the reference options table.
- **C4.** No SDK package version was pinned. Technical pack requires two sources for version/compatibility claims.
- **C5.** Two doc hosts appeared — `code.claude.com` and `platform.claude.com`. Both need to be confirmed as live canonical hosts.

## Looked for and could not find

- An explicit `thinking_tokens` / reasoning-token field in any documented session message shape.
- Any statement of the character-encoding unit for citation offsets.
