#!/usr/bin/env bash
# wm-build-shim-ctl.sh -- install / promote / rollback / check for the wm-build memory-bound shim (wm-build-bound-shim.sh).
#   wm-build-shim-ctl.sh [--dir D] install [--replace]   ~/.cargo/bin/wm-build (ELF) -> hard link wm-build.real + atomic rename of the shim over the path
#   wm-build-shim-ctl.sh [--dir D] place <candidate>     promote target: shim present -> candidate becomes wm-build.real (shim untouched), else wm-build
#   wm-build-shim-ctl.sh [--dir D] rollback              mv -f wm-build.real wm-build (one atomic rename, no restart)
#   wm-build-shim-ctl.sh [--dir D] check                 prints ok | elf-at-path | missing-real | obsolete | expired; exit 0 only on ok; writes the state file
#   wm-build-shim-ctl.sh --selftest                      every mode against a temp dir with stub binaries
# DIR defaults to ~/.cargo/bin. The running daemon keeps its open inode: install hard-links (never cp) the live ELF to wm-build.real first.
# PREMISE: until the wm-build status/runs whole-journal fix is promoted (rb hand PR 1e3f).   EXPIRES: 2026-11-14 -> `check` prints `expired`,
#   `install` refuses to install the shim, `place` still places but to the path (the shim is retired, not refreshed).
# Seams (tests/selftest only): WM_BUILD_SHIM_ELF_MAGIC (first 4 bytes that count as an ELF; default \x7fELF -- tests use "#!/b" so tiny sh stubs
#   whose --version prints a chosen string stand in for ELF binaries), WM_BUILD_SHIM_STATE (default ~/.cache/wm-build-shim/state),
#   WM_BUILD_SHIM_SRC (shim source, default beside this script), WM_BUILD_SHIM_TODAY / WM_BUILD_SHIM_EXPIRES (YYYY-MM-DD),
#   WM_BUILD_SHIM_OBSOLETE_AT (production knob: real --version >= this -> check says obsolete).
set -u

EXPIRES=${WM_BUILD_SHIM_EXPIRES:-2026-11-14}
SELF=$(readlink -f "$0")
SRC=${WM_BUILD_SHIM_SRC:-$(dirname "$SELF")/wm-build-bound-shim.sh}
STATE=${WM_BUILD_SHIM_STATE:-$HOME/.cache/wm-build-shim/state}
ELF_MAGIC=${WM_BUILD_SHIM_ELF_MAGIC:-$'\x7fELF'}
DIR=$HOME/.cargo/bin

die() { echo "wm-build-shim-ctl: $*" >&2; exit 1; }
is_elf() { [ -f "$1" ] && [ "$(head -c4 "$1" 2>/dev/null)" = "$ELF_MAGIC" ]; }
is_shim() { [ -f "$1" ] && ! is_elf "$1" && grep -q 'wm-build-bound-shim' "$1" 2>/dev/null; }
version_of() { "$1" --version 2>/dev/null | head -n1; }
expired() { [[ ${WM_BUILD_SHIM_TODAY:-$(date +%F)} > $EXPIRES ]]; }

cmd_install() {
  local replace=0 pre realv
  [ "${1:-}" = "--replace" ] && replace=1
  expired && die "install refused: shim premise expired $EXPIRES"
  [ -f "$SRC" ] || die "shim source missing: $SRC"
  is_elf "$DIR/wm-build" || die "install refused: $DIR/wm-build is not an ELF (already the shim? use check / place / rollback)"
  pre=$(version_of "$DIR/wm-build")
  if [ -e "$DIR/wm-build.real" ]; then
    realv=$(version_of "$DIR/wm-build.real")
    if [ "$realv" != "$pre" ] && [ "$replace" -ne 1 ]; then
      die "install refused: wm-build.real is '$realv' but $DIR/wm-build is '$pre'; pass --replace to overwrite wm-build.real"
    fi
  fi
  ln -f "$DIR/wm-build" "$DIR/wm-build.real" || die "hard link failed"
  install -m755 "$SRC" "$DIR/.wm-build.shim.tmp" || die "shim copy failed"
  mv -f "$DIR/.wm-build.shim.tmp" "$DIR/wm-build" || die "shim rename failed"
  [ "$(version_of "$DIR/wm-build")" = "$pre" ] || die "verify FAILED: --version through the shim is '$(version_of "$DIR/wm-build")', want '$pre'; run: $SELF --dir $DIR rollback"
  "$DIR/wm-build" --selftest >/dev/null 2>&1 || die "verify FAILED: shim --selftest; run: $SELF --dir $DIR rollback"
  echo "installed shim at $DIR/wm-build; real = $DIR/wm-build.real ($pre)"
}

cmd_place() {
  local cand=${1:-} target tmp
  [ -n "$cand" ] || die "usage: place <candidate-binary>"
  is_elf "$cand" && [ -x "$cand" ] || die "place refused: $cand is not an executable ELF"
  if is_shim "$DIR/wm-build" && ! expired; then target=$DIR/wm-build.real; else target=$DIR/wm-build; fi
  tmp=$DIR/.$(basename "$target").tmp
  if ! { cp "$cand" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$target"; }; then die "place failed"; fi
  echo "placed $target $(version_of "$target")"
}

cmd_rollback() {
  is_shim "$DIR/wm-build" || die "rollback refused: $DIR/wm-build is not the shim"
  is_elf "$DIR/wm-build.real" || die "rollback refused: $DIR/wm-build.real is not an ELF"
  mv -f "$DIR/wm-build.real" "$DIR/wm-build" || die "rollback rename failed"
  echo "rolled back: $DIR/wm-build is the real binary again ($(version_of "$DIR/wm-build"))"
}

cmd_check() {
  local word=ok realv
  if expired; then word=expired
  elif ! is_elf "$DIR/wm-build.real"; then word=missing-real
  elif is_elf "$DIR/wm-build"; then word=elf-at-path
  elif ! is_shim "$DIR/wm-build"; then word=missing-real
  elif [ -n "${WM_BUILD_SHIM_OBSOLETE_AT:-}" ]; then
    realv=$(version_of "$DIR/wm-build.real" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
    if [ -n "$realv" ] && [ "$(printf '%s\n%s\n' "$WM_BUILD_SHIM_OBSOLETE_AT" "$realv" | sort -V | head -n1)" = "$WM_BUILD_SHIM_OBSOLETE_AT" ]; then
      word=obsolete
    fi
  fi
  mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s %s\n' "$(date -Is)" "$word" > "$STATE" 2>/dev/null
  echo "$word"
  [ "$word" = ok ]
}

cmd_selftest() {
  local t n=0 bad=0 out ino
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' RETURN
  export WM_BUILD_SHIM_ELF_MAGIC='#!/b' WM_BUILD_SHIM_STATE=$t/state WM_BUILD_SHIM_SRC=$SRC
  export WM_BUILD_SHIM_EXPIRES=2999-01-01 WM_BUILD_SHIM_TODAY=2026-10-24
  # shellcheck disable=SC2016
  mkstub() { printf '#!/bin/sh\n[ "$1" = --version ] && { echo "wm-build stub %s"; exit 0; }\necho STUB-RAN "$@"\n' "$2" > "$1"; chmod 755 "$1"; }
  ok() { n=$((n + 1)); if [ "$2" != "$3" ]; then echo "selftest FAIL: $1 (got '$2' want '$3')" >&2; bad=1; fi; }
  c() { "$SELF" --dir "$t/d" "$@"; }
  mkdir -p "$t/d"; mkstub "$t/d/wm-build" 0.1.0; mkstub "$t/cand" 0.2.0
  out=$(c check); ok "check before install" "$out" missing-real
  ino=$(stat -c %i "$t/d/wm-build")
  c install >/dev/null 2>&1; ok "install rc" $? 0
  ok "hard link keeps inode" "$(stat -c %i "$t/d/wm-build.real")" "$ino"
  ok "path is shim" "$(is_shim "$t/d/wm-build" && echo y)" y
  out=$(c check); ok "check after install" "$out" ok
  c place "$t/cand" >/dev/null 2>&1; ok "place rc" $? 0
  ok "place leaves shim" "$(is_shim "$t/d/wm-build" && echo y)" y
  ok "place updates real" "$("$t/d/wm-build.real" --version)" "wm-build stub 0.2.0"
  c rollback >/dev/null 2>&1; ok "rollback rc" $? 0
  ok "rollback restores real" "$("$t/d/wm-build" --version)" "wm-build stub 0.2.0"
  c rollback >/dev/null 2>&1; ok "rollback refuses on ELF path" $? 1
  mkstub "$t/d/wm-build.real" 0.1.0
  out=$(c check); ok "check elf-at-path" "$out" elf-at-path
  c install >/dev/null 2>&1; ok "install refuses mismatch" $? 1
  c install --replace >/dev/null 2>&1; ok "install --replace" $? 0
  WM_BUILD_SHIM_OBSOLETE_AT=0.2.0 c check >/dev/null 2>&1; ok "check obsolete rc" $? 1
  out=$(WM_BUILD_SHIM_OBSOLETE_AT=0.2.0 c check); ok "check obsolete" "$out" obsolete
  out=$(WM_BUILD_SHIM_TODAY=2999-01-02 c check); ok "check expired" "$out" expired
  WM_BUILD_SHIM_TODAY=2999-01-02 c install >/dev/null 2>&1; ok "expired install refuses" $? 1
  WM_BUILD_SHIM_TODAY=2999-01-02 c place "$t/cand" >/dev/null 2>&1; ok "expired place -> path" "$("$t/d/wm-build" --version)" "wm-build stub 0.2.0"
  [ "$bad" -eq 0 ] || exit 1
  echo "selftest OK n=$n"
}

args=()
while [ $# -gt 0 ]; do
  case $1 in
    --dir) [ $# -ge 2 ] || die "--dir needs a value"; DIR=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
case ${1:-} in
  install) shift; cmd_install "$@" ;;
  place) shift; cmd_place "$@" ;;
  rollback) cmd_rollback ;;
  check) cmd_check ;;
  --selftest) cmd_selftest ;;
  *) echo "usage: $0 [--dir D] install [--replace] | place <candidate> | rollback | check | --selftest" >&2; exit 64 ;;
esac
