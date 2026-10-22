# r7-host-probe.sh -- run ON ryzen7 by r7-mon-host (ssh bash -s < this file). READ-ONLY: cgroup memory.events, journalctl -k, /proc/pressure, df.
B=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice
for d in $B/wm-build*.service; do
  [ -r "$d/memory.events" ] || continue
  echo "OOM $(basename "$d") $(awk '$1=="oom_kill"{print $2}' "$d/memory.events")"
done
echo "KOOM $(journalctl -k --since -2min --no-pager -q 2>/dev/null | grep -ci 'out of memory')"
echo "PSIMEM $(awk '$1=="some"{for(i=2;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/memory)"
echo "PSIIO $(awk '$1=="some"{for(i=2;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/io)"
echo "DFI $(df -i /tmp | awk 'NR==2{gsub("%","",$5); print $5}')"
echo "DFH $(df -h / | awk 'NR==2{gsub("%","",$5); print $5}')"
echo "SVC $(systemctl --user show wm-build.service -p ActiveState --value) $(systemctl --user show wm-build.service -p ActiveEnterTimestampMonotonic --value)"
echo END
