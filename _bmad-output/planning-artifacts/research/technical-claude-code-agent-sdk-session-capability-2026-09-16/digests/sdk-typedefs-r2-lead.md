# Digest: Published Agent SDK type definitions — round 2, lead (first-hand, authoritative)

Method: fetched the published package from the npm registry and read its shipped `.d.ts` directly,
rather than relying on rendered doc pages (which, as verified, do not contain literal type
declarations). This is the most primary source available for the SDK's type surface.

- Package: `@anthropic-ai/claude-agent-sdk`
- Version: **0.3.274** (`npm view ... version`, confirmed against the tarball's own `package.json`)
- Registry last-modified: **2026-09-17T00:12:14.433Z** (`npm view ... time.modified`) — i.e. current to the hour
- Files read: `package/sdk.d.ts` (9,368 lines), `package/sdk-tools.d.ts` (4,184 lines)
- Accessed 2026-09-16

## D1 — `ModelUsage`, verbatim

```typescript
export declare type ModelUsage = {
    inputTokens: number;
    outputTokens: number;
    /**
     * Thinking tokens, already counted inside outputTokens. Counts only turns run on CLI versions
     * that record this field: absent when none did, and partial for a resumed session that began
     * on an older version.
     */
    thinkingTokens?: number;
    cacheReadInputTokens: number;
    cacheCreationInputTokens: number;
    webSearchRequests: number;
    costUSD: number;
    contextWindow: number;
    maxOutputTokens: number;
    /**
     * Canonical model id used for the pricing lookup (e.g. 'claude-opus-4-7'). May differ from the
     * raw model string this entry is keyed by (provider-specific ids, aliases).
     */
    canonicalModel?: string;
    /**
     * API provider that served this model (e.g. 'firstParty', 'bedrock', 'vertex', 'foundry',
     * 'anthropicAws', 'mantle', 'gateway').
     */
    provider?: string;
    // costBasis: 'list' | 'managed' | 'unknown' — which price table priced the most recent request
};
```

**This OVERTURNS the round-2 assistant's claim that no thinking-token field exists, and supersedes
the lead's own earlier caution (U11).** `thinkingTokens` exists, with three documented caveats in the
type's own comment: it is optional; it counts only turns run on CLI versions that record it; and it is
partial for a session resumed from an older version. It is **already counted inside `outputTokens`**,
so it is a sub-total, not an additive term.

## D2 — `NonNullableUsage`, verbatim

```typescript
export declare type NonNullableUsage = {
    [K in keyof BetaUsage]: NonNullable<BetaUsage[K]>;
};
```

It IS derived from the Anthropic API's `BetaUsage` type — a mapped type stripping nullability. This
also overturns the round-2 assistant's claim that it is a custom type unrelated to the API `Usage`.

## D3 — `SDKResultMessage`, verbatim (abridged to decision-relevant fields)

```typescript
export declare type SDKResultMessage = SDKResultSuccess | SDKResultError;

export declare type SDKResultSuccess = {
    type: 'result';
    subtype: 'success';
    duration_ms: number;
    duration_api_ms: number;
    ttft_ms?: number;
    is_error: boolean;
    num_turns: number;
    result: string;
    stop_reason: string | null;
    total_cost_usd: number;
    usage: NonNullableUsage;
    modelUsage: Record<string, ModelUsage>;
    permission_denials: SDKPermissionDenial[];
    queued_turn_count?: number;
    structured_output?: unknown;
    result_index?: number;
    // ... plus ~15 timing fields
};

export declare type SDKResultError = {
    type: 'result';
    subtype: 'error_during_execution' | 'error_max_turns' | 'error_max_budget_usd'
           | 'error_max_structured_output_retries';
    ...
};
```

The shipped doc comments are materially richer than the web docs:

- On `usage`: "MAIN AGENT LOOP ONLY — excludes Task subagent, sidechain, and auxiliary model calls, and is per-turn in streaming-input sessions. Prefer modelUsage for token/cost accounting."
- On `modelUsage`: "Per-model totals for every model call made through the query pipeline during this query() call — main loop, Task subagents, sidechains, and internal calls such as compaction and Workflow agents... **Internal helper calls outside the query pipeline (e.g. the permission classifier, token-count probes) are excluded**; crash/startup-error results may carry zeroed usage, resumed sessions start fresh, and a mid-session /clear resets the running total. The correct field for token/cost accounting; **treat it as an estimate, not a billing statement**."
- On `total_cost_usd`: "Cumulative estimated cost in USD for this query() call... **An estimate, not a billing statement.**"

`modelUsage` is `Record<string, ModelUsage>` — keyed by the raw model string, with `canonicalModel`
available inside each entry when the raw key is a provider-specific id or alias.

## D4 — `SDKUserMessage`, verbatim — the decisive evidence for Q2's input half

```typescript
export declare type SDKUserMessage = {
    type: 'user';
    /**
     * An Anthropic Messages API user message: a MessageParam with role "user" whose content is a
     * string or an array of content blocks (text, image, document, tool_result, ...). See the
     * Messages API reference for the block types.
     */
    message: MessageParam;
    parent_tool_use_id: string | null;
    isSynthetic?: boolean;
    tool_use_result?: unknown;
    priority?: 'now' | 'next' | 'later';
    origin?: SDKMessageOrigin;
};
```

**The input type is the Anthropic SDK's own `MessageParam`, and the shipped comment names `document`
explicitly among the permitted block types.** This overturns the round-1 assistant's assertion that the
session input is "a prompt string only". It is a string OR an `AsyncIterable<SDKUserMessage>`, and an
`SDKUserMessage` carries a full `MessageParam`. A `MessageParam` can structurally hold a
`DocumentBlockParam` with `citations: {enabled: true}`.

**What this does NOT establish:** that Claude Code's harness forwards such a block to the Messages API
unmodified, with citations enabled. That is runtime behavior, not a type guarantee. See D6.

## D5 — `SDKAssistantMessage`, verbatim (abridged)

```typescript
export declare type SDKAssistantMessage = {
    type: 'assistant';
    /**
     * Shaped like an Anthropic Messages API Message object (role "assistant"): id, model, content
     * blocks (text, thinking, tool_use, ...), stop_reason and usage. When streamed, content typically
     * holds the single block this message delivers and stop_reason is still null. See the Messages
     * API reference for the block types.
     */
    message: BetaMessage;
    parent_tool_use_id: string | null;
    error?: SDKAssistantMessageError;
    uuid: UUID;
    session_id: string;
    request_id?: string;
    ...
};
```

The output type is the Anthropic SDK's own `BetaMessage`, which carries `id`, `model`, `usage`, and
content blocks. A `BetaMessage` text block structurally carries a `citations` array. So the output
type does not preclude citations reaching the host either — again a type fact, not a behavior fact.

## D6 — Citations: exhaustive absence across the SDK's own surface

Case-insensitive search for `citation` across all shipped `.d.ts` files, with `Elicitation`
false-positives separated out by tokenizing:

- `package/sdk.d.ts`: **zero** genuine `citation` identifiers. All 52 raw matches are `Elicitation`,
  `ElicitationHookInput`, `elicitationId`, etc. — the substring "citation" inside "Elicitation".
- `package/sdk-tools.d.ts`: **exactly one** occurrence — `citations?: unknown[] | null;` — and it is
  inside the **Agent/Task tool's output shape** (`{agentId, agentType, content: {type: "text", text,
  citations}[], resolvedModel, modelsUsed}`), i.e. the subagent report structure. It is typed
  `unknown[]`, carrying no citation location structure at all.

**Conclusion:** the Agent SDK's type surface contains no citations feature — no `citations: {enabled}`
option, no `CitationCharLocation`, no char-offset type. What structural capability exists is inherited
entirely from the pass-through Anthropic types (`MessageParam` in, `BetaMessage` out).

## D7 — Caching: exhaustive absence, and what control does exist

- Case-insensitive search for `cache_control` / `cacheControl` across `sdk.d.ts`: **zero occurrences**
  in 9,368 lines.
- The only caching knobs on the options surface are TTL selectors:
  ```typescript
  promptCacheTtl?: '5m' | '1h';
  subagentPromptCacheTtl?: '5m' | '1h';
  ```
  With the shipped comment on the second: "Prompt cache TTL for everything outside the main
  conversation — subagents, workflows, background and helper requests: \"5m\" or \"1h\". Unset =
  automatic (5 minutes unless ENABLE_PROMPT_CACHING_1H=1). The CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL
  environment variable takes precedence."

- `systemPrompt` accepted shapes, verbatim — note that none is a structured content-block array, so
  there is no position at which a host could attach a breakpoint:
  ```typescript
  systemPrompt?: string | string[] | {
      type: 'custom';
      prompt: string | string[];
      snapshot?: boolean;
  } | {
      type: 'preset';
      preset: 'claude_code';
      append?: string;
      excludeDynamicSections?: boolean;
      snapshot?: boolean;
  };
  ```

- Adjacent and relevant to cache stability: `systemPromptSnapshot?: boolean` — "Record the
  conversation's system prompt once and reuse it verbatim on every later request and resume. Omitted
  or true (the default): the prompt is rendered on the first request... and the record is sent as-is
  afterwards — even when a later launch passes different text — until compaction."

## D8 — Structured output, verbatim

```typescript
export declare type OutputFormat = JsonSchemaOutputFormat;
export declare type OutputFormatType = 'json_schema';

// on Options:
outputFormat?: OutputFormat;
// @example
// outputFormat: {
//   type: 'json_schema',
//   schema: { type: 'object', properties: { result: { type: 'string' } } }
// }

// on SDKResultSuccess:
structured_output?: unknown;

// on SDKResultError:
subtype: ... | 'error_max_structured_output_retries';
```

Mechanism note from a shipped comment: "End-turn tool sessions (`outputFormat: {type:
'json_schema'}`...): a completed turn there ends on a successful tool_result carrier — with no trailing
assistant message — followed by a `structured_output` attachment holding the turn's actual output (the
carrier's data is a placeholder)." So the session's schema-constrained output is implemented as an
end-turn tool, not as the Messages API's `output_config.format`.

## D9 — Budget ceiling

```typescript
maxBudgetUsd?: number;
```
Plus an adjacent API-side token budget option: "API-side task budget in tokens. When set, the model is
made aware of its remaining token budget so it can pace tool use and wrap up before the limit. Sent as
`output_config.task_budget`."

## Overturned by this digest

| Prior claim | Source of prior claim | Status |
|---|---|---|
| "No thinking/reasoning token field exists" | round-2 assistant; lead's own U11 caution | **OVERTURNED** — `thinkingTokens?: number` exists (D1) |
| "`ModelUsage` has no cost breakdown and no model ID" | round-2 assistant | **OVERTURNED** — `costUSD`, `canonicalModel`, `provider`, `contextWindow` all present (D1) |
| "`NonNullableUsage` is a custom type not derived from the API `Usage`" | round-2 assistant | **OVERTURNED** — it is `NonNullable<BetaUsage[K]>` mapped (D2) |
| "`SDKResultMessage` is `{type, tool_use_id, content, is_error}`" | round-2 assistant | **OVERTURNED** — that was a tool-result block; real shape at D3 |
| "The Agent SDK input is a prompt string only, so it cannot submit a document block" | round-1 assistant | **OVERTURNED** — `message: MessageParam`, comment names `document` (D4) |
