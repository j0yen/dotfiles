#!/usr/bin/env bash
# rb-run-coder-remote.test.sh - rb-run-coder.sh launches the coder on redbaron over ssh and NEVER runs claude on the calling host (Joe 10-27 approvals #47).
# (a) normal spawn: ssh systemd-run on redbaron, no local claude; (b) ssh 255 flaps keep waiting then ring; (c) remote start failure -> 79, no local claude;
# (d) gates refuse before any ssh (empty prompt -> 74).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runc=${RB_RUN_CODER_UNDER_TEST:-$here/.local/bin/rb-run-coder.sh}   # the mutation proof points this at a throwaway copy
fail=0; pass() { echo "ok - $*"; }; bad() { echo "NOT OK - $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkcase() { # mkcase <dir>: own HOME + XDG dirs, stubs for ssh/scp/claude/seat-event
  C=$T/$1; H=$C/home; rm -rf "$C"; mkdir -p "$H/.local/bin" "$H/.cache/rb-seat/coders" "$H/.config" "$H/.local/share" "$H/.local/state" "$C/bin"
  export XDG_CONFIG_HOME=$H/.config XDG_CACHE_HOME=$H/.cache XDG_DATA_HOME=$H/.local/share XDG_STATE_HOME=$H/.local/state
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/events.log"\n' "$C" > "$H/.local/bin/seat-event.sh"
  printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/claude.called"\nexit 0\n' "$C" > "$C/bin/claude"; cp "$C/bin/claude" "$H/.local/bin/claude"
  printf '#!/usr/bin/env bash\necho "scp $*" >> "%s/ssh.log"\nexit 0\n' "$C" > "$H/.local/bin/scp"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$C/hold.sh"
  chmod +x "$H"/.local/bin/* "$C/bin/claude" "$C/hold.sh"
  head -c 400 /dev/zero | tr '\0' 'x' > "$C/prompt.md"
}
# stub ssh: logs every call; behaviour by $C/mode: ok | flap | startfail
stubssh() {
  cat > "$H/.local/bin/ssh" <<STUB
#!/usr/bin/env bash
echo "ssh \$*" >> "$C/ssh.log"
case "\$*" in
  *systemd-run*) [ "\$(cat "$C/mode")" = startfail ] && { echo "Failed to start" >&2; exit 1; }; exit 0 ;;
  *is-active*) [ "\$(cat "$C/mode")" = startfail ] && exit 3
     n=\$(( \$(cat "$C/polls" 2>/dev/null || echo 0) + 1 )); echo \$n > "$C/polls"
     if [ "\$(cat "$C/mode")" = flap ]; then case \$n in 1|2) exit 255;; 3) exit 0;; *) exit 3;; esac; fi
     [ \$n -ge 2 ] && exit 3; exit 0 ;;
  *"cat "*) echo 0 ;;
esac
exit 0
STUB
  chmod +x "$H/.local/bin/ssh"
}
run() { PATH="$C/bin:$PATH" HOME=$H RB_SPAWN_HOLD_BIN=$C/hold.sh RB_CODER_POLL_SEC=0 RB_CODER_RETRY_SEC=0 bash "$runc" "$@" >/dev/null 2>&1; }

mkcase a; echo ok > "$C/mode"; stubssh; run na "$C/prompt.md"; rc=$?
if [ $rc = 0 ] && grep -q 'ssh .*redbaron.*systemd-run --user.*--unit=rb-coder-na.*RuntimeMaxSec=5400.*MemoryMax=14G' "$C/ssh.log" && grep -q 'PREMISE' "$C/ssh.log" && grep -q 'EXPIRES' "$C/ssh.log" \
  && grep -q 'WM_SEAT=rb-coder' "$C/ssh.log" && grep -q 'scp .*redbaron:/mnt/data/hand/coders/na.prompt' "$C/ssh.log" && [ ! -e "$C/claude.called" ] && grep -q 'RB-CODER na ended rc=0' "$C/events.log"; then
  pass "(a) spawn -> ssh redbaron systemd-run (premise+expiry, remote env), prompt scp'd, no local claude, seat rung"; else bad "(a) rc=$rc called=$(cat "$C/claude.called" 2>&1) log=$(head -c 600 "$C/ssh.log")"; fi
[ "$(grep -v '^[[:space:]]*#' "$here/.local/bin/rb-run-coder.sh" | grep -c '90-claude-oauth')" = 1 ] && grep -v '^[[:space:]]*#' "$here/.local/bin/rb-run-coder.sh" | grep '90-claude-oauth' | grep -q "^inner='" && pass "(a2) the oauth file is sourced only inside the remote command string" || bad "(a2) oauth sourced outside the remote command"

mkcase b; echo flap > "$C/mode"; stubssh; run nb "$C/prompt.md"; rc=$?
polls=$(cat "$C/polls" 2>/dev/null)
[ $rc = 0 ] && [ "$polls" = 4 ] && grep -q 'RB-CODER nb ended rc=0' "$C/events.log" && [ ! -e "$C/claude.called" ] && pass "(b) 255,255,active,inactive -> 4 polls, then rings rc=0" || bad "(b) rc=$rc polls=$polls"

mkcase c; echo startfail > "$C/mode"; stubssh; run nc "$C/prompt.md"; rc=$?
rep=$(cat "$H/.cache/rb-seat/coders/nc.report.md" 2>/dev/null)
[ $rc = 79 ] && [[ $rep == "REFUSED remote-launch"* ]] && [ ! -e "$C/claude.called" ] && grep -q 'RB-CODER nc REFUSED remote-launch' "$C/events.log" && [ "$(grep -c 'systemd-run' "$C/ssh.log")" = 3 ] && pass "(c) systemd-run fails 3x -> rc=79, '$rep', no local claude" || bad "(c) rc=$rc rep=$rep"

mkcase d; echo ok > "$C/mode"; stubssh; : > "$C/empty.md"; run nd "$C/empty.md"; rc=$?
[ $rc = 74 ] && [ ! -e "$C/ssh.log" ] && [ ! -e "$C/claude.called" ] && pass "(d) empty prompt -> 74 before any ssh" || bad "(d) rc=$rc"

exit $fail
