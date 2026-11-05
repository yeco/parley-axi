#!/usr/bin/env bash
# Tests for bin/parley-axi and checks/parley.check.sh with gh stubbed on PATH. Needs jq. Run: bash tests/run.sh
# shellcheck disable=SC2016,SC2015,SC2034 # conditions are single-quoted on purpose, eval-ed by expect
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export STUB_DIR="$tmp/gh" STUB_LOG="$tmp/gh.log" PATH="$root/tests/stub:$PATH"
export XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state"
unset PARLEY_INBOX PARLEY_INTERVAL PARLEY_AXI PARLEY_OVERLAP PARLEY_CRASH_AT
mkdir -p "$STUB_DIR"
px="$root/bin/parley-axi"
team="$STUB_DIR/acme__team-parley" ops="$STUB_DIR/acme__ops-parley"
fails=0

pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ $# -lt 2 ] || echo "     $2"; fails=$((fails + 1)); }
# expect <name> <shell condition> [detail shown on failure]; the condition sees $out, $rc and the log
expect() { if eval "$2"; then pass "$1"; else bad "$1" "${3:-}"; fi; }
logged() { grep -qF -- "$1" "$STUB_LOG"; }
reset() { : > "$STUB_LOG"; }
run() { out=$("$px" "$@" 2>&1); rc=$?; }

# issue <slug file prefix> <n> <state> <labels...>
issue() {
  local f=$1 n=$2 state=$3; shift 3
  jq -n --arg s "$state" --args '{state:$s, labels:[$ARGS.positional[]|{name:.}]}' "$@" > "$f.issue-$n.json"
}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# rest <n> <open|closed> <updated_at> <comments> <title> <labels...>: one issue as the REST API returns it
rest() {
  local n=$1 s=$2 u=$3 c=$4 t=$5; shift 5
  jq -nc --argjson n "$n" --arg s "$s" --arg u "$u" --argjson c "$c" --arg t "$t" --arg now "$now" --args \
    '{number:$n, title:$t, state:$s, comments:$c, created_at:$now, updated_at:$u, html_url:"https://x/\($n)", labels:[$ARGS.positional[]|{name:.}]}' "$@"
}
inbox() { jq -s . > "$1.issues.json"; } # reads rest lines on stdin
list_json() { # <updated_at> [comments]
  { rest 7 open "$1" "${2:-0}" "Review the PR" to:alice from:bob status:open
    rest 8 open "$1" "${2:-0}" "Second ask" to:alice from:bob status:acknowledged; } | inbox "$team"
}

# --- help
run --help; expect "help lists commands" '[[ $rc == 0 && $out == *decline* && $out == *init* ]]'
for c in init setup inboxes send list show reply ack "done" decline reopen sync; do
  run "$c" --help; expect "$c --help" '[[ $rc == 0 && $out == *usage:* ]]'
done
run frobnicate; expect "unknown command fails" '[[ $rc != 0 && $out == *"unknown command"* ]]'
run list; expect "no local config fails clearly" '[[ $rc != 0 && $out == *"parley-axi setup"* ]]' "$out"

# --- config parsing (through setup, which reads and validates the repo config)
bad_config() { # <name> <json> <expected message part>
  echo "$2" > "$team.parley.json"
  run setup --repo acme/team-parley --as alice
  expect "config: $1" '[[ $rc != 0 && $out == *"$3"* ]]' "$out"
}
bad_config "not json" 'nope' "not a JSON object"
bad_config "no members" '{"members":[]}' "members must be a non-empty array"
bad_config "bad member id" '{"members":[{"id":"a b","github":"x"}]}' "must match"
bad_config "duplicate ids" '{"members":[{"id":"a","github":"x"},{"id":"a","github":"y"}]}' "duplicate member id a"
bad_config "missing github" '{"members":[{"id":"a"}]}' "needs a github login"
bad_config "empty prefix" '{"members":[{"id":"a","github":"x"}],"labels":{"to":""}}' "non-empty strings"
bad_config "same prefixes" '{"members":[{"id":"a","github":"x"}],"labels":{"to":"x:","from":"x:"}}' "must differ"
bad_config "missing status" '{"members":[{"id":"a","github":"x"}],"labels":{"statuses":{"done":""}}}' "needs open, acknowledged"
rm -f "$team.parley.json"
run setup --repo acme/team-parley --as alice
expect "setup without repo config points to init" '[[ $rc != 0 && $out == *"parley-axi init --repo acme/team-parley"* ]]' "$out"
run setup --repo nope --as alice; expect "setup rejects bad repo" '[[ $rc != 0 && $out == *owner/name* ]]'
expect "failed setups wrote no local config" '[ ! -e "$XDG_CONFIG_HOME/parley-axi/config.json" ]'

# --- init: PR mode, idempotent, defaults for the label scheme
reset; run init --repo acme/team-parley --member "alice:alice-gh:Alice A" --member bob:bob-gh
expect "init opens a PR" '[[ $rc == 0 && $out == *"opened https://github.com/acme/team-parley/pull/1"* ]]' "$out"
expect "init branches from the default branch" 'logged "repos/acme/team-parley/git/refs -f ref=refs/heads/parley-init -f sha=abc123"'
expect "init writes the config on the branch" 'logged "-f branch=parley-init"'
expect "init config has members" 'jq -e ".members == [{id:\"alice\",name:\"Alice A\",github:\"alice-gh\"},{id:\"bob\",name:\"bob\",github:\"bob-gh\"}]" "$team.put.json" >/dev/null' "$(cat "$team.put.json")"
expect "init config spells out the default scheme" 'jq -e ".labels.to == \"to:\" and .labels.statuses.declined == \"declined\"" "$team.put.json" >/dev/null'
expect "init creates 8 labels" '[[ $out == *"labels: 8 ensured"* && $(wc -l < "$team.labels") -eq 8 ]]' "$out"
for l in to:alice from:alice to:bob from:bob status:open status:acknowledged status:done status:declined; do
  expect "label $l exists" 'grep -qxF "$l" "$team.labels"'
done
expect "labels get colors and descriptions" 'logged "label create to:alice -R acme/team-parley --color 1d76db --description Message to Alice A --force"'
reset; run init --repo acme/team-parley
expect "init again reuses the open PR" '[[ $rc == 0 && $out == *"already open: https://github.com/acme/team-parley/pull/1"* ]] && ! logged "git/refs"' "$out"
cp "$team.put.json" "$team.parley.json"
reset; run init --repo acme/team-parley
expect "init keeps an existing config" '[[ $rc == 0 && $out == *"exists, kept it"* ]] && ! logged "PUT"' "$out"
reset; STUB_LOGIN=dana-gh run init --repo acme/new-parley --direct
expect "init --direct commits to the default branch" '[[ $rc == 0 && $out == *"committed .parley.json"* ]] && logged "-X PUT" && ! logged "branch=" && ! logged "pr create"' "$out"
expect "init without --member uses the gh login" 'jq -e ".members[0].id == \"dana-gh\"" "$STUB_DIR/acme__new-parley.put.json" >/dev/null'

# --- custom label scheme for a second inbox
cat > "$ops.parley.json" <<'EOF'
{"members":[{"id":"alice","github":"alice-gh"},{"id":"carol","name":"Carol","github":"carol-gh"}],
 "labels":{"to":"for/","from":"by/","status":"state/","statuses":{"open":"new","acknowledged":"seen","done":"closed","declined":"wontdo"},
           "colors":{"to":"#000000"}}}
EOF
reset; run init --repo acme/ops-parley
for l in for/carol by/alice state/new state/seen state/closed state/wontdo; do
  expect "custom label $l created" 'grep -qxF "$l" "$ops.labels"'
done
expect "colors drop the # and fall back per kind" 'logged "label create for/alice -R acme/ops-parley --color 000000" && logged "label create by/alice -R acme/ops-parley --color 5319e7"'

# --- setup
run setup --repo acme/team-parley --as zed; expect "setup rejects non-members" '[[ $rc != 0 && $out == *"not a member"* && $out == *"alice, bob"* ]]' "$out"
grep -vxF status:done "$team.labels" > "$tmp/l" && cp "$team.labels" "$tmp/full" && mv "$tmp/l" "$team.labels"
run setup --repo acme/team-parley --as alice; expect "setup reports missing labels" '[[ $rc != 0 && $out == *"missing labels in acme/team-parley: status:done"* ]]' "$out"
mv "$tmp/full" "$team.labels"
run setup --repo acme/team-parley --as alice
expect "setup saves the first inbox as default" '[[ $rc == 0 && $out == "inbox team-parley: acme/team-parley as alice (default)" ]]' "$out"
run setup --repo acme/ops-parley --as alice --name ops
expect "a second inbox does not take the default" '[[ $rc == 0 && $out == "inbox ops: acme/ops-parley as alice" ]]' "$out"
STUB_LOGIN=someone-else run setup --repo acme/ops-parley --as carol --name ops-carol
expect "setup warns on a gh login mismatch" '[[ $rc == 0 && $out == *"warning: gh is logged in as someone-else, but carol is carol-gh"* ]]' "$out"
run setup --repo acme/ops-parley --as alice --name "a/b"; expect "setup rejects odd inbox names" '[[ $rc != 0 && $out == *"--name"* ]]'
run inboxes; expect "inboxes lists all, marks default" '[[ $out == *"team-parley* acme/team-parley alice"* && $out == *"ops acme/ops-parley alice"* ]]' "$out"

# --- send
reset; run send --to bob --subject "Check this" --body "Please look" --link https://example.com/pr/1 --due 2026-11-10
expect "send prints number and url" '[[ $out == "sent #42 to bob: https://github.com/acme/team-parley/issues/42" ]]' "$out"
for want in "--label to:bob" "--label from:alice" "--label status:open" "--title Check this" "Please look" "- https://example.com/pr/1" "Due: 2026-11-10"; do
  expect "send passes '$want'" 'logged "$want"' "$(cat "$STUB_LOG")"
done
run send --to bob --subject s --json; expect "send --json" '[[ $(jq -r ".number,.to" <<<"$out" | paste -sd" ") == "42 bob" ]]' "$out"
reset; run send --to alice --subject s; expect "send to yourself works (notes, self-tests)" '[[ $rc == 0 ]] && logged "--label to:alice --label from:alice"'
run send --to zed --subject s; expect "send to non-member fails" '[[ $rc != 0 && $out == *"not a member"* ]]'
run send --to bob; expect "send without subject fails" '[[ $rc != 0 && $out == *--subject* ]]'
run send --to bob --subject s --due tomorrow; expect "send bad due fails" '[[ $rc != 0 && $out == *YYYY-MM-DD* ]]'
run send --to bob --subject s --link ftp://x; expect "send bad link fails" '[[ $rc != 0 && $out == *http* ]]'
run send --to bob --subject s --bogus; expect "unknown option fails" '[[ $rc != 0 && $out == *"unknown option"* ]]'
echo "from file" > "$tmp/body.txt"; reset; "$px" send --to bob --subject s --body-file "$tmp/body.txt" >/dev/null
expect "send --body-file" 'logged "from file"'
reset; echo "from stdin" | "$px" send --to bob --subject s --body-file - >/dev/null; expect "send --body-file -" 'logged "from stdin"'
reset; run --as bob send --to alice --subject s; expect "--as overrides the configured member" '[[ $rc == 0 ]] && logged "--label from:bob"' "$out"


# --- multiple inboxes
reset; run --inbox ops send --to carol --subject s
expect "--inbox picks the repo and its labels" '[[ $rc == 0 && $out == *acme/ops-parley* ]] && logged "issue create -R acme/ops-parley" && logged "--label for/carol --label by/alice --label state/new"' "$(cat "$STUB_LOG")"
reset; run send --to carol --subject s --inbox ops; expect "--inbox works after the command" '[[ $rc == 0 ]] && logged "-R acme/ops-parley"'
reset; out=$(PARLEY_INBOX=ops "$px" send --to carol --subject s 2>&1); expect "PARLEY_INBOX picks the inbox" 'logged "-R acme/ops-parley"'
run --inbox nope list; expect "unknown inbox fails" '[[ $rc != 0 && $out == *"unknown inbox"* ]]'
issue "$ops" 5 OPEN for/alice by/carol state/new
reset; run --inbox ops ack 5
expect "custom labels map onto the same states" '[[ $out == "#5 open -> acknowledged" ]] && logged "issue edit 5 -R acme/ops-parley --add-label state/seen --remove-label state/new"' "$out $(cat "$STUB_LOG")"

# --- list
list_json 2026-11-05T10:00:00Z
reset; run list
expect "list asks for open messages to me, all pages" 'logged "--paginate repos/acme/team-parley/issues?labels=to%3Aalice&state=open&sort=updated&direction=asc&per_page=100"' "$(cat "$STUB_LOG")"
expect "list row format" '[[ $(head -1 <<<"$out") == "#8 from:bob acknowledged "*"s \"Second ask\" https://x/8" ]]' "$out"
expect "list shows both rows" '[[ $(wc -l <<<"$out") -eq 2 ]]'
reset; run list --sent --all; expect "list --sent --all" 'logged "labels=from%3Aalice&state=all"'
run list --json; expect "list --json is normalized" '[[ $(jq -r ".[1] | [.number,.subject,.from,.to,.status,.state] | join(\",\")" <<<"$out") == "7,Review the PR,bob,alice,open,open" ]]' "$out"
rest 9 open 2026-11-05T10:00:00Z 0 "Broken" to:alice from:bob status:open status:done | inbox "$team"
run list --json; expect "list --json flags broken status labels" '[[ $(jq -r ".[0].status" <<<"$out") == conflict ]]' "$out"
echo '[]' > "$team.issues.json"; run list; expect "list empty" '[[ $out == "no messages" ]]'

# --- message state machine: every (state, command) pair; "-" means rejected
while read -r st cmd want; do
  gh_state=OPEN; case $st in done|declined) gh_state=CLOSED ;; esac
  issue "$team" 20 "$gh_state" to:alice from:bob "status:$st"
  reset; if [ "$cmd" = ack ]; then run ack 20; else run "$cmd" 20 why; fi
  if [ "$want" = - ]; then
    expect "$st + $cmd is rejected" '[[ $rc != 0 && $out == *"#20 is $st"* ]] && ! logged "issue edit" && ! logged "issue comment"' "$out"
    continue
  fi
  expect "$st + $cmd -> $want" '[[ $rc == 0 && $out == "#20 $st -> $want" ]]' "$out"
  expect "$st + $cmd records the transition" 'logged "parley: $st -> $want by alice" && logged "<!-- parley-transition {\"v\":1,\"from\":\"$st\",\"to\":\"$want\",\"by\":\"alice\"} -->"' "$(cat "$STUB_LOG")"
  expect "$st + $cmd swaps the status label" 'logged "issue edit 20 -R acme/team-parley --add-label status:$want --remove-label status:$st"'
  case $want in
    done|declined) expect "$st + $cmd closes" 'logged "issue close 20" && ! logged "issue reopen"' ;;
    open) expect "$st + $cmd reopens" 'logged "issue reopen 20" && ! logged "issue close"' ;;
    *) expect "$st + $cmd keeps it open" '! logged "issue close" && ! logged "issue reopen"' ;;
  esac
  expect "$st + $cmd writes record, then open/closed, then label" '[[ $(grep -n "issue comment" "$STUB_LOG" | cut -d: -f1) -lt $(grep -n "issue edit" "$STUB_LOG" | cut -d: -f1) ]] && ! grep -A9 "issue edit" "$STUB_LOG" | grep -qE "issue (close|reopen)"'
done <<'EOF'
open ack acknowledged
open done done
open decline declined
open reopen -
acknowledged ack -
acknowledged done done
acknowledged decline declined
acknowledged reopen -
done ack -
done done -
done decline -
done reopen open
declined ack -
declined done -
declined decline -
declined reopen open
EOF
reset; "$px" "done" 7 "merged it" >/dev/null 2>&1 || true
issue "$team" 9 OPEN to:alice from:bob status:acknowledged
reset; "$px" "done" 9 merged it >/dev/null; expect "done note goes into the record" 'logged "merged it"'
run decline 9; expect "decline needs a reason" '[[ $rc != 0 && $out == *usage:* ]]'
issue "$team" 21 CLOSED to:alice from:bob status:done
reset; run --as bob reopen 21 not fixed; expect "the sender can reopen" '[[ $rc == 0 && $out == "#21 done -> open" ]] && logged "by bob"' "$out"
issue "$team" 22 OPEN to:alice from:bob status:open
run --as bob ack 22; expect "the sender cannot ack" '[[ $rc != 0 && $out == *"addressed to alice"* ]]'
issue "$team" 23 CLOSED to:alice from:bob status:open
reset; run "done" 23
expect "rerun finishes a transition that crashed before its label" '[[ $rc == 0 ]] && ! logged "issue close" && logged "--add-label status:done --remove-label status:open"' "$out"
issue "$team" 10 OPEN to:alice from:bob status:open status:acknowledged
reset; run "done" 10; expect "two status labels are rejected" '[[ $rc != 0 && $out == *"2 status labels"* ]] && ! logged "issue edit"' "$out"
issue "$team" 24 OPEN to:alice from:bob
run ack 24; expect "no status label is rejected" '[[ $rc != 0 && $out == *"0 status labels"* ]]' "$out"

# --- errors
issue "$team" 8 OPEN to:bob from:alice status:open
issue "$team" 11 OPEN bug
reset; run ack 8
expect "ack on someone else's message fails" '[[ $rc != 0 && $out == *"addressed to bob"* ]]' "$out"
expect "wrong recipient makes no edit" '! logged "issue edit"'
run ack 404; expect "unknown issue" '[[ $rc != 0 && $out == *"no message #404"* ]]' "$out"
run ack 11; expect "non-parley issue" '[[ $rc != 0 && $out == *"not a parley message"* ]]' "$out"
run ack abc; expect "non-numeric issue" '[[ $rc != 0 && $out == *numeric* ]]'
out=$(STUB_NO_AUTH=1 "$px" list 2>&1); rc=$?
expect "missing gh auth fails clearly" '[[ $rc != 0 && $out == *"not authenticated"* ]]'

# --- show / reply
jq -n '{number:30, title:"Review the PR", state:"OPEN", createdAt:"2026-11-05T10:00:00Z", url:"https://x/30", body:"Please look\n\n<!-- parley-message {\"v\":1} -->",
  labels:[{name:"to:alice"},{name:"from:bob"},{name:"status:open"}],
  comments:[{author:{login:"alice-gh"}, createdAt:"2026-11-05T11:00:00Z", body:"parley: open -> acknowledged by alice\n<!-- parley-transition {} -->"}]}' > "$team.issue-30.json"
run show 30
expect "show renders header, body and comments" '[[ $out == *"#30 Review the PR"* && $out == *"from:bob to:alice status:open open"* && $out == *"Please look"* && $out == *"--- alice-gh 2026-11-05T11:00:00Z"* && $out == *"open -> acknowledged by alice"* ]]' "$out"
expect "show hides the machine-readable markers" '[[ $out != *"<!--"* ]]' "$out"
reset; "$px" show 30 --json >/dev/null; expect "show --json" 'logged "issue view 30 -R acme/team-parley --json number,title,body"'
reset; "$px" reply 30 hello there >/dev/null; expect "reply comments" 'logged "issue comment 30 -R acme/team-parley --body hello there"'
reset; echo "from stdin" | "$px" reply 30 - >/dev/null; expect "reply reads stdin" 'logged "--body from stdin"'
issue "$team" 13 OPEN to:bob from:bob status:open
run reply 13 hi; expect "reply on a stranger's thread fails" '[[ $rc != 0 && $out == *"not you"* ]]'

# --- delivery: sync keeps a cursor and per-message versions, and delivers at least once
st="$XDG_STATE_HOME/parley-axi/team-parley"
fresh() { rm -rf "$st"; }
cursor() { jq -r .cursor "$st/state.json"; }
{ rest 7 open 2026-11-05T10:00:00Z 0 "Review the PR" to:alice from:bob status:open
  rest 8 open 2026-11-05T10:01:00Z 0 "Second ask" to:alice from:bob status:acknowledged
  rest 9 closed 2026-11-04T10:00:00Z 1 "Old news" to:alice from:bob status:done
  rest 12 open 2026-11-05T10:02:00Z 0 "Not mine" to:bob from:alice status:open; } | inbox "$team"
fresh; reset; run sync
expect "first sync delivers open messages to me" '[[ $rc == 0 && $(wc -l <<<"$out") -eq 2 && $out == *"#7 new from:bob open \"Review the PR\" https://x/7"* && $out == *"#8 new from:bob acknowledged"* ]]' "$out"
expect "first sync treats closed messages as history" '[[ $out != *"#9"* && $(jq -r ".versions[\"9\"].status" "$st/state.json") == done ]]'
expect "first sync reads everything, all pages" '! logged "since=" && logged "--paginate" && logged "per_page=100"'
expect "cursor is the newest server timestamp" '[[ $(cursor) == 2026-11-05T10:01:00Z ]]'
reset; run sync; expect "nothing new, nothing printed twice" '[[ $out == "no new messages" ]]' "$out"
expect "next sync re-reads an overlap window before the cursor" 'logged "since=2026-11-05T09:51:00Z"' "$(cat "$STUB_LOG")"
{ rest 7 open 2026-11-05T11:00:00Z 2 "Review the PR" to:alice from:bob status:open
  rest 8 closed 2026-11-05T11:01:00Z 0 "Second ask" to:alice from:bob status:done
  rest 14 open 2026-11-05T11:02:00Z 0 "Edited" to:alice from:bob status:open; } | inbox "$team"
run sync
expect "new comments are delivered" '[[ $out == *"#7 updated (+2 comment(s)) from:bob open"* ]]' "$out"
expect "status changes are delivered" '[[ $out == *"#8 updated (acknowledged -> done, closed) from:bob done"* ]]' "$out"
rest 14 open 2026-11-05T11:05:00Z 0 "Edited title" to:alice from:bob status:open | inbox "$team"
run sync; expect "edits are delivered" '[[ $out == "#14 updated (edited) from:bob open \"Edited title\" https://x/14" ]]' "$out"
expect "cursor follows the newest update" '[[ $(cursor) == 2026-11-05T11:05:00Z ]]'
{ rest 14 open 2026-11-05T11:05:00Z 0 "Edited title" to:alice from:bob status:open
  rest 15 open 2026-11-05T10:58:00Z 0 "Late arrival" to:alice from:bob status:open; } | inbox "$team"
run sync; expect "a message that shows up late inside the overlap window is delivered" '[[ $out == "#15 new from:bob open \"Late arrival\" https://x/15" ]]' "$out"
expect "cursor never moves backward" '[[ $(cursor) == 2026-11-05T11:05:00Z ]]'
rest 7 open 2026-11-05T10:59:00Z 1 "Review the PR" to:alice from:bob status:open | inbox "$team"
run sync; expect "a stale read is not an update" '[[ $out == "no new messages" && $(jq -r ".versions[\"7\"].comments" "$st/state.json") == 2 ]]' "$out"
rest 16 open 2026-11-05T09:00:00Z 0 "Lost in the past" to:alice from:bob status:open | inbox "$team"
run sync; expect "a message older than the overlap window is not fetched by sync" '[[ $out == "no new messages" ]]' "$out"
cp "$st/state.json" "$tmp/before.json"
run sync --verify
expect "verify reports a message that was never surfaced" '[[ $rc != 0 && $out == *"#16 never surfaced: open \"Lost in the past\""* && $out == *"verify: 1 problem(s)"* ]]' "$out"
expect "verify changes nothing" 'cmp -s "$st/state.json" "$tmp/before.json"'
expect "verify reads every message" 'logged "labels=to%3Aalice&state=all&sort=updated&direction=asc&per_page=100 "' "$(tail -1 "$STUB_LOG")"
{ rest 7 open 2026-11-05T12:00:00Z 3 "Review the PR" to:alice from:bob status:open
  rest 17 open 2026-11-05T10:00:00Z 0 "Two states" to:alice from:bob status:open status:done
  rest 18 open 2026-11-05T10:00:00Z 0 "Half closed" to:alice from:bob status:done; } | inbox "$team"
run sync --verify --json
expect "verify --json lists every problem" '[[ $rc != 0 && $(jq ".problems | length" <<<"$out") -eq 5 ]]' "$out"
expect "verify reports an update not surfaced" '[[ $out == *"#7 update not surfaced: delivered 2026-11-05T11:00:00Z, now 2026-11-05T12:00:00Z"* ]]' "$out"
expect "verify reports broken status labels" '[[ $out == *"#17 status labels broken (conflict)"* && $out == *"#18 is done but the issue is open"* ]]' "$out"
fresh; list_json 2026-11-05T10:00:00Z; "$px" sync >/dev/null
run sync --verify; expect "verify passes once everything is delivered" '[[ $rc == 0 && $out == "verify: 2 message(s), all surfaced, states consistent" ]]' "$out"

# clock skew: only server timestamps move the cursor, so a remote clock ahead of ours is fine
fresh; rest 7 open 2030-01-01T00:00:00Z 0 "From the future" to:alice from:bob status:open | inbox "$team"
"$px" sync >/dev/null; reset; run sync
expect "cursor and overlap use server time" '[[ $(cursor) == 2030-01-01T00:00:00Z ]] && logged "since=2029-12-31T23:50:00Z"' "$(cat "$STUB_LOG")"
fresh; list_json 2026-11-05T10:00:00Z; PARLEY_OVERLAP=3600 "$px" sync >/dev/null; reset; PARLEY_OVERLAP=3600 "$px" sync >/dev/null
expect "PARLEY_OVERLAP widens the window" 'logged "since=2026-11-05T09:00:00Z"'

# pagination: more than 100 messages, served in pages of 100
fresh; for i in $(seq 100 349); do rest "$i" open "2026-11-05T10:00:00Z" 0 "Ask $i" to:alice from:bob status:open; done | inbox "$team"
run sync --json
expect "sync delivers all 250 messages across pages" '[[ $(jq "length" <<<"$out") -eq 250 && $(jq "[.[].number] | unique | length" <<<"$out") -eq 250 ]]' "$(head -c 300 <<<"$out")"
run sync --verify; expect "verify sees all 250 as surfaced" '[[ $rc == 0 && $out == "verify: 250 message(s), all surfaced, states consistent" ]]' "$out"

# crash at each step: nothing is lost, and nothing repeats once a sync commits
for step in write-pending emit commit swap; do
  fresh; list_json 2026-11-05T10:00:00Z
  out1=$(PARLEY_CRASH_AT=$step "$px" sync 2>&1); rc1=$?
  out2=$("$px" sync 2>&1); out3=$("$px" sync 2>&1)
  expect "crash before $step: the run dies" '[[ $rc1 == 70 ]]' "$rc1 $out1"
  expect "crash before $step: the next sync delivers everything" '[[ $out2 == *"#7 new"* && $out2 == *"#8 new"* ]]' "$out2"
  expect "crash before $step: delivered state is untouched" '[[ $(cursor) == 2026-11-05T10:00:00Z ]]'
  expect "crash before $step: once committed nothing repeats" '[[ $out3 == "no new messages" ]]' "$out3"
done
fresh; out1=$(STUB_GH_FAIL=1 "$px" sync 2>&1); rc1=$?; out2=$("$px" sync 2>&1)
expect "a failed fetch commits nothing" '[[ $rc1 != 0 && $out2 == *"#7 new"* ]]' "$out1 / $out2"
fresh; "$px" sync --no-commit >/dev/null; run sync --no-commit
expect "--no-commit keeps events pending" '[[ $out == *"#7 new"* && -f "$st/pending.json" ]]' "$out"
"$px" sync --commit; run sync; expect "--commit marks them delivered" '[[ $out == "no new messages" && ! -f "$st/pending.json" ]]' "$out"
run sync --commit; expect "--commit with nothing pending is a no-op" '[[ $rc == 0 && -z $out ]]'

# --- polling check
chk="$root/checks/parley.check.sh"
unseal() { rm -f "$XDG_STATE_HOME"/parley-axi/*.last-check; }
fresh; list_json 2026-11-05T10:00:00Z
out=$(bash "$chk"); rc=$?
expect "check prints one line for new messages" '[[ $rc == 0 && $(wc -l <<<"$out") -eq 1 && $out == "parley: 2 message event(s): #7 new from bob: Review the PR; #8 new from bob: Second ask - read with: parley-axi show <n>" ]]' "$out"
out=$(bash "$chk"); expect "check is rate limited" '[[ -z $out ]]'
unseal; out=$(bash "$chk"); expect "check prints nothing for delivered messages" '[[ -z $out ]]' "$out"
list_json 2026-11-05T11:00:00Z 1; unseal; out=$(bash "$chk")
expect "check reports new comments" '[[ $out == "parley: 2 message event(s): #7 updated (+1 comment(s)) from bob: Review the PR;"* ]]' "$out"
list_json 2026-11-05T12:00:00Z 2; unseal; out=$(STUB_GH_FAIL=1 bash "$chk" 2>&1); rc=$?
expect "check is silent and exits 0 when gh fails" '[[ $rc == 0 && -z $out ]]' "$out"
unseal; (bash "$chk" >&-) 2>/dev/null; rc=$?
expect "check exits 0 when it cannot print" '[[ $rc == 0 ]]'
unseal; out=$(bash "$chk"); expect "check delivers what a failure held back" '[[ $out == "parley: 2 message event(s): #7 updated (+1 comment(s))"* ]]' "$out"
echo '[]' > "$team.issues.json"; unseal; out=$(bash "$chk"); expect "check is silent with no messages" '[[ -z $out ]]'
rest 5 open 2026-11-05T10:00:00Z 0 "Ops ask" for/alice by/carol state/new | inbox "$ops"
out=$(bash "$chk" ops); expect "check takes an inbox argument" '[[ $out == "parley: 1 message event(s): #5 new from carol: Ops ask - read with: parley-axi --inbox ops show <n>" ]]' "$out"
out=$(XDG_CONFIG_HOME="$tmp/none" bash "$chk" other 2>&1); rc=$?
expect "check is silent without local config" '[[ $rc == 0 && -z $out ]]' "$out"

echo; [ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
