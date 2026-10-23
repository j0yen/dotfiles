#!/usr/bin/env bash
# tests/aide-verifier.test.sh: runs aide-verifier.sh --selftest under a throwaway HOME (fakes only: no unit, no wm-decide row,
# no seat bell, no claude), then greps the script for the anchored attribution regex and the merge-gate call. Run: bash tests/aide-verifier.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../.local/bin/aide-verifier.sh"
fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
th=$(mktemp -d "${TMPDIR:-/tmp}/aide-verifier-test.XXXXXX"); trap 'rm -rf "$th"' EXIT
bash -n "$script" && pass "bash -n" || bad "bash -n"
out=$(HOME="$th" bash "$script" --selftest 2>&1); rc=$?
last=$(printf '%s\n' "$out" | tail -n1)
if [ $rc = 0 ] && [[ $last =~ ^selftest:\ ([0-9]+)/([0-9]+)\ passed$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -ge 90 ] \
   && ! printf '%s\n' "$out" | grep -q '^FAIL'; then pass "selftest ($last)"; else bad "selftest rc=$rc"; printf '%s\n' "$out" | grep -v '^PASS' | tail -n 20; fi
# ---- vcap4: which unit states count toward the cap (ported from r7's closed dotfiles#71; fakes only, throwaway HOME) ----
# The stub tells activating from deactivating: it honours the script's --state=a,b,c list by EXACT token, never by substring
# (a substring match makes "activating" also match "deactivating", so dropping activating from the list could never fail).
vc=$th/vc; mkdir -p "$vc/home/.config/environment.d" "$vc/bin" "$vc/av"; : >"$vc/home/.config/environment.d/90-claude-oauth.conf"
cat >"$vc/bin/fake-systemctl" <<'F'
#!/bin/bash
case "$2" in
  list-units) st=""; for a in "$@"; do case "$a" in --state=*) st="${a#--state=}" ;; esac; done
    while read -r u s; do [ -n "$u" ] || continue; case ",$st," in *",$s,"*) echo "$u loaded $s running fake" ;; esac; done <"$FAKE_DIR/units" ;;
  show) echo "[not set]" ;;
esac
exit 0
F
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$FAKE_DIR/sdrun.log"\n' >"$vc/bin/fake-sdrun"
printf '#!/bin/bash\necho "$1" >>"$FAKE_DIR/room.log"\necho "{\\"ok\\":true,\\"room_mb\\":9000}"\n' >"$vc/bin/fake-room"
printf '#!/bin/bash\nexit 0\n' >"$vc/bin/fake-bell"; chmod +x "$vc"/bin/*
vl() { local nm="$1"; shift; HOME="$vc/home" FAKE_DIR="$vc" AIDE_VERIFIER_DIR="$vc/av" AIDE_VERIFIER_ROOM_CMD="$vc/bin/fake-room" AIDE_VERIFIER_SYSTEMD_RUN="$vc/bin/fake-sdrun" \
  AIDE_VERIFIER_SYSTEMCTL="$vc/bin/fake-systemctl" AIDE_VERIFIER_BELL="$vc/bin/fake-bell" AIDE_VERIFIER_SELFTEST=1 AIDE_VERIFIER_SLOT_CEIL=2 AIDE_VERIFIER_POLL_S=1 \
  bash "$script" launch "$nm" --repo j0yen/dotfiles --pr 7 --gated d-20261023-055214-aide-49cf --token 'tests/*.test.sh EXIT=0' --suite 'bash tests/run.sh' \
  --head 0123456789abcdef0123456789abcdef01234567 "$@" 2>&1; }
# stub self-check: the state filter is exact-token (activating is not deactivating)
printf 'rb-verifier-s.service activating\n' >"$vc/units"
[ -z "$(FAKE_DIR=$vc bash "$vc/bin/fake-systemctl" --user list-units '*-verifier-*' --state=active,deactivating,reloading)" ] \
  && [ -n "$(FAKE_DIR=$vc bash "$vc/bin/fake-systemctl" --user list-units '*-verifier-*' --state=activating)" ] \
  && pass "vcap4 stub: --state matches exact tokens (activating != deactivating)" || bad "vcap4 stub does not tell activating from deactivating"
# (1) an ACTIVATING unit counts: 1 active + 1 activating at ceiling 2 -> cap reached, exit 2, nothing started
printf 'rb-verifier-a.service active\nr7-verifier-b.service activating\n' >"$vc/units"; rm -f "$vc/sdrun.log"
out=$(vl act1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"verifier cap reached: 2 of 2"* ]] && [ ! -e "$vc/sdrun.log" ] \
  && pass "vcap4 (1) 1 active + 1 activating at ceiling 2 -> exit 2, nothing started" || bad "vcap4 (1) activating unit did not count (rc=$rc: $out)"
# (1b) a DEACTIVATING unit counts too (control: the stub must not conflate it with activating)
printf 'rb-verifier-a.service active\nr7-verifier-b.service deactivating\n' >"$vc/units"; rm -f "$vc/sdrun.log"
out=$(vl deact1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"2 of 2"* ]] && [ ! -e "$vc/sdrun.log" ] \
  && pass "vcap4 (1b) 1 active + 1 deactivating at ceiling 2 -> exit 2" || bad "vcap4 (1b) deactivating unit did not count (rc=$rc: $out)"
# (2) FAILED units never count: 1 active + 2 failed at ceiling 2 -> launches, room priced for 1 active (1024 x 2 = 2048 MB)
printf 'rb-verifier-a.service active\nr7-verifier-f1.service failed\naide-verifier-f2.service failed\n' >"$vc/units"; rm -f "$vc/sdrun.log" "$vc/room.log"
out=$(vl fail1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$vc/sdrun.log")" = 1 ] && [ "$(cat "$vc/room.log")" = 2048 ] \
  && pass "vcap4 (2) 1 active + 2 failed at ceiling 2 -> launches, room asked 2048 MB" || bad "vcap4 (2) failed units counted (rc=$rc room=$(cat "$vc/room.log" 2>/dev/null): $out)"

grep -qF '^[[:space:]]*(co-authored-by:|generated with)' "$script" && pass "script carries the anchored attribution regex" || bad "anchored attribution regex missing"
grep -q 'merge-gate' "$script" && pass "script calls merge-gate" || bad "merge-gate missing"
grep -qF -- '--agent {{AGENT}} --via verifier --model sonnet --kind verdict --gates' "$script" && pass "prompt template records the verdict row shape" || bad "verdict row shape missing"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
