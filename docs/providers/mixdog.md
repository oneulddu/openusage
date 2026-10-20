# Mixdog

Tracks your Mixdog coding-agent usage on this Mac — every model request
Mixdog makes, across all the providers and models it routes to. Everything comes from Mixdog's local
usage ledger; nothing is sent over the network.

## What it tracks

| Metric | Meaning |
|---|---|
| Usage Trend | A day-by-day sparkline of tokens over the last month |
| Today / Yesterday / Last 30 Days | Cost and tokens across all your Mixdog requests |

Usage Trend is always visible; the three spend rows sit behind the provider's caret. Hover a spend row
for the per-model breakdown.

## Where the data comes from

Use Mixdog as usual. OpenUsage reads Mixdog's usage ledger at `~/.mixdog/data/usage/ledger.sqlite`
(or under `$MIXDOG_DATA_DIR` if you've set it), read-only. There's no login and nothing to paste. The
provider turns on automatically when that ledger holds at least one request.

## Costs and model prices

The dollars are the cost Mixdog records for each request. For subscription logins (Claude, ChatGPT)
Mixdog prices the tokens at public API rates, so the values are estimates, not what you're billed.

Some requests have no recorded cost — usually a custom endpoint whose model isn't in Mixdog's price
catalog. Those requests are left out of the dollar and token totals, and the spend rows show the
unknown-model warning. To include them, open **Customize → Mixdog → Model Prices**: every model with
unpriced requests is listed there. Enter its input, output, cache-read, and cache-write prices per
million tokens (an empty field counts as $0) and choose **Save**. The prices apply only to requests
without a recorded cost, and the source note on hover then reads "Includes your model prices".
**Clear** removes a saved price. Changes recalculate the rows right away.

## Troubleshooting

- **"Mixdog not detected"** — there's no usage ledger yet. Run a Mixdog session, then refresh. If you
  keep Mixdog's data somewhere custom, make sure `MIXDOG_DATA_DIR` is visible to OpenUsage too.
- **"Couldn't read Mixdog's usage ledger"** — the ledger exists but couldn't be read this refresh
  (for example while Mixdog holds a write lock). Refresh again; if it persists, check the permissions
  on `~/.mixdog/data/usage`.
- **Spend rows show a warning triangle** — some models have no recorded cost. Set their prices under
  **Customize → Mixdog → Model Prices**.

## Under the hood

The ledger's `events` view has one row per request: timestamp, model, input, output, cache-read, and
cache-write tokens, and `cost_usd` (empty when Mixdog couldn't price the model). OpenUsage reads the
last 30 calendar days of rows and groups them by local day. History is machine-local and can be
combined across Macs with iCloud Sync.
