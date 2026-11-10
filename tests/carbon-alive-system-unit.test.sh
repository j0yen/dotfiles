#!/usr/bin/env bash
# carbon-alive-system-unit.test.sh — A1446 one witness: carbon-alive.sh runs under a SYSTEM unit pair with User=jsy
# (.config/systemd/system-units/), the user unit pair is retired from the tree (install.sh no longer links it, a host
# still linked to it is reported stale), and the script works with HOME alone (no XDG_*, XDG_RUNTIME_DIR, user bus or
# local systemctl). Hermetic: fake ssh/curl/systemctl/loginctl, a fake HOME under a temp dir, install.sh only in
# --dry-run --link-only (prints, writes nothing).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; pass=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S="$here/.config/systemd/system-units/carbon-alive.service"; Ti="$here/.config/systemd/system-units/carbon-alive.timer"
has() { grep -qx -- "$2" "$1" 2>/dev/null; }

# 1-6: the system unit pair
has "$S" 'User=jsy' && has "$S" 'Group=jsy' && ok "1 system service names User=jsy Group=jsy" || bad "1 User=/Group= (file present: $([ -f "$S" ] && echo yes || echo no))"
has "$S" 'ExecStart=/home/jsy/.local/bin/carbon-alive.sh' && [ "$(grep -c '^ExecStart' "$S")" = 1 ] && [ -x "$here/.local/bin/carbon-alive.sh" ] \
  && ok "2 one absolute ExecStart=/home/jsy/.local/bin/carbon-alive.sh, script present in the repo" || bad "2 ExecStart"
[ -f "$S" ] && [ -f "$Ti" ] && ! grep -q '%h' "$S" "$Ti" && ok "3 no %h in the system unit pair (it would be /root)" || bad "3 %h or missing file"
envs="$(grep '^Environment' "$S" 2>/dev/null)"
[ -f "$S" ] && has "$S" 'Environment=HOME=/home/jsy' && ! grep -qiE 'token|secret|pass|key|webhook|url|auth|cred|cookie' <<<"$envs" \
  && ! grep -q '^EnvironmentFile' "$S" && ! grep -vqE '^Environment=(HOME|XDG_STATE_HOME|XDG_CONFIG_HOME)=/home/jsy(/[^ ]*)?$' <<<"$envs" \
  && ok "4 Environment= only HOME (XDG_* under /home/jsy allowed), no secret-like key, no EnvironmentFile" || bad "4 Environment lines: $envs"
{ has "$S" 'Type=oneshot' && has "$S" 'Nice=10' && has "$S" 'TimeoutStartSec=60' && has "$S" 'ConditionHost=!carbon' \
  && has "$S" 'NoNewPrivileges=yes' && has "$S" 'PrivateTmp=yes' && has "$S" 'ProtectSystem=strict' \
  && [ "$(grep '^ReadWritePaths=' "$S")" = 'ReadWritePaths=/home/jsy/.local/state/carbon-alive' ] && ! grep -q '^\[Install\]' "$S"; } \
  && ok "5 oneshot, Nice=10, TimeoutStartSec=60, ConditionHost=!carbon, hardening, writes only the state dir, no [Install]" || bad "5 service settings"
{ has "$Ti" 'OnBootSec=2min' && has "$Ti" 'OnUnitActiveSec=2min' && has "$Ti" 'WantedBy=timers.target' && ! grep -q '^Persistent' "$Ti"; } \
  && ok "6 timer every 2 min (OnBootSec + OnUnitActiveSec), WantedBy=timers.target, no Persistent=" || bad "6 timer"

# 7: one witness — no carbon-alive unit on any user-manager search path in the repo, none in timers.tsv
uu="$(cd "$here" && find .config/systemd/user .config/systemd/user.control .local/share/systemd/user -name 'carbon-alive*' 2>/dev/null)"
[ -z "$uu" ] && ! grep -q '^carbon-alive' "$here/.config/fleet/timers.tsv" \
  && ok "7 user unit pair retired from the tree and from timers.tsv" || bad "7 user units still present: ${uu:-none} / tsv: $(grep -c '^carbon-alive' "$here/.config/fleet/timers.tsv")"

# 8: install.sh (dry-run link-only, fake HOME) links no user carbon-alive unit; the system pair lands outside the user
# search path
mkdir -p "$T/ihome" "$T/bin"
printf '#!/bin/sh\necho "$0 $*" >> %s\nexit 0\n' "$T/sysctl-calls" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"; cp "$T/bin/systemctl" "$T/bin/loginctl"
( cd "$here" && env -u FLEET_SYNC_RETIRED -u XDG_STATE_HOME HOME="$T/ihome" PATH="$T/bin:$PATH" bash ./install.sh --dry-run --link-only ) > "$T/iout" 2>&1; irc=$?
[ "$irc" = 0 ] && ! grep -q "would link: $T/ihome/.config/systemd/user/carbon-alive" "$T/iout" \
  && grep -q "would link: $T/ihome/.config/systemd/system-units/carbon-alive.service ->" "$T/iout" \
  && ok "8 install.sh links no user carbon-alive unit; system pair goes to ~/.config/systemd/system-units (not a user unit dir)" \
  || bad "8 install.sh rc=$irc: $(grep carbon-alive "$T/iout" | head -4)"

# 9: a host still linked to the retired user pair is told: install.sh --paths-from <base> HEAD prints stale: for both
base=a3640fdd5c0edff93f8af79a09c18863bacdcec5
if git -C "$here" cat-file -e "$base^{commit}" 2>/dev/null && git -C "$here" rev-parse -q --verify HEAD >/dev/null; then
  mkdir -p "$T/shome/.config/systemd/user"
  for u in service timer; do ln -s "$here/.config/systemd/user/carbon-alive.$u" "$T/shome/.config/systemd/user/carbon-alive.$u"; done
  ( cd "$here" && env -u FLEET_SYNC_RETIRED -u XDG_STATE_HOME HOME="$T/shome" PATH="$T/bin:$PATH" bash ./install.sh --dry-run --link-only --paths-from "$base" HEAD ) > "$T/sout" 2>&1
  grep -qx "stale: $T/shome/.config/systemd/user/carbon-alive.service" "$T/sout" && grep -qx "stale: $T/shome/.config/systemd/user/carbon-alive.timer" "$T/sout" \
    && ok "9 install.sh --paths-from $base..HEAD reports both old user unit links stale" || bad "9 stale report: $(grep -c '^stale:' "$T/sout") stale lines"
else
  echo "SKIP 9 base $base not in this clone's history"
fi

# 10: carbon-alive.sh with HOME only (env -i: no XDG_*, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS) writes its state
# under HOME and alerts through the default Discord deliverer (fake curl), and calls no local systemctl/loginctl
H="$T/home"; mkdir -p "$H/.config/carbon-alive" "$T/tmp" "$T/curl"
ln -s "$here/tests/fixtures/carbon-alive-fake-curl.sh" "$T/bin/curl"
printf 'https://discord.example/api/webhooks/1/TOKENsecret9f3a\n' > "$H/.config/carbon-alive/webhook.url"; chmod 600 "$H/.config/carbon-alive/webhook.url"
: > "$T/sysctl-calls"
ca() { env -i HOME="$H" PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" TMPDIR="$T/tmp" CARBON_ALIVE_HOST=testhost CA_FAKE_RC=255 \
  CARBON_ALIVE_SSH="$here/tests/fixtures/carbon-alive-fake-ssh.sh" CA_CURL_LOG="$T/curl" CARBON_ALIVE_NOW="$1" "$here/.local/bin/carbon-alive.sh"; }
ca 1000000; r1=$?; ca 1000120; r2=$?
sj="$H/.local/state/carbon-alive/state.json"
st="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$sj" 2>/dev/null)"
nc="$( [ -f "$T/curl/calls" ] && wc -l < "$T/curl/calls" || echo 0)"
[ "$r1/$r2" = 0/0 ] && [ "$st" = host-unreachable ] && [ "$nc" = 1 ] && [ ! -s "$H/.local/state/carbon-alive/outbox.jsonl" ] \
  && python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["content"];assert "host-unreachable" in c and "testhost" in c' "$T/curl/stdin" \
  && [ ! -s "$T/sysctl-calls" ] && [ -z "$(ls -A "$T/tmp")" ] \
  && ok "10 HOME only: state.json under HOME = host-unreachable, one Discord post via fake curl, outbox empty, no local systemctl/loginctl" \
  || bad "10 HOME-only run rc=$r1/$r2 state=$st curl=$nc sysctl=$(wc -l < "$T/sysctl-calls")"

echo "carbon-alive-system-unit.test: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
