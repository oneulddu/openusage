#!/usr/bin/env bash
set -euo pipefail

# Mirrors another machine's Mixdog usage into OpenUsage's Mixdog card. Over SSH it aggregates the remote
# ledger's last 32 days into one row per local day, model, and priced/unpriced bucket, then writes those
# rows in the ledger's `events` shape to ~/.config/openusage/mixdog/remotes/<name>.sqlite, which OpenUsage
# reads alongside this Mac's own ledger. Rows without a recorded cost stay unpriced, so the model prices
# set in OpenUsage apply to them. Mirror a machine from one Mac only; iCloud Sync carries it to the others.
#
# Usage: script/pull_mixdog_remote.sh <ssh-host> [name]
#   ssh-host  host or ~/.ssh/config alias with key-based login and sqlite3 installed
#   name      mirror file name (default: the host)

HOST="${1:?usage: $0 <ssh-host> [name]}"
NAME="${2:-$HOST}"
DEST_DIR="$HOME/.config/openusage/mixdog/remotes"
mkdir -p "$DEST_DIR"
# Hidden and without the .sqlite suffix, so OpenUsage never reads a half-written mirror.
TMP="$(mktemp "$DEST_DIR/.$NAME.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

ROWS="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
  'sqlite3 -readonly "${MIXDOG_DATA_DIR:-$HOME/.mixdog/data}/usage/ledger.sqlite"' <<'SQL'
.mode insert events
SELECT CAST(strftime('%s', date(ts / 1000, 'unixepoch', 'localtime') || ' 12:00:00', 'utc') AS INTEGER) * 1000,
       model, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), SUM(cost_usd)
FROM events
WHERE model IS NOT NULL AND ts >= CAST(strftime('%s', 'now', '-32 days') AS INTEGER) * 1000
GROUP BY date(ts / 1000, 'unixepoch', 'localtime'), model, cost_usd IS NULL;
SQL
)"

{
  echo "CREATE TABLE events(ts INTEGER, model TEXT, input INTEGER, output INTEGER,"
  echo "  cache_read INTEGER, cache_write INTEGER, cost_usd REAL);"
  echo "BEGIN;"
  printf '%s\n' "$ROWS"
  echo "COMMIT;"
} | sqlite3 "$TMP"
mv -f "$TMP" "$DEST_DIR/$NAME.sqlite"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) mirrored $HOST: $(sqlite3 "$DEST_DIR/$NAME.sqlite" 'SELECT COUNT(*) FROM events') rows"
