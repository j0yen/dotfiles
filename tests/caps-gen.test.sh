#!/usr/bin/env bash
# caps-gen (P28 stage 2, A323): enforced files are written from caps.tsv; a no-drift check passes on the tracked tree;
# caps-drift --regen rewrites a drifted host file instead of only reporting it. Every path is a scratch home.
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
G="$here/.local/bin/caps-gen.sh"; D="$here/.local/bin/caps-drift.sh"
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
H='# id\tname\tvalue\thost\tenforced_at\tclass\tsource\tverdict\towner\tnote\tpremise\texpires\tapplied_by'

# --- part 1: the tracked tree has no drift against the tracked registry (no-drift check)
out="$("$G" --check --home "$here" --host carbon 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^caps.gen drift=0 errors=0$' <<<"$out" && ok "tracked generated files match caps.tsv" || { bad "tracked tree drifts from caps.tsv"; echo "$out"; }

# --- part 2: fixture registry + manifest covering all three kinds
reg="$tmp/caps.tsv"; man="$tmp/gen.tsv"; home="$tmp/home"; mkdir -p "$home/u/x.service.d" "$home/cfg"
{ printf "$H\n"
  printf 'C001\tbudget\t600 s\tcarbon\tx\tcadence\tJoe\tKEEP\taide\t-\t\t\t\n'
  printf 'C002\tmax_runs\trb 2 ; r7 3\tredbaron,ryzen7\tx\tcadence\tJoe\tKEEP\taide\t-\t\t\t\n'
  printf 'C003\ttick\t20 min\tcarbon\tx\tcadence\tJoe\tKEEP\taide\t-\t\t\t\n'
  printf 'C004\told\t5\tcarbon\tx\tcadence\tJoe\tVOID\taide\t-\t\t\t\n'
} > "$reg"
{ printf 'C001\t\tdropin\tu/x.service.d/10.conf\tService\tEnvironment\tGATE_S={n}\t\n'
  printf 'C002\tredbaron\ttomlkey\tcfg/config.toml\t\tmax_runs\t{n}\trb (\\d+)\n'
  printf 'C002\tryzen7\ttomlkey\tcfg/config.toml\t\tmax_runs\t{n}\tr7 (\\d+)\n'
  printf 'C003\t\ttsvcell\tcfg/seats.tsv\trb\ttick_min\t{n}\t\n'
  printf 'C004\t\tdropin\tu/x.service.d/90.conf\tService\tK\t{n}\t\n'
} > "$man"
printf 'max_runs = 9  # keep\n[box]\nmax_runs = 1\n' > "$home/cfg/config.toml"
printf '# seat\trole\ttick_min\ttimeout_sec\nctl\tc\t30\t1\nrb\trb\t30\t2\n' > "$home/cfg/seats.tsv"
a=(--registry "$reg" --manifest "$man" --home "$home")
out="$("$G" --check "${a[@]}" --host redbaron 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'DRIFT .*u/x.service.d/10.conf.*absent' <<<"$out" && grep -q 'DRIFT .*config.toml' <<<"$out" && grep -q 'DRIFT .*seats.tsv' <<<"$out" \
  && grep -q 'drift=3 errors=0' <<<"$out" && ok "--check reports three drifted files, exit 1" || { bad "--check on fixture"; echo "$out"; }
[ ! -e "$home/u/x.service.d/10.conf" ] && ok "--check writes nothing" || bad "--check wrote a file"
"$G" --write "${a[@]}" --host redbaron >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^Environment=GATE_S=600$' "$home/u/x.service.d/10.conf" && grep -q '^\[Service\]$' "$home/u/x.service.d/10.conf" \
  && ok "--write generates the drop-in (with header)" || bad "drop-in content"
head -1 "$home/u/x.service.d/10.conf" | grep -q '^# GENERATED from' && ok "drop-in names its generator" || bad "drop-in header"
grep -q '^max_runs = 2  # keep$' "$home/cfg/config.toml" && grep -q '^max_runs = 1$' "$home/cfg/config.toml" \
  && ok "tomlkey sets the top-level key for this host (rb pick 2), keeps the comment and the [box] key" || { bad "tomlkey"; cat "$home/cfg/config.toml"; }
printf 'ctl\tc\t30\t1\n' | cmp -s - <(sed -n 2p "$home/cfg/seats.tsv") && grep -q $'^rb\trb\t20\t2$' "$home/cfg/seats.tsv" \
  && ok "tsvcell sets only the rb tick_min cell" || { bad "tsvcell"; cat "$home/cfg/seats.tsv"; }
[ ! -e "$home/u/x.service.d/90.conf" ] && ok "a VOID cap is not generated" || bad "VOID cap generated"
out="$("$G" --check "${a[@]}" --host redbaron 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'drift=0 errors=0' <<<"$out" && ok "second --check is clean (idempotent)" || { bad "idempotence"; echo "$out"; }
"$G" --write "${a[@]}" --host ryzen7 >/dev/null 2>&1
grep -q '^max_runs = 3  # keep$' "$home/cfg/config.toml" && ok "host filter + pick: ryzen7 gets 3" || bad "ryzen7 pick"

# --- part 3: errors are loud
printf 'C999\t\tdropin\tu/y.conf\tS\tK\t{n}\t\n' > "$tmp/bad.tsv"
out="$("$G" --check --registry "$reg" --manifest "$tmp/bad.tsv" --home "$home" --host carbon 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'ERROR C999 not in the registry' <<<"$out" && ok "unknown cap id is an error, exit 1" || { bad "unknown cap"; echo "$out"; }
printf 'C001\t\ttomlkey\tcfg/config.toml\t\tnope\t{n}\t\n' > "$tmp/bad2.tsv"
out="$("$G" --write --registry "$reg" --manifest "$tmp/bad2.tsv" --home "$home" --host carbon 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "ERROR C001: key 'nope' not found" <<<"$out" && ok "missing key in an existing file is an error" || { bad "missing key"; echo "$out"; }

# --- part 4: caps-drift --regen rewrites a drifted generated file
printf "# a\n[Service]\nEnvironment=GATE_S=1\n" > "$home/u/x.service.d/10.conf"
sed $'s|^C001\\(\t[^\t]*\t[^\t]*\t[^\t]*\t\\)x\t|C001\\1~/u/x.service.d/10.conf:3\t|' "$reg" > "$tmp/r2.tsv"
cp "$man" "$tmp/caps-gen.tsv"
out="$("$D" --registry "$tmp/r2.tsv" --root "$tmp" --home "$home" --host carbon 2>&1)"
grep -q '^DRIFT C001 carbon' <<<"$out" && ok "caps-drift reports the drift without --regen" || { bad "drift report"; echo "$out"; }
grep -q 'GATE_S=1$' "$home/u/x.service.d/10.conf" && ok "report-only run leaves the file" || bad "report-only rewrote"
out="$("$D" --registry "$tmp/r2.tsv" --root "$tmp" --home "$home" --host carbon --regen 2>&1)"
grep -q '^caps.regen rc=0$' <<<"$out" && grep -q '^Environment=GATE_S=600$' "$home/u/x.service.d/10.conf" \
  && ok "--regen rewrote the drifted file from the registry" || { bad "--regen"; echo "$out"; }
out="$("$D" --registry "$tmp/r2.tsv" --root "$tmp" --home "$home" --host carbon 2>&1)"
grep -q '^caps.drift count=0 ' <<<"$out" && ok "drift is 0 after regen" || { bad "post-regen drift"; echo "$out"; }
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
