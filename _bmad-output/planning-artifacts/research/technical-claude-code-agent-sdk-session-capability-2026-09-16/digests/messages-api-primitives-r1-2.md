# Digest: Messages API primitives — round 1, assistant 2

Assistant: general-purpose researcher. Budget: 14 tool calls, 7 distinct sources. Accessed 2026-09-16.
Reliability: HIGH. Method was explicit and auditable (full-text grep of a locally saved 74KB doc across
9 encoding-related search terms, plus the API reference schema, plus the SDK's generated type, plus
release notes). Absence claims are corroborated by named negative searches, not by budget exhaustion.

**Canonical host note:** `docs.claude.com` 302-redirects to `platform.claude.com`. Verified:
`https://docs.claude.com/en/docs/build-with-claude/citations` -> 302 -> `https://platform.claude.com/docs/en/build-with-claude/citations`.

## Citations

| # | Claim | Source | Confidence |
|---|---|---|---|
| M1 | `char_location` doc shape: `{type, cited_text, document_index, document_title, start_char_index, end_char_index}`. | platform.claude.com/docs/en/build-with-claude/citations | high |
| M2 | The Python SDK response model `CitationCharLocation` carries a seventh field, `file_id: Optional[str]`, absent from both the doc example and the request-side `CitationCharLocationParam`. | anthropic-sdk-python citation_char_location.py | high |
| M3 | **The docs never state what unit `start_char_index`/`end_char_index` count.** Not bytes, not UTF-8, not UTF-16 code units, not codepoints, not graphemes. | see negative-search table below | high (absence) |
| M4 | The only index statements the docs make are conventions, not units: "For plain text documents: Citations include the character index range (0-indexed)." and "Character indices are 0-indexed with exclusive end indices." The word "character" is used without definition. | citations guide | high (direct quote) |
| M5 | **The docs never mention Unicode normalization** (NFC/NFD) or state which representation of the submitted text offsets index against. `normaliz` returns zero hits across the full citations guide; release notes carry no such entry. | citations guide, release notes | high (absence) |
| M6 | `end_char_index` has **no description at all** in the `/v1/messages` API reference schema. `start_char_index` carries only the constraint `minimum: 0`. | platform.claude.com/docs/en/api/messages | high |
| M7 | Chunking IS documented and is decoupled from the offset-unit question: "Document contents are 'chunked' to define the minimum granularity of possible citations... For plain text documents: Content is chunked into sentences that can be cited from." Custom content: "Your provided content blocks are used as-is and no further chunking is done." | citations guide | high (direct quote) |
| M8 | Location type by source: plain text -> `char_location`; PDF (base64, URL, or file_id) -> `page_location` (1-indexed pages); custom content -> `content_block_location`. Plain text via Files API `file_id` also yields `char_location`. | citations guide | high |
| M9 | Scanned PDFs are not citable: "As image citations are not yet supported, PDFs that are scans of documents and do not contain extractable text are not citable." | citations guide | high (direct quote) |
| M10 | The API reference schema lists five location types, two of which the document-type table omits: `search_result_location` and `web_search_result_location`. | platform.claude.com/docs/en/api/messages | high |
| M11 | Citations must be enabled on all or none of the documents in a request. `title` and `context` are passed to the model but are not citable. | citations guide | high |
| M12 | Enabling citations increases input tokens: "Enabling citations incurs a slight increase in input tokens because of system prompt additions and document chunking." | citations guide | high (direct quote) |

### Negative-search table supporting M3 and M5

| Surface | Method | Result |
|---|---|---|
| Citations guide (full 74KB markdown saved locally) | grep -i for `utf`, `byte`, `codepoint`, `code point`, `code unit`, `grapheme`, `unicode`, `normaliz`, `encod` | Zero hits in prose. Only `encod` hits are `json_encode`/`base64_encode` in sample code. |
| Same file | grep -i `char_index\|character` | 8 hits, all reproduced in M4 or in JSON examples |
| `/v1/messages` API reference incl. expandable schema field descriptions | fetched, queried for field description text | `start_char_index`: `minimum: 0` only. `end_char_index`: no description. Neither mentions any encoding concept. |
| Python SDK generated type | raw source fetch | No docstrings or comments on either field |
| API release notes (full history) | fetched, queried for encoding/unicode/normalization/offset entries | No entries relating to character location, character index offsets, or `char_location` |
| General web search | `start_char_index unicode encoding Anthropic citations` | No primary source. An answer-engine summary asserted indices are "API-guaranteed to be computed by the system"; chased, its only primary citation is the citations doc, which does not say that. Not cited, not relied on. |

## Structured outputs

| # | Claim | Source | Confidence |
|---|---|---|---|
| M13 | Current parameter is `output_config.format` with `{type: "json_schema", schema: {...}}`. The older top-level `output_format` is deprecated: "The `output_format` parameter has moved to `output_config.format`, and beta headers are no longer required." | structured-outputs guide; /api/messages | high (direct quote) |
| M14 | **CONFIRMED INCOMPATIBLE — citations and structured outputs cannot be combined.** Verbatim from a Warning callout titled "Citations and structured outputs are incompatible": "Citations cannot be used together with structured outputs. If you enable citations on any user-provided document (`document` blocks or `search_result` blocks) and also include the `output_config.format` parameter (or the deprecated `output_format` parameter), the API returns a **400 error**." Reason given: "This is because citations require interleaving citation blocks with text output, which is incompatible with the strict JSON schema constraints of structured outputs." | citations guide | high (direct quote) |
| M15 | Documentation asymmetry: the incompatibility warning appears ONLY on the citations page. An explicit search of the structured-outputs page for citations / document blocks / search_result blocks found none. | both pages | high |
| M16 | Structured outputs are GA on the Claude API — no beta header — since the 2026-01-29 release note. Still public beta on Amazon Bedrock and Microsoft Foundry. | release-notes/api | high |
| M17 | `client.messages.parse()` exists. Python takes `output_format=<model class>`; TypeScript takes `output_config: {format: zodOutputFormat(...)}` and reads `response.parsed_output`. Cross-SDK naming differs. | structured-outputs guide | medium-high |
| M18 | Documented schema limitations: recursive schemas; complex types within enums; external `$ref`; numerical constraints (`minimum`, `maximum`, `multipleOf`); string constraints (`minLength`, `maxLength`); array constraints beyond `minItems` of 0 or 1; `additionalProperties` set to anything other than `false`. | structured-outputs guide | high |

## Prompt caching

| # | Claim | Source | Confidence |
|---|---|---|---|
| M19 | Syntax: `"cache_control": {"type": "ephemeral"}`, optionally `"ttl": "1h"`. Default TTL `"5m"`. API reference: "Create a cache control breakpoint at this content block." | prompt-caching guide; /api/messages | high |
| M20 | Cacheable positions, verbatim: tool definitions in `tools`; content blocks in the `system` array; text messages in `messages.content` for user and assistant turns; **images & documents** in `messages.content` in user turns; tool_use and tool_result blocks. | prompt-caching guide | high (direct quote) |
| M21 | Exceptions, verbatim: "Thinking blocks cannot be cached directly with `cache_control`... **Sub-content blocks (like citations) themselves cannot be cached directly. Instead, cache the top-level block.** Empty text blocks cannot be cached." | prompt-caching guide | high (direct quote) |
| M22 | Maximum 4 cache breakpoints per request. A 5th returns 400: "If 4 explicit block-level breakpoints already exist, the API returns a 400 error (no slots left for automatic caching)." | prompt-caching guide | high |
| M23 | Minimum cacheable prefix varies by model: 512 tokens (Fable 5.1, Mythos 5.1, Opus 5, Fable 5, Mythos 5); 1,024 (Opus 4.8, Sonnet 5, Sonnet 4.6, Sonnet 4.5, Opus 4.1, Opus 4, Sonnet 4); 2,048 (Mythos Preview, Opus 4.7, Haiku 3.5); 4,096 (Opus 4.6, Opus 4.5, Haiku 4.5). | prompt-caching guide | high |
| M24 | **Silent failure below the minimum**, verbatim: "Shorter prompts cannot be cached, even if marked with `cache_control`. Any requests to cache fewer than this number of tokens will be processed without caching, and no error is returned." | prompt-caching guide | high (direct quote) |
| M25 | Usage fields: `cache_creation_input_tokens` ("tokens written to the cache when creating a new entry"), `cache_read_input_tokens` ("tokens retrieved from the cache for this request"), and `input_tokens` ("tokens which were not read from or used to create a cache"). Mixed-TTL breakdown available as `cache_creation: {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`. | prompt-caching guide | high |
| M26 | Pricing multipliers: 5-minute cache write 1.25x base input; 1-hour cache write 2x; cache read 0.1x. Exception: "Cache hits and refreshes on Claude Fable 5.1 and Claude Mythos 5.1 are priced at 0.025x the base input price." | prompt-caching guide | high |
| M27 | **A `document` content block CAN carry `cache_control`** — two independent confirmations. Prompt-caching page lists "Images & Documents" among cacheable blocks; citations page states: "The citation blocks generated in responses cannot be cached directly, but the source documents they reference can be cached. To optimize performance, apply `cache_control` to your top-level document content blocks." | prompt-caching + citations guides | high (direct quote x2) |
| M28 | Automatic caching shipped for the Messages API on 2026-02-19: "Add a single `cache_control` field to your request body and the system automatically caches the last cacheable block, moving the cache point forward as conversations grow... Works alongside existing block-level cache control." | release-notes/api | high |
| M29 | "Citations work in conjunction with other API features including prompt caching, token counting, and batch processing." | citations guide | high (direct quote) |

## Leads worth chasing (assistant's own list, retained)

1. The offset unit is an empirical test task, not a research task: submit a plain-text document containing a non-BMP character (e.g. U+1F600) and a combining sequence (`e` + U+0301) before the cited span, then compare the returned `start_char_index` against codepoint slicing, UTF-16 code-unit slicing, and byte offsets. One request settles it.
2. Test normalization in the same request: submit NFD-composed text and check whether `cited_text` round-trips byte-identically against the submitted bytes at the returned offsets.
3. `search_result_location` / `web_search_result_location` are in the schema but absent from the citations guide's table.
4. Custom content documents appear inline-only; no `file_id` variant found.
5. Structured outputs remain beta on Bedrock/Foundry; re-verify per platform if deployment is not direct-to-Claude-API.

## What the assistant looked for and could not find

- Any statement of the encoding unit for `start_char_index`/`end_char_index` (5 surfaces searched, listed above).
- Any statement about server-side Unicode normalization.
- Any statement about which representation offsets index against.
- A publicly published OpenAPI/JSON schema document for the Messages API.
- Any mention of citations on the structured outputs page.
- `file_id` / Files API support for custom content (`{"type":"content"}`) documents.
