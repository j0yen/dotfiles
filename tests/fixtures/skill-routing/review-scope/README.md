# review-scope fixture (PRD fable-launch-review-scope-guard R9)

Recorded by running the launcher's own path (`flr_record_inputs` then `flr_record_vectors` in `tests/fable-launch-review_lib.sh`); no digest or scope id here was computed by hand.

- Launcher source commit: `4bf514c62e623aa3f822186fd9b68b8297365b50` (dotfiles), `.local/bin/fable-launch.sh` sha256 `ffb44bb45170190935e1e48a14bf418d7ac6bacb7ec5ba39067db424f8e2e81e`.
- Stubs: `PRD-rs-alpha.md`, `PRD-rs-beta.md`, `notes.md`; byte-identical copies under `sub/`; differing `other/notes.md` and `other/PRD-rs-alpha.md`.
- Manifests (`<name>.sha256`, paths relative to this directory): `happy` `reordered` `prefixed` `dupline` `dupname` `single` `crlf` `blank` `nonl` `noprd` `dupprd` `stale` `cwdonly` `nonutf8` .
- `scope-vectors.tsv`: `manifest`, `canonical` (the scope_id, or `refused:line-rule` | `refused:prd-repeat`), `launcher` (`ok` or `refused:<check>`). Each id is the `scope_id` of the row the launcher wrote for that manifest: launch rows for `ok`, denied rows for `refused:no-prd` and `refused:sha256sum`. Each vector was launched from the parent directory as `review-scope/<name>.sha256` under task `VEC-<name>` with a pre-drawn `--session-id`.
- `rows.jsonl`: the rows the launcher wrote for task `RS-ROWS`, in order: author launch, review launch (`happy`), same-scope denied (`prefixed` beside a live `happy` reviewer), author denied (beside the live author), resume denied (the author session resumed with `happy`).
- Rewrite: `scope` in `rows.jsonl` is the manifest's path relative to this directory; the original values were the absolute paths `/mnt/data/hand/rb-a1721-review-scope-guard-20261116/src/tests/fixtures/skill-routing/review-scope/<name>.sha256` (recorded in a clone at that path). AC 7 compares every field but `ts`, `session`, `account` and the ids and pids inside `reasons`.
- `crlf.sha256` and `nonutf8.sha256` are byte-exact fixtures (CR line ends; a non-UTF-8 byte in a path): mark them `-text` in any `.gitattributes` either repo adds. Neither repo has one today.
