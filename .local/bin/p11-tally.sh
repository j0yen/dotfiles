#!/usr/bin/env bash
# p11-tally.sh - P11 verifier-trial tally from the ledger model column (open-asks P11, approvals #139/#141).
# Population: via='verifier' AND model=$P11_MODEL (claude-opus-5-5) AND ts>=$P11_SINCE (2026-10-31T13:46).
# Corrected = Fable regrade verdict CORRECT, or outcome state bad. Rule: KEEP if corrected <= 3 of 20 graded,
# else REVERT to sonnet; fewer than 20 graded at $P11_END = REVERT. Read-only (sqlite3 -readonly).
# Env: P11_DB (~/.local/state/swarm-decide/decisions.sqlite), P11_MODEL, P11_SINCE, P11_N (20), P11_MAX_CORRECTED (3).
set -u
db="${P11_DB:-$HOME/.local/state/swarm-decide/decisions.sqlite}"
model="${P11_MODEL:-claude-opus-5-5}"; since="${P11_SINCE:-2026-10-31T13:46}"
n="${P11_N:-20}"; maxc="${P11_MAX_CORRECTED:-3}"
[ -r "$db" ] || { echo "p11-tally: cannot read $db" >&2; exit 2; }
case "$model$since$n$maxc" in *\'*|*\;*) echo "p11-tally: bad parameter" >&2; exit 2;; esac
row=$(sqlite3 -readonly "$db" "
 select count(*),
  coalesce(sum(json_extract(regrade,'\$.verdict') is not null),0),
  coalesce(sum(json_extract(regrade,'\$.verdict')='CORRECT' or json_extract(outcome,'\$.state')='bad'),0)
 from (select * from decisions where via='verifier' and model='$model' and ts>='$since' order by ts limit $n);") || exit 2
IFS='|' read -r rows graded corrected <<< "$row"
if [ "$graded" -lt "$n" ]; then state="PENDING"
elif [ "$corrected" -le "$maxc" ]; then state="KEEP"; else state="REVERT"; fi
echo "P11 model=$model since=$since rows=$rows/$n graded=$graded corrected=$corrected (keep if <=$maxc/$n) state=$state"
