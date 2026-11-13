#!/usr/bin/env bash
# Canonical open-asks.tsv transactions (recovery plan 666e step 3). ctl is the sole writer; flock + backup + validate + rollback.
#   ctl-ledger-txn.sh add  <due> <what> <done-check> <note>    -> prints new id
#   ctl-ledger-txn.sh close <id> <evidence>                    -> col4 = DONE <ts> ctl (evidence)
set -euo pipefail
L="${LEDGER:-$HOME/.cache/aide/open-asks.tsv}"; V="${LEDGER_VALIDATE:-$HOME/.cache/rb-seat/asks-validate.py}"
exec 9>"$L.lock"; flock -w 20 9
bak="$L.bak-txn"; cp -f "$L" "$bak"
ts=$(date +%Y-%m-%dT%H:%M)
case "${1:-}" in
  add) [ $# -eq 5 ] || { echo "usage: add due what done-check note" >&2; exit 64; }
    python3 -I - "$L" "$ts" "$2" "$3" "$4" "$5" <<'PY'
import sys,re
L,ts,due,what,dc,note=sys.argv[1:7]
rows=open(L).read().split('\n'); ci=rows.index('# CLOSED')
n=max(int(m.group(1)) for x in rows if (m:=re.match(r'A(\d+)\t',x)))+1
rid='A%d'%n
if any(x.startswith(rid+'\t') for x in rows): sys.exit('id collision')
rows.insert(ci,'\t'.join([rid,ts,'ctl',due,what,dc,note]))
open(L,'w').write('\n'.join(rows)); print(rid)
PY
    ;;
  close) [ $# -eq 3 ] || { echo "usage: close id evidence" >&2; exit 64; }
    python3 -I - "$L" "$ts" "$2" "$3" <<'PY'
import sys
L,ts,rid,ev=sys.argv[1:5]
rows=open(L).read().split('\n'); hit=0
for i,x in enumerate(rows):
    if x.startswith(rid+'\t'):
        c=x.split('\t'); c[3]='DONE %s ctl (%s)'%(ts,ev); rows[i]='\t'.join(c); hit+=1; idx=i
if hit!=1: sys.exit('row %s matched %d'%(rid,hit))
if len(rows[idx].split('\t'))<7 or not rows[idx].split('\t')[5].strip(): print('refused: row %s has no done-check (A1216)'%rid,file=sys.stderr); sys.exit(65)
r=rows.pop(idx); ci=rows.index('# CLOSED'); rows.insert(ci+1,r)
open(L,'w').write('\n'.join(rows))
PY
    ;;
  claim) [ $# -eq 3 ] || { echo "usage: claim id worker" >&2; exit 64; }
    python3 -I - "$L" "$ts" "$2" "$3" <<'PY2'
import sys
L,ts,rid,worker=sys.argv[1:5]
rows=open(L).read().split('\n'); ci=rows.index('# CLOSED'); hit=0
for i,x in enumerate(rows[:ci]):
    f=x.split('\t')
    if f[0]==rid and len(f)>=7:
        if 'claim=' in f[6]: sys.exit('row %s already claimed'%rid)
        f[6]='claim=%s@%s | %s'%(worker,ts,f[6]); rows[i]='\t'.join(f); hit+=1
if hit!=1: sys.exit('row %s matched %d open rows'%(rid,hit))
open(L,'w').write('\n'.join(rows)); print('claimed',rid,worker)
PY2
    ;;
  *) echo "usage: add|close|claim" >&2; exit 64;;
esac
vout=$(python3 -I "$V" 2>&1 | tail -1)
if [[ "$vout" != *"violations: 0"* ]]; then cp -f "$bak" "$L"; echo "rolled back: validator found violations" >&2; exit 1; fi
# Canonical durability (A1235 / foundation 5796): the TSV edit counts only once wm-decide asks holds the same ids; failure rolls the TSV back.
imp="${ASKS_IMPORT_CMD:-wm-decide asks import}"; lst="${ASKS_LIST_CMD:-wm-decide asks --tsv}"
if ! $imp "$L" >/dev/null 2>&1; then cp -f "$bak" "$L"; echo "rolled back: canonical wm-decide asks import failed" >&2; exit 1; fi
want="$(grep -v '^#' "$L" | cut -f1 | { grep . || true; } | sort)"; have="$($lst 2>/dev/null | { grep -v '^#' || true; } | cut -f1 | { grep . || true; } | sort)"
if [ "$want" != "$have" ]; then cp -f "$bak" "$L"; $imp "$L" >/dev/null 2>&1; echo "rolled back: canonical ids differ from the TSV after import" >&2; exit 1; fi
