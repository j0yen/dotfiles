# Adaptive skill routing (/5whysandrhyme, /wwhtbt) — ledger A1300

Approved by Joe (Discord #general, 2026-11-08). One policy, one resolver, one managed launcher.

## Pieces

| Piece | Path | Role |
|---|---|---|
| Policy | `.config/skill-routing/policy.json` | The ONLY place skills, classes, routes, escalation reasons, review rules and allowed model/effort live. Skills are data: add one here, no code change. |
| Resolver | `.local/lib/skill-route-resolve.py` | stdlib only. JSON in (stdin or `--file`), JSON out `{ok, governed, model_id, effort, route, reasons[]}`. Exit 2 = denied. |
| Shell helpers | `.local/lib/skill-route.sh` | `sr_governed`, `sr_resolve`, `sr_recipe`, `sr_managed_worker`. Sourced by hooks and the audit. |
| Managed launcher | `.local/bin/fable-launch.sh --route-request FILE` | Resolves, records, then starts. Account routing is unchanged (Fable -> jyen.pm, everything else -> josephsyen). |
| Session reader | `.local/lib/skill-route-terminal.py` | stdlib only, read-only (A1300 FFDR R3). Joins the decision log's launch rows with account-lane `sessions.json` and `events.jsonl`: `session <sid>`, `task <id> --skill S [--role R] [--scope-id X]`, `review-ancestor --pid P [--self S]`. Each session gets `terminal.outcome` (`absent`, `running`, `interrupted`, `completed`, `never-dispatched`, `failed`, `unknown`) and `provenance {ok, reasons}`. Exit 2 = usage error, unreadable log, refused `ACCOUNT_LANE_STATE` override or a non-regular state file. |
| Skill gate | `.claude/hooks/fable-skill-spawn-gate.sh` | PreToolUse(Skill): governed skill inline = denied unless this process is its managed worker. |
| Slash gate | `.claude/hooks/skill-route-prompt-guard.sh` | UserPromptSubmit: a typed `/5whysandrhyme` or `/wwhtbt` is blocked outside the managed worker. |
| Agent guard | `.claude/hooks/skill-agent-effort-guard.sh` | PreToolUse(Agent): native spawns naming a governed skill may use the BASELINE route only. |
| Account guard | `.claude/hooks/fable-native-agent-guard.sh` | The parent's lane comes from launch provenance (A1300 FFDR R5): a parent whose `FABLE_LAUNCH_MODEL` is a Fable id denies a non-Fable or omitted-model native child and allows a Fable child at high; any other parent denies a Fable child; `FABLE_LAUNCH_ACCOUNT` without `FABLE_LAUNCH_MODEL` denies every Agent call. No policy read; deny texts name no account. |
| Audit | `.local/bin/model-effort-audit.sh` | Model-free. Selected vs actual model per managed launch, reasons, usage, exceptions; effort reported `unverifiable` unless the transcript states it. |
| Decision log | `~/.local/state/skill-routing/decisions.jsonl` (`SKILL_ROUTING_DECISIONS` overrides) | One row per launch, denial or declared replay (`launch`, `denied`, `replay`), fourteen fields in order: ts, decision, task_id, skill, route, model, effort, account, session, resume, reasons, role, scope, scope_id. |

## Policy (approved)

- `5whysandrhyme`: baseline Fable (`claude-fable-5-1`) **high**. xhigh only for `recurring_failure`, `contradictory_evidence`, `consequential_prevention`, each with evidence refs.
- `wwhtbt`: baseline Sonnet (`claude-sonnet-5-5`) **medium** for `straightforward_reversible`; Fable high for `strategy_cross_system`; Fable xhigh for `contested_assumptions` / `unresolved_consequential`. Anything above baseline needs evidence refs.
- `dream` (A1300 FFDR): a class is required; baseline `deterministic`. Deterministic classes (discovery, contract, duplicates, lint, manifest, persistence) start no model; extraction, inventory, classification -> Haiku; amendment, draft_approved_vision -> Sonnet medium; new_vision, prioritization, difficult_decomposition -> Opus (`claude-opus-5-5`) high and consequential_uncertainty -> Opus xhigh, each with evidence refs; `max_exception` -> the recorded Fable max exception. Every routed Dream model except that exception is non-Fable, so it takes the nonfable lane (its primaries; the reserve only after observed exhaustion). This holds on governed hosts (carbon) only, until redbaron/ryzen7 carry the policy and resolver or the Dream SKILL.md frontmatter changes (A1723).
- Missing `decision_class` = baseline (never the strongest). An unknown class string is denied.
- Evidence ref = `kind:value`, kind in `ledger|file|pr|run|commit|page`. `file:` must exist, `ledger:` is checked read-only through `wm-asks asks query` (lookup failure fails closed). Placeholders (`none`, `tbd`, ...) and free text are rejected.
- Upfront escalation needs no analysis result: the input facts (refs) justify it.
- Second review: never automatic. Only for a reason listed in the policy's `review.reasons` (`unresolved_assumption`, `contradiction`, `independent_verifier_required`, ...), with evidence. Route: the skill's `review_route` when the policy names one (Dream: `opus-high`, `claude-opus-5-5` high), else the global `review.route` (Fable high). An unknown `review_route` is a policy error (deny). A re-review of a manifest whose earlier review ended without a clean result declares `review.replay` (see Review launches).
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

## Review launches (A1300 FFDR R4)

Routed launches (`--route-request`) only; every row keeps its fourteen fields.

- Worker env (R4.1): `SKILL_ROUTE_ROLE` (author|review), `SKILL_ROUTE_SESSION` (the id handed to the CLI) and `SKILL_ROUTE_SCOPE_ID` (empty for an author), beside `FABLE_LAUNCH_ACCOUNT` and `FABLE_LAUNCH_MODEL`.
- Nested dispatch (R4.2): a routed launch is denied (`nested-dispatch`, exit 64, nothing started) when it inherits `SKILL_ROUTE_ROLE=review`, or when `skill-route-terminal.py review-ancestor` finds a review session among its ancestors: a review's claim pid with the same start time, or a `claude` / `account-lane.py run` process whose argv carries a review session id. tmux servers and driver scripts are never ancestors that count.
- Self-review and reuse (R4.3): a review whose id equals the inherited `SKILL_ROUTE_SESSION` is denied (`self-review`); a fresh launch whose pre-drawn id is not a canonical lowercase UUID (`session-id-grammar`) or already appears in a launch row (`session-reuse`) is denied.
- Unchanged review replay (R4.4), inside the guard lock: a resume of a `completed` review is denied, and so is any `review.replay` on a resume. A fresh review reads every prior review of the same task, skill and `scope_id` through the reader (`timeout 10`; a failure denies). A `running` or `completed` prior always denies: freeze a new manifest that adds its result or the disposition file. `failed`, `interrupted` and `unknown` priors block until `review.replay {reason, evidence (with a ledger: ref), prior}` names exactly that set. A declaration with nothing to declare is denied. A `never-dispatched` prior (the Fable limit before any model work) does not block. An accepted declaration writes one `replay` row (the launch row's fields, `reasons` = `{prior, prior_outcomes, reason, evidence}`) immediately before the launch row.
- The reader sits beside the launcher, else `~/.local/lib/skill-route-terminal.py`. `SKILL_ROUTE_TERMINAL` overrides it only under `FABLE_LAUNCH_TEST=1` (R4.5).
- Outside `FABLE_LAUNCH_TEST=1` the launcher refuses `SKILL_ROUTE_POLICY` and `SKILL_ROUTE_LEDGER_IDS` (exit 64, R4.6). `SKILL_ROUTING_DECISIONS` stays honoured for disposable-root proofs.

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
- `fable-native-agent-guard.sh`: a native Fable Agent under a Fable parent (by launch model since A1300 FFDR R5) needs effort `high`; xhigh/max are directed to the launcher with a reason.
- `fable-skill-spawn-gate.sh`: unpinned fable-spawn skills print `--effort high`; 5whysandrhyme/wwhtbt SKILL.md pin `effort: high`.
- `fable-review.sh` default effort `high` (`FABLE_REVIEW_EFFORT` overrides).
- Test: `tests/fable-quota-routing.test.sh` (`FQR_ROOT=<tree>` replays it on other bytes for RED).
- Not in this slice: grader (swarm-decide `wm_decide/regrade.py` `EFFORT`), dream skill (vibecode-kit, separate repo; see dream-phase routing), write/improv/beauty now tracked at effort high (tests/skill-creative-pins-high.test.sh; live copies under ~/.claude/skills change only at promotion),
  `max` as a managed skill route, ~/.claude/CLAUDE.md pin text, install.
