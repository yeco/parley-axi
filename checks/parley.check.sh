#!/usr/bin/env bash
# parley.check.sh [inbox]: a polling check for agent supervisors.
# Prints ONE line when open messages addressed to you are new or updated since the last run,
# and nothing otherwise: nothing when rate limited, nothing on gh or network failure. Always exits 0.
# Inbox: first argument, else PARLEY_INBOX, else the default inbox from `parley-axi setup`.
# Env: PARLEY_INTERVAL (seconds between real checks, default 300), PARLEY_AXI (path to parley-axi).
# State: $XDG_STATE_HOME/parley-axi/<inbox>.last-check (rate limit) and <inbox>.seen (number@updatedAt keys).
# shortcut: your own ack or reply bumps updatedAt, so it can produce one extra notice; filter by actor if that gets noisy.
set -uo pipefail
inbox=${1:-${PARLEY_INBOX:-}}
interval=${PARLEY_INTERVAL:-300}
dir="$(cd "$(dirname "$0")" && pwd)"
axi=${PARLEY_AXI:-$(command -v parley-axi || echo "$dir/../bin/parley-axi")}
state=${XDG_STATE_HOME:-$HOME/.local/state}/parley-axi
mkdir -p "$state" 2>/dev/null || exit 0
stamp="$state/${inbox:-default}.last-check"
seen="$state/${inbox:-default}.seen"
now=$(date +%s)
last=$(cat "$stamp" 2>/dev/null || echo 0)
[ $((now - last)) -lt "$interval" ] && exit 0
echo "$now" > "$stamp"   # stamp before the call so a failing gh also backs off
limit=$(command -v timeout || command -v gtimeout || true)
rows=$(${limit:+"$limit" 30} "$axi" ${inbox:+--inbox "$inbox"} list --json 2>/dev/null |
  jq -r '.[] | "\(.number)@\(.updatedAt)\t\(.from // "?")\t\(.subject)"' 2>/dev/null) || exit 0
touch "$seen"
n=0 out="" who="" keys=""
while IFS=$'\t' read -r key from title; do
  [ -n "$key" ] || continue
  keys="$keys$key"$'\n'
  grep -qxF "$key" "$seen" && continue
  n=$((n + 1))
  out="$out${out:+; }#${key%%@*} $title"
  case ",$who," in *",$from,"*) ;; *) who="$who${who:+,}$from" ;; esac
done <<< "$rows"
printf '%s' "$keys" > "$seen"   # keep only open messages, so the file never grows
[ "$n" -gt 0 ] || exit 0
echo "parley: $n new or updated message(s) from $who: $out - read with: parley-axi ${inbox:+--inbox $inbox }list"
