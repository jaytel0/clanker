# Spend Refactor Spec

Issue: [jaytel0/clanker#9](https://github.com/jaytel0/clanker/issues/9)

Research source: [spend-tab-codexbar-research.md](./spend-tab-codexbar-research.md)

## Decision

Keep Clanker's Spend tab local-only for now.

The CodexBar research is useful background, but Clanker should not add a visible provider-status section or any provider credential/API surface yet. The current product value is a compact notch view of local agent usage from Codex, Claude, and Pi logs.

## Objective

Make the local Spend tab clearer and safer without expanding scope into provider billing.

The Spend tab should continue to show:

- local estimated spend when model pricing is known
- local token totals
- local event counts
- breakdowns by harness
- breakdowns by project
- confidence labels: `Reported`, `Estimated`, `Tokens`, or `Unknown`

## Non-Goals

- provider status rows
- provider account identity
- subscription/quota status
- reset countdowns from remote providers
- credit balances
- browser-cookie scraping
- API-key or OAuth setup
- provider billing charts
- quota warning notifications

## Current Local Model

Local Spend is built from:

- `HarnessUsageAdapter`
- `HarnessUsageSnapshot`
- `HarnessUsageStore`
- `SpendSummary`
- `NotchRootView` Spend UI

This is enough for the current product. Do not stretch these types to represent provider billing. If provider status becomes valuable later, add it as an explicitly opted-in details/settings surface, not as a default notch section.

## Implementation Guidance

Keep the Spend pane focused on local activity:

1. Overview cards:
   - Spend
   - Tokens
   - Events

2. Breakdown sections:
   - By harness
   - By project

3. Empty state:
   - No usage snapshots in the selected timeframe.

Do not show a provider status group, provider overview card, provider source setup, or provider connection prompt.

## Local Improvements Worth Doing Later

These are still in scope because they improve the local-only model:

- Add parser fixtures for Codex cumulative token events.
- Add parser fixtures for Claude duplicate usage IDs.
- Add parser fixtures for Pi reported cost vs token-only events.
- Add incremental append tests.
- Add rotated/truncated file fallback tests.
- Add cache tests for future local index fields such as file size or parsed byte offset.

## Acceptance Checks

- Spend can be understood without connecting any provider account.
- All displayed spend values come from local logs.
- Estimated local cost is labeled `Estimated`.
- Token-only local usage is labeled `Tokens`.
- No provider status section appears in the notch.
- No provider refresh runs on the 1-second live session cadence.
