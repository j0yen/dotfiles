---
name: jira-writing-guide
description: >
  Apply the AtScale Jira-writing playbook when drafting or reviewing any Jira content —
  ticket titles, bug descriptions, story descriptions, comments, status updates,
  customer-escalation tickets, close comments, epic summaries. Centers on two
  non-negotiables — (1) **lead with the ask** (BLUF: the first line of every title,
  description, and comment names the verb-driven action you need from the reader; updates
  without an ask still name the decision-relevant delta on line 1), and (2) **name things
  specifically** (hostname + product version + build, not aliases like "nonprod", "the
  cluster", "staging", "QA", "latest"; account name + ID, not "the customer"; query ID +
  SQL fingerprint, not "the slow query") — and the Jira-specific discipline that flows
  from them: the 6-block bug template (ask, environment, reproduction, expected, actual,
  impact), the 5-block story template, the comment-as-email rule, the
  future-incident-responder test (would a stranger paged at 2am 18 months from now
  understand this ticket cold), one-ticket-one-ask discipline, severity vs priority
  separation, field-vs-prose discipline (use components / labels / fix-version, do not
  bury findable metadata in prose), link discipline (PR, customer ticket, related Jira,
  RFC / doc — paste permalinks, never "see Slack"), customer-escalation specifics
  (named account + tier + SE owner + escalation path), the seven Jira anti-patterns,
  and the 5-block review checklist. Use when drafting any Jira ticket or comment,
  reviewing someone else's, triaging a customer escalation, filing bugs from QA, writing
  release-blocker tickets, drafting close comments, or cleaning up sprint backlog
  hygiene. Includes the `acli` (Atlassian CLI) command recipes for reading, searching,
  creating, editing, commenting on, and transitioning tickets from a Claude Code session
  — `acli` is the right tool for any Jira read/write, not WebFetch or paste-in.
  Trigger on requests like "file a Jira", "create a bug ticket", "write up
  this issue in Jira", "draft the ticket for X", "review this Jira description",
  "tighten this comment", "ticket for the customer escalation", "log a defect", "log a
  story for X", "is this ticket clear", "write the close comment", "file a release
  blocker", "draft the Jira update", "review my open jira tickets", "pull my jira tickets",
  "list my open jiras". Skip pure PRD / RFC / design-doc authoring (use
  prd-writing-guide / technical-writing-for-pms — Jira tickets are work units, not
  design artifacts), customer-voice signals (use add-customer-signals /
  scan-customer-signals), Slack message phrasing, and PR-comment style.
version: 1.0.0
last_updated: 2026-05-27
---

# Jira Writing Guide — write tickets your future self can act on cold

## Core frame

A Jira ticket has a long life and many readers: the engineer triaging tomorrow, the PM scoping next sprint, the support engineer on a customer call six months from now, the on-call answering a page at 2am 18 months from now, the GTM lead pulling release notes, the auditor reading the close comment. None of them have the context the author had at write-time. Tickets that depend on author-context decay into noise; tickets that stand alone retain value across years. The two disciplines that determine whether a ticket survives that test are **leading with the ask** and **naming things specifically** — every other rule flows from one of those two.

## Two non-negotiable rules

### 1. Lead with the ask (BLUF)

The first line of every **title**, **description**, and **comment** states the verb-driven action the reader is being asked to take. If there is no ask, the first line states the decision-relevant delta (what is now true that was not true before). Context follows the ask, never precedes it.

- **Title with ask:** `Approve cache-miss regression fix for AtScale 2024.3.2-rc3 before Fri release cut` — not `Cache regression`.
- **Description first line:** `Need eng owner by 2026-05-29 to triage p95 regression on prod-east-snowflake-1.atscale.com running AtScale 2024.3.2-rc2 build 47291.` — not `So I was looking at the latency dashboards and...`.
- **Comment with ask:** `@mike please confirm the fix landed in build 47291 before I close.` — not `Hey, quick question...`.
- **Status update with no ask:** `Repro confirmed on AtScale 2024.3.2-rc3; root-caused to aggregate-planner edge case in `TimeGrainResolver`; fix in PR #4471; will close on merge.` — one line, four facts, no preamble.

If the ticket has no ask at any layer (title, description, comment), it is probably the wrong artifact — a Slack post, a doc, or an RFC.

### 2. Name things specifically — no aliases

Every environment, build, customer, query, dataset, model, and role is named by its fully-qualified identity. Aliases lose meaning across time, teams, customer escalations, and parallel environments. A ticket that says "the nonprod issue" is unusable six months later when a different nonprod environment exists.

| Don't write | Write |
|---|---|
| nonprod, staging, QA, dev | `qa-east-1.atscale.com` (hostname) |
| the cluster, our cluster | `qa-east-1.atscale.com`, 3-node, 32GB heap each |
| latest, v2024, the new build | `AtScale 2024.3.2-rc2 build 47291` |
| the customer, a large retail customer | `Albertsons (HubSpot acct 4471), tier-1 escalation` |
| the slow query | query ID `q-8a3f9` + SQL fingerprint + model + grain |
| the dashboard | `Sales-Daily-v3.pbix` (Power BI), analyst persona |
| the model | catalog `sales_prod` / cube `orders_v3` + SML commit `a8c91f` |
| on Snowflake | `Snowflake AWS us-east-1 account xy12345.snowflakecomputing.com, warehouse XL_WH` |
| with Power BI | `Power BI Desktop 2.142.928.0, XMLA endpoint, DirectQuery` |

The discipline extends to **roles** (`analyst persona with role rl_finance_readonly`) and **time** (`2026-05-27 14:32 UTC`, not "today" or "this morning"). Cost of a few extra characters: trivial. Cost of an undebuggable ticket during a customer escalation: enormous.

## Ticket templates

### Bug — 6 blocks

1. **Ask** (first line of description): what action you need, by whom, by when, severity.
2. **Environment** — fully-qualified hostnames, builds, clients, backends, auth modes, customer if applicable.
3. **Reproduction** — numbered, minimal, runnable by a stranger. Exact commands, exact UI clicks, exact query text. Strip steps that aren't part of the minimum repro.
4. **Expected** — what should happen, with a citation to the spec / docs / API contract if one exists.
5. **Actual** — what happens instead. Paste exact error text (don't paraphrase), log lines (timestamp + node + level), stack traces, query plans, in code blocks.
6. **Impact** — what breaks for which persona, quantified (customers affected, ARR at risk, p95 delta, blocked release).

### Story — 5 blocks

1. **Ask** — what you want approved / built / scheduled, by whom.
2. **User need** — `As a [named persona], I want [outcome] so that [business outcome].` Outcome, not mechanism.
3. **Acceptance criteria** — Given/When/Then, each independently testable. The PM-QA contract.
4. **Out of scope** — what a reasonable reader might assume is included but isn't. Prevents scope drift.
5. **Dependencies & links** — blocking tickets, PRD / RFC, design doc, customer ticket. Paste permalinks.

### Customer escalation — additions on top of Bug

- Named account, account ID, tier (1/2/3), CSM / SE owner, escalation channel.
- Customer-quoted symptom in `quotes`, kept separate from internal diagnosis.
- Workaround (if any) and whether the customer has accepted it.
- Linked support ticket (Zendesk / HubSpot ID + permalink).

### Epic — 3 blocks

1. **Ask** — what outcome the epic delivers, for whom, by when.
2. **Scope** — bulleted list of stories with links, not a prose narrative.
3. **Success metric** — one measurable outcome with baseline, target, and measurement method.

## Comments are emails, not chat

- One comment, one packet. Self-readable without re-reading the thread.
- First line is the ask or the decision-relevant delta. Never `Hey,` or `So,`.
- Status comments must include four things: what changed since last comment + what is next + what is blocking + ETA. If any are unknown, say "no change" or "unknown" explicitly — silence reads as confusion.
- @-mention the responsible person in the first line if you need a reply.
- Paste log lines, queries, stack traces in code blocks. Never paraphrase machine output.
- Screenshots are never sole evidence — they can't be grepped and lose context. Screenshot + caption + underlying text is fine.

## Reading and writing tickets — use `acli`

The Atlassian CLI (`acli`, available at `/opt/homebrew/bin/acli`, authenticated as the user) is the right way to read or modify Jira from a Claude Code session. Prefer it over WebFetch, scraping the Jira UI, or asking the user to paste tickets in.

```bash
# search — JQL is the universal interface
acli jira workitem search --jql "reporter = currentUser() AND statusCategory != Done" \
  --fields "key,summary,status,issuetype,assignee" --csv --limit 100
# allowed search fields are limited (no 'project', no 'description'); summary/key/status/issuetype/assignee/priority work

# read one ticket including description (description is NOT available in search)
acli jira workitem view ATSCALE-12345 --fields "summary,description,issuetype" --json
# view takes exactly one key — for batches, fan out with shell parallelism (`for k in ...; do ... & done; wait`)
# all-fields: --fields '*all' ; default also includes comments

# create (one-line description only — see ADF section below for anything structured)
acli jira workitem create --project ATSCALE --type Bug --summary "..." --description "..."

# create / edit with required custom fields, ADF body, or epic-parenting — use JSON
acli jira workitem create --from-json /tmp/create.json
acli jira workitem edit    --from-json /tmp/edit.json --yes

# edit one-liners
acli jira workitem edit ATSCALE-12345 --summary "..."

# add a comment (subcommand is `comment create`, flag is `--body` not `-b` on the wrapper)
acli jira workitem comment create --key ATSCALE-12345 --body "..."

# transition
acli jira workitem transition ATSCALE-12345 --status "In Review"
```

Gotchas worth remembering:

- **`search` and `view` take different field sets.** Search rejects `description` and `project`; view accepts `*all`. Don't reach for `description` in search — fan out to `view` after.
- **`view` is single-key.** For N tickets, run N parallel `view` calls in a shell `for` loop with `&` + `wait`. JSON output is large (some tickets > 50KB); write to `/tmp/jira_<KEY>.json` and have a subagent read them rather than dumping into the main context.
- **JQL field allow-list is narrow.** `reporter = currentUser()`, `assignee = currentUser()`, `statusCategory != Done`, `project = ATSCALE`, `text ~ "..."`, `labels = ...`, `created >= -7d` — all fine. If a field is rejected, drop it and filter in post.
- **Descriptions come back as ADF (Atlassian Document Format) JSON, not markdown.** When reviewing for writing quality, look at the JSON's `text` nodes.
- **`--description` / `--description-file` do NOT parse markdown.** Whatever you pass becomes a single ADF text node inside one paragraph — `##` headings, `- ` bullets, `**bold**`, and `` `code` `` spans are lost. Acceptable only for one-line bodies. For anything with structure (headings, lists, code spans, bold), build ADF JSON and use `--from-json`. See "Writing structured bodies as ADF" below.
- **Priority is not settable via acli.** No `--priority` flag on create or edit; not in `--from-json` schema either. New tickets inherit a default (often the parent epic's priority). To set a non-default priority: post a triage comment on the ticket recommending the target, or set it in the Jira UI.
- **Project may require custom fields you can't pass via top-level flags.** ATSCALE project rejects create unless **Team** (`customfield_12100`, value is the team's UUID string) and **Customer/s** (`customfield_10105`, value `[{"id":"14309"}]` for "Internal") are populated. Discover the field IDs by reading an existing ticket in the project with `--fields '*all' --json` and pass them via `additionalAttributes` in `--from-json`.
- **Epic-parenting goes through `parentIssueId`** in the create JSON (acli wording says "sub-task only" but it works for Story-under-Epic on modern Atlassian). Also populate `customfield_10008` with the same epic key as a belt-and-suspenders.
- **The comment command is a subcommand.** `acli jira workitem comment --body "..."` fails with `unknown flag: --body`. Use `acli jira workitem comment create --key KEY-1 --body "..."` (or `--body-file`).
- **Don't paste secrets into ticket bodies.** acli is authenticated; whatever you write goes to Jira Cloud immediately. There is no dry-run on `edit`/`comment`/`transition` — confirm with the user before applying.

### Writing structured bodies as ADF

The robust pattern for any ticket body with headings, lists, code spans, or bold:

1. Write the body as a `.md` file (so it's reviewable and editable as markdown).
2. Convert to ADF JSON with a small markdown→ADF helper. Minimal version (`~/.claude/scripts/md_to_adf.py` or similar) handles `## ` headings, `- ` bullet lists, `1. ` ordered lists, `**bold**`, and `` `code` `` — that's enough for almost every ticket. Output shape:
   ```json
   {"description": {"type":"doc","version":1,"content":[...blocks...]}}
   ```
3. Wrap for the edit endpoint: `{"issues": ["ATSCALE-12345"], "description": <adf-doc>}`.
4. Upload: `acli jira workitem edit --from-json /tmp/edit.json --yes`.
5. Verify by reading back: `acli jira workitem view KEY --fields description --json | jq '.fields.description.content | map(.type)'` — expect a mix of `paragraph`, `heading`, `bulletList`, `orderedList`, not a single `paragraph`.

For **create**, do the same in two passes: first `create --from-json` with a placeholder description plus the required custom fields, then `edit --from-json` with the real ADF body. Two API calls but each call uses the format acli is happy with.

If you skip the converter and use `--description-file` with raw markdown, the ticket will render as a wall of text with no structure — and you'll have to come back and redo it.

## Field-vs-prose discipline

Use Jira fields for their purpose; don't bury findable metadata in prose.

- **Components** — which subsystem (Query Planner, MCP Server, Aggregate Cache, SML Compiler). Drives routing.
- **Labels** — cross-cutting tags (`customer-blue-yonder`, `release-blocker-2024.3.2`, `regression`). Drives search.
- **Affects Version / Fix Version** — exact builds. Drives release notes and triage.
- **Severity** ≠ **Priority**. Severity = how broken (business impact). Priority = when to fix (relative order). A sev-1 with an accepted workaround can be P2.
- **Assignee** — exactly one human accountable.
- **Linked issues** — `blocks`, `is blocked by`, `duplicates`, `relates to`. Use the relationship types, not prose.

## Heuristics

- **The future-incident-responder test.** Could someone paged at 2am 18 months from now, with no prior context, follow this ticket cold? If not, it's underspecified.
- **One ticket, one ask.** If the title needs an "and", split. "Performance and UX improvements" is an epic, not a ticket.
- **Convert pronouns to nouns.** Search the draft for `this / that / it / there` — if the referent isn't on the same line, name it.
- **Quantify everything.** "Slow" → "p95 14.2s vs 800ms baseline". "A lot of customers" → "11 of 47 enterprise accounts".
- **Paste, don't paraphrase, machine output.** Stack traces, query plans, error messages, log lines — copy in code blocks. Paraphrase loses the strings the next person will grep for.
- **Permalinks, not references.** "See the Slack thread" rots; the paste-able permalink survives. Same for "the doc", "the spec".
- **Timestamp in UTC with offset noted if local matters.** "Yesterday afternoon" decays in 24 hours.
- **Close with a close comment.** Root cause, what shipped, in which build, how to verify. The close comment is what future-you reads first.

## Anti-patterns (the 7)

1. **Buried ask** — description opens with backstory; the action is in paragraph 4.
2. **Alias soup** — "the nonprod cluster", "the slow query on the customer's env", "the latest build". Decay-by-design.
3. **Screenshot-only evidence** — pictures of stack traces, log lines, queries that should be pasted as text.
4. **Pronoun chains** — "this fails when we try it on theirs" — every noun replaced by a pronoun.
5. **Multi-ask ticket** — bug + feature request + question piled together; no clean close state.
6. **Status comments without status** — "still working on it" with no delta, no ETA, no blocker.
7. **Diagnosis-in-description** — "the bug is X" stated as fact before X is verified; pollutes the search index and misleads future triage. Diagnosis goes in comments, after evidence.

## 5-block review checklist

Before submitting a ticket or comment:

1. **Ask check** — Is the verb-driven action in the first line? If no ask, is the decision-relevant delta there?
2. **Naming check** — Any aliases (`nonprod`, `the cluster`, `latest`, `the customer`)? Replace with fully-qualified identity.
3. **Reproduction check** — Could a stranger run the repro without asking questions? Are commands / queries / clicks exact?
4. **Evidence check** — Are logs, errors, stack traces pasted as text in code blocks (not screenshots)?
5. **Field check** — Components, labels, affects/fix version, severity, priority, assignee, linked issues all set?

## When to apply

- Drafting any Jira ticket — bug, story, task, epic, sub-task.
- Drafting any Jira comment — status update, question, close comment, escalation handoff.
- Reviewing someone else's Jira content for clarity, completeness, or close-readiness.
- Triaging a customer escalation into a Jira ticket.
- Writing release-blocker tickets where the audience extends to GTM and exec.
- Cleaning up sprint backlog hygiene before planning.

## Out of scope

- PRDs / RFCs / design docs — use `prd-writing-guide` and `technical-writing-for-pms`. Jira tickets are work units, not design artifacts.
- Customer-voice signals — use `add-customer-signals` / `scan-customer-signals`.
- Slack message phrasing or PR-comment style.
- Jira tooling questions (workflow config, custom fields) — this skill covers content, not configuration.

## Source

AtScale Jira-writing playbook, 2026-05-27. Grounded in two corrections received in practice: lead with the ask, and replace aliases with hostname + exact version + build. See [[feedback-jira-writing]].
