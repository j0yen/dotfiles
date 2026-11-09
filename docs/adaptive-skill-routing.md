# Adaptive skill routing (/5whysandrhyme, /wwhtbt) — ledger A1300

Approved by Joe (Discord #general, 2026-11-08). One policy, one resolver, one managed launcher.

## Pieces

| Piece | Path | Role |
|---|---|---|
| Policy | `.config/skill-routing/policy.json` | The ONLY place skills, classes, routes, escalation reasons, review rules and allowed model/effort live. Skills are data: add one here, no code change. |
| Resolver | `.local/lib/skill-route-resolve.py` | stdlib only. JSON in (stdin or `--file`), JSON out `{ok, governed, model_id, effort, route, reasons[]}`. Exit 2 = denied. |
| Shell helpers | `.local/lib/skill-route.sh` | `sr_governed`, `sr_resolve`, `sr_recipe`, `sr_managed_worker`. Sourced by hooks and the audit. |
| Managed launcher | `.local/bin/fable-launch.sh --route-request FILE` | Resolves, records, then starts. Account routing is unchanged (Fable -> jyen.pm, everything else -> josephsyen). |
| Skill gate | `.claude/hooks/fable-skill-spawn-gate.sh` | PreToolUse(Skill): governed skill inline = denied unless this process is its managed worker. |
| Slash gate | `.claude/hooks/skill-route-prompt-guard.sh` | UserPromptSubmit: a typed `/5whysandrhyme` or `/wwhtbt` is blocked outside the managed worker. |
| Agent guard | `.claude/hooks/skill-agent-effort-guard.sh` | PreToolUse(Agent): native spawns naming a governed skill may use the BASELINE route only. |
| Account guard | `.claude/hooks/fable-native-agent-guard.sh` | Unchanged semantics: a native Fable child is denied off jyen.pm, a non-Fable child is denied under a jyen.pm parent. |
| Audit | `.local/bin/model-effort-audit.sh` | Model-free. Selected vs actual model per managed launch, reasons, usage, exceptions; effort reported `unverifiable` unless the transcript states it. |
| Decision log | `~/.local/state/skill-routing/decisions.jsonl` (`SKILL_ROUTING_DECISIONS` overrides) | One row per launch or denial: task_id, skill, route, model, effort, account, session, resume, reasons. |

## Policy (approved)

- `5whysandrhyme`: baseline Fable (`claude-fable-5-1`) **high**. xhigh only for `recurring_failure`, `contradictory_evidence`, `consequential_prevention`, each with evidence refs.
- `wwhtbt`: baseline Sonnet (`claude-sonnet-5-5`) **medium** for `straightforward_reversible`; Fable high for `strategy_cross_system`; Fable xhigh for `contested_assumptions` / `unresolved_consequential`. Anything above baseline needs evidence refs.
- Missing `decision_class` = baseline (never the strongest). An unknown class string is denied.
- Evidence ref = `kind:value`, kind in `ledger|file|pr|run|commit|page`. `file:` must exist, `ledger:` is checked read-only through `wm-asks asks query` (lookup failure fails closed). Placeholders (`none`, `tbd`, ...) and free text are rejected.
- Upfront escalation needs no analysis result: the input facts (refs) justify it.
- Second review: never automatic. Only for `unresolved_assumption`, `contradiction`, `independent_verifier_required`, with evidence; route Fable high.
- No `max`, no implicit fallback to Codex or any other provider. Unknown model/effort, malformed JSON, malformed policy: deny.
- Task text is data: the request travels as a JSON file or stdin; only validated enums and regex-checked ids reach any command line.

## Launching

```
cat > /tmp/req.json <<'J'
{"task_id":"A1300","skill":"5whysandrhyme","escalation":{"reason":"recurring_failure","evidence":["ledger:A1300","file:/path/evidence.md"]}}
J
~/.local/bin/fable-launch.sh --route-request /tmp/req.json -p "Invoke the 5whysandrhyme skill ..."
```

A denied route exits 64 before anything starts and writes a `denied` row. An allowed route sets `--model/--effort` (a conflicting `--model/--effort` is refused), passes `--session-id` so the row links to the session, strips `WM_SEAT`/`ANTHROPIC_MODEL`/`CLAUDE_CODE_SUBAGENT_MODEL` from the worker env (isolation from ctl model switching) and exports `SKILL_ROUTE_*` so the gates recognise the worker. `--resume SID` must carry the session's recorded model/effort; a changed route needs a new session. A second launch of the same task+skill while an earlier worker is alive exits 73. Plain (non-route) Fable launches stay xhigh-only.

## Residual bypasses (declared)

- Hooks are not a sandbox. Anyone with arbitrary shell can run `claude` directly with any model/effort, edit or unset the hooks, or write to the decision log. The audit detects drift of launches it knows about; it cannot see a `claude` started outside the managed launcher.
- Effort per turn is not exposed by the runtime. The audit says `unverifiable`; it never infers effort from tokens or latency.
- Hook inputs that are unreadable fail open for unrelated tools/skills by design; governed-skill-shaped calls fail closed.
- A governed workflow can be described to a native Agent without naming the skill; the effort guard matches strong patterns only (documented in the hook).
- The installed `SKILL.md` files still carry `model: fable` / `effort: xhigh` frontmatter. The route ignores it (inline use is blocked), but removal belongs to the install step and is reported by the audit as info until done.
- `ledger:` evidence proves the id exists, not that it supports the claim; the reviewer of the decision row owns that judgment.

## Rollback

1. Revert the merge commit of branch `adaptive-skill-routing` (a normal `git revert -m1`; no history rewrite).
2. Installed copies: restore the previous `fable-launch.sh`, `fable-skill-spawn-gate.sh`, `skill-agent-effort-guard.sh`, `fable-native-agent-guard.sh`, `analysis-skill-router.sh`, `model-effort-audit.sh`, `skill-model-policy.sh`; remove `skill-route-prompt-guard.sh` and its `UserPromptSubmit` entry from `~/.claude/settings.json`; remove `~/.local/lib/skill-route*.{sh,py}` and `~/.config/skill-routing/`.
3. Soft rollback without a revert: delete a skill's key from `policy.json`. It becomes ungoverned and the hooks stop acting on it.
4. The decision log is append-only history; leave it.

## Fable quota routing addendum (A1300, Joe 2026-11-08) — source slice A/C
- Fresh Fable defaults to `high`. `fable-launch.sh` (unmanaged launch) accepts `high`, defaults an omitted effort to `high`, and accepts
  `xhigh`/`max` only with `FABLE_LAUNCH_EFFORT_REASON` (>= 8 chars, echoed to stderr); other values exit 64. Managed routes still come from
  `.config/skill-routing/policy.json` (5whysandrhyme baseline fable-high; wwhtbt baseline sonnet-medium; evidenced xhigh escalation).
- `fable-native-agent-guard.sh`: a native Fable Agent under jyen.pm needs effort `high`; xhigh/max are directed to the launcher with a reason.
- `fable-skill-spawn-gate.sh`: unpinned fable-spawn skills print `--effort high`; 5whysandrhyme/wwhtbt SKILL.md pin `effort: high`.
- `fable-review.sh` default effort `high` (`FABLE_REVIEW_EFFORT` overrides).
- Test: `tests/fable-quota-routing.test.sh` (`FQR_ROOT=<tree>` replays it on other bytes for RED).
- Not in this slice: grader (swarm-decide `wm_decide/regrade.py` `EFFORT`), dream skill (vibecode-kit, separate repo; see dream-phase routing), write/improv/beauty now tracked at effort high (tests/skill-creative-pins-high.test.sh; live copies under ~/.claude/skills change only at promotion),
  `max` as a managed skill route, ~/.claude/CLAUDE.md pin text, install.
