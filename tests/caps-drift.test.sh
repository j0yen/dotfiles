#!/usr/bin/env bash
# caps-drift (P28 mechanism 3, stage 1 report only; amendment 1 falsifier part 1):
# restored retired 90-min quota drop-ins with VOID registry rows are reported; a healthy host reports count 0;
# an unreadable or missing file is `unknown`, never ok; --status-json merges caps.drift atomically and touches nothing else.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
D="$here/.local/bin/caps-drift.sh"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
H='# id\tname\tvalue\thost\tenforced_at\tclass\tsource\tverdict\towner\tnote\tpremise\texpires\tapplied_by'
UD=".config/systemd/user"
S1="$UD/seat-tick@.timer.d/60-quota-stretch.conf"
S2="$UD/swarm-decide-regrade.timer.d/60-quota-stretch.conf"
S3="$UD/seat-tick@.timer.d/50-drain-brake.conf"

# --- part 1: restore the retired drop-ins from git history (#181 24e320d^, #191 14d724c^) into a scratch home
home="$tmp/home"; mkdir -p "$home/$UD/seat-tick@.timer.d" "$home/$UD/swarm-decide-regrade.timer.d"
git -C "$here" show "24e320d^:$S1" > "$home/$S1" 2>/dev/null && git -C "$here" show "24e320d^:$S2" > "$home/$S2" 2>/dev/null \
  && git -C "$here" show "24e320d^:$S3" > "$home/$S3" 2>/dev/null && ok "restored 3 retired drop-ins from 24e320d^ (#181)" || bad "git restore of drop-ins from 24e320d^"
grep -q '90' "$home/$S1" && ok "restored 60-quota-stretch.conf carries the 90 min value" || bad "restored drop-in lacks the 90 min value"
reg="$tmp/caps.tsv"
{ printf "$H\n"
  printf 'C007b\tseat tick stretch\t90 min\tryzen7,orch (tracked in dotfiles)\t~/%s:6\trationing\tJoe\tVOID\taide\t-\tquota\t\t\n' "$S1"
  printf 'C026a\tregrade stretch\t60 min\tryzen7,orch (tracked in dotfiles)\t~/%s:6\trationing\tJoe\tVOID\taide\t-\tquota\t\t\n' "$S2"
  printf 'C007a\tdrain brake\t30 min\tryzen7,orch (tracked in dotfiles)\t~/%s:7\trationing\tJoe\tDEAD\taide\t-\tquota\t\t\n' "$S3"
} > "$reg"
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 2>&1)"
grep -q '^DRIFT C007b ryzen7 .*60-quota-stretch.conf' <<<"$out" && grep -q '^DRIFT C026a ryzen7 .*swarm-decide-regrade.timer.d/60-quota-stretch.conf' <<<"$out" \
  && ok "falsifier part 1: both restored 90/60-min quota drop-ins reported" || { bad "falsifier part 1"; echo "$out"; }
grep -q '^caps.drift count=3 first=C007b$' <<<"$out" && ok "summary line count=3 first=C007b" || { bad "summary"; echo "$out"; }
echo "$out" | sed 's/^/  | /'
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host carbon 2>&1)"
grep -q '^caps.drift count=0 first=-$' <<<"$out" && ok "rows of other hosts are not read (carbon: count 0)" || { bad "host filter"; echo "$out"; }

# --- healthy host: files removed, live row matching
rm -rf "$home"; mkdir -p "$home/.config/wm-build"
printf 'a = 1\nmax_tokens_day = 0\nmax_runs = 4\n' > "$home/.config/wm-build/config.toml"
{ printf "$H\n"
  printf 'C007b\tseat tick stretch\t90 min\tryzen7\t~/%s:6\trationing\tJoe\tVOID\taide\t-\tquota\t\t\n' "$S1"
  printf 'C093\tmax_tokens_day\t0 (none)\tryzen7\t~/.config/wm-build/config.toml:2\trationing\tn\tKEEP\trb\t-\t\t\t\n'
  printf 'C089\tmax_runs\t4\tryzen7\t~/.config/wm-build/config.toml:3\tmemory\tn\tKEEP\trb\t-\t\t\t\n'
  printf 'C900\tother host\t7\tredbaron\t~/.config/wm-build/config.toml:1\tmemory\tn\tKEEP\trb\t-\t\t\t\n'
} > "$reg"
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 2>&1)"
grep -q '^caps.drift count=0 first=-$' <<<"$out" && grep -q '^caps.unknown count=0$' <<<"$out" && ok "healthy host: count 0, unknown 0" || { bad "healthy host"; echo "$out"; }

# --- a live row whose host value changed is drift
sed -i 's/^max_runs = 4/max_runs = 9/' "$home/.config/wm-build/config.toml"
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 2>&1)"
grep -q '^DRIFT C089 ryzen7 ~/.config/wm-build/config.toml:3' <<<"$out" && grep -q '^caps.drift count=1 first=C089$' <<<"$out" && ok "changed live value reported as drift" || { bad "live drift"; echo "$out"; }

# --- unreadable and missing files are unknown, never ok
chmod 000 "$home/.config/wm-build/config.toml"
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 2>&1)"
chmod 644 "$home/.config/wm-build/config.toml"
if [ "$(id -u)" != 0 ]; then
  grep -q '^UNKNOWN C093 ryzen7 .*unreadable' <<<"$out" && grep -q '^caps.drift count=0 first=-$' <<<"$out" && ok "unreadable file is UNKNOWN, not ok" || { bad "unreadable file"; echo "$out"; }
else bad "running as root: chmod 000 cannot make a file unreadable, unreadable case unproven"; fi
rm -f "$home/.config/wm-build/config.toml"
out="$("$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 2>&1)"
grep -q '^UNKNOWN C093 ryzen7 .*No such file' <<<"$out" && grep -q '^caps.unknown count=2$' <<<"$out" && ok "missing file is UNKNOWN (count 2)" || { bad "missing file"; echo "$out"; }

# --- --status-json: creates/merges caps.drift only, atomic (no tmp left)
sj="$tmp/status.json"; printf '{"seats":{"rb":1},"caps":{"other":5}}\n' > "$sj"
"$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 --status-json "$sj" >/dev/null 2>&1
python3 -I - "$sj" <<'PY' && ok "status.json: caps.drift {count,first,unknown,ts} merged, seats + caps.other untouched" || bad "status.json merge"
import json, sys
d = json.load(open(sys.argv[1]))
dr = d["caps"]["drift"]
assert d["seats"] == {"rb": 1} and d["caps"]["other"] == 5
assert dr["count"] == 0 and dr["first"] == "-" and dr["unknown"] == 2 and dr["ts"].endswith("Z"), dr
PY
[ -z "$(ls "$tmp" | grep 'status.json.tmp' || true)" ] && ok "no tmp file left beside status.json" || bad "tmp file left"
rm -f "$sj"; "$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 --status-json "$sj" >/dev/null 2>&1
python3 -I -c 'import json,sys;assert json.load(open(sys.argv[1]))["caps"]["drift"]["unknown"]==2' "$sj" && ok "status.json created when absent" || bad "status.json create"
printf '{broken' > "$sj"; "$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 --status-json "$sj" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(cat "$sj")" = '{broken' ] && ok "corrupt status.json is refused and left untouched" || bad "corrupt status.json (rc=$rc)"

# --- stage 1 never rewrites a host file
before="$(cd "$tmp" && find home -type f -exec sha256sum {} + 2>/dev/null | sort)"
"$D" --registry "$reg" --root "$tmp" --home "$home" --host ryzen7 >/dev/null 2>&1
[ "$before" = "$(cd "$tmp" && find home -type f -exec sha256sum {} + 2>/dev/null | sort)" ] && ok "host files unchanged by a run" || bad "host file changed"

# --- the real registry parses and runs on a scratch root
out="$("$D" --root "$tmp" --home "$tmp/empty" --host redbaron 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^caps.drift count=0 first=-$' <<<"$out" && ok "real caps.tsv on an empty host root: rc 0, retired rows absent" || { bad "real registry run (rc=$rc)"; echo "$out" | tail -3; }
# units
grep -q '^OnCalendar=hourly' "$here/.config/systemd/user/caps-drift.timer" && grep -q 'caps-drift.sh --status-json' "$here/.config/systemd/user/caps-drift.service" && ok "caps-drift.timer hourly + caps-drift.service present" || bad "units"
exit $fail
