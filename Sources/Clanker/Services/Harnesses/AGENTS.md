# Harness Adapter Guide

This folder owns harness-specific integrations. A harness adapter may know
where a tool stores sessions and how that tool names token fields, but it must
emit normalized Clanker models before anything reaches stores or SwiftUI.

## Architecture

- `HarnessUsageAdapter` is the adapter boundary. Implement this protocol for
  every new usage/spend source.
- `HarnessUsageScanner` invokes registered adapters and deduplicates snapshots.
- `HarnessUsageStore` refreshes snapshots on a timer and publishes them to the
  notch view model.
- `HarnessUsageSnapshot` is the normalized output. Views and summary logic must
  depend on this type, not raw JSON from a harness.

## Adding a Harness

1. Add a new `HarnessID` case if the harness does not already exist.
2. Create a new adapter type in this folder that conforms to
   `HarnessUsageAdapter`.
3. Parse only documented or locally observed stable files/APIs. Keep the raw
   parser inside the adapter.
4. Emit `HarnessUsageSnapshot` with:
   - `sessionID`
   - `harness`
   - `projectName`
   - `cwd`
   - `model`
   - `UsageTokenBreakdown`
   - `costUSD`
   - `costSource`
   - `pricingSource`
   - `observedAt`
5. Register the adapter in `HarnessUsageRegistry.adapters`.
6. Build with `./script/build_and_run.sh --verify`.

## Cost Rules

- Use `.reported` only when the harness provides an explicit cost field.
- Use `.estimated` only when a local pricing rule is deliberately implemented
  and `pricingSource` names that rule.
- Use `.quotaOnly` when token counts are known but dollars are not.
- Use `.unknown` when neither token counts nor cost can be trusted.
- Never silently convert request counts, quota counters, or subscription usage
  into dollars. Model those as token-only or quota-only until a real pricing
  rule exists.

## Parser Rules

- Prefer cumulative totals over summing streaming deltas.
- Deduplicate repeated assistant records by stable ids when a harness writes
  multiple transcript rows for the same model response.
- Keep scan limits bounded. Spend refresh runs in the background while the app
  is open.
- Do not mutate harness transcript/session files.

## UI Rules

The Spend tab should only consume `SpendSummary` and `SpendBreakdownItem`.
Adding a harness must not require changing SwiftUI unless the product needs a
new presentation concept.
