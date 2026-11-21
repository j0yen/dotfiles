. /home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/env.sh
echo == c5a start never happens, DP_START exit 0 no-op
mk c5; printf '#!/bin/bash\necho call >> $T/startcalls\n' > $T/st.sh; chmod +x $T/st.sh; export DP_START=$T/st.sh DP_STALE=2
printf 'Dispatch: ctl\n' > $T/fb/a.task.md
$SCRIPT scan; $SCRIPT scan; sleep 2.5; $SCRIPT scan; $SCRIPT scan; sleep 2.5; $SCRIPT scan; wc -l < $T/startcalls
echo == c5b start fails always
mk c5b; printf '#!/bin/bash\necho call >> $T/startcalls\nexit 1\n' > $T/st.sh; chmod +x $T/st.sh; export DP_START=$T/st.sh DP_STALE=2
printf 'Dispatch: ctl\n' > $T/fb/a.task.md
$SCRIPT scan; sleep 2.5; $SCRIPT scan; sleep 2.5; $SCRIPT scan; sleep 2.5; $SCRIPT scan; wc -l < $T/startcalls; ls $T/st/claims/*/
echo == c6 edit
mk c6; export DP_START=/home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/startbg.sh; printf 'Dispatch: ctl\nv1\n' > $T/fb/a.task.md
$SCRIPT scan; sleep 1; printf 'Dispatch: ctl\nv2\n' > $T/fb/a.task.md; $SCRIPT scan; sleep 1; $SCRIPT scan; wc -l < $T/runs
echo == c6b marker variants
mk c6b; export DP_START=/home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/startbg.sh
printf 'Dispatch: ctl\r\n' > $T/fb/crlf.task.md
printf 'Dispatch: ctl   \n' > $T/fb/trail.task.md
printf 'Dispatch: ctl\t\n' > $T/fb/tab.task.md
printf ' Dispatch: ctl\n' > $T/fb/lead.task.md
printf 'Dispatch: ctl' > $T/fb/nonl.task.md
printf 'Dispatch: ctlx\n' > $T/fb/pref.task.md
printf 'dispatch: ctl\n' > $T/fb/lower.task.md
printf 'Dispatch: ctl\n' > $T/fb/x.task.md.bak
$SCRIPT scan; sleep 1; $SCRIPT scan
echo == c7 spaces
mk c7; export DP_START=/home/jsy/.cache/tmp/claude-1000/-home-jsy/42a49890-bce4-4f7d-868d-ff20c8476b99/scratchpad/dv/startbg.sh
printf 'Dispatch: ctl\n' > "$T/fb/my task  file.task.md"; printf 'Dispatch: ctl\n' > "$T/fb/it's $(id).task.md"
$SCRIPT scan; sleep 1; $SCRIPT scan; cat $T/runs
echo == c7b spaces via systemd
mk c7b; unset DP_START; cat > $T/w.sh <<W
#!/bin/bash
echo "\$1" >> $T/runs
W
chmod +x $T/w.sh; export DP_WORKER=$T/w.sh
printf 'Dispatch: ctl\n' > "$T/fb/my task  file.task.md"; $SCRIPT scan; sleep 2; cat $T/runs; cat $T/st/claims/*/receipt.json
