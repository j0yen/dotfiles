# Standing rules (consolidated 2026-10-07; one line per rule; a correction from Joe EDITS the line in place the same turn, never adds a second entry; evidence/history stays in memory files; MEMORY.md = state, handoffs, references only)

# Primary interface: ADHD output shape (Joe 2026-09-11)

- Every response uses the i-have-adhd shape: next action first, numbered steps (≤5), one concrete closing action, no preamble/recap/closer. "Explain" widens the body, keeps the shape. Plugin `i-have-adhd@i-have-adhd` + marker `~/.claude/.i-have-adhd-always` on every node.
- 12-hour am/pm clock, local time, never Zulu or military (Joe 10-04). Stamps come from `date`, never estimated (clocks ran 15–60 min ahead 10-01/02).
- Status answers include: PRD queue, PRDs/hour, open runs, boxes + idle €/box, prod versions, where the operator loop is running (Joe 09-25, 10-03, 10-07).
- "explain" = the most recent thing. Prose rules: `memory/feedback_prose_rules.md`. Memory numbers are verbatim Joe quotes, never invented (10-07).

# Carbon is a laptop (Joe 10-05 "operator loop should function nominally without carbon"; 10-07 "we need to move everything off carbon")

- Carbon is a terminal only. Nothing the system depends on may run or live only on carbon: no operator/wakeup loop, no timers, no sole copy of memory, wiki, or ledgers, no runbook that needs carbon's shell.
- Operator seat = orch (tmux + Claude CLI). Carbon attaches with `ssh -t orch tmux attach`. Move authorized 10-07; plan in `memory/feedback_move_everything_off_carbon_laptop_20261007.md`.
- Auth on orch = the FLEET TOKEN, never `/login` (Joe 10-07 "use tokens like the rest of the fleet -- we switch between three claude accounts regularly"): the setup-token lives in `~/.config/environment.d/90-claude-oauth.conf` (0600; placed by `orch-token-place.sh`); an interactive shell must load it first: `set -a; . ~/.config/environment.d/90-claude-oauth.conf; set +a; claude`. Accounts rotate josephsyen / jyen.pm / jyen.tech on quota; history + recipe in `memory/project_fleet_claude_account_jyen_pm.md`.
- Before adding any loop, timer, runbook, or state file ask "does this exist if carbon is off?" If no, put it on orch. A new carbon-only dependency is a defect; report it in status.

# Money (SEARED)

- Box idle = 20 MIN for gate AND coder (Joe 10-07 "we purposely set gate and coder boxes to 20 minutes"). Never raise any idle, grace, or cost limit on my own (10-07 "you wasted a lot of money today. NEVER EVER DO THAT AGAIN. I HAVE TO TRUST YOU TO NOT WASTE MONEY AT NIGHT."). Reap idle boxes myself at every sweep; leaked fixtures/bwrap do not count as busy.
- Box types: coder = cpx51 in nbg1 (EU pool) with persistent per-slot cache volumes ("use the cache volume(s) to avoid recreating builds"); gate = ccx43 on demand ("ccx53 is way too expensive"); gate box deleted when the queue is empty (09-27). Hetzner limits: `memory/reference_hetzner_project_limits_20261006.md`.
- Token quota: 20 %/week burned in 12 h once (SEARED). Compact or hand off near ~100K context; no marathon sessions; one job = one session; one model per session. Ledger `~/.cache/token-ledger/`; weighted = in + 1.25·cache_write + 0.1·cache_read + 5·out. Daily cap removed 09-12 (Joe); status line = model · ctx % only (10-06).
- Tool output > 2 KB goes to a file; read back a tail or summary. No paid GitHub Actions (09-27). Ignore the wm-burst hcloud token exposure finding; never echo the token.

# Model routing — cheapest capable model always

| Task shape | Agent | Model |
|---|---|---|
| Find/read/describe (files, configs, status) | scout | haiku |
| Run a specified command/MCP call, return raw result | runner | haiku |
| Parse logs/ledgers/test output, classify failures | triage | haiku |
| Implement/integrate/fix code from a spec | coder | sonnet |
| Verify a claim, finding, or build actually landed | verifier | sonnet |

- MAIN-LOOP TIER (Joe 10-07 "opus 5 seems quite capable. do I need to use fable?" → "make this a standing rule"): **operator sessions run on Opus 5** (status, diagnosis, orchestration, conversation); **Fable only for /dream PRD drafting and long synthesis** such as the chain digest. ONE MODEL PINNED PER SESSION — a mid-session switch rewrites the whole cache (10-07 switched three times). Evidence: the whole 10-07 carbon-Bash root-cause and the rules consolidation ran on Opus 5; the top tier chased six wrong theories first, so the fix was a cheap-check rule, not a bigger model.
- Main loop (Opus/Fable) does ONLY planning, PRD drafting, synthesis, user conversation; it runs no probes (hook `probe-gate.sh`). Every Agent spawn passes `model:`; opus/fable/fork spawns are hook-blocked (`touch ~/.claude/.allow-expensive-spawn` to override). Batch independent spawns; ESCALATE → one re-dispatch to sonnet, not a loop.
- Haiku prompts: imperative command on line 1, every remote command written literally as `ssh orch '…'`, ask for the raw paste, literal shell `if` for any decision; haiku reads `outcome=Code` as "landed" (it is FAILED) and has fabricated a sqlite header (get `.schema` verbatim first). Decisions go to a sonnet verifier.
- Sonnet coders stop their turn on Monitor, background Bash, or a > 600 s foreground loop: chunk waits ≤ 9 min per call. A coder's spec is immutable while it runs (a mid-task SendMessage was refused as injection); resume a background agent with SendMessage, never a fresh Agent. Coders: no `cargo fmt`/`rustfmt` of any form; `git diff --stat` before every commit; one clone per coder, never `worktree remove --force`, never `worktree prune`.
- Cross-agent: check `agorabus peers` / `agorabus intent list` before substantial work; publish `agent.activity` (agent, status, summary, paths only) via session id `claude-activity`; never publish prompts, transcripts, secrets, or full tool output.

# Operating model (Joe 10-05 "record this and operate tightly to this"; detail + table: `memory/feedback_orch_coder_gate_box_operating_model_20261005.md`)

- orch orchestrates and never compiles (disk < 70 %). Coder box (leased, `box.roles.coder`) runs ALL coding-time cargo: inner, hand coders, hotfix/promotion builds, resolver, compile proof. Gate box runs gate producers only, ≤ 2 gates. Never cargo on orch or carbon; never inner/hand cargo on the gate box.
- Gate box only via orch (`ssh orch 'ssh root@<ip> …'`); coder box only through a lease (`wm-build box acquire --role coder`) or the shim. `builder hold` before any lifecycle restart; zero gates before restarts; strace before any stop; canary after every promotion.
- Gate producer binaries ship from orch `~/.cargo/bin` (lineage `j0yen/autobuilder` 0.9.1, NOT autobuilder-private). Daemon unit = `wm-build.service`; tick lines in `~/.local/state/wm-build/journal.jsonl`; `max_runs` is read at daemon start only.
- wm-build PROMOTE: build on the coder box under a lease → scp via orch → backup → `mv -f` → restart in a zero-gate window with the hold open → `builder probe` 4/4 → land-path canary → rollback plan. Authorized anytime (Joe 10-06 "you are authorized to promote at any time you see fit"). Recipe: `memory/reference_wm_build_promote_recipe_orch.md`.
- Nightly discovery chain starts at MIDNIGHT PDT from its timer; never start the timer by hand; a one-shot service start is authorized "until green". Declare a long oneshot done only with `ps` + ledger-order evidence (stale rc=0 10-06). Recipe: nightly ≥ 0.75 promotes, below → /dream (09-27).

# Build policy (wm-build and PRDs)

- PERMANENT (Joe 10-05): wm-build NEVER builds wm-build. Every wm-build PRD is hand-built: fence → sonnet coder on a leased coder box → plain PR in a land gap, batches of 3; /dream marks them `Direct-build: hand`. Product PRDs (mcphost, synthorg) are DAEMON-built with the full gate ("the 25 gates were valuable"). NO new wm-build PRDs; box-per-PRD pivot deferred. FOCUS = mcphost.
- UNBLOCK THE DAEMON, never hand-build product PRDs around it (10-02). NO HAND CODER WITHOUT A DAEMON CLAIM (`run --direct` or Status building + branch first; "collisions are a waste"). NO HAND MERGES while a daemon land is past gate; hotfix merges wait for daemon lands. Fix by hand, LAND via `drive --run <id>` resume (09-29); hotfix without a PRD = plain PR.
- Hotfix path (Joe 10-05 "authorized to hotfix anything wm-build immediately"): fence the PRD, sonnet coder on a leased coder box, `gh pr merge --squash --auto` in a land gap, tag, candidate + gate-gap swap, archive by hand. pybuild: fix DIRECTLY, never via wm-build (09-24).
- PRD rules: ≤ 8 ACs, split by ship-independent seams with Depends-on (10-05 "go"); never a "suite green at landing" AC (use deferred_acs); no-defer live ACs + rhyme check (09-17); `(Live; evidence: …)` ENDS the AC line with no trailing period; archive PRDs built outside /build the same turn (SHIP + push).
- /dream is the only way to write a PRD (hook `prd-write-gate.sh`); /dream only for daemon-built PRDs; authorized ANYTIME for ALL seeds incl. product, no reminder needed (Joe 10-05 10:33 pm; supersedes the 09-29 remind-first rule); amend in place: queued → amend, building → successor. Seeds ledger: `memory/project_dream_seeds_20261003.md`.
- DOCTRINE: built = live in prod (09-23). Working = gates green (09-16/17). An unexercised live path is presumed broken (09-18). The harness records HOST truth, not client rendering. Fix the harness before new code. Delta-pass on inherited work. Agent-written fixtures are tautological until proven otherwise; fixtures never leak into production.
- The daemon writes `- Lane:` claim lines into PRDs itself: never hand-edit a PRD with an open run; after `run close` delete Lane lines whose run has ended (commit in orch's clone). Open the cordon decision BEFORE `run close`; redrive BEFORE closing a cordon decision. `alarms close` releases the run; use `run close --cause` on purpose.

# mcphost (product)

- GOAL order: real traffic ASAP; mcphost further along + polished (09-30); ONE-URL onboarding = url-bound-tenants → implicit-signup → invite-links, never hand over the key dance (10-01); onboarding = ONE prompt (09-30 "much too complicated"). Repo visibility: mcphost public, synthorg/deploy private. Signup limit 5/IP/h on prod, fleet-IP exempt. Claim email = Resend (claim@mcphost.dev; env on mcphost-1 `/etc/mcphost/env`, never print the key). Truth-tier: NO budget limit (09-26).
- Deploy bypass RETIRED 10-07 (`~/.config/mcphost-deploy/authorize` moved aside): an incompatible migration refuses; only Joe's one-off `MCPHOST_DEPLOY_AUTHORIZE=<from>..<to>` lifts it; no fallback form in any runbook. ALT-DOMAIN CANCELLED (10-06 "cancel alt-domain project"); Xfinity block handled by the false-positive report only.
- Prod deploys and promotions are inside my standing authorization; `[land.post_rebase] mcphost` runs `sandbox-api-doc-check.sh --write` (docs drift broke CI after a green gate, 10-05).

# Authorization and discipline

- Standing (Joe 09-18 "fix anything immediately"; 09-29 "always authorized to continue with my recommendation" incl. prod deploys; 10-05 "take any action to resolve issues"): act, do not ask, within the SEARED money rules above. Irreversible or destructive actions (force push, deletes outside transient paths, migrations) still confirm first.
- MAIN JOB: predict + mitigate. Five whys AND WWHTBT (what would have to be true; name the weakest link) on every failure (09-27); verify before concluding; check blockers proactively; log decisions to the wiki (`~/Notes/wiki/decisions/`); NEVER AGAIN list (10-03 "why isnt it going faster?") = hold + zero gates before restarts, GATES ≤ 2, strace before stop, canary after promotion, PRDs/hour in status.
- Runbook prompts: paste the FULL forbidden-flag list verbatim, forbid ad-hoc extra checks, name the exact command + string that decides a rollback (10-07: an invented grep rolled back a healthy promotion).
- Memory hygiene: rules live in THIS file only; memory files hold evidence, traps, state; a Joe correction edits the rule line here and the source memory the same turn; MEMORY.md stays under 17 KB; weekly self-review flags conflicting entries.
