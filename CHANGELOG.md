# Changelog

Notable changes. The format is loosely [Keep a Changelog](https://keepachangelog.com/); versions are
git tags, and the published images (`muster`, `muster-hub-base`, `muster-broker`) carry the same tag.

Why versions matter here: `common-setup.sh` deliberately resolves the *latest* node, claude and tuicr
at build time, so a commit does not identify an artifact. A tag does — see
`docs/adr/0001-image-builds.md`.

Every commit on `master` is published as well, under its `git describe` name (`0.1.1-7-gabc1234`) and a
moving `dev`, so running an unreleased change never requires cutting a release for it. Those are not
releases and are not listed here.

## Unreleased

### Added
- **`claude-settings.json`** — a stack can set its own claude settings (a `statusLine`, a model, a
  permissions policy) by dropping a JSON file next to `mounts`. The broker deep-merges it into the
  shared `~/.claude/settings.json` at every spawn: only the keys it names, a key removed from the
  file is retracted again unless someone changed that value by hand, and a file it cannot parse
  applies nothing rather than clobbering the file that also holds the login. Whole-line `//` comments
  are allowed. See "The stack's claude settings" in `README-remote.md`.
- `muster job <box>` — run an **unattended job in a box**: spawn it (or reuse it), wait for its
  claude to actually be up, brief it with a multi-line prompt, and wait for the agent to write a
  result file inside its own home, which the hub already mounts read-only. Prints that file on
  stdout (notes go to stderr) with an exit status a caller can branch on — `0` answered, `3` never
  did. `--detach` / `--collect` split the two halves so one caller can run many boxes at once and
  survive its own restart; `--purge` bins the box once the answer is in, never before, and never one
  holding unreviewed work. See "Unattended job boxes" in `README-remote.md`.

### Fixed
- **The terminal cleanup no longer scrambles the screen it just cleaned up.** `muster.bash_aliases`
  sent `\e[?1049l` after every command, but that escape does not only leave the alternate screen —
  per xterm's ctlseqs it also "restores the cursor as in DECRC", on the normal screen too. So a
  command that ran a pager (`cbx push` shows its `--stat` listing through less/delta) left a saved
  cursor behind, the cleanup restored it, and everything the next command printed landed on top of
  output still on screen. The alternate screen is now *asked about* with DECRQM and the escape sent
  only when the terminal answers that it is set; no answer means no. `<prefix>tty`, the explicit
  "my terminal is wrecked" hatch, still sends it unconditionally.

## [0.1.0] — 2026-08-02

### Added
- First public release. Extracted from the private Ansible repository it grew up in, with its history.
