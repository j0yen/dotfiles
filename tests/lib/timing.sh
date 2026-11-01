#!/usr/bin/env bash
# tests/lib/timing.sh — load-tolerant wall-clock check for the sub-200 ms hook
# tests (vtim, ctl ruling 3175).
#
#   med_ms N cmd [args...]
#
# Runs `cmd` N times (N must be given; the checks use 3), each in its own FRESH temp state dir
# ($MED_STATE, exported, removed after the sample) so a hook that keeps state
# between calls cannot answer the later samples from the first one. Prints
# every sample and the median, always (pass or fail). Passes (rc 0) iff the
# median < 200 ms AND every sample < 1000 ms (a hang ceiling). The limits are
# constants: no threshold raise, no load scaling, no skip. Sets MED_MS (median)
# and MED_SAMPLES (array); $MED_SAMPLE (1-based) is exported during a sample so
# a mutation proof can slow chosen samples. `cmd` runs in this shell (not a subshell) so it may
# set globals; its exit status is the caller's to check inside `cmd`.
MED_MEDIAN_MAX_MS=200
MED_SAMPLE_MAX_MS=1000

med_ms() {
    local _n=3 _i _t0 _t1 _sorted _s _max=0 _verdict _rc=0 _mid
    case "${1:-}" in ''|*[!0-9]*|0) echo "med_ms: usage: med_ms N cmd..." >&2; return 2 ;; esac
    _n=$1; shift
    MED_SAMPLES=()
    for ((_i = 0; _i < _n; _i++)); do
        MED_STATE=$(mktemp -d) || return 1
        MED_SAMPLE=$(( _i + 1 )); export MED_STATE MED_SAMPLE
        _t0=${EPOCHREALTIME/./}
        "$@"
        _t1=${EPOCHREALTIME/./}
        rm -rf -- "${MED_STATE:?}"
        MED_SAMPLES+=( $(( (_t1 - _t0) / 1000 )) )
    done
    unset MED_SAMPLE
    _sorted=$(printf '%s\n' "${MED_SAMPLES[@]}" | sort -n)
    _mid=$(( _n / 2 ))
    MED_MS=$(printf '%s\n' "$_sorted" | sed -n "$((_mid + 1))p")
    for _s in "${MED_SAMPLES[@]}"; do [ "$_s" -gt "$_max" ] && _max=$_s; done
    if [ "$MED_MS" -lt "$MED_MEDIAN_MAX_MS" ] && [ "$_max" -lt "$MED_SAMPLE_MAX_MS" ]; then
        _verdict=ok
    else
        _verdict=SLOW; _rc=1
    fi
    echo "timing: samples=${MED_SAMPLES[*]} ms median=${MED_MS} ms max=${_max} ms (need median<${MED_MEDIAN_MAX_MS}, every sample<${MED_SAMPLE_MAX_MS}) $_verdict"
    return "$_rc"
}
