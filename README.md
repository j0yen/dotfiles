# dotfiles

The home for the `claude-self` cluster: a machine-personal `CLAUDE_SELF.md`, the SessionStart hook that surfaces it into every Claude session, and the small CLI that lints, edits, and restores it.

This is deliberately not the full dotfiles repo. `settings.json`, the ctrace/recall/scratch hook scripts, and the other scratch CLIs live in the public [`~/wintermute/dotfiles/`](https://github.com/j0yen/wintermute/tree/master/dotfiles). These files split out because they carry personal content — voice, values, standing corrections — that doesn't belong in a public repo. Two repos, one boundary: public tooling there, the personal file here.

## Layout

```
.
├── .claude/
│   ├── CLAUDE_SELF.md            # live self-preferences (symlinked into ~/.claude/)
│   ├── CLAUDE_SELF.default.md    # default template — the default-restore source
│   └── scripts/
│       └── claude-self-start.sh  # SessionStart hook — surfaces CLAUDE_SELF.md into context
├── .config/
│   └── autostart/
│       └── claude-on-login.desktop  # autostart entry: open Claude on login / i3 restart
├── .local/
│   └── bin/
│       └── claude-self           # CLI: show / edit / lint / log / diff / default-restore / path
├── install.sh                    # symlink installer with backups
└── README.md
```

## How it fits together

`CLAUDE_SELF.md` is the machine-personal file. `claude-self-start.sh` is a SessionStart hook: on every session it lints the live file and emits it into context as a system-prompt augmentation, after the project `CLAUDE.md` and before any skill runs. The hook is silent when the file is missing; when the file is present but fails lint, it ships the content anyway behind a `LINT FAILED` marker — a malformed file should be visible and fixable, not invisible.

The lint rules `claude-self` enforces (and the hook checks):

- exactly the seven canonical section headers, in order: Voice, Values, Defaults, Things I keep getting wrong, Aspirations, Boundaries, Changelog;
- at most 200 lines total;
- the Aspirations section has at least one non-empty bullet;
- no duplicate bullet text within a section.

`claude-self` subcommands: `show`, `edit` (lint-on-save loop), `lint [--quiet]`, `log`, `diff [REF]`, `default-restore` (overwrite the live file from the template, with confirmation), and `path`.

## Install

```sh
git clone git@github.com:j0yen/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh --dry-run     # preview every link and backup
./install.sh               # symlink each tracked file into the matching $HOME path
```

`install.sh` walks every file in the repo and symlinks it to the same relative path under `$HOME`, skipping its own meta (`README.md`, `install.sh`, `.gitignore`) and `settings.local.json`. An existing non-symlink target is backed up to `<name>.bak.<timestamp>` before linking; an already-correct symlink is left alone, so reruns are idempotent.

After this, run `~/wintermute/dotfiles/install.sh` too, so `settings.json` is in place with the `claude-self-start.sh` hook registered as a SessionStart entry.

## Where it fits

The personal half of a two-repo split: this repo holds `CLAUDE_SELF.md` and its tooling; [`wintermute/dotfiles`](https://github.com/j0yen/wintermute/tree/master/dotfiles) holds the public settings and shared hook scripts.

## Shared watcher lib (`.local/lib/watcher-premise.sh` + `.local/lib/watcher-premise.spec`)

Sourced by every write-capable watcher (PREMISE + EXPIRES + `--selftest`). `install.sh` links it into `~/.local/lib`, so a hand copy is moved aside as `*.bak.<ts>` and replaced by the symlink with the same bytes. After linking, `install.sh` runs `.local/bin/watcher-lib-postapply.sh` (the dotfiles source's fleet-sync `post`, so it runs when fleet-sync fast-forwards the clone), which writes `~/.local/state/watchers/_lib.json` atomically: `{sha, bash_n_ok, source_ok, selftests{<consumer>: ok|fail|no-selftest}}`. Consumers are discovered (scripts in `~/.local/bin` with a non-comment `watcher-premise.sh` line), never hand-listed. Self-test: `.local/bin/watcher-lib-postapply.sh --selftest`.

`_lib.json` also carries `checked_at` (ISO UTC). The post-apply step runs only when fleet-sync fast-forwards the clone (and a failure is only echoed), so an hourly user timer re-runs it: `.config/systemd/user/watcher-lib-postapply.{service,timer}` (`OnCalendar=hourly`, `Persistent=true`). `install.sh` links the unit files but nothing in dotfiles or fleet-sync enables them; each host needs this once after the apply:

```sh
systemctl --user daemon-reload && systemctl --user enable --now watcher-lib-postapply.timer
```

## Merge gate on the seats (`.local/seat-bin/gh`, `.local/bin/rb-merge.sh`, `.local/bin/seat-gh-scope-check`)
`~/.local/seat-bin/gh` is a shim for the operator seats only. It passes every `gh` call through untouched (args, stdin, exit code) except `pr merge` (also `--auto`, the REST `pulls/N/merge` endpoint and the auto-merge GraphQL mutations), which it refuses unless `WM_DECIDE_GATE_OK=<verdict-id>` is set AND `merge-events.jsonl` holds a `gate-pass` for that verdict, PR and repo. Every refusal is logged as a wm-decide row (`--kind gate --model deterministic`, `decision=<verdict id|none>`). It is a guard, not a lock: a seat can still call `/usr/bin/gh`. `rb-merge.sh <verdict-id> <pr> <owner/name>` is the only caller that sets the variable: `set -euo pipefail`, gate output captured (never piped), then `&&` into `gh pr merge --squash --match-head-commit <full OID>` and `wm-decide merge-done`.

The shim dir must be on a seat's PATH and never on `wm-build.service`'s (the daemon merges through gh): `install.sh` links it to `~/.local/seat-bin/`, not `~/.local/bin/`, and nothing in `environment.d` or a profile names it. The seat launcher puts it first (`env PATH=$HOME/.local/seat-bin:$PATH claude ...` in `seat-relaunch.sh`). `seat-gh-scope-check` proves both halves (`--selftest` offline; with no argument it reads `systemctl --user show wm-build.service -p Environment` on redbaron and ryzen7 and the PATH of the running seat processes). Tests: `tests/gh_merge_shim.test.sh`, `tests/rb_merge_wrapper.test.sh`.

## Live-clone guard

`live-clone-guard.sh install <repo>` writes a pre-commit hook that refuses every commit in a checkout that must only move by fast-forward from its remote (a live clone); commits in worktrees of the same repo pass, and `LIVE_CLONE_COMMIT=1` overrides for a deliberate hand action. `install.sh` runs `live-clone-guard.sh ensure`, which reads `~/.config/live-clone-guard/repos` (one absolute path per line, `#` comments; per host, not shipped by this repo). carbon's file:

```
# live clones on carbon: never commit here; use a worktree + PR
/home/jsy/wintermute/fleet-dash
/home/jsy/dotfiles
/home/jsy/wintermute/wm-build
```

## Watchman root guard (`.local/bin/watchman`, `.local/bin/watchman-root-guard.sh`, `.config/watchman-guard/deny.list`)

Incident 10-20: a watchman client added the root `/home/jsy`; 12 s later the 65536 inotify watches were gone (10-23: systemd could not add unit watches).
- `deny.list` is the ONE list of roots watchman must never watch (equality match on `realpath -m`, never a prefix; descendants pass). The shim and the sweeper both read it through `.local/lib/watchman-guard-lib.sh`.
- The shim `~/.local/bin/watchman` (linked by `install.sh`; `~/.local/bin` precedes `/usr/bin` in tmux seats, coders, user units and the aide) logs every call as one redacted JSON line in `~/.local/state/watchman-guard/clients.jsonl` (ts, pid = the server log's `pid=N`, 3 ppid cmdlines, cwd, argv, kind; never env) and refuses CLI `watch`, `watch-project`, `trigger`, `state-enter`, `state-leave`, `subscribe` on a DENY root (exit 1). It fails open everywhere else; library clients (pywatchman) are logged, not refusable.
- `watchman-root-guard.sh` (PREMISE + EXPIRES 2026-11-24 + `--selftest`) `watch-del`s any DENY root with `/usr/bin/watchman --no-spawn --no-local` under `timeout 10`, bells the ctl seat (one per root per 10 min) and is the only enforcement for library clients. `watchman-root-guard.timer` (1 min) is the real guard; `.path` (PathChanged on the saved-state file) is a fast path that needs an inotify watch and is dead when watches are exhausted.
- Enable after merge: `systemctl --user daemon-reload && systemctl --user enable --now watchman-root-guard.timer watchman-root-guard.path`.
- Deferred (3c): `enforce_root_files` / `WATCHMAN_CONFIG_FILE`, until clients.jsonl names the owners of the 4 rootless roots or EXPIRES.
- Test: `bash tests/watchman-guard.test.sh` (stub watchman only, never the real server; includes mutations i/ii/iii/v/vi).
