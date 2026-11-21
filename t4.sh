. /home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/env.sh
mkw(){ cat > $T/w.sh <<W
#!/bin/bash
echo "\$1" >> $T/runs
sleep ${1:-0}
W
chmod +x $T/w.sh; }
cat > /home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/nsp.sh <<'N'
#!/bin/bash
echo "$*" >> $NLOGF
N
echo == c8 systemd happy
mk c8; cat > $T/w.sh <<W
#!/bin/bash
echo "\$1" >> $T/runs
W
chmod +x $T/w.sh; export DP_WORKER=$T/w.sh
printf 'Dispatch: ctl\n' > $T/fb/a.task.md
$SCRIPT scan; sleep 2; cat $T/runs; $SCRIPT st""atus; systemctl --user list-units --all 'ctl-dispatch-*' --no-legend; cat $T/st/claims/*/receipt.json; echo
echo == c4 kill -9
mk c4; cat > $T/w.sh <<W
#!/bin/bash
echo "\$1" >> $T/runs
sleep 300
W
chmod +x $T/w.sh; export DP_WORKER=$T/w.sh
cat > $T/n.sh <<W
#!/bin/bash
echo "\$*" >> $T/nlog
W
chmod +x $T/n.sh; export DP_NOTIFY=$T/n.sh DP_STALE=1
printf 'Dispatch: ctl\n' > $T/fb/a.task.md
$SCRIPT scan; sleep 1.5
U=$(systemctl --user list-units --all 'ctl-dispatch-*' --no-legend | awk '{print $1}' | head -1); echo unit=$U
P=$(systemctl --user show -p MainPID --value $U); echo mainpid=$P; pgrep -P $P -a
kill -9 $P; sleep 1; systemctl --user list-units --all 'ctl-dispatch-*' --no-legend
sleep 1.5; $SCRIPT scan; $SCRIPT scan; sleep 1; $SCRIPT scan
echo runs:; cat $T/runs; echo nlog:; cat $T/nlog; echo receipt:; cat $T/st/claims/*/receipt.json; echo; ls $T/st/claims/*/
pgrep -af "sleep 300" | grep -v pgrep
