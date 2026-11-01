#!/usr/bin/env bash
# repo-suite-poll.sh - carbon's post-merge AND pre-merge signal for j0yen/dotfiles and j0yen/vibecode-kit: the hermetic suite
# (repo-suite.sh) on every unseen sha, posted to GitHub as the commit status `carbon/repo-suite`.
#   decisions/2026-10-24-dotfiles-vibecode-kit-decisions-graded-wwhtbt.md mechanisms 4+5 and Fable regrade items 2, 4, 9.
#   repo-suite-poll.sh              one poll (the repo-suite.timer unit runs this)
#   repo-suite-poll.sh --seed REPO SHA   queue one sha to be run even though it was seen (REPO = j0yen/dotfiles | dotfiles)
#   repo-suite-poll.sh --selftest   hermetic: fake gh + fake runner + a local bare repo, a throwaway state dir
# Unseen shas, per repo: `git ls-remote origin refs/heads/main` (one sha) + `gh pr list --state open --json number,headRefOid,
# isCrossRepository` (one per open PR; a cross-repo/fork PR is never run: its code would execute on carbon) + the --seed queue.
# Per unseen sha: a throwaway worktree of the repo's bare mirror under $STATE/wt/ (never /tmp), the suite in the bwrap runner, a log at
# $STATE/logs/<name>-<sha>.log, and
#   gh api repos/R/statuses/SHA -f context=carbon/repo-suite -f state=pending|success|failure|error -f description="<sha7> exit=<n> log=<path>"
# pending at the start, the final state at the end. suite exit 0 -> success, 1 -> failure; any other exit (2 refused, 124/137 killed,
# a crash) is an infrastructure fault, not a verdict: the sha is retried on the next poll and after MAX_ATTEMPTS posts `error`.
# A finished sha whose final status could not be posted (network) is re-posted from its log without re-running.
# The reader is swarm-decide prstate.ci_main: it trusts `success` only when the description's log=<path> exists on this host.
# Seen-sha state: $STATE/seen.json. Fleet-dash file: ~/.cache/fleet-dash/repo-suite.json = {repo: {sha, state, age_s, pass, fail, ts,
# unseen, unseen_oldest_s, ...}} (sha/state = origin/main's head; unseen_oldest_s over main + PR shas; collector: carbon.repo_suite).
# One poll starts a new sha only while it is under BUDGET_S (900 s) old, so a poll ends inside the unit's TimeoutStartSec=40min
# (the runner's own cap is 20 min wall). Carbon only: the unit's ExecCondition checks the hostname and the ROOM.
# Env (tests): REPO_SUITE_STATE REPO_SUITE_JSON REPO_SUITE_GH REPO_SUITE_RUNNER REPO_SUITE_REPOS ("R kind [url]" lines) REPO_SUITE_BUDGET_S
#   REPO_SUITE_MAX_ATTEMPTS REPO_SUITE_RUN_TIMEOUT
# Exit: 0 poll done (or another poll holds the lock), 64 usage.
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
STATE=${REPO_SUITE_STATE:-$HOME/.local/state/repo-suite}
JSON_OUT=${REPO_SUITE_JSON:-$HOME/.cache/fleet-dash/repo-suite.json}
GH=${REPO_SUITE_GH:-gh}
RUNNER=${REPO_SUITE_RUNNER:-$HERE/repo-suite.sh}
BUDGET_S=${REPO_SUITE_BUDGET_S:-900}
MAX_ATTEMPTS=${REPO_SUITE_MAX_ATTEMPTS:-3}
RUN_TIMEOUT=${REPO_SUITE_RUN_TIMEOUT:-1260}
CONTEXT=carbon/repo-suite
REPOS=${REPO_SUITE_REPOS-'j0yen/dotfiles dotfiles
j0yen/vibecode-kit plain'}
SEEN=$STATE/seen.json
now() { date +%s; }
iso() { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%SZ; }
note() { echo "repo-suite-poll: $*" >&2; }

# ---- seen.json ------------------------------------------------------------------------------------------------------------------
seen_init() { mkdir -p "$STATE/logs" "$STATE/wt" "$STATE/work" "$STATE/mirrors"; [ -s "$SEEN" ] && jq -e . "$SEEN" >/dev/null 2>&1 || echo '{"shas":{},"queue":[]}' > "$SEEN"; }
seen_mut() { local tmp; tmp=$(mktemp "$STATE/.seen.XXXXXX") && jq "$@" "$SEEN" > "$tmp" && mv "$tmp" "$SEEN" || { rm -f "$tmp"; note "seen.json update failed"; return 1; }; }
e_get() { jq -r --arg r "$1" --arg s "$2" --arg f "$3" '.shas[$r][$s][$f] // empty' "$SEEN"; }
e_put() { seen_mut --arg r "$1" --arg s "$2" --argjson o "$3" '.shas[$r][$s] = ((.shas[$r][$s] // {}) + $o)'; }

post_status() {  # R SHA STATE DESC
  "$GH" api "repos/$1/statuses/$2" -f "context=$CONTEXT" -f "state=$3" -f "description=$4" >/dev/null 2>&1
}
logpath() { echo "$STATE/logs/$1-$2.log"; }

memwatch() { local f=$1 m v; m=$(awk '/MemAvailable/{print $2}' /proc/meminfo); while :; do v=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "$v" -lt "$m" ] && m=$v; echo "$m" > "$f"; sleep 5 9>&-; done; }

# ---- one sha --------------------------------------------------------------------------------------------------------------------
run_one() {  # R name kind mirror sha label
  local R=$1 name=$2 kind=$3 mirror=$4 sha=$5 label=$6 s7=${5:0:7} wt work log rc att st started pass fail mb mm wp
  wt=$STATE/wt/$name-$s7; work=$STATE/work/$name-$s7; log=$(logpath "$name" "$sha")
  git -C "$mirror" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt" "$work"; git -C "$mirror" worktree prune >/dev/null 2>&1
  if ! git -C "$mirror" cat-file -e "$sha^{commit}" 2>/dev/null; then
    note "$R $sha ($label): not in the mirror (force-pushed away?)"; e_put "$R" "$sha" '{"state":"gone"}'; return 0
  fi
  git -C "$mirror" worktree add --detach "$wt" "$sha" >/dev/null 2>&1 || { note "$R $sha: worktree add failed"; return 1; }
  mkdir -p "$work"
  att=$(( $(e_get "$R" "$sha" attempts | sed 's/^$/0/') + 1 )); started=$(now)
  { echo "repo-suite $R $sha ($label) kind=$kind attempt=$att started=$(iso "$started")"; } > "$log"
  e_put "$R" "$sha" "{\"state\":\"running\",\"attempts\":$att,\"started\":$started,\"log\":\"$log\"}"
  post_status "$R" "$sha" pending "$s7 exit=- log=$log" || note "$R $sha: pending post failed"
  mm=$work/memmin; mb=$(awk '/MemAvailable/{print $2}' /proc/meminfo); memwatch "$mm" 9>&- & wp=$!
  timeout -k 30 "$RUN_TIMEOUT" "$RUNNER" "$wt" "$name-$s7" "$work" "$kind" > "$work/runner.out" 2>&1 < /dev/null 9>&-; rc=$?
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  local sum=$work/$name-$s7/summary.txt
  pass=$(sed -n 's/^SUMMARY .* pass=\([0-9]*\) .*/\1/p' "$sum" 2>/dev/null | tail -n1); fail=$(sed -n 's/^SUMMARY .* fail=\([0-9]*\) .*/\1/p' "$sum" 2>/dev/null | tail -n1)
  pass=${pass:-0}; fail=${fail:-0}
  {
    [ -s "$sum" ] && cat "$sum" || { echo "(no summary.txt)"; tail -n 20 "$work/runner.out"; }
    echo "MEM_AVAILABLE_KB before=$mb min=$(cat "$mm" 2>/dev/null || echo "$mb")"
    if [ -s "$work/$name-$s7/reds-tails.txt" ]; then echo "--- red tails ---"; cat "$work/$name-$s7/reds-tails.txt"; fi
    echo "EXIT=$rc pass=$pass fail=$fail finished=$(iso)"
  } >> "$log"
  case $rc in
    0) st=success ;;
    1) st=failure ;;
    *) if [ "$att" -ge "$MAX_ATTEMPTS" ]; then st=error; else st=retry; fi ;;
  esac
  git -C "$mirror" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt" "$work"; git -C "$mirror" worktree prune >/dev/null 2>&1
  e_put "$R" "$sha" "{\"state\":\"$st\",\"exit\":$rc,\"pass\":$pass,\"fail\":$fail,\"ts\":$(now),\"posted\":\"pending\"}"
  if [ "$st" = retry ]; then note "$R $sha: infrastructure exit=$rc (attempt $att/$MAX_ATTEMPTS), retry next poll"; return 0; fi
  if post_status "$R" "$sha" "$st" "$s7 exit=$rc log=$log"; then e_put "$R" "$sha" "{\"posted\":\"$st\"}"; else note "$R $sha: final post failed, will re-post"; fi
  return 0
}

repost_finals() {  # R name: finals whose last posted state is not the final one
  local R=$1 name=$2 sha st rc log
  while IFS=$'\t' read -r sha st rc; do
    [ -n "$sha" ] || continue
    log=$(logpath "$name" "$sha"); [ -s "$log" ] || continue
    if post_status "$R" "$sha" "$st" "${sha:0:7} exit=$rc log=$log"; then e_put "$R" "$sha" "{\"posted\":\"$st\"}"; else note "$R $sha: re-post failed"; fi
  done < <(jq -r --arg r "$R" '.shas[$r] // {} | to_entries[] | select((.value.state=="success" or .value.state=="failure" or .value.state=="error") and .value.posted != .value.state) | [.key,.value.state,(.value.exit//0)] | @tsv' "$SEEN")
}

# ---- one repo -------------------------------------------------------------------------------------------------------------------
POLL_START=$(now)
ran_total=0
poll_repo() {  # R kind url
  local R=$1 kind=$2 url=${3:-https://github.com/$1.git} name=${1##*/} mirror main_sha prs n sha cross t0 label
  mirror=$STATE/mirrors/$name.git
  [ -d "$mirror" ] || { git init -q --bare "$mirror" && git -C "$mirror" remote add origin "$url"; } || { note "$R: mirror init failed"; return 0; }
  git -C "$mirror" remote set-url origin "$url" 2>/dev/null
  main_sha=$(timeout 60 git -C "$mirror" ls-remote origin refs/heads/main 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$main_sha" ]; then note "$R: ls-remote main failed"; echo "$R" >> "$STATE/.lsremote-failed"; return 0; fi
  echo "$R $main_sha" >> "$STATE/.mains"
  prs=$(timeout 60 "$GH" pr list --repo "$R" --state open --json number,headRefOid,isCrossRepository --limit 100 2>/dev/null | jq -r '.[] | [.number,.headRefOid,(.isCrossRepository // false)] | @tsv' 2>/dev/null) || prs=""
  # observed: "sha<TAB>label", main first, then seeds, then PRs by number; each sha once
  local obs=() seenset=" "
  add() { case "$seenset" in *" $1 "*) return ;; esac; seenset="$seenset$1 "; obs+=("$1"$'\t'"$2"); }
  add "$main_sha" main
  while IFS= read -r sha; do [ -n "$sha" ] && add "$sha" seed; done < <(jq -r --arg r "$R" --arg n "$name" '.queue[] | select(.repo==$r or .repo==$n) | .sha' "$SEEN")
  while IFS=$'\t' read -r n sha cross; do
    [ -n "$n" ] || continue
    if [ "$cross" = true ]; then note "$R#$n: cross-repo PR, not run"; continue; fi
    add "$sha" "pr#$n"
  done < <(printf '%s\n' "$prs" | sort -n)
  local nowt; nowt=$(now)
  # record first-seen; prune unseen/running entries that are no longer observed
  local entry lst=""
  for entry in "${obs[@]}"; do
    sha=${entry%%$'\t'*}; label=${entry#*$'\t'}
    if [ -z "$(e_get "$R" "$sha" state)" ]; then e_put "$R" "$sha" "{\"state\":\"unseen\",\"first\":$nowt,\"label\":\"$label\"}"; else e_put "$R" "$sha" "{\"label\":\"$label\"}"; fi
    lst="$lst\"$sha\","
  done
  seen_mut --arg r "$R" --argjson keep "[${lst%,}]" '.shas[$r] |= (to_entries | map(select((.value.state | IN("unseen","running","retry") | not) or (.key as $k | $keep | index($k)))) | from_entries)'
  repost_finals "$R" "$name"
  # run what is unseen
  local need=0
  for entry in "${obs[@]}"; do sha=${entry%%$'\t'*}; case "$(e_get "$R" "$sha" state)" in unseen|running|retry) need=1 ;; esac; done
  if [ "$need" = 1 ]; then
    timeout 300 git -C "$mirror" fetch -q origin '+refs/heads/main:refs/heads/main' >/dev/null 2>&1 || note "$R: fetch main failed"
  fi
  for entry in "${obs[@]}"; do
    sha=${entry%%$'\t'*}; label=${entry#*$'\t'}
    case "$(e_get "$R" "$sha" state)" in unseen|running|retry) ;; *) continue ;; esac
    if [ "$ran_total" -gt 0 ] && [ $(( $(now) - POLL_START )) -ge "$BUDGET_S" ]; then note "budget ${BUDGET_S}s reached: $R $sha ($label) waits for the next poll"; continue; fi
    case "$label" in pr#*) timeout 120 git -C "$mirror" fetch -q origin "+refs/pull/${label#pr#}/head:refs/pull/${label#pr#}/head" >/dev/null 2>&1 || true ;; esac
    run_one "$R" "$name" "$kind" "$mirror" "$sha" "$label" && ran_total=$((ran_total + 1))
  done
  # a queue entry is done once its sha is final
  seen_mut --arg r "$R" --arg n "$name" '. as $d | .queue |= map(select(((.repo==$r or .repo==$n) | not) or (($d.shas[$r][.sha].state // "") | IN("success","failure","error") | not)))'
}

# ---- fleet-dash json ------------------------------------------------------------------------------------------------------------
write_json() {
  local nowt tmp prev failed; nowt=$(now); mkdir -p "$(dirname "$JSON_OUT")"
  prev=$(jq -c . "$JSON_OUT" 2>/dev/null || echo '{}'); [ -n "$prev" ] || prev='{}'
  failed=$(sort -u "$STATE/.lsremote-failed" 2>/dev/null | jq -R . | jq -sc . 2>/dev/null || echo '[]'); [ -n "$failed" ] || failed='[]'
  tmp=$(mktemp "$(dirname "$JSON_OUT")/.repo-suite.XXXXXX") || return 1
  jq --argjson prev "$prev" --argjson failed "$failed" --argjson now "$nowt" --arg iso "$(iso "$nowt")" --arg repos "$REPOS" --arg mains "$(cat "$STATE/.mains" 2>/dev/null)" '
    def pstate: if . == "running" or . == "retry" then "pending" else . end;
    ($mains | split("\n") | map(select(length>0) | split(" ")) | map({key:.[0], value:.[1]}) | from_entries) as $main
    | . as $d
    | reduce ($repos | split("\n")[] | select(length>0) | split(" ")[0]) as $r ({};
        if ($failed | index($r)) then .[$r] = (($prev[$r] // {}) + {error:"ls-remote failed"})
        else
          ($main[$r] // "") as $m
          | ($d.shas[$r] // {}) as $e
          | ($e[$m] // {}) as $me
          | ([$e | to_entries[] | select(.value.state | IN("unseen","running","retry")) | ($now - (.value.first // $now))] | sort) as $ages
          | .[$r] = {sha:$m, state:(($me.state // "unseen") | pstate),
                     age_s:(if ($me.state // "unseen") | IN("success","failure","error") then ($now - ($me.ts // $now)) else ($now - ($me.first // $now)) end),
                     pass:($me.pass // null), fail:($me.fail // null), ts:$iso,
                     unseen:($ages | length), unseen_oldest_s:(if ($ages|length)>0 then $ages[-1] else 0 end),
                     log:($me.log // null)}
        end)' "$SEEN" > "$tmp" && mv "$tmp" "$JSON_OUT" || { rm -f "$tmp"; note "json write failed"; return 1; }
}

poll() {
  seen_init
  exec 9> "$STATE/poll.lock"
  flock -n 9 || { echo "repo-suite-poll: another poll holds the lock"; return 0; }
  : > "$STATE/.lsremote-failed"; : > "$STATE/.mains"
  local R kind url
  while read -r R kind url; do
    [ -n "$R" ] || continue
    poll_repo "$R" "$kind" "$url"
  done <<< "$REPOS"
  write_json
  # keep seen.json bounded: finals older than 60 days go
  seen_mut --argjson cut "$(( $(now) - 5184000 ))" '.shas |= with_entries(.value |= with_entries(select((.value.state | IN("success","failure","error","gone") | not) or ((.value.ts // $cut + 1) > $cut))))'
  return 0
}

seed() {  # R SHA
  local R=$1 sha=$2 full=""
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "repo-suite-poll: --seed wants a 40-hex sha" >&2; exit 64; }
  seen_init
  local line r k u
  while read -r r k u; do [ "$r" = "$R" ] || [ "${r##*/}" = "$R" ] && full=$r; done <<< "$REPOS"
  [ -n "$full" ] || { echo "repo-suite-poll: unknown repo $R" >&2; exit 64; }
  seen_mut --arg r "$full" --arg s "$sha" '.queue += [{repo:$r,sha:$s}] | del(.shas[$r][$s])' && echo "seeded $full $sha"
}

# ---- selftest -------------------------------------------------------------------------------------------------------------------
selftest() {
  local pass=0 fail=0 g="git -c user.name=t -c user.email=t@t"
  T=$(mktemp -d "${TMPDIR:-/tmp}/repo-suite-poll-st.XXXXXX") || exit 2
  trap 'rm -rf "${T:-/nonexistent}"' EXIT
  ck() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi; }
  # a bare "origin" with main (2 commits) and a PR ref
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$T/src"; ( cd "$T/src" && echo 1 > f && git add f && $g commit -qm c1 && echo 2 > f && $g commit -qam c2 && git push -q "$T/remote.git" main )
  local m1; m1=$(git -C "$T/src" rev-parse HEAD)
  ( cd "$T/src" && git checkout -q -b pr7 && echo p > p && git add p && $g commit -qm p1 && git push -q "$T/remote.git" pr7:refs/pull/7/head )
  local p7a; p7a=$(git -C "$T/src" rev-parse HEAD); git -C "$T/src" checkout -q main
  # fake gh: `pr list` prints $FD/prs.json; `api repos/R/statuses/SHA -f k=v ...` appends "SHA state description" to $FD/posts.log
  mkdir -p "$T/fd"; cat > "$T/gh" <<'EOF'
#!/bin/bash
FD=$(dirname "$0")/fd
case "$1 $2" in
  "pr list") cat "$FD/prs.json" ;;
  "api repos"*|"api "*) path=$2; shift 2; st=; ds=; cx=
     while [ $# -gt 0 ]; do case "$1" in -f) case "$2" in state=*) st=${2#state=};; description=*) ds=${2#description=};; context=*) cx=${2#context=};; esac; shift ;; esac; shift; done
     [ -z "$FAKE_POST_FAIL" ] || exit 1
     echo "${path##*/} $cx $st $ds" >> "$FD/posts.log" ;;
  *) exit 99 ;;
esac
EOF
  # fake runner: exit code from $FD/rc-<sha7> (default 0); writes summary.txt like the real one; counts its calls
  cat > "$T/runner" <<'EOF'
#!/bin/bash
FD=$(dirname "$0")/fd; tree=$1 label=$2 out=$3
mkdir -p "$out/$label"; s7=${label##*-}; rc=0; [ -f "$FD/rc-$s7" ] && rc=$(cat "$FD/rc-$s7")
echo "$label" >> "$FD/runs.log"
[ -f "$tree/f" ] || { echo "tree has no f" >&2; exit 5; }
{ echo "TREE $tree"; echo "SUMMARY label=$label pass=7 fail=$([ $rc = 1 ] && echo 2 || echo 0) skipped=1 slow>60s=0 wall=1s"; } > "$out/$label/summary.txt"
[ "$rc" = 1 ] && echo "=== brokentest RC1" > "$out/$label/reds-tails.txt"
exit "$rc"
EOF
  chmod +x "$T/gh" "$T/runner"
  echo '[]' > "$T/fd/prs.json"
  export REPO_SUITE_STATE=$T/state REPO_SUITE_JSON=$T/out/repo-suite.json REPO_SUITE_GH=$T/gh REPO_SUITE_RUNNER=$T/runner REPO_SUITE_REPOS="j0yen/dotfiles dotfiles $T/remote.git" REPO_SUITE_BUDGET_S=900
  local P="$T/fd/posts.log" R="$T/fd/runs.log" J="$T/out/repo-suite.json" S="$T/state"
  local p
  p=$(printf '[{"number":7,"headRefOid":"%s","isCrossRepository":false},{"number":8,"headRefOid":"%s","isCrossRepository":true}]' "$p7a" "$(printf 'f%.0s' $(seq 40))")
  echo "$p" > "$T/fd/prs.json"
  # 1. first poll: main + PR7 run, PR8 (fork) does not; PR7's suite is red
  echo 1 > "$T/fd/rc-${p7a:0:7}"
  "$SELF" >"$T/o1" 2>&1; ck "poll 1 exits 0" $?
  [ "$(wc -l < "$R")" = 2 ]; ck "poll 1 ran exactly main + PR7 (fork PR skipped): $(wc -l < "$R") runs" $?
  grep -q "^$m1 carbon/repo-suite pending ${m1:0:7} exit=- log=$S/logs/dotfiles-$m1.log\$" "$P"; ck "main: pending first, description '<sha7> exit=- log=<path>'" $?
  grep -q "^$m1 carbon/repo-suite success ${m1:0:7} exit=0 log=$S/logs/dotfiles-$m1.log\$" "$P"; ck "main: final success exit=0 with the log path" $?
  grep -q "^$p7a carbon/repo-suite failure ${p7a:0:7} exit=1 log=" "$P"; ck "PR7 head: suite exit 1 -> failure" $?
  [ -s "$S/logs/dotfiles-$m1.log" ] && grep -q "EXIT=0 pass=7 fail=0" "$S/logs/dotfiles-$m1.log"; ck "log written with the summary and EXIT line" $?
  grep -q "=== brokentest RC1" "$S/logs/dotfiles-$p7a.log"; ck "red log carries the red tails" $?
  [ "$(jq -r '.["j0yen/dotfiles"] | "\(.sha) \(.state) \(.pass) \(.fail) \(.unseen)"' "$J")" = "$m1 success 7 0 0" ]; ck "repo-suite.json: main sha, success, pass 7, fail 0, unseen 0 ($(jq -c '.["j0yen/dotfiles"]|{state,pass,fail,age_s,unseen}' "$J"))" $?
  [ -z "$(find "$S/wt" "$S/work" -mindepth 1 2>/dev/null)" ]; ck "worktrees and work dirs removed" $?
  # 2. second poll: nothing is unseen, nothing posted, nothing run
  local pn rn; pn=$(wc -l < "$P"); rn=$(wc -l < "$R"); "$SELF" >"$T/o2" 2>&1
  [ "$(wc -l < "$P")" = "$pn" ] && [ "$(wc -l < "$R")" = "$rn" ]; ck "poll 2: seen shas are not re-run or re-posted" $?
  # 3. a new main commit and a new PR7 head: both run; the old shas do not
  ( cd "$T/src" && echo 3 > f && $g commit -qam c3 && git push -q "$T/remote.git" main && git checkout -q pr7 && echo q >> p && $g commit -qam p2 && git push -q "$T/remote.git" pr7:refs/pull/7/head && git checkout -q main )
  local m2 p7b; m2=$(git -C "$T/src" rev-parse main); p7b=$(git -C "$T/src" rev-parse pr7)
  echo "[{\"number\":7,\"headRefOid\":\"$p7b\",\"isCrossRepository\":false}]" > "$T/fd/prs.json"
  rn=$(wc -l < "$R"); "$SELF" >"$T/o3" 2>&1
  [ "$(( $(wc -l < "$R") - rn ))" = 2 ] && grep -q "^$m2 carbon/repo-suite success" "$P" && grep -q "^$p7b carbon/repo-suite success" "$P"; ck "poll 3: the new main sha and the new PR head each ran once and passed" $?
  # 4. infrastructure exit (2): no final status, retried; the 3rd attempt posts error
  ( cd "$T/src" && echo 4 > f && $g commit -qam c4 && git push -q "$T/remote.git" main ); local m3; m3=$(git -C "$T/src" rev-parse main)
  echo '[]' > "$T/fd/prs.json"; echo 2 > "$T/fd/rc-${m3:0:7}"
  "$SELF" >"$T/o4" 2>&1; ! grep -qE "^$m3 carbon/repo-suite (success|failure|error)" "$P" && grep -q "^$m3 carbon/repo-suite pending" "$P"; ck "infra exit 2 (attempt 1): pending only, no verdict" $?
  [ "$(jq -r '.["j0yen/dotfiles"].state' "$J")" = pending ]; ck "json says pending while retrying" $?
  "$SELF" >"$T/o4" 2>&1; ! grep -qE "^$m3 carbon/repo-suite (success|failure|error)" "$P"; ck "infra exit 2 (attempt 2): still no verdict" $?
  "$SELF" >"$T/o4" 2>&1; grep -q "^$m3 carbon/repo-suite error ${m3:0:7} exit=2 log=" "$P"; ck "infra exit 2 (attempt 3): posts error exit=2" $?
  # 5. a failed final post is re-posted from the log without re-running
  ( cd "$T/src" && echo 5 > f && $g commit -qam c5 && git push -q "$T/remote.git" main ); local m4; m4=$(git -C "$T/src" rev-parse main)
  rn=$(wc -l < "$R"); FAKE_POST_FAIL=1 "$SELF" >"$T/o5" 2>&1
  [ "$(( $(wc -l < "$R") - rn ))" = 1 ] && ! grep -q "^$m4 carbon/repo-suite success" "$P"; ck "gh down: the suite ran once, no status landed" $?
  "$SELF" >"$T/o5" 2>&1
  grep -q "^$m4 carbon/repo-suite success ${m4:0:7} exit=0 log=" "$P" && [ "$(( $(wc -l < "$R") - rn ))" = 1 ]; ck "gh back: the final status is re-posted, the suite is not re-run" $?
  # 6. --seed re-runs a seen sha once
  rn=$(wc -l < "$R"); "$SELF" --seed dotfiles "$m1" >/dev/null && "$SELF" >"$T/o6" 2>&1
  [ "$(( $(wc -l < "$R") - rn ))" = 1 ] && [ "$(jq -r --arg s "$m1" '.queue | length' "$S/seen.json")" = 0 ] && [ "$(jq -r --arg s "$m1" '.shas["j0yen/dotfiles"][$s].state' "$S/seen.json")" = success ]; ck "--seed: the seen sha ran again once and left the queue" $?
  "$SELF" --seed dotfiles nothex >/dev/null 2>&1; [ $? = 64 ]; ck "--seed with a bad sha -> 64" $?
  # 7. budget: with BUDGET_S=0 only the first of two unseen shas runs per poll; the other is unseen and ages in the json
  ( cd "$T/src" && echo 6 > f && $g commit -qam c6 && git push -q "$T/remote.git" main ); local m5; m5=$(git -C "$T/src" rev-parse main)
  ( cd "$T/src" && git checkout -q pr7 && echo r >> p && $g commit -qam p3 && git push -q "$T/remote.git" pr7:refs/pull/7/head && git checkout -q main ); local p7c; p7c=$(git -C "$T/src" rev-parse pr7)
  echo "[{\"number\":7,\"headRefOid\":\"$p7c\",\"isCrossRepository\":false}]" > "$T/fd/prs.json"
  rn=$(wc -l < "$R"); REPO_SUITE_BUDGET_S=0 "$SELF" >"$T/o7" 2>&1
  [ "$(( $(wc -l < "$R") - rn ))" = 1 ] && [ "$(jq -r '.["j0yen/dotfiles"].unseen' "$J")" = 1 ]; ck "budget reached: one run, one sha left unseen (json unseen=1)" $?
  REPO_SUITE_BUDGET_S=0 "$SELF" >"$T/o7" 2>&1
  [ "$(jq -r '.["j0yen/dotfiles"].unseen' "$J")" = 0 ]; ck "the next poll runs the waiting sha (unseen=0)" $?
  # 8. an unseen sha's age is in the json; a PR that disappeared is pruned
  printf '#!/bin/bash\nexit 2\n' > "$T/runner_infra"; chmod +x "$T/runner_infra"
  ( cd "$T/src" && echo 7 > f && $g commit -qam c7 && git push -q "$T/remote.git" main && git checkout -q -b pr9 && echo z > z && git add z && $g commit -qm z1 && git push -q "$T/remote.git" pr9:refs/pull/9/head && git checkout -q main )
  local m6 p9; m6=$(git -C "$T/src" rev-parse main); p9=$(git -C "$T/src" rev-parse pr9)
  echo "[{\"number\":9,\"headRefOid\":\"$p9\",\"isCrossRepository\":false}]" > "$T/fd/prs.json"
  REPO_SUITE_RUNNER=$T/runner_infra REPO_SUITE_MAX_ATTEMPTS=9 "$SELF" >"$T/o8" 2>&1
  [ "$(jq -r --arg s "$p9" '.shas["j0yen/dotfiles"][$s].state' "$S/seen.json")" = retry ]; ck "an infra-failed PR head stays 'retry' (unseen) while the PR is open" $?
  jq --arg s "$m6" '.shas["j0yen/dotfiles"][$s].first -= 7300' "$S/seen.json" > "$T/seen.tmp" && mv "$T/seen.tmp" "$S/seen.json"
  REPO_SUITE_RUNNER=$T/runner_infra REPO_SUITE_MAX_ATTEMPTS=9 "$SELF" >"$T/o8" 2>&1
  [ "$(jq -r '.["j0yen/dotfiles"] | (.unseen_oldest_s > 7200)' "$J")" = true ]; ck "unseen_oldest_s > 7200 after main's sha waited 2 h ($(jq -r '.["j0yen/dotfiles"].unseen_oldest_s' "$J") s)" $?
  echo '[]' > "$T/fd/prs.json"; REPO_SUITE_RUNNER=$T/runner_infra REPO_SUITE_MAX_ATTEMPTS=9 "$SELF" >"$T/o8" 2>&1
  [ "$(jq -r --arg s "$p9" '.shas["j0yen/dotfiles"][$s] // "gone"' "$S/seen.json")" = gone ]; ck "a PR that closed before its sha finished is pruned" $?
  # 9. lock: a second poll while one holds the lock exits 0 without work
  ( exec 8> "$S/poll.lock"; flock 8; "$SELF" > "$T/o9" 2>&1 ); grep -q "another poll holds the lock" "$T/o9"; ck "a held lock -> the second poll steps aside" $?
  # 10. description fits GitHub's 140 characters with the real log path
  local d="abcdefg exit=124 log=/home/jsy/.local/state/repo-suite/logs/vibecode-kit-$(printf 'a%.0s' $(seq 40)).log"
  [ "${#d}" -le 140 ]; ck "worst-case description is ${#d} <= 140 chars" $?
  # 11. ls-remote failure keeps the old json entry and marks the error
  REPO_SUITE_REPOS="j0yen/dotfiles dotfiles $T/nonexistent.git" "$SELF" >"$T/o11" 2>&1
  [ "$(jq -r '.["j0yen/dotfiles"].error' "$J")" = "ls-remote failed" ]; ck "ls-remote failure -> json keeps the entry with error='ls-remote failed'" $?
  echo "repo-suite-poll selftest: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --seed) [ $# -eq 3 ] || { echo "usage: repo-suite-poll.sh --seed REPO SHA" >&2; exit 64; }; seed "$2" "$3"; exit $? ;;
  "") poll; exit $? ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  *) echo "usage: repo-suite-poll.sh [--selftest | --seed REPO SHA]" >&2; exit 64 ;;
esac
