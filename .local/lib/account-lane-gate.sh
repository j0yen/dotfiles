#!/usr/bin/env bash
# account-lane-gate.sh -- one definition of "is the account lane policy in force" for the global guards (rotate, 429 watcher, ctl-launch,
# ctl-account-follow). A1300/A1301 F3.
#   enforced = a policy file is present and readable (ACCOUNT_LANE_POLICY, else ~/.config/account-lanes/policy.json): run the checks.
#   broken   = the policy is NOT readable but the lane tool is installed (ACCOUNT_LANE_PY or ~/.local/lib/account-lane.py), or a policy path was
#              named and is unreadable: this is an installed setup that lost its policy. The guards REFUSE (fail closed) and say why; they never
#              silently permit a forbidden global account switch. Reviewed rollback = restore the previous scripts AND remove the tool; deleting
#              or breaking policy.json alone is not a rollback.
#   legacy   = neither the policy nor the tool is installed: behaviour is unchanged from before this feature.
# al_gate_state prints enforced|broken|legacy. al_gate_why prints the one-line actionable warning for `broken`.
al_gate_state() {
  local pol="${ACCOUNT_LANE_POLICY:-}" tool
  if [ -n "$pol" ]; then [ -r "$pol" ] && { echo enforced; return 0; } || { echo broken; return 0; }; fi
  [ -r "$HOME/.config/account-lanes/policy.json" ] && { echo enforced; return 0; }
  tool="${ACCOUNT_LANE_PY:-$HOME/.local/lib/account-lane.py}"
  if [ -e "$tool" ] || [ -e "$HOME/.config/account-lanes" ]; then echo broken; else echo legacy; fi
}
al_gate_why() {
  echo "account lane policy NOT in force: the lane tool is installed but the policy (${ACCOUNT_LANE_POLICY:-$HOME/.config/account-lanes/policy.json}) is missing or unreadable. Refusing global account moves (fail closed). Restore policy.json, or roll back by restoring the previous scripts and removing account-lane.py (reviewed rollback)."
}
