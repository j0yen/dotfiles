. ./env.sh; cd $S
echo == c1
mk c1; printf 'Dispatch: ctl\nbody\n' > $T/fb/a.task.md; printf 'no marker\n' > $T/fb/b.task.md; printf 'x\nDispatch: ctl\n' > $T/fb/c.task.md
export DP_START=$S/startbg.sh
$SCRIPT scan; sleep 1; $SCRIPT scan; sleep 1; cat $T/runs; $SCRIPT st""atus
echo == c2
mk c2; printf 'Dispatch: ctl\n' > $T/fb/a.task.md; export DP_START=$S/startbg.sh
DP_HOLD=false $SCRIPT scan; ls $T/st/claims; sleep 1; $SCRIPT scan; sleep 1; cat $T/runs
echo == c3
mk c3; for i in 1 2 3; do printf "Dispatch: ctl\n$i\n" > $T/fb/f$i.task.md; done; export DP_START=$S/startbg.sh
for i in $(seq 8); do $SCRIPT scan >$T/o$i 2>&1 & done; wait; sleep 2; sort $T/runs | uniq -c; grep -h claimed $T/o* | wc -l
