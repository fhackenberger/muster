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
- **`muster golden migrate <box>|--all`** — move a box onto the current golden and **carry its
  uncommitted work across**. The move is unavoidably a fresh upper layer, so the work travels as a
  patch through the box's `~/keep` (a bind mount outside the overlay, and so the one part of a box
  that survives being recreated), re-applied with `git apply -3`. It lists the paths first and warns
  where they overlap the new golden's own uncommitted files — `snapshot` bakes the hub's dirty tree
  into every golden on purpose, so that collision is real. It cannot carry commits, and refuses a box
  with unpushed ones before capturing anything.
- **`golden snapshot` leaves boxes behind instead of refusing.** A box whose work is not safe to
  discard stays on the golden it is on, and the snapshot happens anyway; `--force` moves everyone and
  says what that costs. Goldens were always versioned and `reap`/`retire` always expected a box to sit
  on an older one — `snapshot` was the one command that did not. `muster ls` now marks a box that is
  not on the current golden.

- **`muster-ask`** — an optional stack service that runs **one locked-down `claude -p` per
  request**, so a project service wanting a single inference (classify this photograph, extract these
  fields) no longer has to bake the claude CLI and a bind mount of the shared, logged-in `~/.claude`
  into its own application image, nor drive a whole agent box for something that is not agentic.
  Every request is a fresh process, so context resets between calls by construction. Off unless a
  stack sets `COMPOSE_PROFILES=ask`; it runs from the box image, publishes no port, and refuses to
  start without `ASK_TOKEN`. A request names a dir **key** from `ASK_DIRS`, never a path; tools come
  from an allow-list and `Bash`/`Write`/`Edit`/`WebFetch` are refused however that list is set;
  `--permission-mode` is not a parameter. `muster ask` is the CLI end of it. Deliberately NOT on the
  box-broker: that component owns the docker socket, its invariant is that a caller never chooses
  mounts, and its token authorises spawning boxes. See "One locked-down claude call" in
  `README-remote.md`.
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
- **A resumed box no longer jumps to whatever golden is current.** `create_box` bound
  `current_golden()` unconditionally, which was invisible while `golden snapshot` moved every box at
  once — but the moment one is left behind, an ordinary `recreate` (a new image, say) would silently
  re-point it at a newer tree while keeping the upper layer computed against the old one. Its index
  and HEAD live in that layer, so everything that changed between the two snapshots would show up as
  an uncommitted modification the agent never made. A resume now stays on the box's recorded golden;
  only `--fresh` or `golden migrate` moves it. For the same reason `golden retire`'s "move them"
  option now checks the box first and moves it with `--fresh`, instead of re-stacking its old layer.
- **Two golden snapshots in the same second no longer collide.** The id is second-resolution and the
  broker refuses a duplicate, so the second one sealed nothing and reported "already exists" — much
  easier to hit now that a snapshot is not blocked by a dirty box. It picks the next free suffix.
- **A porcelain line like `" M a.txt"` is printed as one file, not two.** The dirty listing used an
  unquoted `printf '  %s\n' $dirty`, which word-split every entry into its status and its path.

- **`golden snapshot` now refuses a box that has committed but never handed off.** The check ran
  `git status --porcelain` in each box and nothing else, while its own refusal told you to "commit +
  handoff" — so it enforced only the first half. A box's `.git` lives in the same overlay as its
  working tree, and the snapshot recreates every box with a fresh upper layer, so an agent that
  finished a piece of work and committed it without handing off had a clean status and commits that
  existed nowhere else: they were deleted. The broker's `/box/<name>/dirty` now also reports the
  box's `HEAD`, and the hub refuses unless `refs/agents/<box>` already contains it — naming whether
  the commit is one it has never seen or merely one ahead of the last handoff. An older broker that
  does not report `HEAD` is called out as version drift rather than passing silently.

- **A build in a live stack directory no longer ships the stack's own state to the docker daemon.**
  `compose.yml` builds every image with `context: .`, and a stack directory *is* this directory once
  it has been copied to a server — so `docker compose --profile build build hub-image` there tarred
  up `data/` (the goldens, every box's overlay layer, and `data/claude`, which holds the **claude
  login**) along with `.env`, `service-env` and `git-identity/`. In CI the gap is invisible, because
  a fresh checkout has no `data/`; it appears the first time someone builds where the stack runs,
  which is the supported way to run a stack whose add-on nobody else builds. There is now a
  `.dockerignore`. It is deliberately **not** a copy of `.gitignore`: `build-setup.sh` is gitignored
  and must stay *in* the context, since `Dockerfile.addon` COPYs it. A test asserts both halves —
  that `data/` is excluded, and that nothing any Dockerfile COPYs is.

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
