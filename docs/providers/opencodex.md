# OpenCodex

OpenCodex shows the quota summaries reported by your hub for Codex, Claude, Grok, Gemini,
and Kiro. Missing windows stay empty. If the hub combines multiple accounts, the meters reflect
that combined quota, and Codex Weekly only shows a reset time when a single account is included. It also shows a token usage trend and estimated spend for Today, Yesterday,
and Last 30 Days. The trend keeps the hub's own 30 calendar days, and Today and Yesterday pick
those days by this Mac's date, so they line up when the hub and the Mac share a time zone. Hub
spend is included in Total Spend. Confirmed matching OpenCodex requests are removed from the
native Codex log estimates before that sum is calculated (see below).

Quota meters are visible by default. Kiro Monthly, the trend, and spend are under the card's caret.
Nothing is pinned to the menu bar by default; star any meter in Customize to pin it. Hub history
already includes all connected devices, so OpenUsage never adds copies from other Macs through iCloud.

## Setup

For a chosen hub, create `~/.config/openusage/opencodex.json`:

```json
{"baseURL": "http://127.0.0.1:10101", "adminTokenFile": "~/.opencodex/admin-api-token"}
```

You can use `"adminToken": "your-token"` instead of `adminTokenFile`. Surrounding whitespace is
trimmed. This configuration takes precedence; an invalid file does not fall back to another hub.
Keep the configuration and token files private.

Without that file, OpenUsage reads `$OPENCODEX_HOME/admin-api-token`, or
`~/.opencodex/admin-api-token` when `OPENCODEX_HOME` is unset, and uses `http://127.0.0.1:10100`.
Provider detection checks these same local files without contacting the hub.

## Requests And Errors

OpenUsage reads `/api/provider-quotas` and `/api/usage?days=30` with your admin token.
Costs come from the hub and are estimates.

- **Not Configured:** no usable token was found.
- **Invalid Configuration / Unreadable File:** check the URL, JSON, token path, or file permissions.
- **Authentication Failed:** the hub rejected the token (401 or 403).
- **Connection / Request / Response Error:** the hub could not be reached or returned unusable data.

Quota failures show a provider error. If only usage history fails, the quota meters remain available,
spend rows show no data, and the failure is recorded in the app's log.

## Removing Codex Overlap

When a hub is configured, native Codex history is compared with its read-only
`/api/request-history` endpoint. A match requires the hashed thread identity (or recorded parent
identity for a subagent), the same model, exact input and output token counts, and a completion
time within 30 seconds. Only an unambiguous one-to-one match is excluded. The Codex remainder is
priced locally; OpenCodex retains the hub's own estimate. Quotas and reset actions are unchanged.

Original session files are never changed or copied. Only compact request metadata is kept in
memory, with paginated reads and incremental refreshes; it is discarded when the app exits.
The first history scan may finish after the quota refresh and appear on the next refresh.
Disabling the OpenCodex card hides its contribution to the total; it does not reassign confirmed
hub requests to the native Codex card while the hub configuration remains present.

This is conservative reconciliation, not a guarantee that all historical overlap can be removed.
Missing identities, different token reporting, clock differences, ambiguous matches, a truncated
ledger, or an unavailable hub leave the affected local usage in place with a warning. Other
providers, pi/OpenCode records, and older iCloud peer histories are not reconciled by this native
Codex matcher. The combined total displays an overlap note. Provider refreshes are independent,
so recently completed requests can settle on a later refresh. No current model prefix or proxy
configuration is used to classify past requests.
