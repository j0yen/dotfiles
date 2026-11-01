# aide-lane.sh: the ONE lane-name rule for aide lanes (aide-launch.sh --lane, seat-event.sh aide:<lane>). Source it; it defines only.
# tests/aide-lane-regex.test.sh pins both callers to it (no drift).
AIDE_LANE_RE='^[a-z][a-z0-9-]{0,15}$'
aide_lane_valid() { [[ "${1:-}" =~ $AIDE_LANE_RE ]]; }
