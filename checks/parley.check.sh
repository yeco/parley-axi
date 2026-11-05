#!/usr/bin/env bash
# parley.check.sh [inbox]: a polling check for agent supervisors.
# Prints ONE line when messages addressed to you are new or changed since the last delivery, and nothing
# otherwise: nothing when rate limited, nothing on gh or network failure. Always exits 0.
# Delivery is at least once: events are marked delivered (sync --commit) only after the line is printed,
# so a crash or a failed print brings them back on the next run.
# Inbox: first argument, else PARLEY_INBOX, else the default inbox from `parley-axi setup`.
# Env: PARLEY_INTERVAL (seconds between real checks, default 300), PARLEY_AXI (path to parley-axi).
# State: $XDG_STATE_HOME/parley-axi/<inbox>.last-check (rate limit); delivery state belongs to parley-axi sync.
set -uo pipefail
inbox=${1:-${PARLEY_INBOX:-}}
interval=${PARLEY_INTERVAL:-300}
dir="$(cd "$(dirname "$0")" && pwd)"
axi=${PARLEY_AXI:-$(command -v parley-axi || echo "$dir/../bin/parley-axi")}
state=${XDG_STATE_HOME:-$HOME/.local/state}/parley-axi
mkdir -p "$state" 2>/dev/null || exit 0
stamp="$state/${inbox:-default}.last-check"
now=$(date +%s)
last=$(cat "$stamp" 2>/dev/null || echo 0)
[ $((now - last)) -lt "$interval" ] && exit 0
echo "$now" > "$stamp"   # stamp before the call so a failing gh also backs off
limit=$(command -v timeout || command -v gtimeout || true)
axi() { ${limit:+"$limit" 60} "$axi" ${inbox:+--inbox "$inbox"} "$@" 2>/dev/null; }
events=$(axi sync --no-commit --json) || exit 0
line=$(jq -r 'select(length > 0) | "parley: \(length) message event(s): " + (map("#\(.number) \(.event)" +
  (if (.changes | length) > 0 then " (" + (.changes | join(", ")) + ")" else "" end) + " from \(.from // "?"): \(.subject)") | join("; "))' \
  <<<"$events" 2>/dev/null) || exit 0
if [ -n "$line" ]; then echo "$line - read with: parley-axi ${inbox:+--inbox $inbox }show <n>" || exit 0; fi
axi sync --commit >/dev/null
exit 0
