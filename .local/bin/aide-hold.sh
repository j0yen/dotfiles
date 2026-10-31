#!/usr/bin/env bash
# aide-hold.sh place|lift|probe: the grading-hold writer that PROVES a consumer on every acting host (1071 mechanism M4, approvals #125/#110).
# Why: hold #108 was a flag on RedBaron that no RedBaron process read, so run 1071 landed and tagged under it.
#   aide-hold.sh probe
#   aide-hold.sh place --approval <N> --reason "<text>" --expires <iso>
#   aide-hold.sh lift  --approval <N> --reason "<text>"
#   aide-hold.sh --selftest         (runs tests/hold-consumers.test.sh from the repo checkout this script is linked from)
# Canonical flag: ~/.local/state/aide/grading-hold (same default as wm-build land.hold_file). Acting hosts: carbon orch redbaron ryzen7.
# Consumers are DERIVED from each host's units and scripts, never tabled:
#   orch      `systemctl --user cat 'mcphost-deploy-*'`: every .service has a ConditionPathExists=! line on the canonical path (NEVER `show -p`: it prints empty for drop-ins)
#   redbaron/ryzen7  `wm-build config show` land.hold_file = canonical path, else rb-land-hold-watch.timer active AND rb-/r7-land-hold-watch.sh contains the canonical path
#   carbon    rb-merge.sh / fd-merge.sh / grader-backlog-loop.sh in ~/.local/bin contain the canonical path
# place exits non-zero and names the hosts unless, after writing, the probe reads flag=present AND a consumer on every acting host.
# lift writes each consumer's own marker (RB/r7: ~/.local/state/rb-land-hold/premise-lifted), removes the flag, and exits non-zero unless the probe reads every host as not enforcing.
# Output: ~/.cache/fleet-dash/hold-consumers.json {host: {flag: present|absent|unread, consumer, expires, ts}}. An ssh failure is `unread` and keeps the host's previous
# consumer and ts, never `none`. Probe reads are read-only ssh (ConnectTimeout); place/lift write only the two state files above. No secrets printed, no sudo.
# Env (tests): AIDE_HOLD_HOSTS, AIDE_HOLD_OUT, AIDE_HOLD_SSH, AIDE_HOLD_NOW, AIDE_HOLD_LOCAL (host name run locally, default carbon).
set -u

CANON='aide/grading-hold'
FLAG_REL='.local/state/aide/grading-hold'
MARK_REL='.local/state/rb-land-hold/premise-lifted'
read -r -a HOSTS <<< "${AIDE_HOLD_HOSTS:-carbon orch redbaron ryzen7}"
OUT=${AIDE_HOLD_OUT:-$HOME/.cache/fleet-dash/hold-consumers.json}
SSH=${AIDE_HOLD_SSH:-ssh}
LOCAL_HOST=${AIDE_HOLD_LOCAL:-carbon}
NOW=${AIDE_HOLD_NOW:-$(date +%s)}

usage() { echo "usage: aide-hold.sh probe | place --approval N --reason TEXT --expires ISO | lift --approval N --reason TEXT | --selftest" >&2; exit 64; }

# rd HOST CMD: run CMD on HOST (locally for the carbon host), stdin from /dev/null unless piped in by the caller
rd() {
  local h=$1 cmd=$2
  if [ "$h" = "$LOCAL_HOST" ]; then bash -c "$cmd"
  else "$SSH" -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$h" "$cmd"; fi
}

FLAG_CMD='f="$HOME/'$FLAG_REL'"; if [ -e "$f" ]; then echo present; sed -n "s/^EXPIRES=//p" "$f" | head -n 1; else echo absent; fi'
ORCH_CMD="systemctl --user cat 'mcphost-deploy-*' 2>/dev/null; exit 0"
CFG_CMD='b="$HOME/.cargo/bin/wm-build"; if [ -x "$b" ]; then "$b" config show 2>/dev/null | grep -E "hold_file"; fi; exit 0'
WATCH_CMD='if [ "$(systemctl --user is-active rb-land-hold-watch.timer 2>/dev/null)" = active ]; then for s in rb-land-hold-watch.sh r7-land-hold-watch.sh; do if grep -q "'$CANON'" "$HOME/.local/bin/$s" 2>/dev/null; then echo "$s"; fi; done; fi; exit 0'
CARBON_CMD='for s in rb-merge.sh fd-merge.sh grader-backlog-loop.sh; do if grep -q "'$CANON'" "$HOME/.local/bin/$s" 2>/dev/null; then echo "$s"; fi; done; exit 0'

host_class() { case $1 in orch) echo orch;; redbaron|ryzen7) echo watch;; *) echo carbon;; esac; }

# the orch parse: every mcphost-deploy-*.service must carry ConditionPathExists=! on the canonical path (main file or drop-in)
orch_parse() {
  awk -v canon="$CANON" '
    /^# \/.*\.service$/ { n = split($2, a, "/"); cur = a[n]; units[cur] = 1; drop[cur] = ""; next }
    /^# \/.*\.service\.d\/.*\.conf$/ { n = split($2, a, "/"); if (cur != "") drop[cur] = a[n]; next }
    index($0, "ConditionPathExists=!") == 1 && index($0, canon) > 0 { if (cur != "") cov[cur] = 1 }
    END {
      total = 0; hit = 0; name = ""
      for (u in units) { total++; if (cov[u]) { hit++; if (name == "" || (drop[u] != "" && drop[u] < name)) name = drop[u] } }
      if (total > 0 && hit == total) print "mcphost-deploy-*.service " (name == "" ? "ConditionPathExists" : name)
      else print "none"
    }'
}

# consumer_of HOST -> prints a consumer name, `none`, or `UNREAD`
consumer_of() {
  local h=$1 out rc cls; cls=$(host_class "$h")
  case $cls in
    orch)
      out=$(rd "$h" "$ORCH_CMD" </dev/null 2>/dev/null); rc=$?
      [ $rc -eq 0 ] || { echo UNREAD; return; }
      printf '%s\n' "$out" | orch_parse ;;
    watch)
      out=$(rd "$h" "$CFG_CMD" </dev/null 2>/dev/null); rc=$?
      [ $rc -eq 0 ] || { echo UNREAD; return; }
      if printf '%s\n' "$out" | grep -q "$CANON"; then echo "wm-build land.hold_file"; return; fi
      out=$(rd "$h" "$WATCH_CMD" </dev/null 2>/dev/null); rc=$?
      [ $rc -eq 0 ] || { echo UNREAD; return; }
      out=$(printf '%s\n' "$out" | sed -n 1p); echo "${out:-none}" ;;
    *)
      out=$(rd "$h" "$CARBON_CMD" </dev/null 2>/dev/null); rc=$?
      [ $rc -eq 0 ] || { echo UNREAD; return; }
      out=$(printf '%s\n' "$out" | sed -n 1p); echo "${out:-none}" ;;
  esac
}

# probe_rows: one TSV row per host: host flag consumer expires (empty consumer = keep previous)
probe_rows() {
  local h out rc flag exp con
  for h in "${HOSTS[@]}"; do
    out=$(rd "$h" "$FLAG_CMD" </dev/null 2>/dev/null); rc=$?
    flag=$(printf '%s\n' "$out" | sed -n 1p); exp=$(printf '%s\n' "$out" | sed -n 2p)
    if [ $rc -ne 0 ] || { [ "$flag" != present ] && [ "$flag" != absent ]; }; then
      printf '%s\tunread\t\t\n' "$h"; continue
    fi
    con=$(consumer_of "$h"); [ "$con" = UNREAD ] && con=''
    printf '%s\t%s\t%s\t%s\n' "$h" "$flag" "$con" "$exp"
  done
}

do_probe() {
  local rows; rows=$(mktemp "${TMPDIR:-/tmp}/aide-hold-rows.XXXXXX") || return 2
  probe_rows > "$rows"
  mkdir -p "$(dirname "$OUT")"
  python3 -I - "$OUT" "$rows" "$NOW" <<'PY'
import json, os, sys
out, rows, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    prev = json.load(open(out))
    if not isinstance(prev, dict):
        prev = {}
except (OSError, ValueError):
    prev = {}
res = {}
for line in open(rows):
    h, flag, con, exp = (line.rstrip("\n").split("\t") + ["", "", "", ""])[:4]
    old = prev.get(h) if isinstance(prev.get(h), dict) else {}
    if flag == "unread":
        res[h] = {"flag": "unread", "consumer": old.get("consumer") or "unread",
                  "expires": old.get("expires"), "ts": old.get("ts", now)}
    else:
        res[h] = {"flag": flag, "consumer": con or old.get("consumer") or "unread",
                  "expires": exp or None, "ts": now}
lines = ["  %s: %s" % (json.dumps(h), json.dumps(res[h], separators=(", ", ": "))) for h in res]
tmp = out + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    f.write("{\n" + ",\n".join(lines) + "\n}\n")
os.replace(tmp, out)
for h in res:
    r = res[h]
    print("aide-hold: %s flag=%s consumer=%s" % (h, r["flag"], r["consumer"]))
PY
  local rc=$?
  rm -f -- "$rows"
  return $rc
}

# hosts whose probe row says "no consumer or flag not present" (for place)
bad_hosts_place() {
  python3 -I - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for h, r in d.items():
    if r.get("flag") != "present":
        print("%s(flag=%s)" % (h, r.get("flag")))
    elif r.get("consumer") in (None, "", "none", "unread"):
        print("%s(consumer=%s)" % (h, r.get("consumer")))
PY
}

parse_args() {
  APPROVAL=''; REASON=''; EXPIRES=''
  while [ $# -gt 0 ]; do
    case $1 in
      --approval) APPROVAL=${2:-}; shift 2 || usage ;;
      --reason) REASON=${2:-}; shift 2 || usage ;;
      --expires) EXPIRES=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case $APPROVAL in ''|*[!0-9]*) echo "aide-hold: --approval needs a number" >&2; exit 64;; esac
  [ -n "$REASON" ] || { echo "aide-hold: --reason is required" >&2; exit 64; }
}

do_place() {
  parse_args "$@"
  [ -n "$EXPIRES" ] && date -d "$EXPIRES" >/dev/null 2>&1 || { echo "aide-hold: --expires needs an ISO date" >&2; exit 64; }
  local content h wfail=()
  content=$(printf 'APPROVAL=%s\nREASON=%s\nEXPIRES=%s\nPLACED=%s\n' "$APPROVAL" "${REASON//$'\n'/ }" "$EXPIRES" "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)")
  for h in "${HOSTS[@]}"; do
    printf '%s\n' "$content" | rd "$h" 'umask 077; d="$HOME/.local/state/aide"; mkdir -p "$d" && cat > "$d/grading-hold.tmp.$$" && mv -f "$d/grading-hold.tmp.$$" "$d/grading-hold"' 2>/dev/null \
      || wfail+=("$h")
  done
  do_probe || exit 2
  local bad; bad=$(bad_hosts_place | tr '\n' ' ')
  if [ "${#wfail[@]}" -gt 0 ] || [ -n "$bad" ]; then
    echo "aide-hold: place #$APPROVAL FAILED: a hold without a reader is a flag nothing enforces. Hosts: write-failed=[${wfail[*]:-}] not-proven=[${bad% }]" >&2
    exit 1
  fi
  echo "aide-hold: placed #$APPROVAL on ${#HOSTS[@]} hosts, a consumer proven on each (expires $EXPIRES)"
}

do_lift() {
  parse_args "$@"
  local h cls bad=()
  for h in "${HOSTS[@]}"; do
    cls=$(host_class "$h")
    if [ "$cls" = watch ]; then
      rd "$h" 'd="$HOME/.local/state/rb-land-hold"; mkdir -p "$d" && date -u +%Y-%m-%dT%H:%M:%SZ > "$d/premise-lifted"' </dev/null 2>/dev/null || bad+=("$h(marker write failed)")
    fi
    rd "$h" 'rm -f "$HOME/'$FLAG_REL'"' </dev/null 2>/dev/null || bad+=("$h(flag remove failed)")
  done
  do_probe || exit 2
  python3 -I - "$OUT" <<'PY' > "${TMPDIR:-/tmp}/aide-hold-lift.$$"
import json, sys
for h, r in json.load(open(sys.argv[1])).items():
    if r.get("flag") != "absent":
        print("%s(flag=%s)" % (h, r.get("flag")))
PY
  while IFS= read -r l; do bad+=("$l"); done < "${TMPDIR:-/tmp}/aide-hold-lift.$$"
  rm -f -- "${TMPDIR:-/tmp}/aide-hold-lift.$$"
  for h in "${HOSTS[@]}"; do
    [ "$(host_class "$h")" = watch ] || continue
    rd "$h" 'test -e "$HOME/'$MARK_REL'" && echo yes; exit 0' </dev/null 2>/dev/null | grep -q yes || bad+=("$h(premise-lifted marker not read)")
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    echo "aide-hold: lift #$APPROVAL FAILED, still enforcing or unproven: ${bad[*]}" >&2
    exit 1
  fi
  echo "aide-hold: lifted #$APPROVAL on ${#HOSTS[@]} hosts, no consumer enforcing"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  probe) [ $# -eq 0 ] || usage; do_probe ;;
  place) do_place "$@" ;;
  lift) do_lift "$@" ;;
  --selftest)
    t="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)/tests/hold-consumers.test.sh"
    [ -f "$t" ] || { echo "aide-hold: --selftest needs the repo checkout (tests/hold-consumers.test.sh)" >&2; exit 2; }
    exec bash "$t" ;;
  *) usage ;;
esac
