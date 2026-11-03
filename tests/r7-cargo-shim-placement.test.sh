#!/usr/bin/env bash
# A681: the cargo shim keeps ryzen7 cargo targets off the root device. Fake cargo + hostname on PATH, fake root dir, fake ssd root; no real cargo runs.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"; fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T" "${OFF:-}"' EXIT
FAKEROOT=$T/root; mkdir -p "$FAKEROOT/proj/sub" "$T/bin" "$T/home/.cargo/bin" "$T/home/.local/lib"
# a dir on a different device than the fake root stands for "already on the ssd"
OFF=""; rdev=$(stat -c %d "$FAKEROOT")
for c in /dev/shm /mnt/ssd /run/user/$(id -u) /var/tmp; do
  [ -d "$c" ] && [ -w "$c" ] && [ "$(stat -c %d "$c")" != "$rdev" ] && { OFF=$(mktemp -d "$c/a681.XXXXXX"); break; }
done
cat > "$T/home/.cargo/bin/cargo" <<'X'
#!/bin/bash
echo "ARGS=$*"; echo "TGT=${CARGO_TARGET_DIR-<unset>}"; echo "INNER=${R7_CARGO_SHIM_INNER-<unset>}"
X
printf '#!/bin/bash\n[ "$1" = -s ] && echo "${FAKE_HOST:-ryzen7}"\n' > "$T/bin/hostname"
printf '#!/bin/bash\nexit "${FAKE_FINDMNT_RC:-0}"\n' > "$T/bin/findmnt"
chmod 755 "$T/home/.cargo/bin/cargo" "$T/bin/hostname" "$T/bin/findmnt"
SSD=$T/ssd; mkdir -p "$SSD"
run() { # env assignments as args after --; runs the shim from the fake project dir
  ( cd "$FAKEROOT/proj" && env -u CARGO_TARGET_DIR -u R7_CARGO_SHIM_INNER HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" R7_ROOT_PATH="$FAKEROOT" R7_SSD_ROOT="$SSD" R7_FINDMNT="$T/bin/findmnt" "$@" "$R/.local/bin/cargo" build --release 2>"$T/err"; echo "RC=$?" ) 
}
# 1. non-ryzen7 host: args and env pass unchanged, root-device target untouched
o=$(run FAKE_HOST=carbon CARGO_TARGET_DIR="$FAKEROOT/proj/target")
echo "$o" | grep -qx 'ARGS=build --release' && echo "$o" | grep -qx "TGT=$FAKEROOT/proj/target" && echo "$o" | grep -qx 'RC=0' && [ ! -s "$T/err" ] && ok "non-ryzen7: args and target unchanged" || bad "non-ryzen7: $o"
# 2. ryzen7 + root-device target (exported) -> rewritten under the ssd root
o=$(run CARGO_TARGET_DIR="$FAKEROOT/proj/target")
echo "$o" | grep -qx "TGT=$SSD/cargo-target/hand-proj" && echo "$o" | grep -qx 'ARGS=build --release' && echo "$o" | grep -qx 'INNER=1' && grep -qx "r7-cargo-slot: target moved off root -> $SSD/cargo-target/hand-proj" "$T/err" && ok "ryzen7 root target (exported) rewritten, one stderr line" || bad "ryzen7 root target: $o / $(cat "$T/err")"
# 3. ryzen7 + nothing exported (<cwd>/target on root) -> rewritten
o=$(run X=1)
echo "$o" | grep -qx "TGT=$SSD/cargo-target/hand-proj" && ok "ryzen7 unset target (<cwd>/target) rewritten" || bad "ryzen7 unset target: $o"
# 3b. relative target on root -> rewritten
o=$(run CARGO_TARGET_DIR=sub/tgt)
echo "$o" | grep -qx "TGT=$SSD/cargo-target/hand-proj" && ok "ryzen7 relative root target rewritten" || bad "ryzen7 relative target: $o"
# 4. ryzen7 + target already on another device -> untouched, silent
if [ -n "$OFF" ]; then
  o=$(run CARGO_TARGET_DIR="$OFF/new/tgt")
  echo "$o" | grep -qx "TGT=$OFF/new/tgt" && echo "$o" | grep -qx 'RC=0' && [ ! -s "$T/err" ] && ok "ryzen7 target off the root device: unchanged" || bad "ryzen7 off-root target: $o / $(cat "$T/err")"
else echo "SKIP no second device for the off-root case"; fi
# 5. ryzen7 + root target + ssd not mounted -> exit 75, cargo not run
o=$(run FAKE_FINDMNT_RC=1 CARGO_TARGET_DIR="$FAKEROOT/proj/target")
echo "$o" | grep -qx 'RC=75' && ! echo "$o" | grep -q '^ARGS=' && grep -qx 'r7-cargo-slot: /mnt/ssd not mounted, refusing root target' "$T/err" && ok "ssd not mounted: exit 75, cargo not run" || bad "ssd unmounted: $o / $(cat "$T/err")"
# 6. R7_CARGO_SHIM_INNER=1 -> unchanged even for a root target on ryzen7
o=$(run R7_CARGO_SHIM_INNER=1 CARGO_TARGET_DIR="$FAKEROOT/proj/target")
echo "$o" | grep -qx "TGT=$FAKEROOT/proj/target" && echo "$o" | grep -qx 'RC=0' && [ ! -s "$T/err" ] && ok "INNER=1: unchanged" || bad "INNER=1: $o"
# 7. the slot script sources the same lib and calls the check before it makes the target dir
s=$R/.local/bin/r7-cargo-slot.sh
grep -q 'r7-cargo-place.sh' "$s" && grep -n 'r7_cargo_place "\$TOP"' "$s" | cut -d: -f1 | { read -r a; b=$(grep -n 'mkdir -p "\$CARGO_TARGET_DIR"' "$s" | cut -d: -f1); [ "$a" -lt "$b" ]; } && ok "slot script runs the device check before mkdir of the target" || bad "slot script not wired"
bash -n "$s" && bash -n "$R/.local/bin/cargo" && bash -n "$R/.local/lib/r7-cargo-place.sh" && ok "bash -n on all three files" || bad "syntax"
exit $fail
