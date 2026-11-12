#!/usr/bin/env bash
# rb-coder-launch.sh <name> [--dry-run] : launch rb-coder-<name> on RedBaron only after a host room read.
# Fable correction class (05b3 fcdf 3e63 9ed9 80ca ccbd 3fcd 9ad2 bd12, 11-02): coders were launched on RB with
# no MemAvailable / psi / running-unit read. This wrapper reads them, refuses below the floor, launches, then
# reads is-active + MainPID. Paste the ROOM and LAUNCH lines into the launch row's evidence.
# Floors: MemAvailable >= 14 GiB (coder peak; the unit carries TasksMax=infinity and no Memory caps, A1483/A1570), psi io full avg60 <= 40, psi memory full avg60 <= 10, < 3 rb-coder units running.
set -u
name=${1:?name}; dry=${2:-}
room=${RB_ROOM_READ:-}; [ -n "$room" ] || room=$(ssh -o ConnectTimeout=10 -o BatchMode=yes redbaron '
ma=$(awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo)
io=$(awk "/^full/{split(\$3,a,\"=\");print a[2]}" /proc/pressure/io)
me=$(awk "/^full/{split(\$3,a,\"=\");print a[2]}" /proc/pressure/memory)
co=$(systemctl --user list-units --no-legend --state=running "rb-coder-*" | wc -l)
inn=$(systemctl --user list-units --no-legend --state=running "wm-build-inner*" | wc -l)
echo "$ma $io $me $co $inn"') || { echo "ROOM unread (ssh failed): REFUSED"; exit 3; }
read -r ma io me co inn <<<"$room"
echo "ROOM $(date '+%-l:%M:%S %p') mem_avail_gib=$ma psi_io_full60=$io psi_mem_full60=$me coders_running=$co inners_running=$inn"
why=""
[ "$ma" -lt 14 ] && why="$why mem_avail<14"
awk -v x="$io" 'BEGIN{exit !(x>40)}' && why="$why psi_io>40"
awk -v x="$me" 'BEGIN{exit !(x>10)}' && why="$why psi_mem>10"
[ "$co" -ge 3 ] && why="$why coders>=3"
[ -n "$why" ] && { echo "REFUSED:$why"; exit 2; }
[ "$dry" = "--dry-run" ] && { echo "ROOM OK (dry-run, nothing launched)"; exit 0; }
ssh -o ConnectTimeout=10 -o BatchMode=yes redbaron "systemd-run --user --unit rb-coder-$name -p TasksMax=infinity -p IOWeight=50 --collect ~/.local/bin/rb-run-coder.sh $name ~/.cache/rb-seat/coders/$name.prompt 2>&1 | tail -n 1; sleep 8; echo LAUNCH is-active=\$(systemctl --user is-active rb-coder-$name) pid=\$(systemctl --user show -p MainPID --value rb-coder-$name)"
