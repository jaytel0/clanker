# Spend Tab Provider Model Proposal

Research target: [steipete/CodexBar](https://github.com/steipete/CodexBar), inspected at commit `6498d20` on 2026-05-16.

Issue: [jaytel0/clanker#9](https://github.com/jaytel0/clanker/issues/9)

Decision update: Clanker should stay local-only for the Spend tab for now. The provider/account model below is retained as research background, not as the current implementation direction.

## Summary

Clanker's Spend tab should keep local agent activity, provider quota, provider cash spend, and credit balances as separate concepts. CodexBar's strongest lesson is not any one provider integration; it is the separation between:

- quota/reset windows (`RateWindow`)
- provider-reported cash usage or budget (`ProviderCostSnapshot`)
- credit balances and credit history (`CreditsSnapshot`)
- local log-derived token/cost estimates (`CostUsageTokenSnapshot`)

Clanker already has a good local-log foundation in `HarnessUsageAdapter`, `HarnessUsageSnapshot`, `SpendSummary`, and an mtime-based incremental cache. The next step is to add a provider/account layer beside that local harness layer rather than stretching `HarnessUsageSnapshot` until it represents unrelated billing concepts.

## CodexBar Patterns Worth Keeping

CodexBar normalizes provider limits into `UsageSnapshot`, with `primary`, `secondary`, `tertiary`, and named extra quota windows. Each `RateWindow` carries used percentage, window length, reset timestamp or reset text, and optional regeneration information.

Provider spend is modeled separately with `ProviderCostSnapshot`: used amount, limit, currency, period label, reset time, and update time. Credits are also separate through `CreditsSnapshot`, with a remaining balance and dated credit events. Local history is yet another path through `CostUsageTokenSnapshot`, which reports session and 30-day token/cost estimates from local logs.

Provider integrations sit behind a fetch pipeline. `ProviderSourceMode` distinguishes `auto`, `web`, `cli`, `oauth`, and `api`; `ProviderFetchKind` distinguishes CLI, web, OAuth, API token, local probe, and web dashboard strategies. The returned value includes source labels and strategy identity, so UI can say where a number came from without knowing provider internals.

Refresh cadence is intentionally split. CodexBar polls provider state on a configurable cadence, defaults to 5 minutes, runs token/cost history on a slower 1-hour TTL with a long timeout, and keeps manual refresh available. Local storage scans are throttled and coalesced separately.

## Clanker Today

Clanker has a 1-second live session loop in `LocalSessionStore`; this should remain focused on "what is running right now." The Spend path is on demand: `HarnessUsageStore.start()` loads cached snapshots and `refreshNow()` scans when the notch opens or the user selects Spend.

Current usage snapshots are local event records:

- harness ID
- session ID and project/cwd
- model
- token breakdown
- optional USD cost
- `UsageCostSource`: `reported`, `estimated`, `quotaOnly`, `unknown`
- observed time and source file path

That is correct for local agent logs. It is not enough for provider state. A subscription quota may have no dollars, a cash balance may have no tokens, a monthly bill may be provider-reported, and a local estimate may not be billable spend.

## Proposed Model

Add a provider/account layer that can be cached and displayed next to local summaries.

```swift
struct ProviderSpendSnapshot: Identifiable, Equatable, Sendable {
    var id: String
    var provider: SpendProviderID
    var account: SpendAccountIdentity?
    var planLabel: String?
    var quotaWindows: [SpendQuotaWindow]
    var cashUsage: SpendCashUsage?
    var creditBalance: SpendCreditBalance?
    var localUsage: SpendLocalUsageSummary?
    var sources: [SpendObservationSource]
    var updatedAt: Date
}

struct SpendQuotaWindow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String              // "Session", "Weekly", "Monthly", provider-specific label
    var usedPercent: Double?
    var remainingPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?
    var resetDescription: String?
    var source: SpendObservationSource
}

struct SpendCashUsage: Equatable, Sendable {
    var used: Decimal?
    var limit: Decimal?
    var currencyCode: String
    var period: String?            // "Monthly", "Billing period", etc.
    var resetsAt: Date?
    var source: SpendObservationSource
}

struct SpendCreditBalance: Equatable, Sendable {
    var remaining: Decimal?
    var unit: String               // "credits", "USD", provider token name
    var events: [SpendCreditEvent]
    var source: SpendObservationSource
}

struct SpendObservationSource: Equatable, Sendable {
    var confidence: UsageCostSource // reported, estimated, quotaOnly, unknown
    var acquisition: SpendAcquisitionKind
    var label: String               // "Local logs", "Codex RPC", "OAuth", "API key"
    var detail: String?
}
```

Keep `UsageCostSource` or rename it later to a more general `SpendConfidence`; the current cases are already the acceptance-criteria labels.

The key domain split is:

- **Harness**: the local agent/log format, such as Codex, Claude, Pi, or Terminal.
- **Provider**: the billing or quota account, such as OpenAI/ChatGPT, Anthropic, Pi, OpenRouter, or a future provider.

A harness can produce local usage for a provider, and a provider can have multiple acquisition methods. The UI should never add quota percentages to dollars or treat local estimated cost as provider-reported spend.

## Adapter Boundaries

Keep local log parsing behind `HarnessUsageAdapter`, but make it explicitly local-history oriented.

Add provider adapters beside it:

```swift
protocol SpendProviderAdapter: Sendable {
    var provider: SpendProviderID { get }
    var supportedSources: [SpendAcquisitionKind] { get }
    func refresh(context: SpendProviderRefreshContext) async -> ProviderSpendRefreshResult
}
```

Recommended acquisition kinds:

- `localLogs`: current Codex, Claude, and Pi JSONL scans
- `cliRPC`: Codex app-server or provider CLI usage command
- `oauth`: provider OAuth credentials already created by a CLI
- `apiKey`: explicit token/API key
- `browserSession`: browser cookies or web dashboard
- `localAppData`: local provider app files
- `unknown`

Start conservatively:

- Default on: local logs only.
- Consider safe auto-detection: local auth/CLI metadata that does not require secrets or pop prompts.
- Explicit opt-in: OAuth refresh, API keys, browser cookies, dashboard scraping.

Browser-cookie scraping should not be part of the first Clanker implementation. It is useful in CodexBar, but it greatly expands the trust boundary for a notch utility.

## Refresh Strategy

Use three loops, not one.

1. **Live sessions**
   Keep `LocalSessionStore` at 1 second. It should not scan spend history or call provider APIs.

2. **Local spend/history indexing**
   Keep lazy refresh on first Spend open. Add a TTL, likely 5-15 minutes, while the app is running. Manual refresh should force a scan. Move toward CodexBar-style cache fields when needed: file path, mtime, size, parsed bytes, last model/totals/turn ID, and day buckets. This avoids reparsing large append-only JSONL files.

3. **Provider/account refresh**
   Run only for opted-in sources. Use a 5-15 minute TTL for quota/account state and a slower TTL for expensive history endpoints. Manual refresh should force provider refresh, but UI must show stale cached data while refresh is in flight.

Implementation detail: keep provider refresh results in a separate cache file from local event snapshots. Provider failures should not delete local spend history.

## Spend Tab UX

The notch panel should stay compact and scannable. Use a layered view:

1. **Overview row**
   Show three high-signal values:
   - Today local activity: tokens/events, source `Estimated` or `Tokens`
   - 30-day local estimate: dollars when known, source `Estimated`
   - Provider status: best quota/credit signal, source `Reported`, `Quota-only`, or `Unknown`

2. **Provider rows**
   One row per provider with known data:
   - provider icon/name
   - plan/account label when available
   - primary quota percentage or remaining credit/balance
   - reset countdown when known
   - source badge, such as `Reported - OAuth`, `Quota-only - CLI`, or `Estimated - Local logs`

3. **Local breakdown**
   Keep the current harness/project breakdown, but label it clearly as local activity. It should not sit under a generic "Spend" heading when all values are estimated or token-only.

4. **Details surface later**
   The notch should not try to show every provider-specific lane. Detailed charts, credit history, credential controls, and raw source diagnostics belong in Settings or a future details window.

Empty states should distinguish:

- No local usage found.
- Provider source not connected.
- Provider quota connected but no cash/balance data.
- Cached data is stale or refresh failed.

## Privacy And Source Controls

Each provider needs source-level controls with plain labels:

- Local logs: reads local agent transcript/usage files.
- CLI/RPC: asks an installed provider CLI for account or quota state.
- OAuth/API key: uses explicit credentials.
- Browser session: reads authenticated browser cookies or web dashboard data.

For the first provider-aware Spend tab:

- Do not require login for local Spend.
- Do not import browser cookies automatically.
- Do not store manual cookies in plaintext config.
- Prefer Keychain for secrets when credentials are added.
- Redact emails, cookies, Authorization headers, bearer tokens, and API keys from logs.
- Avoid background CLI probes that can spin or prompt. CodexBar has had CPU risk around CLI/PTY loops; Clanker should use timeouts, backoff, and explicit source opt-in.

## Testing Plan

Add fixtures before expanding UI behavior:

- Codex JSONL with cumulative `total_token_usage`, `last_token_usage`, forked sessions, and appended lines.
- Claude JSONL with duplicate assistant message IDs, cache read/write tokens, and unknown model pricing.
- Pi JSONL with provider-reported `usage.cost.total` and token-only events.
- Provider quota snapshots for session, weekly, monthly, and unknown reset windows.
- Provider cash snapshots with used/limit/reset and no quota.
- Credit balance snapshots with remaining credits and dated usage events.
- Cache migration fixtures for provider snapshots and local index state.

Focused tests:

- Local parser dedupe and delta calculation per harness.
- Incremental append parsing without rereading unchanged bytes.
- Truncation/rotation behavior falls back to full parse.
- `SpendSummary` never mixes reported provider cash with local estimated dollars.
- Source/confidence badge selection for reported, estimated, quota-only, and unknown.
- Reset countdown formatting and stale-data behavior.

## Implementation Split

1. **Model PR**
   Add provider spend models, cache schema, fixtures, and source/confidence tests. No UI behavior change.

2. **Local index PR**
   Refactor current `HarnessUsageStore` cache toward per-file size/offset/day buckets where it matters. Preserve current UI output.

3. **Spend summary PR**
   Add a `SpendDashboardSummary` that combines provider snapshots with local summaries without merging their units.

4. **Notch UI PR**
   Update the Spend pane to separate "Local activity" and "Provider status" groups with source badges and stale states.

5. **Settings/source controls PR**
   Add per-provider source toggles. Ship local logs enabled by default; leave credentialed sources disabled until selected.

6. **First provider PR**
   Add the safest provider adapter first. Recommended order: Codex CLI/RPC quota if available without prompting, then Claude local/OAuth metadata, then API-key based sources. Defer browser dashboard scraping.

7. **Detailed surface PR**
   Move charts, credit history, and source diagnostics into Settings or a separate details sheet after the notch summary is stable.

## Avoid For Now

- A full CodexBar-style provider catalog.
- Browser cookie scraping by default.
- Per-second spend/provider refresh.
- Combining quota percentages, credits, and dollars into one total.
- Treating local API-equivalent estimates as billable provider spend.
- Account-scoping local log history unless the UI explicitly labels that scope.
- Credit purchase flows.
- Quota warning notifications before the data model and source labels are proven.

## Acceptance Criteria Mapping

- Subscription/quota and direct cash spend are separate: `SpendQuotaWindow` vs. `SpendCashUsage`.
- Source/confidence labels are explicit: `SpendObservationSource.confidence` and acquisition labels.
- Harness/provider scaling is explicit: local `HarnessUsageAdapter` remains separate from `SpendProviderAdapter`.
- Refresh avoids large rescans: live session polling, local history indexing, and provider refresh have separate cadences and caches.
- Implementation is issue-ready: the work is split into seven small PRs above.

## CodexBar Sources

- Architecture: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/docs/architecture.md
- Refresh loop: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/docs/refresh-loop.md
- Providers: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/docs/providers.md
- Usage and rate windows: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/UsageFetcher.swift
- Provider fetch pipeline: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/Providers/ProviderFetchPlan.swift
- Provider cost: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/ProviderCostSnapshot.swift
- Credits: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/CreditsModels.swift
- Local cost models: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/CostUsageModels.swift
- Cost cache: https://github.com/steipete/CodexBar/blob/6498d20d37c2289dd9070ae10afb86017e58b3d1/Sources/CodexBarCore/Vendored/CostUsage/CostUsageCache.swift
