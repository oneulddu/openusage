# OpenCodex

OpenCodex shows the quota summaries reported by your hub for Codex, Claude, Grok, Gemini,
and Kiro. Missing windows stay empty. If the hub combines multiple accounts, the meters reflect
that combined quota, and Codex Weekly only shows a reset time when a single account is included. It also shows a token usage trend and estimated spend for Today, Yesterday,
and Last 30 Days. The trend keeps the hub's own 30 calendar days, and Today and Yesterday pick
those days by this Mac's date, so they line up when the hub and the Mac share a time zone. Hub
spend is left out of Total Spend because it already includes the other providers' requests.

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
