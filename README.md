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
