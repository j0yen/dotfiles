#!/usr/bin/env bash
# Joe 2026-11-06: ctl is Sonnet 5.5 / medium. Validate before auth or stopping a seat.
# Caller supplies args; output CTL_POLICY_ARGS array with explicit authoritative pins.
ctl_model_policy() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/wm-decide/seat-model-hold.json" m e a seen_m=0 seen_e=0 v
  m=$(jq -er '.ctl.model | select(type=="string")' "$file" 2>/dev/null) || { echo 'ctl: missing/invalid model policy; refusing launch' >&2; return 64; }
  e=$(jq -er '.ctl.effort | select(type=="string")' "$file" 2>/dev/null) || { echo 'ctl: missing/invalid effort policy; refusing launch' >&2; return 64; }
  [ "$m" = claude-sonnet-5-5 ] && [ "$e" = medium ] || { echo 'ctl: policy differs from Joe-approved Sonnet 5.5/medium; refusing launch' >&2; return 64; }
  CTL_POLICY_ARGS=()
  while [ "$#" -gt 0 ]; do
    a=$1; shift
    case "$a" in
      --model|--effort)
        [ "$#" -gt 0 ] || { echo "ctl: $a needs a value" >&2; return 64; }
        v=$1; shift ;;
      --model=*|--effort=*) v=${a#*=} ;;
      --fallback-model|--fallback-model=*) echo 'ctl: model fallback overrides are forbidden' >&2; return 64 ;;
      --) CTL_POLICY_ARGS+=("--" "$@"); break ;;
      *) CTL_POLICY_ARGS+=("$a"); continue ;;
    esac
    case "$a" in
      --model|--model=*)
        seen_m=$((seen_m+1)); [ "$seen_m" -eq 1 ] && [ "$v" = "$m" ] || { echo 'ctl: conflicting/duplicate model override refused' >&2; return 64; } ;;
      --effort|--effort=*)
        seen_e=$((seen_e+1)); [ "$seen_e" -eq 1 ] && [ "$v" = "$e" ] || { echo 'ctl: conflicting/duplicate effort override refused' >&2; return 64; } ;;
    esac
  done
  CTL_POLICY_ARGS=(--model "$m" --effort "$e" "${CTL_POLICY_ARGS[@]}")
}
