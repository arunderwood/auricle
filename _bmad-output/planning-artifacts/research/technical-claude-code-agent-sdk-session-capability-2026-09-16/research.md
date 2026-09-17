---
title: 'Technical research: Claude Code / Claude Agent SDK session capability surface'
type: 'technical'
topic: 'Claude Code / Claude Agent SDK session capability surface'
decision: 'Epic 3 AI invocation architecture — whether to call the Anthropic Messages API directly from Swift or drive a managed Claude Code / Claude Agent SDK session from the host process'
source: 'native run (bmad-deep-recon, run mode)'
status: complete
preset: 'standard'
validation: 'normal'
created: '2026-09-16'
updated: '2026-09-16'
claims_verified: 17
claims_unverified: 0
claims_overturned: 5
---

# Technical research: Claude Code / Claude Agent SDK session capability surface

**Decision this research serves:** Epic 3 AI invocation architecture — whether to call the Anthropic Messages API directly from Swift (`Sources/ClaudeSummarizer`, `Sources/ClaudeAIReviewers`) or invoke the model through a managed Claude Code / Claude Agent SDK session driven from the host process.

## Scope

This document reports **capability facts only**. It contains no recommendation, no comparison against the status quo, and no design. That was the explicit commission: establish what a programmatically driven session exposes to a host, so a later roundtable decides with evidence rather than with assumption.

Every verdict below is one of three values: **CONFIRMED AVAILABLE** (field/API name plus a source), **CONFIRMED UNAVAILABLE** (the statement or exhaustive absence that says so), or **UNVERIFIABLE FROM DOCS** (stated plainly, with the searches that make the absence credible). Where documentation is ambiguous it is reported as ambiguous rather than resolved by inference.

**Companion artifact.** `../technical-claude-code-ai-invocation-architecture-2026-09-16/` covers
the same decision from the other side: invocation *mechanics* — headless invocation, attaching to
a running session, lifecycle and kill, tool and filesystem scope, and prompts-as-files. This
document covers the *capability surface* the session exposes back to a host. The two are
orthogonal and were run independently against the same version anchor (Claude Code 2.1.220);
neither contradicts the other. One point of mutual corroboration is worth noting: that artifact
found `subtype` reads `"success"` on failed runs and that a host must branch on `is_error`. The
probes here hit exactly that case — an expired login surfaced through `is_error` while `subtype`
was unhelpful — and were written to read `is_error` first.

**Versions this reflects.** `@anthropic-ai/claude-agent-sdk` **0.3.274**, registry-modified 2026-09-17T00:12Z, read directly from the published tarball [4]. `claude-agent-sdk` (PyPI) **0.2.153**, updated 2026-09-15 [10]. Doc pages carry no publication dates but reference Claude Code releases up to v2.1.265. Nothing here is answered from model memory; every claim traces to a source retrieved on 2026-09-16.

---

## Verdict table

| # | Question | Verdict | The short answer |
|---|---|---|---|
| **1** | Per-call usage metadata | **CONFIRMED AVAILABLE** | All of it, at two granularities. Per-step on `assistant` messages; per-call totals plus a model-keyed `modelUsage` breakdown on the `result` message — including `thinkingTokens`, both cache counters, canonical model id, and `costUSD`. Two caveats bite: per-step `output_tokens` is a documented **placeholder**, and every dollar figure is a **client-side estimate** the docs say not to make financial decisions from. |
| **2a** | Citations — can a session submit a citations-enabled document and get offsets back? | **UNVERIFIABLE FROM DOCS** → **OBSERVED: YES, with a catch** | Docs say nothing, in either direction. **Measured 2026-09-16 [P1]:** a session *does* forward the document and citations *do* reach the host — but **only as `citations_delta` stream events under `--include-partial-messages`**. The reassembled `assistant` message carries `citations: []` — the key is present on exactly the cited block, emptied of its payload. A host reading assistant messages sees nothing; a host reading stream events gets full `char_location` objects. |
| **2b** | Citations — offset semantics of `start_char_index` / `end_char_index` | **UNVERIFIABLE FROM DOCS** → **OBSERVED: Unicode codepoints, no normalization** | The docs still never state the unit — five surfaces, nine terms, named negative results; `end_char_index` has no description at all in the API reference schema. **Measured 2026-09-16 [P1]:** offsets are **Unicode codepoints**, counted against the text **exactly as submitted** — no server-side NFC pass. Confirmed on two inputs whose predictions differed. This is an observation of current behavior, **not a documented contract**. |
| **3** | Structured output | **CONFIRMED AVAILABLE** | `outputFormat: {type: 'json_schema', schema}` on the session options; the parsed payload arrives as `structured_output` on the result message; failure surfaces as result subtype `error_max_structured_output_retries`. CLI equivalent: `--output-format json --json-schema`. |
| **4** | Prompt caching — per-block `cache_control` | **CONFIRMED UNAVAILABLE** (control) / **CONFIRMED AVAILABLE** (observability) | `cache_control` appears **zero times** in 9,368 lines of shipped type definitions, and no `systemPrompt` shape accepts a structured content-block array, so no position exists at which a host could attach a breakpoint. The docs state plainly: "You do not need to configure caching yourself." Host control is TTL-bucket-level only. Cache hits **are** observable via `cacheReadInputTokens` / `cacheCreationInputTokens`. |
| **5** | Billing | **CONFIRMED AVAILABLE — either** | Determined by a documented 7-step credential precedence order. `ANTHROPIC_API_KEY` → API workspace, pay-per-token. `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) → Claude subscription, requires Pro/Max/Team/Enterprise. For an unattended host, two rules decide it: in `-p` mode a present API key **always** wins, and `--bare` mode refuses OAuth entirely. |

---

## 1. Per-call usage metadata — CONFIRMED AVAILABLE

### Granularity: three documented levels

The docs define the vocabulary explicitly [1]: a **`query()` call** is one invocation, producing one `result` message at the end (except in streaming-input mode, where each turn emits its own). A **step** is a single request/response cycle within a call — "Each step produces assistant messages with token usage." A **session** is a series of calls linked by session id.

So the host gets usage **per model call** (step) *and* **per call**. Not per session — the docs are explicit: "The SDK doesn't provide a session-level total, so if your application makes multiple `query()` calls... accumulate the totals yourself" [1].

### Per-step, on the assistant message

"In TypeScript, each assistant message contains a nested `BetaMessage` (accessed via `message.message`) with an `id` and a `usage` object with token counts (`input_tokens`, `output_tokens`). In Python, the `AssistantMessage` dataclass exposes the same data directly via `message.usage` and `message.message_id`." [1]

Two handling requirements come with it:

- **Deduplicate by message id.** "When Claude uses multiple tools in one turn, all messages in that turn share the same ID, so deduplicate by ID to avoid double-counting." [1]
- **Per-step `output_tokens` is unusable.** From a Warning callout: "The deduplicated per-step values are accurate for input and cache tokens. Per-step `output_tokens` is a placeholder, so read output tokens from the result message." The mechanism: "Claude Code builds each assistant message from the usage the API reported when the response began, so the message's `output_tokens` is only the count the API had reported at `message_start`, before the response was generated." [1]

### Per-call, on the result message

Verbatim from the shipped type definitions [4]:

```typescript
export declare type SDKResultSuccess = {
    type: 'result';
    subtype: 'success';
    duration_ms: number;
    duration_api_ms: number;
    num_turns: number;
    result: string;
    stop_reason: string | null;
    total_cost_usd: number;
    usage: NonNullableUsage;
    modelUsage: Record<string, ModelUsage>;
    permission_denials: SDKPermissionDenial[];
    structured_output?: unknown;
    // ... plus ~15 timing fields
};
```

`NonNullableUsage` is derived directly from the Anthropic API's own usage type [4]:

```typescript
export declare type NonNullableUsage = {
    [K in keyof BetaUsage]: NonNullable<BetaUsage[K]>;
};
```

### The per-model breakdown, including thinking tokens

`modelUsage` is `Record<string, ModelUsage>` — keyed by the raw model string. Verbatim [4]:

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
    /** Canonical model id used for the pricing lookup (e.g. 'claude-opus-4-7'). May differ from the
     *  raw model string this entry is keyed by (provider-specific ids, aliases). */
    canonicalModel?: string;
    /** API provider that served this model (e.g. 'firstParty', 'bedrock', 'vertex', ...). */
    provider?: string;
};
```

This maps one-to-one onto every field named in the question, and onto every field the summarize-stage telemetry payload records:

| Asked for | Field | Where |
|---|---|---|
| `input_tokens` | `inputTokens` / `usage.input_tokens` | `modelUsage` entry; result `usage`; per-step |
| `output_tokens` | `outputTokens` / `usage.output_tokens` | `modelUsage` entry; result `usage` — **not** per-step (placeholder) |
| thinking tokens | `thinkingTokens?` | `modelUsage` entry only. Optional; already inside `outputTokens` |
| cache write | `cacheCreationInputTokens` | `modelUsage` entry; result `usage`; per-step |
| cache read | `cacheReadInputTokens` | `modelUsage` entry; result `usage`; per-step |
| model id actually used | `modelUsage` map key + `canonicalModel` | also on `system/init` [2] and `SDKAssistantMessage.message.model` |
| cost | `costUSD` per model; `total_cost_usd` per call | result message |

**`thinkingTokens` carries three caveats stated in its own type comment** [4]: it is optional; it "counts only turns run on CLI versions that record this field: absent when none did"; and it is "partial for a resumed session that began on an older version." It is a sub-total of `outputTokens`, not an additive term — double-counting it would overstate output.

### What the fields exclude — differs per field

The shipped comments are materially more precise than the rendered docs [4]:

- `usage`: "**MAIN AGENT LOOP ONLY** — excludes Task subagent, sidechain, and auxiliary model calls, and is per-turn in streaming-input sessions. Prefer modelUsage for token/cost accounting."
- `modelUsage`: "Per-model totals for every model call made through the query pipeline... main loop, Task subagents, sidechains, and internal calls such as compaction and Workflow agents. **Internal helper calls outside the query pipeline (e.g. the permission classifier, token-count probes) are excluded**."

So even `modelUsage`, the widest field, is not a complete account of tokens spent by the process.

### The cost figure is an estimate, and the docs say not to rely on it

From a Warning callout [1]: "The `total_cost_usd` and `costUSD` fields are client-side estimates, not authoritative billing data. The SDK computes them locally from a price table bundled at build time, unless a `modelPricing` table is in effect. They can drift from what you are actually billed when: pricing changes; the installed SDK version does not recognize a model; billing rules apply that the client cannot model."

And, unambiguously: "Use these fields for development insight and approximate budgeting. For authoritative billing, use the Usage and Cost API or the Usage page in the Claude Console. **Do not bill end users or trigger financial decisions from these fields.**"

The shipped type comments repeat it twice — on `total_cost_usd`: "An estimate, not a billing statement"; on `modelUsage`: "treat it as an estimate, not a billing statement" [4].

One billing rule *is* modeled client-side: "When a response's `usage` reports `inference_geo: \"us\"`, the SDK multiplies the list price of that response's tokens by 1.1" [1].

`costBasis` on each `modelUsage` entry reports which price table priced that model: `list`, `managed` (an org `modelPricing` table), or `unknown` — "no pricing row and no built-in price matched the model ID, so costUSD is a guess at the default model's rate" [4]. Requires Claude Code v2.1.246 or later.

### Degenerate cases

- **Crash:** an `error_during_execution` result after a session crash "may carry zeroed `usage`, `total_cost_usd`, and `modelUsage`." The docs give a documented recovery procedure from earlier messages [1].
- **Budget exceeded:** on subtype `error_max_budget_usd`, "`usage` leaves out the response that crossed the budget, while `total_cost_usd` and `modelUsage` include it" [1].
- **Reset:** "resumed sessions start fresh, and a mid-session `/clear` resets the running total" [4].

### A host-settable spend ceiling exists

`maxBudgetUsd?: number` (TS) / `max_budget_usd` (Python) is an option on the session; exceeding it terminates the call with result subtype `error_max_budget_usd` [1][4]. It is enforced against the same client-side estimate described above — the ceiling is as accurate as the estimate is.

### CLI surface

"With `--output-format json`, the response payload includes `total_cost_usd` and a per-model cost breakdown, so scripted callers can track spend per invocation without consulting the usage dashboard. Both figures are client-side estimates and can differ from your actual bill." [2] And: "The last line of the stream is a `result` message with the final response text, cost, and session metadata." [2]

---

## 2. Citations — UNVERIFIABLE FROM DOCS (both halves)

### 2a. Can a session submit a citations-enabled document and receive locations?

**The types permit it.** Verbatim [4]:

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
    ...
};
```

The session's `prompt` parameter is `string | AsyncIterable<SDKUserMessage>`, and an `SDKUserMessage` carries a full Anthropic `MessageParam` — whose shipped comment names `document` explicitly. A `MessageParam` can structurally hold a `DocumentBlockParam` with `citations: {enabled: true}`. On the output side, `SDKAssistantMessage.message` is a `BetaMessage`, whose text blocks structurally carry a `citations` array [4].

**The SDK has no citations feature of its own.** An exhaustive case-insensitive search across all shipped `.d.ts` files [4], with `Elicitation` false positives separated by tokenizing:

- `sdk.d.ts` (9,368 lines): **zero** genuine `citation` identifiers. All 52 raw matches are the substring inside `Elicitation` / `elicitationId` / `ElicitationHookInput`.
- `sdk-tools.d.ts` (4,184 lines): **exactly one** — `citations?: unknown[] | null;` — and it sits inside the **Agent/Task tool's report shape**, typed `unknown[]`, carrying no location structure whatsoever.

There is no `citations: {enabled}` option, no `CitationCharLocation` type, no char-offset type anywhere in the SDK's surface.

**No documentation states the behavior.** Neither the cost-tracking page, the headless page, the TypeScript reference, nor the Python reference mentions citations or document content blocks in the context of a session.

**Therefore the honest verdict is UNVERIFIABLE FROM DOCS.** What the types permit is a structural fact about pass-through Anthropic types. Whether Claude Code's harness forwards a citations-enabled document to the Messages API unmodified — and whether it surfaces returned `char_location` objects to the host rather than flattening content to text — is runtime behavior that no document addresses. Reporting this as "yes" or as "no" would both be inference.

### 2b. Offset semantics — the load-bearing gap

**The Messages API documentation never states what unit `start_char_index` and `end_char_index` count.**

The complete specification the docs offer is two statements of *convention*, neither of which is a *unit* [5]:

> "For plain text documents: Citations include the character index range (0-indexed)."

> "Character indices are 0-indexed with exclusive end indices."

The word "character" is used without definition. That is the entirety of it.

**There is likewise no statement about Unicode normalization,** and no statement about which representation of the submitted text the offsets index against — the raw bytes as submitted, or some server-transformed copy.

The absence is credible because it survives named negative searches across five independent surfaces [5][8][9][13]:

| Surface | Method | Result |
|---|---|---|
| Citations guide (full page source) | `grep -i` for `utf`, `codepoint`, `code point`, `code unit`, `grapheme`, `unicode`, `normaliz`, `NFC`, `NFD` | **Zero matching lines each.** Separately, `byte` returns 6 matches and `encod` returns several — *all* inside SDK code samples reading a PDF off disk (`read_bytes()`, `ReadAllBytesAsync`, `byte[] pdfBytes`, `json_encode`/`base64_encode`). None defines an index unit. Independently re-run by a fresh-context verifier |
| Same file | `grep -i "char_index\|character"` | 8 hits, all reproduced above or inside JSON examples |
| `/v1/messages` API reference incl. expandable schema field descriptions | fetched, queried for field description text | `start_char_index`: constraint `minimum: 0` only. **`end_char_index`: no description at all.** Neither mentions any encoding concept |
| Python SDK generated type `CitationCharLocation` | raw source fetch | No docstrings, no comments on either field |
| API release notes (full history) | fetched, queried for encoding/normalization/offset entries | No entries relating to character location, character index offsets, or `char_location` |

A general web search surfaced no primary source. One answer-engine summary asserted the indices are "API-guaranteed to be computed by the system"; its only primary citation is the citations doc, which does not say that. Not cited, not relied on.

**Why the silence has teeth.** For a consumer, this is the difference between codepoint slicing, UTF-16 code-unit slicing (Swift's `String.Index` / `NSString`), and byte slicing. The three agree on ASCII and diverge on any non-BMP character — an emoji, many CJK extension characters — and on combining sequences. A transcript of spoken meetings is exactly the kind of text where such characters appear unpredictably.

**Adjacent facts that are documented,** and that are sometimes mistaken for an answer to this question:

- **Chunking is documented, and is a different thing.** "Document contents are 'chunked' to define the minimum granularity of possible citations... For plain text documents: Content is chunked into sentences that can be cited from." Custom content documents: "Your provided content blocks are used as-is and no further chunking is done." [5] Chunking sets the *minimum citable span*; it does not define the *unit of the index*. The docs never connect the two.
- **Location type varies by document source** [5]: plain text (inline or Files API `file_id`) → `char_location`; PDF (base64, URL, or `file_id`) → `page_location`, 1-indexed pages; custom content → `content_block_location`, 0-indexed block indices. Scanned PDFs are not citable at all: "As image citations are not yet supported, PDFs that are scans of documents and do not contain extractable text are not citable."
- **A seventh field exists in practice.** The doc example shows six fields on `char_location`; the Python SDK response model `CitationCharLocation` carries a seventh, `file_id: Optional[str]`, absent from both the doc example and the request-side param schema [13]. Minor, but it means the doc example is not an exhaustive field list.
- **Two location types are undocumented in the guide.** The API reference schema lists five: `char_location`, `page_location`, `content_block_location`, `search_result_location`, `web_search_result_location`. The guide's document-type table covers only the first three [8].

---

## 3. Structured output — CONFIRMED AVAILABLE

Verbatim from the shipped types [4]:

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

The host constrains the session's final output to a JSON schema and receives it **as data on the result message**, not by parsing conversational text. Python uses `output_format` on `ClaudeAgentOptions`; the result carries `structured_output` [12].

**Mechanism — worth knowing, because it is not the Messages API feature.** From a shipped comment [4]: "End-turn tool sessions (`outputFormat: {type: 'json_schema'}`, or any MCP tool using `_meta['claude/endTurn']`): a completed turn there ends on a successful tool_result carrier — with no trailing assistant message — followed by a `structured_output` attachment holding the turn's actual output (the carrier's data is a placeholder)." The session implements schema-constrained output as an **end-turn tool**, not by sending `output_config.format` to the Messages API. This distinction matters for question 2 and is taken up under Cross-cutting findings.

**CLI equivalent** [2]: "To get output conforming to a specific schema, use `--output-format json` with `--json-schema` and a JSON Schema definition. The response includes metadata about the request (session ID, usage, etc.) with the structured output in the `structured_output` field."

Two CLI behaviors are documented [2]:
- Invalid schema fails fast: "`claude` exits with `Error: --json-schema is not a valid JSON Schema` followed by the validator's diagnostic."
- `format` is annotation-only: "Claude Code accepts schemas that use the `format` keyword, such as `\"format\": \"email\"`, but treats `format` as an annotation and doesn't enforce it."

**For reference, the Messages API's own structured outputs** (a different mechanism, same goal) is `output_config.format` — GA on the Claude API since the 2026-01-29 release, no beta header; still public beta on Amazon Bedrock and Microsoft Foundry [6][9]. Its documented schema limitations: no recursive schemas, no complex types within enums, no external `$ref`, no numerical constraints (`minimum`/`maximum`/`multipleOf`), no string constraints (`minLength`/`maxLength`), no array constraints beyond `minItems` of 0 or 1, and `additionalProperties` must be `false` [6]. Whether the session's end-turn-tool implementation inherits the same limitations is **not documented**.

---

## 4. Prompt caching — CONFIRMED UNAVAILABLE (per-block control) / CONFIRMED AVAILABLE (observability)

### Per-block `cache_control` is not exposed. This is an exhaustive absence, not a search failure.

- `cache_control` and `cacheControl` appear **zero times** across all 9,368 lines of the shipped `sdk.d.ts` [4].
- No `systemPrompt` shape accepts a structured content-block array, so **there is no position at which a host could attach a breakpoint**. Verbatim [4]:

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

- The docs state the policy directly [1]: "The Agent SDK automatically uses prompt caching to reduce costs on repeated content. **You do not need to configure caching yourself.**"

### What host control does exist: TTL buckets

Two knobs, both TTL selectors, in two buckets [1][4]:

```typescript
promptCacheTtl?: '5m' | '1h';           // main conversation
subagentPromptCacheTtl?: '5m' | '1h';   // subagents, workflows, background and helper requests
```

Plus the `ENABLE_PROMPT_CACHING_1H` environment variable, which "asks for the 1-hour TTL on every request in both buckets"; the per-bucket controls take precedence [1]. The bucket split is documented: "Your own turns fall in the main conversation TTL bucket, together with the helpers Claude Code runs inline with them. The requests Claude Code makes outside that conversation, such as subagents, have a separate TTL control." [1]

One adjacent option bears on cache stability — `systemPromptSnapshot?: boolean` [4]: "Record the conversation's system prompt once and reuse it verbatim on every later request and resume. Omitted or true (the default): the prompt is rendered on the first request... and the record is sent as-is afterwards — even when a later launch passes different text — until compaction."

### Default TTL depends on the billing mode

"Cache entries for your own turns use a 5-minute TTL by default when you authenticate with an API key or run on Amazon Bedrock, Google Cloud's Agent Platform, Microsoft Foundry, or Claude Platform on AWS." Whereas "On a Claude subscription within your plan's included usage, you get the 1-hour TTL on your own turns... without setting this variable, and Claude Code drops those turns to the 5-minute TTL once you're drawing on usage credits." [1]

### Cache hits are observable — CONFIRMED AVAILABLE

`cacheReadInputTokens` and `cacheCreationInputTokens` on each `modelUsage` entry, and `cache_read_input_tokens` / `cache_creation_input_tokens` on the API-derived `usage` object at both per-step and per-call level [1][4].

### For reference: what the Messages API layer offers that the session layer does not

Directly, the Messages API exposes everything the session does not [7]:

- `"cache_control": {"type": "ephemeral"}`, optionally `"ttl": "1h"` (default `"5m"`), placed on individual blocks.
- Cacheable positions, verbatim: tool definitions in `tools`; content blocks in the `system` array; text messages in `messages.content` for user and assistant turns; **images & documents** in `messages.content` in user turns; tool_use and tool_result blocks.
- **A `document` block can carry `cache_control`** — confirmed twice. The caching page lists "Images & Documents" among cacheable blocks; the citations page states: "The citation blocks generated in responses cannot be cached directly, but the source documents they reference can be cached. To optimize performance, apply `cache_control` to your top-level document content blocks." [5][7]
- Maximum **4** breakpoints per request; a 5th returns 400 [7].
- Minimum cacheable prefix varies by model — 512 tokens (Fable 5.1, Mythos 5.1, Opus 5, Fable 5, Mythos 5); 1,024 (Opus 4.8, Sonnet 5, Sonnet 4.6, Sonnet 4.5, Opus 4.1, Opus 4, Sonnet 4); 2,048 (Mythos Preview, Opus 4.7, Haiku 3.5); 4,096 (Opus 4.6, Opus 4.5, Haiku 4.5) [7].
- **Silent failure below the minimum**, verbatim: "Shorter prompts cannot be cached, even if marked with `cache_control`. Any requests to cache fewer than this number of tokens will be processed without caching, **and no error is returned**." [7]
- Pricing multipliers: 5-minute write 1.25x base input and 1-hour write 2x, both stated unconditionally. Cache read is **not** stated flat — the page reads "Cache read tokens are 0.1 times the base input tokens price (see the table footnote for per-model exceptions)", and names 0.025x for Fable 5.1 and Mythos 5.1. Treat 0.1x as the default with per-model exceptions, not as a universal rate [7].
- Exceptions worth noting: "Thinking blocks cannot be cached directly with `cache_control`... **Sub-content blocks (like citations) themselves cannot be cached directly. Instead, cache the top-level block.** Empty text blocks cannot be cached." [7]
- Automatic caching shipped 2026-02-19: "Add a single `cache_control` field to your request body and the system automatically caches the last cacheable block, moving the cache point forward as conversations grow... Works alongside existing block-level cache control." [9]

---

## 5. Billing — CONFIRMED AVAILABLE (either; determined by credential precedence)

A programmatically driven session can be billed to **either** an Anthropic API key **or** a Claude subscription. Neither is required; the docs name the Agent SDK explicitly on both paths.

### The Agent SDK inherits the CLI's credential resolution — stated directly

> "`apiKeyHelper`, `ANTHROPIC_API_KEY`, and `ANTHROPIC_AUTH_TOKEN` apply to the CLI and the surfaces that wrap it, including the VS Code extension, **the Agent SDK**, and GitHub Actions." [3]

And on the subscription side:

> "Developers can log in from several paths: the terminal `/login` flow, the VS Code extension, **the Agent SDK**, `claude setup-token`, `/install-github-app`, and gateway sign-in..." [3]

### The precedence order, verbatim

"When multiple credentials are present, Claude Code chooses one in this order:" [3]

| # | Credential | Billed to |
|---|---|---|
| 1 | Cloud provider credentials, when `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, or `CLAUDE_CODE_USE_FOUNDRY` is set | The cloud provider's account |
| 2 | `ANTHROPIC_AUTH_TOKEN` — "Sent as the `Authorization: Bearer` header" | Whatever the LLM gateway/proxy bills to |
| 3 | `ANTHROPIC_API_KEY` — "Sent as the `X-Api-Key` header" | **Anthropic API workspace, pay-per-token** |
| 4 | `apiKeyHelper` script output | Pay-per-token (dynamic/rotating credential) |
| 5 | `CLAUDE_CODE_OAUTH_TOKEN` — "A long-lived OAuth token generated by `claude setup-token`" | **Claude subscription** |
| 6 | Anthropic profile and federation credentials | Depends on the profile's auth mode |
| 7 | Subscription OAuth from `/login` — "the default for Claude Pro, Max, Team, and Enterprise users" | **Claude subscription** |

### Three rules that decide it for an unattended host process

1. **An API key beats a subscription, silently, in `-p` mode.** "If you have an active Claude subscription but also have `ANTHROPIC_API_KEY` set in your environment, Claude Code uses the API key once you approve it." And decisively: "**In non-interactive mode (`-p`), the key is always used when present.**" [3]
2. **Subscription billing for an unattended process goes through `claude setup-token`.** "This token authenticates with your Claude subscription and requires a Pro, Max, Team, or Enterprise plan. It can only make model requests..." [3]
3. **`--bare` mode forecloses the subscription path entirely.** "Bare mode does not read `CLAUDE_CODE_OAUTH_TOKEN`. If your script passes `--bare`, authenticate with `ANTHROPIC_API_KEY` or an `apiKeyHelper` instead." [3] Corroborated on the headless page: "In bare mode, Claude Code never reads OAuth credentials or the system keychain." [2] This matters because the same page states: "**`--bare` is the recommended mode for scripted and SDK calls, and will become the default for `-p` in a future release.**" [2]

### What `total_cost_usd` means under a subscription

It remains a client-side estimate computed from a bundled price table, under both billing modes [1]. Under a subscription there is no per-token bill for it to estimate — usage is included in the plan — so the figure represents what the same tokens would have cost at API list price, not money owed. The docs' blanket instruction stands regardless of billing mode: "Do not bill end users or trigger financial decisions from these fields." [1]

### Third-party providers

Bedrock, Google Cloud's Agent Platform, and Microsoft Foundry are selected by environment variable and sit at precedence 1, outranking everything else; they bill to the cloud account [3]. A signed-in Claude apps gateway session sits outside the list entirely and outranks even those [3].

---

## Empirical findings (measured, not documented)

Two probes were built into this directory and run on 2026-09-16 against Claude Code CLI
**2.1.220**, model **`claude-fable-5`** (the session's own default — the host did not pin one).
Raw stream captures are in `evidence/`. **Everything in this section is an observation of
current behavior, not a documented guarantee.** Anthropic has published no contract for any of
it and could change it without a release note.

### [P1] Citations do reach the host — but not where a host would look

A session was driven via `claude -p --input-format stream-json`, fed an `SDKUserMessage` whose
`message.content` held a plain-text `document` block with `citations: {enabled: true}`.

**What arrived in the reassembled `assistant` messages:** the response was split into three text
blocks, and the middle one — the cited span — carried a `citations` key that the control run did
not have. The key was present. The array was **empty**:

```json
{"type": "text", "text": "exactly 1427 hertz", "citations": []}
```

Read alone, that looks like citations being stripped. It is not.

**What arrived in the raw stream, with `--include-partial-messages`:**

```json
{"type":"content_block_delta","index":2,
 "delta":{"type":"citations_delta",
          "citation":{"type":"char_location",
                      "cited_text":"The Auricle beacon transmits at exactly 1427 hertz. ",
                      "document_index":0,"document_title":"Beacon field log",
                      "start_char_index":53,"end_char_index":105}}}
```

The full `char_location` object is there. Claude Code's `content_block_start` opens the block
with `citations: []`, the payload arrives as a `citations_delta`, and the accumulated assistant
message is never updated to fold it in.

**The integration consequence, stated as fact:** a host that consumes `assistant` messages
receives citation-shaped blocks with no location data. A host that consumes `stream_event`
frames under `--include-partial-messages` and handles `citations_delta` receives complete
`char_location` objects. The two surfaces disagree, and only one carries the offsets.

### [P2] Offsets are Unicode codepoints, against the text as submitted

The probe document's prefix was built so all four candidate units predict different offsets.
Two requests, identical but for Unicode normalization of the prefix:

| | prefix predicts | | | | observed `start_char_index` | slice reproducing `cited_text` |
|---|---|---|---|---|---|---|
| | UTF-8 | UTF-16 | codepoints | graphemes | | |
| **A** — precomposed (already NFC) | 69 | 56 | **53** | 50 | **53** | `codepoints` — sole match |
| **B** — decomposed (NFD sequences) | 73 | 60 | **57** | 50 | **57** | `codepoints` — sole match |

The decisive test was not the arithmetic. For each candidate the probe sliced the submitted
string at `[start:end)` and compared against the server's own `cited_text`. Under `codepoints`
the slice reproduced it exactly; under the other three it returned visibly misaligned text
(`'a̩a̩ station. The Auricle beacon...'` for UTF-8 bytes, `'n. The Auricle beacon...'` for UTF-16
code units). Exactly one unit matched, in both runs.

**Normalization:** request B's offsets matched the **as-submitted** document (`57`) and not the
NFC-normalized one (`53`). Slicing B's offsets against an NFC-normalized copy matched *nothing*.
The server indexes the bytes it was given; it does not normalize first.

**Against the canonicalization invariant.** architecture.md:1417-1426 specifies "UTF-8 byte
offsets into the NFC-normalized representation" and flags it for verification at implementation
time. The measurement says the API returns **codepoint** offsets against the text **as
submitted**. Both axes of that invariant differ from what was observed. Stated as a fact, not a
recommendation — the invariant's own escape hatch anticipated exactly this, since it provides
for "a translation step in `CanonicalTranscript` that exposes the same offset semantics
Anthropic returns."

For a Swift host this is the difference that matters: Swift's `String.Index` is neither of
these, `NSString`/`utf16` offsets would be wrong by 3 in this document, and `utf8` offsets wrong
by 16.

### [P3] Version-gated usage fields, confirmed by their absence

CLI 2.1.220's `result.modelUsage` entry for `claude-fable-5` carried exactly:

```
cacheCreationInputTokens, cacheReadInputTokens, canonicalModel, contextWindow,
costUSD, inputTokens, maxOutputTokens, outputTokens, provider, webSearchRequests
```

`thinkingTokens` and `costBasis` were **absent** — corroborating both version gates read out of
the shipped `.d.ts`: `costBasis` "requires Claude Code v2.1.246 or later", and `thinkingTokens`
"counts only turns run on CLI versions that record this field: absent when none did." This CLI
is 2.1.220, below both. The other ten fields match the declared type exactly.

### [P4] The empty `citations: []` is a deliberate no-op in Claude Code's accumulator

Open question #7 asked whether the emptied array is intentional or a defect. The shipped
executable answers it. Claude Code 2.1.220 ships as a bun-compiled Mach-O binary with its JS
embedded; `strings -a` over it surfaces two distinct stream accumulators.

**The bundled Anthropic SDK accumulator handles citations correctly:**

```js
case "citations_delta": {
  if (n?.type === "text")
    r.content[t.index] = { ...n, citations: [...(n.citations ?? []), t.delta.citation] };
  break;
}
```

**Claude Code's own accumulator — the one that raises `tengu_streaming_error` telemetry on
unexpected block types — explicitly matches the case and does nothing:**

```js
switch (bi.type) {
  case "citations_delta": break;
  case "input_json_delta": if (kn.type !== "tool_use" && kn.type !== "server_tool_use") throw M("tengu_streaming_e...
```

`case "citations_delta": break;` is an explicit empty case, not an unhandled default. The delta
type is recognized — which is why no error is raised — and its payload is deliberately discarded
rather than folded into the accumulating block. That is why the assistant message shows the
`citations` key (it came from `content_block_start`) with an empty array.

**Consequence:** this is settled behavior of the harness, not a transient bug likely to be fixed
by accident. A host wanting citation offsets must read `citations_delta` stream events itself.
Whether Anthropic intends to change it is not knowable from the artifact.

**Separately:** `citations_delta` is **not documented on the Messages API streaming page** either
— a full-text search of that page returns zero matches for "citation", while it documents
`text_delta`, `input_json_delta`, `thinking_delta` and `signature_delta` [14]. So the one surface
that does carry the offsets is itself undocumented.

### [P5] A session gets structured output AND citations in one call — the direct API cannot

The Messages API documents these as mutually exclusive, with a 400 [5]. A session was given a
citations-enabled document block *and* `--json-schema` in the same invocation. It returned both,
with no error:

```json
structured_output: {"frequency_hz": 1427,
                    "source_quote": "The Auricle beacon transmits at exactly 1427 hertz."}
citations_delta:   {"type": "char_location", "start_char_index": 53, "end_char_index": 105}
```

The offsets are identical to [P2], so the citation machinery is unchanged. The explanation is the
mechanism difference already read out of the shipped `.d.ts`: a session implements schema output
as an **end-turn tool**, not as `output_config.format`, and the documented incompatibility is
specific to `output_config.format`. The constraint is real at the layer where it is documented,
and does not transfer to the layer above it.

**This is a capability the direct-call path does not have.** Not a recommendation — a difference
in what the two paths can express.

### [P6] All three location types traverse a session

[P1]/[P2] exercised plain text only. PDF and custom-content documents were then sent the same way:

| document source | location type returned | payload |
|---|---|---|
| `{"type":"text","media_type":"text/plain"}` | `char_location` | `start_char_index` / `end_char_index`, codepoints [P2] |
| `{"type":"base64","media_type":"application/pdf"}` | `page_location` | `start_page_number: 1`, `end_page_number: 2` — 1-indexed, as documented |
| `{"type":"content","content":[...]}` | `content_block_location` | `start_block_index: 1`, `end_block_index: 2` — 0-indexed, exclusive end |

Two details worth recording:

- **The PDF's `cited_text` did not byte-match the source text.** It came back as
  `'The Auricle beacon transmits at exactly 1427 hertz.\r\n'` — CRLF introduced by the PDF text
  layer. PDFs carry no character offsets at all, only page numbers, so a host cannot resolve a
  PDF citation to a span without its own search, and that search would have to tolerate the text
  layer's own line handling.
- **Custom content sidesteps character offsets entirely.** Sending three content blocks
  (`PREFIX`, `TARGET`, `TAIL`) returned `start_block_index: 1` — pointing at exactly the
  `TARGET` block. No encoding question arises, because no character index is involved. Stated as
  a fact about the API surface; what to do with it is a design decision this document does not
  make.

### [P7] The session's structured output does not inherit the Messages API's schema limitations

The Messages API documents several unsupported schema features, including string constraints
(`minLength`/`maxLength`) and recursive schemas [6]. Both were sent to a session:

| feature | documented at the Messages API | observed through a session |
|---|---|---|
| `minLength: 40` | unsupported | **respected** — asked for `"x"`, received `"x"` padded to exactly 40 characters |
| recursive `$ref` (`#/$defs/node`) | unsupported | **accepted** — returned `{"node":{"name":"root","child":{"name":"leaf"}}}` |

Consistent with [P5]: the session's end-turn-tool mechanism is not `output_config.format` and does
not carry its restrictions. **What is not determined** is *how* `minLength` is satisfied — a
constrained decoder and a retry loop would both produce a conforming value. The first attempt
returned `error_max_turns` under `--max-turns 1` and succeeded at 5, which is consistent with
retries but does not prove them. Recorded as an open mechanism, not a claim.

### Scope of these measurements

- One CLI version (2.1.220), one model (`claude-fable-5`), one day. All three document source
  types are now covered [P6]; what is not covered is any other model, any other CLI version, and
  the direct Messages API path.
- The probes are reproducible: `session_citation_probe.py` and `citation_offset_probe.py`,
  sharing `probe_common.py`. Re-run them on the staleness schedule below.
- `citation_offset_probe.py` — the direct Messages API path — has **still not been run**; it
  needs `ANTHROPIC_API_KEY`. [P2] was obtained through the session instead, so the direct path
  remains unconfirmed, though there is no reason to expect it to differ.

---

## Cross-cutting findings

These are the things only the combination shows.

**1. Citations and structured outputs are documented as mutually exclusive at the Messages API layer — a 400 error.** From a Warning callout titled "Citations and structured outputs are incompatible" [5]:

> "Citations cannot be used together with structured outputs. If you enable citations on any user-provided document (`document` blocks or `search_result` blocks) and also include the `output_config.format` parameter (or the deprecated `output_format` parameter), the API returns a **400 error**."

> "This is because citations require interleaving citation blocks with text output, which is incompatible with the strict JSON schema constraints of structured outputs."

**Measured correction [P5]: this constraint does not reach the session layer.** A session given a citations-enabled document and `--json-schema` returned both, no 400. The documented incompatibility is specific to `output_config.format`; a session uses an end-turn tool instead. So the constraint is real where it is documented and simply absent one layer up — which inverts what it implies for the two paths. The documentation is also stated in exactly one direction: the warning appears only on the citations page. An explicit search of the structured-outputs page for any mention of citations, document blocks, or `search_result` blocks found none [6]. A team reading only the structured-outputs page would not learn it.

**Scope note, stated carefully.** The documented 400 is specific to `output_config.format` (or deprecated `output_format`) combined with citations. It does **not** say that asking for JSON *by prompt instruction* alongside citations fails — that is a different mechanism and the docs are silent on it. Separately, the session's `outputFormat` is implemented as an end-turn tool rather than as `output_config.format` [4], so whether a session hits this same 400 is **not determined by the quoted statement**. Both of those were open questions; **both are now measured** — [P5] for the session's `outputFormat`, and the prompt-instruction variant remains untested and undocumented.

**2. Every telemetry field the summarize stage records is obtainable from a session — but `cost_usd` changes meaning.** `model_id`, `input_tokens`, `output_tokens`, and `thinking_tokens` all have exact counterparts. `cost_usd` does not: from the Messages API it would be computed by the caller from token counts and known rates; from a session it arrives pre-computed as a client-side estimate from a price table bundled at SDK build time, which the docs explicitly warn may not recognize a newer model (`costBasis: "unknown"`, in which case "costUSD is a guess at the default model's rate") [4].

**3. The caching finding and the cost-ceiling constraint pull in opposite directions.** Per-block `cache_control` is confirmed unavailable through a session, and a session's own caching is automatic and opaque. The caching approach described at architecture.md:1430-1441 — distinct cache tiers for system prompt, glossary, and attendee context, with the transcript deliberately uncached — depends on placing breakpoints on specific blocks. Four breakpoints per request exist at the Messages API layer [7]; zero are exposed at the session layer [4]. This is a factual gap between the two layers, stated here without a recommendation about it.

**4. The citations question resolved in opposite directions at the two layers — and the measurement, not the documentation, is what separated them.** The documentation gap is real and unchanged: Anthropic states no offset contract. But the behavior is now measured on both halves — citations do traverse a session [P1], and offsets are codepoints against the submitted text [P2]. What remains is that a host would be building on observed behavior rather than a published guarantee, on a surface (`citations_delta` stream events) that the reassembled message surface contradicts. That is a different kind of risk from "unknown", and it is the one to carry into the roundtable.

---

## Where each finding lands against the stated constraints

Factual mapping only. No recommendation is offered or implied.

| Constraint | What it needs | What the evidence says |
|---|---|---|
| architecture.md:1233 — summarize telemetry records `model_id`, `input_tokens`, `output_tokens`, `thinking_tokens`, `cost_usd` | Five fields per call | All five have session counterparts. `thinking_tokens` → `thinkingTokens`, optional and CLI-version-dependent. `cost_usd` → `costUSD`, a client-side estimate the docs say not to base financial decisions on. |
| architecture.md:1356-1362 — `ClaudeCitationsSummarizer` built on `CitationCharLocation` offsets | Citations reaching the host, with known offset semantics | **Measured available [P1]** — but only off `citations_delta` stream events; the assistant-message surface returns `citations: []`. Offset semantics **measured as codepoints [P2]**. Both are observations, not documented contracts. |
| architecture.md:1417-1426 — canonicalization invariant, UTF-8 byte offsets into NFC-normalized text | A documented offset contract to verify against | No contract is published. **Measured behavior differs from the invariant on both axes [P2]:** codepoints, not UTF-8 bytes; text as submitted, not NFC-normalized. The invariant's own translation-step escape hatch anticipated this. |
| architecture.md:1430-1441 (Decision 3.5) — `cache_control` tiering across system prompt / glossary / attendee context | Per-block breakpoint placement | Messages API: available, 4 breakpoints, documents cacheable. Session: CONFIRMED UNAVAILABLE — zero `cache_control` occurrences, no `systemPrompt` shape accepting blocks. TTL-bucket control only. |
| architecture.md:1356-1362 — structured JSON items each carrying a citations array | Schema-constrained output and citations together | **Measured available through a session [P5]; returns 400 on the direct Messages API [5].** The two paths differ on exactly this combination. |
| prd.md:705 (NFR-C1) — per-meeting cost ceiling, ≤$0.50 default | A cost figure to enforce against | A session provides `total_cost_usd` and a `maxBudgetUsd` enforcement option. Both rest on the same client-side estimate the docs warn against using for financial decisions; the authoritative alternative named by the docs is the Usage and Cost API, which is out-of-band and after the fact. |

---

## Open questions

What this research could not answer, and what it would take.

1. ~~**Does a Claude Code session forward a citations-enabled document block and surface `char_location` back?**~~ **ANSWERED [P1]** — yes, but only via `citations_delta` stream events under `--include-partial-messages`; the reassembled `assistant` message carries an empty `citations: []`. Reproducible with `session_citation_probe.py`.
2. ~~**What unit are `start_char_index` / `end_char_index`?**~~ **ANSWERED [P2]** — Unicode codepoints. Sole matching unit on two inputs with differing predictions. Still undocumented, so this is observed behavior rather than a contract; re-verify on the staleness schedule.
3. ~~**Does the server index the submitted bytes, or a normalized copy?**~~ **ANSWERED [P2]** — the text as submitted. The NFD request's offsets matched the as-submitted document and matched nothing at all against an NFC-normalized copy.
4. ~~**Does a session's `outputFormat` hit the same citations 400?**~~ **ANSWERED [P5]** — no. Both came back in one call with no error. The documented incompatibility is specific to `output_config.format` and does not reach the session layer.
5. ~~**Does the session's structured output inherit the Messages API's schema limitations?**~~ **ANSWERED [P7]** — not for the two tested: `minLength` was respected and a recursive `$ref` was accepted. The *mechanism* (constrained decoding vs retry) is undetermined and is the residual question.
6. **What is the npm-published version history?** The npm web page returned 403 to automated fetch; the version was obtained from the registry API instead [4]. Not a gap that affects any verdict.
7. ~~**Is the empty `citations: []` intentional or a defect?**~~ **ANSWERED [P4]** — a deliberate no-op. Claude Code's own accumulator carries an explicit `case "citations_delta": break;`, while the Anthropic SDK accumulator bundled beside it folds the payload in correctly. Settled harness behavior, not an accident. Whether Anthropic intends to change it remains unknowable from the artifact.
8. ~~**Do `page_location` and `content_block_location` traverse a session?**~~ **ANSWERED [P6]** — all three types traverse. PDFs carry page numbers only and their `cited_text` did not byte-match the source (CRLF from the text layer); custom content returns block indices and involves no character offsets at all.
9. **Does the direct Messages API path agree with [P2]?** `citation_offset_probe.py` is built but unrun — it needs `ANTHROPIC_API_KEY`. No reason to expect divergence; unconfirmed all the same.
10. **How is `minLength` satisfied — constrained decoding or a retry loop?** [P7] shows a conforming value; it does not show the mechanism. It matters for cost and latency: retries are billable turns. Distinguishable by counting `num_turns` across schemas of increasing difficulty.
11. **Does the prompt-instruction route to JSON coexist with citations on the direct API?** The documented 400 covers `output_config.format` only. Untested, undocumented.
12. **`search_result_location` and `web_search_result_location`** appear in the API reference schema but not in the citations guide's document-type table [8]. Out of scope here; flagged if tool-result citations ever matter.

---

## Method note

Three researchers ran behind the research firewall, plus first-hand lead fetches. Two subagent findings were **overturned** by the lead against more primary sources, and the corrections are recorded rather than quietly absorbed:

- One assistant reported the Agent SDK input as "a prompt string only," concluding citations were impossible. The shipped type declares `message: MessageParam`. **Overturned.**
- One assistant reported that no thinking-token field exists and that `ModelUsage` carries no cost or model id. The shipped type declares `thinkingTokens`, `costUSD`, `canonicalModel`, `provider`, `contextWindow`, and `maxOutputTokens`. **Overturned.** That assistant's `SDKResultMessage` extraction was in fact the tool-result content block type; its digest is retained at `digests/type-reference-r2-1-LOW-RELIABILITY.md` with the failures annotated.

The lesson is recorded because it shaped the method: **rendered documentation pages do not contain literal type declarations** [11], and an assistant asked to quote types from them will produce something type-shaped. The authoritative move was to pull the published package from the registry and read the shipped `.d.ts` directly. Every type-level verdict in this document rests on that file, not on a doc page's prose.

A fresh-context verifier then re-checked the six load-bearing quoted claims the lead had not
verified first-hand, against their named sources. **All six returned VERIFIED.** Two precision
corrections came out of it and are applied above: the cache-read multiplier is qualified per-model
in the source rather than flat, and the `byte` search term does return matches in the citations
guide — all of them inside SDK code samples, none defining an index unit. The offset-unit absence
claim was independently re-run and holds.

One further distinction was enforced throughout: an UNVERIFIABLE returned by an assistant that exhausted its budget is **not** the same finding as an UNVERIFIABLE returned after an exhaustive named search. Only the latter appears in the verdict table. Question 2b qualifies on that standard — five surfaces, nine search terms, named negative results.

---

## Source appendix

| [n] | Supports | Publisher | Pub date | Accessed | Confidence |
|---|---|---|---|---|---|
| [1] | Usage granularity, per-step placeholder, `modelUsage`, cost-estimate warnings, cache TTL controls, `maxBudgetUsd` | [code.claude.com — Track cost and usage](https://code.claude.com/docs/en/agent-sdk/cost-tracking) | none shown; refs SDK TS v0.3.239 / Py v0.2.144 | 2026-09-16 | high |
| [2] | CLI `--output-format json`/`stream-json`, `--json-schema`, `system/init`, bare mode | [code.claude.com — Run Claude Code programmatically](https://code.claude.com/docs/en/headless) | none shown; refs CC v2.1.265 | 2026-09-16 | high |
| [3] | Credential precedence, Agent SDK named on both paths, `claude setup-token`, `-p` key precedence | [code.claude.com — Authentication](https://code.claude.com/docs/en/authentication) | none shown; refs CC v2.1.265 | 2026-09-16 | high |
| [4] | All literal type declarations: `ModelUsage`, `NonNullableUsage`, `SDKResultMessage`, `SDKUserMessage`, `SDKAssistantMessage`, `Options`, `OutputFormat`; the zero-occurrence `cache_control` and citations searches | [npm — @anthropic-ai/claude-agent-sdk](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) v0.3.274, shipped `sdk.d.ts` + `sdk-tools.d.ts` | registry modified 2026-09-17T00:12:14Z | 2026-09-16 | high — published package artifact |
| [5] | `char_location` shape, 0-indexed/exclusive convention, chunking, location type by source, scanned-PDF exclusion, citations↔structured-outputs 400, document cacheability | [platform.claude.com — Citations](https://platform.claude.com/docs/en/build-with-claude/citations) | none shown | 2026-09-16 | high |
| [6] | `output_config.format` current shape, `messages.parse()`, schema limitations, absence of any citations mention | [platform.claude.com — Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) | none shown | 2026-09-16 | high |
| [7] | `cache_control` syntax and allowed positions, 4-breakpoint cap, per-model minimum prefix, silent sub-minimum failure, pricing multipliers, block exceptions | [platform.claude.com — Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) | none shown | 2026-09-16 | high |
| [8] | `start_char_index` `minimum: 0` and `end_char_index` having no description; five location types in schema | [platform.claude.com — Messages API reference](https://platform.claude.com/docs/en/api/messages) | none shown | 2026-09-16 | high |
| [9] | Structured outputs GA 2026-01-29; automatic caching 2026-02-19; no offset/encoding entries in full history | [platform.claude.com — API release notes](https://platform.claude.com/docs/en/release-notes/api) | dated entries | 2026-09-16 | high |
| [10] | Python SDK version | [PyPI — claude-agent-sdk](https://pypi.org/project/claude-agent-sdk/) 0.2.153 | 2026-09-15 | 2026-09-16 | high — package registry |
| [11] | `outputFormat` option shape; confirmation that the page carries no literal type declarations | [code.claude.com — TypeScript Agent SDK reference](https://code.claude.com/docs/en/agent-sdk/typescript) | none shown | 2026-09-16 | medium — page is tabular, not declarative |
| [12] | Agent SDK structured outputs option and `structured_output` result field | [code.claude.com — Agent SDK structured outputs](https://code.claude.com/docs/en/agent-sdk/structured-outputs) | none shown | 2026-09-16 | high |
| [P1] | Citations traverse a session only as `citations_delta` stream events; assistant message carries `citations: []` | Own measurement — `session_citation_probe.py` + `evidence/session-stream-nfc.jsonl` | run 2026-09-16, CLI 2.1.220, `claude-fable-5` | 2026-09-16 | high — direct observation, raw capture archived |
| [P2] | Offsets are Unicode codepoints against the text as submitted; no server-side normalization | Own measurement — `evidence/session-stream-nfc.jsonl` + `evidence/session-stream-nfd.jsonl` | run 2026-09-16 | 2026-09-16 | high — sole matching unit on two differing inputs |
| [P3] | CLI 2.1.220 `modelUsage` omits `thinkingTokens` and `costBasis`, confirming both version gates | Own measurement — `evidence/session_citation_probe_result.json` | run 2026-09-16 | 2026-09-16 | high |
| [P4] | `case "citations_delta": break;` in Claude Code's own accumulator vs correct accumulation in the bundled SDK | Own measurement — `strings -a` over the shipped binary at `~/.local/share/claude/versions/2.1.220` | binary dated 2026-07-29 | 2026-09-16 | high — shipped executable |
| [14] | Messages API streaming page documents `text_delta`, `input_json_delta`, `thinking_delta`, `signature_delta` and **no** `citations_delta` | [platform.claude.com — Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming) | none shown | 2026-09-16 | high — full-text search, zero matches for "citation" |
| [P5] | Session returned `structured_output` and `char_location` citations in one call, no 400 | Own measurement — `capability_probes.py` E1, `evidence/capability_probes_result.json` | run 2026-09-16 | 2026-09-16 | high |
| [P6] | All three location types traverse a session; PDF `cited_text` carries CRLF; custom content returns block indices | Own measurement — `capability_probes.py` E2 | run 2026-09-16 | 2026-09-16 | high |
| [P7] | `minLength` respected and recursive `$ref` accepted through a session, both documented unsupported on the Messages API | Own measurement — `capability_probes.py` E3 | run 2026-09-16 | 2026-09-16 | medium-high — outcome clear, mechanism undetermined |
| [13] | `CitationCharLocation` response model carrying `file_id`; no field docstrings | [github.com/anthropics/anthropic-sdk-python — citation_char_location.py](https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/src/anthropic/types/citation_char_location.py) | main branch | 2026-09-16 | high — generated from schema |

**Host note:** `docs.claude.com` 302-redirects to `platform.claude.com`. Verified: `https://docs.claude.com/en/docs/build-with-claude/citations` → 302 → `https://platform.claude.com/docs/en/build-with-claude/citations`. Claude Code documentation lives on `code.claude.com`; Claude API documentation on `platform.claude.com`. Both hosts are canonical for their respective products.

---

## Staleness map

Per the technical pack's freshness bars, mapped to this run's claim classes.

| Claim class | Bar | Claims | Re-check by |
|---|---|---|---|
| Version & compatibility | ≤ 1 month | SDK version 0.3.274 / PyPI 0.2.153; `thinkingTokens` CLI-version dependency; `costBasis` requiring v2.1.246+ | **2026-10-16** |
| Capability surface (AI-adjacent landscape) | ≤ 3 months | All five verdicts; the citations↔structured-outputs 400; per-model cache minimums and pricing multipliers | **2026-12-16** |
| Ecosystem signals | ≤ 6 months | Credential precedence order; bare mode becoming the `-p` default | 2027-03-16 |

| **Measured behavior (undocumented)** | **≤ 1 month** | **[P1]–[P7]: stream-delta-only citations, codepoint offsets, session/API divergence on structured-output+citations and on schema limits** | **2026-10-16** |

**Earliest re-check: 2026-10-16.** The SDK shipped a new version the day this ran (registry-modified 2026-09-17T00:12Z), and three findings are explicitly version-gated — `thinkingTokens` records "only turns run on CLI versions that record this field," `costBasis` requires v2.1.246+, and bare mode "will become the default for `-p` in a future release." A Refresh against `sdk.d.ts` at the then-current version is the work order; it is one `npm pack` and four greps.

[P1] and [P2] age fastest of anything here, precisely because they are undocumented: behavior with no published contract can change without a release note, and nothing would announce it. Both probes are checked in and rerunnable in under a minute — `session_citation_probe.py` for the pass-through, plus the `--include-partial-messages` capture for the offsets. The documentation gap itself resolves only if Anthropic publishes an offset contract.
