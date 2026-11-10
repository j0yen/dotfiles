#!/usr/bin/env bash
# Five-whys 2026-11-09 mechanisms 1, 2, 4: the dotfiles copies under .config/carbon-sigkill-trace carry the settings the page names and, on carbon, equal what is installed.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; S="$here/.config/carbon-sigkill-trace"
p=0; f=0
ck() { if eval "$2"; then p=$((p+1)); echo "PASS $1"; else f=$((f+1)); echo "FAIL $1"; fi; }
ck "trace script has the sig==9 tracepoint filter" 'grep -q "args->sig == 9" "$S/carbon-sigkill-trace.bt"'
ck "trace service runs bpftrace on the installed script" 'grep -q "^ExecStart=/usr/bin/bpftrace -q /usr/local/lib/carbon-sigkill-trace.bt" "$S/carbon-sigkill-trace.service"'
ck "user@1000 drop-in sets Restart=on-abnormal" 'grep -q "^Restart=on-abnormal" "$S/10-restart-on-abnormal.conf"'
ck "user@1000 drop-in sets RestartSec=5" 'grep -q "^RestartSec=5" "$S/10-restart-on-abnormal.conf"'
ck "watch script starts user@1000 when inactive" 'grep -q "systemctl start user@1000.service" "$S/carbon-user-manager-watch.sh"'
ck "watch timer fires every minute" 'grep -q "^OnUnitActiveSec=1min" "$S/carbon-user-manager-watch.timer"'
if [ "$(uname -n)" = carbon ] && [ -f /usr/local/lib/carbon-sigkill-trace.bt ]; then
  ck "installed trace script matches" 'cmp -s "$S/carbon-sigkill-trace.bt" /usr/local/lib/carbon-sigkill-trace.bt'
  ck "installed watch script matches" 'cmp -s "$S/carbon-user-manager-watch.sh" /usr/local/lib/carbon-user-manager-watch.sh'
  ck "installed drop-in matches" 'cmp -s "$S/10-restart-on-abnormal.conf" /etc/systemd/system/user@1000.service.d/10-restart-on-abnormal.conf'
fi
echo "passed=$p failed=$f"; [ "$f" = 0 ]
