---
title: 'Story 3.10: GoogleCalendarSource + OAuth PKCE + Keychain Refresh-Token + EventMatcher'
type: 'feature'
created: '2026-09-18'
status: 'done'
baseline_revision: '78b0cf21bc22ed169670da1f13ac94c939ae5a1d'
review_loop_iteration: 0
followup_review_recommended: true
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-3-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      A loopback listener stuck in `.waiting` would hang `authorize()` outside `redirectTimeout`.
    evidence: |-
      `LoopbackRedirectListener.start()` awaits only `.ready`, `.failed` or `.cancelled`, `handle(state:)` ignores `.waiting`, and `GoogleOAuthFlow.awaitRedirect` applies the timeout only after `start()` returns. Whether `NWListener` on `127.0.0.1` with an ephemeral port ever reports `.waiting` and never resolves is unverified. It would settle by running `authorize()` where the listener cannot bind (for example a sandboxed build without `com.apple.security.network.server`) and observing which state arrives.
    location: >-
      Sources/GoogleCalendarSource/LoopbackRedirectListener.swift (handle(state:))
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** `CalendarInterface` and `GoogleCalendarSource` are empty placeholder targets. Nothing can authorize against Google, fetch the event a capture falls inside, or list upcoming events, so Stories 3.11 (graceful degradation), 3.7's enrichment and 6.7 (upcoming strip) have no source to call.

**Approach:** Declare the `CalendarSource` protocol, `CalendarEvent`, `CalendarEventID` and `CalendarError` in `CalendarInterface`. Implement `GoogleCalendarSource` (an actor) in the concrete target: an installed-application OAuth 2.0 flow with PKCE and a loopback redirect, the refresh token in Keychain, a read-only Calendar API v3 client, and a pure `EventMatcher`. Tests run against stubbed Google responders and never touch the network or the maintainer's Keychain item.

## Boundaries & Constraints

**Always:**
- Protocol shape: `authorize() async throws`, `fetchActiveEvent(at: Date) async throws -> CalendarEvent?`, `upcomingEvents(in: TimeInterval) async throws -> [CalendarEvent]`. `CalendarSource` is `Sendable`. Each domain error is a typed enum (AR-PAT-7).
- `CalendarEvent` carries `id: CalendarEventID`, `title`, `attendees: [CalendarAttendee]` (`email`, `displayName?`), `start`, `end`. `CalendarEventID` wraps the namespaced string `google:<event_id>` and follows `MeetingID`'s shape.
- `CalendarEvent.attendeeDisplayNames` returns display names only and skips an attendee with none. It never derives a name from an email (NFR-Pr4: emails never reach prompt assembly).
- The OAuth flow is the installed-application flow: PKCE (S256), a `127.0.0.1` loopback redirect on an ephemeral port, and a random `state` that the redirect must echo. The device-code flow cannot be used: Google's device flow does not allow the Calendar scope.
- Scope is exactly `https://www.googleapis.com/auth/calendar.readonly`. If the token response does not grant it, `authorize()` throws `.authorizationFailed`.
- The refresh token lives in Keychain (`kSecClassGenericPassword`, service `com.auricle.app.google-oauth-refresh-token`), read at the moment it is needed and never held in a property. The access token lives in actor memory only. Nothing persists either to disk, config or env (NFR-S1).
- All Google requests use HTTPS on an ephemeral `URLSession` with TLS 1.2 minimum. An endpoint override with a non-`https` scheme is rejected by a `precondition`. There is no insecure fallback (NFR-S5).
- Calendar requests target `calendars/primary` with `singleEvents=true` and a `fields` mask limited to what `CalendarEvent` carries.
- The OAuth client ID (and an optional client secret, sent only when present) is injected through the initializer. The browser opener is an injected closure. No default touches AppKit, `Process` or a config file.
- `EventMatcher` is pure. It keeps events with `start <= t <= end` (both inclusive) that have a `dateTime` start and end and are not cancelled. Among several matches it picks the smallest duration, then the latest start, then the smallest event id.
- Failure mapping is typed: no stored refresh token → `.notAuthorized`; `invalid_grant`, a second 401, or a non-rate-limit 403 → `.authorizationExpired`; 429 or a 403 with a rate-limit reason → `.rateLimited`; transport error or 5xx → `.unreachable`; an undecodable 2xx → `.malformedResponse`. One attempt per call, no retry. Cancellation propagates untouched.
- An expired access token (or one within 60 s of expiry) refreshes before the call. A 401 drops the cached token, refreshes once and retries once.
- Log only through `Log(category: "google-calendar")` with status codes and counts. No token, code, verifier, event title, attendee or email reaches a log field.

**Never:**
- Don't wire the source into `SummarizeStage`, `InternalStageWorker`, `AuricleApp` or any composition root, and don't write `calendar.json`. Those belong to Story 3.11.
- Don't add config loading, a CLI verb, or a UI for authorization, and don't touch `Project.swift`.
- Don't add `Codable` to the calendar types (Story 3.11 owns the `calendar.json` schema).
- Don't depend on `ClaudeSummarizer` or reuse `KeychainAPIKey`; the new store mirrors its shape inside `GoogleCalendarSource`.
- Don't read or write the maintainer's real Keychain item in any test.
- No new third-party package.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Authorize, first time | Browser closure requests `redirect_uri?code=…&state=…` | Token exchange carries `code_verifier`; refresh token stored; scope check passes | No error |
| Authorize, state mismatch | Redirect echoes a different `state` | Nothing stored | `.authorizationFailed` |
| Authorize, user denies | Redirect carries `error=access_denied` | Nothing stored | `.authorizationFailed` |
| Authorize, no redirect | Closure never requests the redirect within the injected timeout | Listener closed | `.authorizationFailed` |
| Authorize, scope not granted | Token response lacks `calendar.readonly`, or has no `refresh_token` | Nothing stored | `.authorizationFailed` |
| Active event, one match | `t` inside one event | That event, id `google:<id>` | No error |
| Active event, several matches | Nested events, or one ends exactly when another starts | Smallest duration wins; ties: later start, then smaller id | No error |
| Active event, no match | Nothing covers `t`; or only all-day or cancelled events | `nil` | No error |
| Upcoming events | Events start in `[now, now+window]` | Sorted by start; an event already running is excluded | No error |
| Access token expired | Cached token past expiry | Refresh, then the call succeeds | No error |
| Access token rejected | API returns 401 once, then 200 | One refresh, one retry, success | Second 401 → `.authorizationExpired` |
| Refresh fails, revoked | Token endpoint returns `invalid_grant` | Keychain item kept | `.authorizationExpired` |
| Never authorized | No Keychain item | No network call | `.notAuthorized` |
| Offline | `URLError` or 5xx | None | `.unreachable` |
| Rate limited | 429, or 403 `rateLimitExceeded` | None | `.rateLimited` |
| Attendee without a name | `displayName` absent | Listed in `attendees`, absent from `attendeeDisplayNames` | No error |

</intent-contract>

## Code Map

- `Sources/CalendarInterface/ManifestPlaceholder.swift`, `Sources/GoogleCalendarSource/ManifestPlaceholder.swift` -- empty placeholders whose own comment says to delete them once the target has real code.
- `Package.swift:77,117,139,154` -- `CalendarInterface` deps `Core`; `GoogleCalendarSource` deps `Core`, `CalendarInterface`; `GoogleCalendarSourceTests` deps lack `CalendarInterface`, which `--explicit-target-dependency-import-check error` needs once tests import it. `Summarize` already depends on `CalendarInterface`.
- `Sources/Core/MeetingID.swift` -- the strong-ID shape to copy for `CalendarEventID` (architecture.md:1970 names `CalendarEventID`).
- `Sources/Core/Errors.swift` -- typed-error convention (`Error, Sendable`, associated values for context). `CalendarError` lives in `CalendarInterface`, per architecture.md:2342-2345.
- `Sources/Core/ISO8601UTC.swift` -- `date(from:)` parses RFC 3339 with and without fractional seconds; reuse it for Google's `dateTime` values and for building `timeMin`/`timeMax`.
- `Sources/Core/Log.swift` -- `Log(category:)`; messages are `StaticString`, runtime values go in `fields` tagged `.publicSafe` or `.sensitive`.
- `Sources/ClaudeSummarizer/KeychainAPIKey.swift` -- Keychain read/upsert/delete shape and its `service:` overloads that let tests use a throwaway service. `Tests/ClaudeSummarizerTests/KeychainAPIKeyTests.swift:1-60` -- unique-service-per-test pattern (Swift Testing runs tests concurrently against one process-wide Keychain).
- `Sources/ClaudeSummarizer/AnthropicHTTPClient.swift:111-160` -- ephemeral `URLSession`, `tlsMinimumSupportedProtocolVersion = .TLSv12`, injected session/endpoint. Copy the shape, not the type. `Tests/ClaudeSummarizerTests/AnthropicHTTPClientTests.swift` and `Tests/SummarizeTests/EvalStubResponses.swift` -- the file-local `URLProtocol` stub with a unique endpoint per test.
- `Sources/Summarize/SummaryArtifactMapper.swift:36-52`, `UnenrichedMeetingTitle.swift` -- the calendar-less path Story 3.11 will replace; read-only here.
- `Sources/Summarize/SummarizationPromptBuilder.swift` -- the only `CryptoKit`/SHA256 user in `Sources/`; PKCE reuses `CryptoKit.SHA256`.
- `.swiftlint.yml` -- `composition_root_strategy_bypass` already excludes `Sources/GoogleCalendarSource/` but not `Tests/GoogleCalendarSourceTests/`; the tests construct `GoogleCalendarSource`, so add that directory to the exclusion list. `log_facade_bypass` forbids `Logger(subsystem:`; `file_length` warns at 600; `trailing_comma` is mandatory; `function_parameter_count` warns at 7.
- `_bmad-output/planning-artifacts/architecture.md:2342-2345,2393-2396` -- file layout: `CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift`; `GoogleCalendarSource.swift`, `GoogleOAuthFlow.swift`, `EventMatcher.swift`. `epics.md:1682-1718` -- Story 3.10 ACs. `prd.md:645-673` -- NFR-S1/S5/S6/Pr4/I5.

## Tasks & Acceptance

**Execution:**
- `Sources/CalendarInterface/CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift` -- declare the protocol, `CalendarEvent`, `CalendarAttendee`, `CalendarEventID`, `attendeeDisplayNames`, and `CalendarError` (`notAuthorized`, `authorizationExpired`, `authorizationFailed(reason:)`, `unreachable`, `rateLimited`, `malformedResponse`, all `Equatable`) -- the contract Story 3.11 consumes.
- `Sources/CalendarInterface/ManifestPlaceholder.swift`, `Sources/GoogleCalendarSource/ManifestPlaceholder.swift` -- delete -- each target now has real code.
- `Sources/GoogleCalendarSource/GoogleRefreshTokenStore.swift` -- internal Keychain read/upsert/delete for the refresh token, production service constant plus `service:` overloads for tests -- NFR-S1 without touching the real item in tests.
- `Sources/GoogleCalendarSource/GoogleOAuthFlow.swift` -- PKCE verifier/challenge and `state` generation, authorization URL, loopback listener (`Network` framework, `127.0.0.1`, ephemeral port, one request, a small "you can close this tab" response, injected timeout), code exchange, scope check, refresh-token grant, error mapping -- FR51, NFR-S6.
- `Sources/GoogleCalendarSource/EventMatcher.swift` -- pure selection per the boundaries -- FR52, testable without HTTP.
- `Sources/GoogleCalendarSource/GoogleCalendarSource.swift` -- actor conforming to `CalendarSource`: in-memory access token with expiry, refresh-before-use, one 401 retry, Calendar API list call, response decoding to `CalendarEvent`, status mapping; injected `URLSession`, endpoints and clock -- NFR-I5.
- `Package.swift` -- add `CalendarInterface` to `GoogleCalendarSourceTests` dependencies -- explicit import check.
- `.swiftlint.yml` -- add `.*/Tests/GoogleCalendarSourceTests/.*\.swift$` to `composition_root_strategy_bypass` `excluded`, with the same rationale comment as its sibling entries -- the strategy's own tests construct it.
- `Tests/CalendarInterfaceTests/CalendarEventTests.swift` -- `attendeeDisplayNames` (named, unnamed, all unnamed), `CalendarEventID` namespacing.
- `Tests/GoogleCalendarSourceTests/EventMatcherTests.swift` -- inclusive boundaries, nested events, equal-duration tie-break, all-day and cancelled excluded, no match.
- `Tests/GoogleCalendarSourceTests/GoogleRefreshTokenStoreTests.swift` -- real Keychain round trip and upsert under a unique throwaway service, `notFound`.
- `Tests/GoogleCalendarSourceTests/GoogleOAuthFlowTests.swift` -- authorization URL contents (scope, S256 challenge, `state`, loopback redirect), the I/O rows for authorize, PKCE verifier length/alphabet and challenge correctness against the RFC 7636 test vector.
- `Tests/GoogleCalendarSourceTests/GoogleCalendarSourceTests.swift` -- the remaining I/O rows through a `URLProtocol` stub: active match, disambiguation, expiry refresh, 401 retry, `invalid_grant`, `notAuthorized`, offline, rate limit, `upcomingEvents`, and a check that the outgoing request uses `https`, the `calendars/primary` path, the bearer header and the `fields` mask.

**Acceptance Criteria:**
- Given the stubbed Google responders, when `swift test --explicit-target-dependency-import-check error --filter GoogleCalendarSourceTests` runs, then every I/O row passes and no test reads or writes the production Keychain service.
- Given a token response and an event list containing emails, when the events are turned into prompt-facing names, then no email or email fragment appears.
- Given the full gate, when `scripts/check.sh lint` and `scripts/check.sh swift` run, then both pass; and `scripts/check.sh app` passes because the new target code is compiled into both Xcode schemes.
- Given `git diff main`, then no file under `App/`, `Sources/Summarize/`, `Sources/Persist/` or `Sources/ClaudeSummarizer/` changes.

## Spec Change Log

## Review Triage Log

### 2026-09-18 — Review pass
- verdicts: 47 findings — high 0, medium 5, low 38, false 2, maybe-false 2
- findings:
  - `[low]` `[reject]` (Blind Hunter) A stray request carrying `code`/`error` burns the listener's one-shot before `state` is checked — real for a local process only; the spec's matrix requires a state mismatch to fail with `.authorizationFailed`, and waiting for a matching state adds listener state for an attack that needs same-user local code.
  - `[low]` `[reject]` (Blind Hunter) `URLError(.cancelled)` is rethrown as-is instead of `CancellationError` — the spec says cancellation propagates untouched and the code does exactly that; no reachable caller ends up with a wrong outcome.
  - `[medium]` `[patch]` (Blind Hunter) The `fields` assertion is vacuous (`"end"` matches inside `"attendees(email,displayName)"`) — real: dropping `end(dateTime,date)` from the mask keeps every test green while real Google would return no `end`, so every timed event vanishes and `fetchActiveEvent` returns `nil`; patched: the test now compares the whole mask string.
  - `[low]` `[reject]` (Blind Hunter) A non-throttle 403 (for example `accessNotConfigured`) maps to `.authorizationExpired`, and 408 to `.malformedResponse` — the 403 mapping is the spec's; a first-run misconfiguration is one-time and the status code is logged, and the fix needs a new public error case.
  - `[low]` `[reject]` (Blind Hunter) `upcomingEvents` reads one page of 250 and drops the rest silently — the spec's Design Notes fix "no paging"; 250 events inside a strip-sized window does not happen on a personal calendar, and paging adds a loop and a token field.
  - `[low]` `[reject]` (Blind Hunter) Actor reentrancy allows duplicate refreshes and two concurrent `authorize()` flows — the duplicates are idempotent and cost one extra token request; the fix adds in-flight task state for a race the app's call pattern does not produce.
  - `[low]` `[reject]` (Blind Hunter) Event selection ignores declined invites, focus-time/out-of-office blocks and resource attendees — real for double-booked calendars, but the story's AC defines the candidate set as any event covering the instant with shortest-wins; refining it needs new fields, decoding and rules. Recorded as a residual risk.
  - `[medium]` `[patch]` (Blind Hunter) `attendeeDisplayNames` returns email-shaped and untrimmed display names — real: NFR-Pr4 and the spec's AC promise no email fragment in prompt-facing names, and some imported invites carry the address as the name; patched: names are trimmed, and a name that is empty or contains `@` is skipped, with tests. The sub-claim about newlines and length in names is rejected: prompt hardening belongs to prompt assembly, not this accessor.
  - `[low]` `[patch]` (Blind Hunter) `GoogleRefreshTokenStore` has unused no-argument `read()`/`write(_:)` and a doc comment that names a `delete()` that does not exist — real dead code and an inaccurate comment; patched: the two overloads are removed and the comment corrected.
  - `[low]` `[reject]` (Blind Hunter) The public initializer takes `endpoints` and `session`, so a caller could redirect credentials or drop the TLS floor — the only callers are same-repo composition roots, and the spec requires the endpoint override; no harm shown.
  - `[low]` `[reject]` (Blind Hunter) No `disconnect`/revoke on `CalendarSource` — the story fixes the protocol at three methods; revocation belongs to the Settings and doctor stories.
  - `[low]` `[reject]` (Blind Hunter) One unparseable `dateTime` fails the whole event list — deliberate (a timed event that silently vanishes from matching is worse) and Google always returns RFC 3339 there; the path is tested.
  - `[maybe-false]` `[defer]` (Blind Hunter) The listener could hang `authorize()` outside `redirectTimeout` if it sits in `.waiting`; socket-level paths are only parser-tested — the hang depends on `NWListener` behaviour not demonstrated here; recorded in `deferred`; the missing socket-level test is covered by the patch to the verification-gap row on stray requests.
  - `[low]` `[reject]` (Blind Hunter) The `processExitsWith` tests are wasteful and the negative case covers only the token endpoint — the `precondition` loops over all three URLs in one statement; no harm shown.
  - `[maybe-false]` `[defer]` (Edge Case Hunter) `start()` awaits `.ready`/`.failed`/`.cancelled` only, so a listener stuck in `.waiting` hangs — same root as the Blind Hunter listener row; settling it needs a run where the listener cannot bind.
  - `[low]` `[reject]` (Edge Case Hunter) A stray or forged request consumes the one-shot — same as the first Blind Hunter row.
  - `[low]` `[patch]` (Edge Case Hunter) The 200 page says "Authorization complete." before `state`, scope or the code exchange are checked — real: a user who unticks the calendar scope sees success in the browser while `authorize()` throws; patched: the page text is neutral and the same for every outcome.
  - `[low]` `[reject]` (Edge Case Hunter) Idle `NWConnection`s outlive `listener.cancel()` — they hold nothing sensitive and die with the process; tracking them adds set bookkeeping.
  - `[low]` `[reject]` (Edge Case Hunter) `upcomingEvents(in: .infinity)` builds a non-finite `timeMax` — no caller passes a non-finite window and no crash was shown; a guard adds a branch for an input nobody writes.
  - `[low]` `[reject]` (Edge Case Hunter) More than 250 events in range are dropped without a signal — same as the Blind Hunter paging row.
  - `[low]` `[reject]` (Edge Case Hunter) A zero-duration event wins the shortest-wins rule — same root as the declined/focus-time selection row; the AC fixes shortest-wins.
  - `[low]` `[reject]` (Edge Case Hunter) Declined, focus-time and out-of-office events can be matched — same as the Blind Hunter selection row.
  - `[medium]` `[patch]` (Edge Case Hunter) Email-shaped, padded or resource display names reach prompt-facing names — same root as the Blind Hunter `attendeeDisplayNames` row and patched with it; the resource-room part is rejected with the selection rows.
  - `[low]` `[reject]` (Edge Case Hunter) A 403 `accessNotConfigured` leads to a pointless re-authorize — same as the Blind Hunter 403 row.
  - `[low]` `[reject]` (Edge Case Hunter) A 408 maps to `.malformedResponse` — same as the Blind Hunter 403/408 row; rare.
  - `[low]` `[reject]` (Edge Case Hunter) A locked or ACL-denied Keychain read surfaces as `.authorizationFailed` — Story 3.11 degrades every `CalendarError` the same way, and a locked login Keychain is not an everyday state.
  - `[low]` `[reject]` (Edge Case Hunter) `URLError(.cancelled)` without a cancelled task escapes typed errors — same as the Blind Hunter cancellation row; the session is private and never invalidated.
  - `[low]` `[reject]` (Edge Case Hunter) Actor reentrancy — same as the Blind Hunter reentrancy row.
  - `[low]` `[reject]` (Edge Case Hunter) One malformed event fails the list — same as the Blind Hunter bad-event row.
  - `[low]` `[reject]` (Edge Case Hunter) `SecItemAdd` can return `errSecDuplicateItem` if two processes authorize at once — authorization is interactive, so two concurrent runs do not happen.
  - `[low]` `[patch]` (Edge Case Hunter) The doc says "one attempt with no retry" but `listEvents` re-sends once after a 401 — real inaccuracy; patched: the comment now states the refresh-and-resend and that nothing else retries.
  - `[low]` `[reject]` (Edge Case Hunter) The `fields` mask carries `status`, beyond what `CalendarEvent` carries — the code comment already names `status` and why; the fix would edit the spec's wording.
  - `[low]` `[reject]` (Edge Case Hunter) The TLS/HTTPS guarantee does not bind an injected session or redirects — same as the Blind Hunter public-initializer row; Google's endpoints do not redirect to HTTP.
  - `[medium]` `[patch]` (Edge Case Hunter) The claim that no email fragment reaches prompt names is false for an email-shaped `displayName` — same root as the Blind Hunter `attendeeDisplayNames` row and patched with it.
  - `[medium]` `[patch]` (Verification Gap) The `fields` test cannot detect a dropped `end(...)` selector — same root as the Blind Hunter vacuous-assertion row; patched with it.
  - `[low]` `[patch]` (Verification Gap) `prompt=consent` is not asserted, so removing it breaks re-authorization silently — patched: the authorization-URL test asserts `prompt == "consent"`.
  - `[low]` `[patch]` (Verification Gap) The listener's 404-and-keep-waiting and single-accept behaviour is untested; only the parser is — patched: an end-to-end test sends `GET /favicon.ico` first, expects 404, then completes the real redirect.
  - `[low]` `[patch]` (Verification Gap) Nothing shows that the `state` and PKCE verifier `authorize()` sends are random — patched: a test runs `authorize()` twice and asserts both values differ.
  - `[low]` `[reject]` (Verification Gap) Cancelling a running `authorize()` is untested — the two `CancellationError` catches are pass-throughs, the matrix has no cancellation row, and a task-cancel test against a real listener costs more than the branch is worth.
  - `[low]` `[reject]` (Verification Gap, other) The public initializer's forwarding is never exercised — a pass-through of five arguments.
  - `[low]` `[reject]` (Verification Gap, other) Keychain write/read failure branches are unexercised — the real Keychain cannot be made to fail on demand, and injecting a fake store adds a seam the architecture declines.
  - `[low]` `[reject]` (Verification Gap, other) One bad `dateTime` fails the whole list — same as the Blind Hunter bad-event row.
  - `[false]` `[reject]` (Intent Alignment) The story's "So that" outcome (a calendar title in a note) is unreachable from this diff: no composition root, no authorize trigger — Story 3.11's ACs own the stage integration and `calendar.json`, Story 9.1's Settings scene owns the re-auth button, and epics.md:2212 names the flow (`authorize()` plus an opener closure) as this story's part; this story's own ACs are library-level and all met.
  - `[low]` `[patch]` (Intent Alignment) Other token rejections during a refresh map to `.authorizationFailed`, not the story's `.authorizationExpired`/`.unreachable` — the story lists revoked and unreachable only and a test pins the mapping, but the `.authorizationFailed` doc says only "`authorize()` did not complete"; patched: the doc now covers both uses.
  - `[low]` `[reject]` (Intent Alignment) Email stripping lives in the `attendeeDisplayNames` accessor, and prompt assembly is not in the diff — prompt assembly is Stories 3.2/3.7/3.11; the accessor is the boundary those stories consume.
  - `[false]` `[reject]` (Intent Alignment) Only the installed-application flow is implemented, not device-code — the story says "device-code or installed-application", and Google's device flow does not allow the Calendar scope (checked against Google's documentation).
  - `[low]` `[reject]` (Intent Alignment) The tests never call the public initializer — same as the Verification Gap other-findings row.

## Design Notes

**Why loopback, not device code.** The device-code flow is one of the two flows NFR-S6 allows, but Google restricts it to a short scope list (OpenID, `email`, `profile`, `drive.appdata`, `drive.file`, the two YouTube scopes). `calendar.readonly` is not on it, so the installed-application flow is the only NFR-S6 option that works.

**Client credentials.** Google's guide lists `client_secret` as optional in the token request for loopback clients, while Desktop-type clients may still be issued one. The initializer takes an optional secret and sends it only when present, so either registration works. No config file exists yet (Story 1.2 deferred `Core/Config.swift`), which is why the credentials are injected rather than loaded.

**Boundary handling.** Calendar's `timeMin` is an exclusive lower bound on an event's end and `timeMax` an exclusive upper bound on its start. Asking for `[t-1s, t+1s]` and then applying `EventMatcher`'s inclusive rule client-side makes an event ending or starting exactly at `t` match, as the AC's `<=` requires.

**No retry, no paging.** The calendar is off the hot path and its failure already has a designed outcome (Story 3.11's degraded note), so one attempt per call keeps failure handling simple. The list call asks for `maxResults=250` and reads one page.

**Refresh-token lifetime.** A Google Cloud project left in "Testing" publishing status issues refresh tokens that expire after 7 days. That surfaces here as `invalid_grant`, mapped to `.authorizationExpired`. The stale item stays in Keychain and a later `authorize()` upserts over it.

## Verification

**Commands:**
- `swift test --explicit-target-dependency-import-check error --filter GoogleCalendarSourceTests` -- expected: all tests pass.
- `swift test --explicit-target-dependency-import-check error --filter CalendarInterfaceTests` -- expected: all tests pass.
- `scripts/check.sh lint`, `scripts/check.sh swift`, `scripts/check.sh app` -- expected: all pass.
- `git diff --stat main -- App Sources/Summarize Sources/Persist Sources/ClaudeSummarizer` -- expected: empty.

**Manual checks:**
- `security find-generic-password -s com.auricle.app.google-oauth-refresh-token` before and after `swift test` -- expected: the same result both times (tests never touch it).

## Auto Run Result

**Summary of implemented change:** Story 3.10's calendar layer. `CalendarInterface` now declares the `CalendarSource` protocol, `CalendarEvent`, `CalendarAttendee`, `CalendarEventID` (`google:<id>`), `CalendarError`, and `attendeeDisplayNames`, the accessor that keeps emails out of prompt-facing names. `GoogleCalendarSource` is an actor that authorizes with the installed-application OAuth flow (PKCE S256, a `127.0.0.1` loopback listener, a random `state`), stores the refresh token in Keychain, keeps the access token in memory, refreshes before expiry and once after a 401, and reads `calendars/primary/events` over HTTPS with TLS 1.2 minimum. A pure `EventMatcher` picks the covering event (smallest duration, then later start, then smaller id) and ignores all-day and cancelled events. Failures map to typed `CalendarError` cases with one attempt per call. Nothing is wired into a composition root, the summarize stage, or `calendar.json`; that is Story 3.11.

**Files changed:**
- `Sources/CalendarInterface/CalendarSource.swift`, `CalendarEvent.swift`, `CalendarError.swift` -- protocol, value types, typed errors.
- `Sources/GoogleCalendarSource/GoogleCalendarSource.swift` -- the actor: token cache, refresh, Calendar API calls, status mapping.
- `Sources/GoogleCalendarSource/GoogleOAuthFlow.swift` -- PKCE, authorization URL, code exchange, scope check, refresh grant.
- `Sources/GoogleCalendarSource/LoopbackRedirectListener.swift` -- one-shot `NWListener` on `127.0.0.1` that catches the browser redirect.
- `Sources/GoogleCalendarSource/GoogleRefreshTokenStore.swift` -- Keychain item for the refresh token, service-parameterized for tests.
- `Sources/GoogleCalendarSource/GoogleTransport.swift` -- endpoints (HTTPS enforced), ephemeral TLS 1.2 session, transport-error mapping.
- `Sources/GoogleCalendarSource/GoogleEvent.swift`, `EventMatcher.swift` -- wire decoding and pure selection.
- `Sources/CalendarInterface/ManifestPlaceholder.swift`, `Sources/GoogleCalendarSource/ManifestPlaceholder.swift` -- deleted.
- `Package.swift`, `.swiftlint.yml` -- `CalendarInterface` added to `GoogleCalendarSourceTests`; the strategy's own tests added to the composition-root lint exclusion.
- `Tests/CalendarInterfaceTests/CalendarEventTests.swift`, `Tests/GoogleCalendarSourceTests/*` -- 104 tests, real loopback listener and real Keychain under throwaway services, Google stubbed at the HTTP layer.

**Review findings breakdown:** 47 findings across 4 layers -- 0 high, 5 medium, 38 low, 2 false, 2 maybe-false. Full per-finding detail is in `## Review Triage Log`.
- **Patched (9 entries: 2 medium, 7 low):**
  - The `fields` mask test was vacuous (`"end"` matches inside `"attendees(...)"`); it now compares the whole mask. (medium)
  - `attendeeDisplayNames` returned email-shaped and padded names; it now trims, and skips names that contain `@` or equal the attendee's own email. (medium)
  - Dead no-argument overloads and a wrong doc comment in `GoogleRefreshTokenStore` removed.
  - New tests pin `prompt=consent`, the 404-and-keep-waiting listener behaviour for a stray and a second request, and the randomness of `state` and the PKCE verifier.
  - The redirect page no longer claims "Authorization complete" before the exchange is checked.
  - Two doc comments corrected (`GoogleCalendarSource` retry wording, `CalendarError.authorizationFailed`).
- **Deferred (1):** a listener stuck in `.waiting` could hang `authorize()` outside the timeout (maybe-false, medium if true, unverified; recorded in `deferred`).
- **Rejected (33, 2 of them false):** each has its reason in the log. Main groups: the local-process stray-request DoS, actor reentrancy, paging past 250 events, one-bad-event strictness, `URLError.cancelled` handling, and public `endpoints`/`session` parameters, all judged cosmetic or unreachable with fixes that add state or guards; declined/focus-time/out-of-office/resource-room selection, a product refinement beyond the story's shortest-wins rule; 403 `accessNotConfigured` and 408 mapping; no `disconnect`/revoke, outside the three-method protocol; untested cancellation of `authorize()`, the public initializer, and Keychain failure branches; and the two false findings (the "So that" outcome belongs to Stories 3.11/9.1, and device-code cannot carry the Calendar scope).
- **Follow-up review recommendation:** `true`. Two medium entries were patched (first pass). The named unverified risk: the new `@` rule in `attendeeDisplayNames` and the real-socket tests added in the patch round (favicon then redirect, two-run randomness) have had one review-free pass only.

**Verification performed:**
- `swift test --explicit-target-dependency-import-check error --filter GoogleCalendarSourceTests` -- 90 tests pass; `--filter CalendarInterfaceTests` -- 14 tests pass (before the patch round: 88 and 11).
- `scripts/check.sh lint`, `scripts/check.sh swift` (523 tests) and `scripts/check.sh app` (both Xcode schemes) -- pass, before and after the patch round.
- `git diff --stat 78b0cf21bc22ed169670da1f13ac94c939ae5a1d -- App Sources/Summarize Sources/Persist Sources/ClaudeSummarizer` -- empty.
- `security find-generic-password -s com.auricle.app.google-oauth-refresh-token` -- item not found after the test runs.
- Matrix Test Audit: all 16 matrix rows are covered by tests that ran and passed in the filtered run.

**Residual risks:**
- No run against real Google. The OAuth client registration, the consent screen and the browser hand-off are untested. A Google Cloud project left in "Testing" status issues refresh tokens that expire after 7 days, which shows up as `.authorizationExpired`.
- A 403 for a project without the Calendar API enabled (`accessNotConfigured`) maps to `.authorizationExpired`; only the status code is logged.
- A declined invite, a focus-time or out-of-office block, or a room resource that overlaps a capture can win the shortest-wins rule.
- The loopback listener assumes the app is unsandboxed; a future sandbox needs `com.apple.security.network.server`.
- The composition roots must supply a `GoogleOAuthClient` and an `openBrowser` closure; no config source exists yet (Story 3.11, and the Settings story for the re-auth button).
