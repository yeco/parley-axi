#!/usr/bin/env bash
# Tests for bin/parley-axi and checks/parley.check.sh with gh stubbed on PATH. Needs jq. Run: bash tests/run.sh
# shellcheck disable=SC2016,SC2015,SC2034 # conditions are single-quoted on purpose, eval-ed by expect
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export STUB_DIR="$tmp/gh" STUB_LOG="$tmp/gh.log" PATH="$root/tests/stub:$PATH"
export XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state"
unset PARLEY_INBOX PARLEY_INTERVAL PARLEY_AXI
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
list_json() { # <updatedAt>
  jq -n --arg t "$now" --arg u "$1" '[
    {number:7, title:"Review the PR", createdAt:$t, updatedAt:$u, url:"https://x/7", state:"OPEN", labels:[{name:"to:alice"},{name:"from:bob"},{name:"status:open"}]},
    {number:8, title:"Second ask",    createdAt:$t, updatedAt:$u, url:"https://x/8", state:"OPEN", labels:[{name:"to:alice"},{name:"from:bob"},{name:"status:acknowledged"}]}]' > "$team.issues.json"
}

# --- help
run --help; expect "help lists commands" '[[ $rc == 0 && $out == *decline* && $out == *init* ]]'
for c in init setup inboxes send list show reply ack "done" decline; do
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
run send --to alice --subject s; expect "send to self fails" '[[ $rc != 0 && $out == *"is you"* ]]'
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
expect "custom status swap" '[[ $out == "#5 seen" ]] && logged "issue edit 5 -R acme/ops-parley --add-label state/seen --remove-label state/new"' "$(cat "$STUB_LOG")"

# --- list
list_json 2026-11-05T10:00:00Z
reset; run list
expect "list asks for open messages to me" 'logged "issue list -R acme/team-parley --state open --label to:alice"'
expect "list row format" '[[ $(head -1 <<<"$out") == "#7 from:bob open "*"s \"Review the PR\" https://x/7" ]]' "$out"
expect "list shows both rows" '[[ $(wc -l <<<"$out") -eq 2 ]]'
reset; run list --sent --all; expect "list --sent --all" 'logged "--state all --label from:alice"'
run list --json; expect "list --json is normalized" '[[ $(jq -r ".[1] | [.number,.subject,.from,.to,.status] | join(\",\")" <<<"$out") == "8,Second ask,bob,alice,acknowledged" ]]' "$out"
echo '[]' > "$team.issues.json"; run list; expect "list empty" '[[ $out == "no messages" ]]'

# --- ack / done / decline
issue "$team" 7 OPEN to:alice from:bob status:open
issue "$team" 8 OPEN to:bob from:alice status:open
issue "$team" 9 OPEN to:alice from:bob status:acknowledged
issue "$team" 10 OPEN to:alice from:bob status:open status:acknowledged
issue "$team" 11 OPEN bug
issue "$team" 12 CLOSED to:alice from:bob status:done
reset; run ack 7
expect "ack swaps open to acknowledged" '[[ $rc == 0 && $out == "#7 acknowledged" ]] && logged "issue edit 7 -R acme/team-parley --add-label status:acknowledged --remove-label status:open"' "$(cat "$STUB_LOG")"
expect "ack does not close" '! logged "issue close"'
reset; "$px" "done" 9 "merged it" >/dev/null
expect "done swaps label" 'logged "--add-label status:done --remove-label status:acknowledged"'
expect "done closes with note" 'logged "issue close 9 -R acme/team-parley --comment merged it"'
reset; "$px" "done" 7 >/dev/null; expect "done without note closes" 'logged "issue close 7 -R acme/team-parley"'
expect "done without note has no comment" '! logged "--comment"'
reset; "$px" decline 7 not now please >/dev/null
expect "decline swaps label" 'logged "--add-label status:declined --remove-label status:open"'
expect "decline closes with reason" 'logged "--comment Declined: not now please"'
run decline 7; expect "decline needs a reason" '[[ $rc != 0 && $out == *usage:* ]]'
reset; "$px" "done" 10 >/dev/null
expect "exactly one status label remains" 'logged "--add-label status:done --remove-label status:open --remove-label status:acknowledged"' "$(cat "$STUB_LOG")"

# --- errors
reset; run ack 8
expect "ack on someone else's message fails" '[[ $rc != 0 && $out == *"addressed to bob"* ]]' "$out"
expect "wrong recipient makes no edit" '! logged "issue edit"'
run ack 404; expect "unknown issue" '[[ $rc != 0 && $out == *"no message #404"* ]]' "$out"
run ack 11; expect "non-parley issue" '[[ $rc != 0 && $out == *"not a parley message"* ]]' "$out"
run ack 12; expect "closed message" '[[ $rc != 0 && $out == *"already closed"* ]]' "$out"
run ack abc; expect "non-numeric issue" '[[ $rc != 0 && $out == *numeric* ]]'
out=$(STUB_NO_AUTH=1 "$px" list 2>&1); rc=$?
expect "missing gh auth fails clearly" '[[ $rc != 0 && $out == *"not authenticated"* ]]'

# --- show / reply
reset; "$px" show 7 >/dev/null; expect "show prints comments" 'logged "issue view 7 -R acme/team-parley --comments"'
reset; "$px" show 7 --json >/dev/null; expect "show --json" 'logged "issue view 7 -R acme/team-parley --json number,title,body"'
reset; "$px" reply 7 hello there >/dev/null; expect "reply comments" 'logged "issue comment 7 -R acme/team-parley --body hello there"'
reset; echo "from stdin" | "$px" reply 7 - >/dev/null; expect "reply reads stdin" 'logged "--body from stdin"'
issue "$team" 13 OPEN to:bob from:bob status:open
run reply 13 hi; expect "reply on a stranger's thread fails" '[[ $rc != 0 && $out == *"not you"* ]]'

# --- polling check
chk="$root/checks/parley.check.sh"
unseal() { rm -f "$XDG_STATE_HOME"/parley-axi/*.last-check; }
list_json 2026-11-05T10:00:00Z
out=$(bash "$chk"); rc=$?
expect "check prints one line for new messages" '[[ $rc == 0 && $(wc -l <<<"$out") -eq 1 && $out == "parley: 2 new or updated message(s) from bob: #7 Review the PR; #8 Second ask - read with: parley-axi list" ]]' "$out"
out=$(bash "$chk"); expect "check is rate limited" '[[ -z $out ]]'
unseal; out=$(bash "$chk"); expect "check prints nothing for already seen" '[[ -z $out ]]' "$out"
list_json 2026-11-05T11:00:00Z; unseal; out=$(bash "$chk")
expect "check reports updated messages again" '[[ $out == "parley: 2 new or updated message(s)"* ]]' "$out"
list_json 2026-11-05T12:00:00Z; unseal; out=$(STUB_GH_FAIL=1 bash "$chk" 2>&1); rc=$?
expect "check is silent and exits 0 when gh fails" '[[ $rc == 0 && -z $out ]]' "$out"
unseal; out=$(bash "$chk"); expect "check recovers after failure" '[[ $out == "parley: 2 new or updated message(s)"* ]]'
echo '[]' > "$team.issues.json"; unseal; out=$(bash "$chk"); expect "check is silent with no messages" '[[ -z $out ]]'
expect "check forgets closed messages" '[ ! -s "$XDG_STATE_HOME/parley-axi/default.seen" ]'
jq -n --arg t "$now" '[{number:5, title:"Ops ask", createdAt:$t, updatedAt:$t, url:"u", state:"OPEN", labels:[{name:"for/alice"},{name:"by/carol"}]}]' > "$ops.issues.json"
out=$(bash "$chk" ops); expect "check takes an inbox argument" '[[ $out == "parley: 1 new or updated message(s) from carol: #5 Ops ask - read with: parley-axi --inbox ops list" ]]' "$out"
out=$(XDG_CONFIG_HOME="$tmp/none" bash "$chk" other 2>&1); rc=$?
expect "check is silent without local config" '[[ $rc == 0 && -z $out ]]' "$out"

echo; [ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
