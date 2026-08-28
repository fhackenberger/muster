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
- **`MUSTER_CONF_DIR`** — a stack-dir-relative prefix for every config file this stack reads:
  `mounts`, `service-env`, `box-env`, `port-forwards`, `claude-settings.json`, `hub-services/` and
  `git-identity/`. Set `MUSTER_CONF_DIR=conf` in `.env` and the stack root holds compose.yml, .env
  and `data/` and nothing else. Unset, every path renders byte-for-byte as before (`${VAR:+${VAR}/}`
  contributes the separator only when set), so no existing stack needs anything done to it.

  `.env`, `compose.override.yml` and `compose.project.yml` stay in the root because compose loads all
  three from the project directory — `.env` is where the variable is learned in the first place. The
  Ansible role gains `claude_box_conf_dir` to match, and fails the play when the two disagree: a
  mismatch is otherwise silent, because docker creates a missing bind-mount source as an empty
  directory and the hub simply comes up with no mounts, no service manifests and no git identity.

- **`golden migrate --discard-retired`** — move **killed** boxes onto the current golden without
  starting anything. A box is an overlay whose mount options are fixed when its container is created,
  so every other route to a new golden needs a container: `recreate --fresh` builds one, `golden
  migrate` has to read the working tree out of one. That made freeing a golden dozens of retired
  boxes were pinned to mean resurrecting dozens of agents, each with a claude session and a port
  slot, to tell them nothing. For a box that has no container, though, "which golden am I on" is one
  file and the only thing stopping it moving is that its upper layer exists — so the broker deletes
  the layer, rewrites the file, and the next `box <name>` assembles the overlay on the current
  golden. No docker involved; it refuses outright while a container exists.

  Destructive by definition — nothing can be carried out of a box nothing can talk to — so it is
  opt-in and the flag says what it costs. Gone: every uncommitted file and every commit the box never
  handed off. Kept: `~/keep`, the box's name, branch, claude session, and whatever it pushed to
  `refs/agents/<box>`.

- **`muster golden migrate <box>|--all`** — move a box onto the current golden and **carry its
  uncommitted work across**. The move is unavoidably a fresh upper layer, so the work travels as a
  patch through the box's `~/keep` (a bind mount outside the overlay, and so the one part of a box
  that survives being recreated), re-applied with `git apply -3`. It lists the paths first and warns
  where they overlap the new golden's own uncommitted files — `snapshot` bakes the hub's dirty tree
  into every golden on purpose, so that collision is real. It cannot carry commits, and refuses a box
  with unpushed ones before capturing anything.

  On a collision it now offers **three** answers, not two: `[y]` three-way merge them, `[g]` keep the
  **golden's** version of the colliding paths and drop the agent's, `[N]` skip the box.
  `--golden-wins` answers `g` for every box without a tty, `--force` answers `y`. `g` is usually the
  one you want — these collisions are typically the golden's own setup work, where the agent is
  carrying a stale copy of a file you have since changed by hand, and merging the two only produces
  conflict markers you resolve by taking the golden's side anyway. Nothing is lost either way: the
  stash stays in `~/keep/.migrate/<id>`. The colliding paths are worked out **inside the box** (right
  after the recreate, the checkout is already dirty with exactly the golden's version of them), so
  the broker still runs a fixed `muster-migrate <action> <id>` with no caller-supplied arguments.

  `--all` reaches only boxes that are **up** — a retired box has no container, so there is nothing to
  read its working tree out of — and it now **says which ones it left behind** rather than reporting
  "migrated N" over a stack still sitting on a month-old golden. A box already on the current golden
  is skipped instead of being recreated for nothing.
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

- `muster tabs [--reap]` — the pinchtab sessions whose box is **gone**, and the browser tabs they
  left open. Dry-run unless `--reap`, and it refuses to run at all when the broker cannot say which
  boxes are live, because then every session would look orphaned.

### Changed
- **`muster minto <target> --land <box>` is now `--accept <box>`** (no alias — the old spelling is
  gone). `--land` sat one letter away from `merge --landed`, which means the opposite: `--landed` is
  bookkeeping for work that is *already* in the branch, while this is the step that actually moves
  `<target>` onto the agent's resolved merge. `minto --landed` (the `--here` worktree counterpart)
  keeps its name.
- **`minto <target> --accept <TAB>` completes box names**, on the hub and through the laptop aliases,
  and only the boxes that are actually resolving a merge (one `<box>.mergeinto` state file each) —
  offering every box there names the one thing the command must refuse. Before, both completions kept
  offering branch names after the flag, because they key on the command alone. `--intent <TAB>` now
  offers nothing, which is the right answer for a flag that takes prose.

### Fixed
- **`muster merge --edit` with an empty message left a merge you could not retry.** `git merge --edit`
  opens the editor *after* the merge is in the index and the worktree, so leaving the buffer empty
  aborts the **commit**, not the merge: git keeps `MERGE_HEAD` and a fully staged merge. Nothing is
  conflicted in that state, which is the signal `merge` uses to tell a real conflict from a merge git
  refused outright — so it reported "git refused the merge and NOTHING was merged", and the next
  `muster merge` found its own half-finished merge and refused again, this time as "you have
  uncommitted changes to the files this box touches, commit them first". Two commands, both saying
  the opposite of what had happened, and no way to simply try again.

  The message is composed **before** anything is merged now: `--edit` opens the editor on the same
  seeded buffer as before, and an empty one cancels while `dev`, the index and the worktree are still
  untouched — so the same command works on the second try. The `Cbx-Box:` trailer is re-appended after
  editing rather than trusted to survive it, because `merge --undo` finds the merge by it. As a net
  for every *other* way a merge can be written but not committed (a `commit-msg` hook that says no),
  `merge` now recognises that state and rolls it back with `git merge --abort` instead of claiming
  nothing happened — and a merge left uncommitted by an older version or by hand is refused up front,
  naming both ways out.
- **A `minto` conflict box got its briefing but never sent it.** `minto --box` pasted the briefing the
  moment the broker returned, while the box was still starting — and that box is the slowest of all,
  because `muster-box-init` checks the target out and merges `dev` into it before claude is even
  started. The text reached the composer but the Enter behind it was swallowed by whatever claude was
  still drawing, so the prompt sat there unsent and the box looked idle. It now waits for the box's
  claude to announce itself (the same `.cbx-state` wait `muster job` has always done) before pasting,
  and says so while it waits; a box that never reports one is briefed anyway, with a warning.
- **Every image build failed once pinchtab 0.15.2 was out.** Its postinstall stopped downloading the
  binary to `$HOME/.pinchtab/bin/<version>/` — the reason `common-setup.sh` redirects `HOME` at all —
  and now writes a package-relative `.managed-bin/<version>/` inside the installed module. The install
  kept succeeding; the `find` that followed it was reading an empty directory, and reported "pinchtab
  installed but shipped no linux-amd64 binary", which is not what had happened. Both layouts are
  searched now (pinchtab's own code still falls back to the old one), so pinning an older
  `PINCHTAB_VERSION` keeps working, and the message names the directories it looked in.
- **The first box on a new stack hung at claude's trust prompt.** claude asks "Is this a project you
  trust?" on the first use of a directory and blocks on the answer — which in an unattended box is
  forever, and does not read as a hang: `muster job` sees a claude that started normally and simply
  never proceeds, so it looks like a slow spawn until the timeout. The broker now merges
  `projects.<CHECKOUT_DST>.hasTrustDialogAccepted` into the shared `.claude.json` at spawn, using the
  same override-document merge as the stack's `claude-settings.json` — so nothing else in the file is
  disturbed, a file it cannot parse is left completely alone, and a file already in that state is not
  rewritten at all. One entry covers every box, because they all mount their checkout at the same
  path. Only the FIRST box on a stack ever saw this: after somebody answers by hand, the shared
  config remembers.
- **A killed box's browser tabs stayed open forever.** A session's lifetime is bounded — 24h, or its
  box's kill — but its TAB's is not: `pinchtab session revoke` answers with `remainingTabIds`, the
  tabs it has just orphaned, and nothing read that field. One hub was found holding 19 of them for
  boxes retired weeks earlier, each at foreground priority (pinchtab disables renderer backgrounding
  so screenshots are honest), and because port-forward slots are reused a stale tab does not stay
  pointed at a dead box — it starts loading whatever box takes that slot next. `kill` now revokes a
  box's sessions, subagent ones included (`muster-<box>-<suffix>`), and closes the tabs revoke
  reports; `muster tabs --reap` clears the backlog that predates this.
- **Stopping a service did not stop its processes.** `down` was `tmux kill-window`, which kills what
  is in the pane and nothing else — so `pinchtab server`'s child, a `pinchtab bridge` holding a
  headless Chrome, survived every stop and every crash, reparented, and kept its tabs alive. One had
  outlived its server by 33 hours while `muster ls` reported the service as down, and a restart could
  not displace it either: the orphan still held `SingletonLock` on the profile the new server wanted.
  `down` now stops the whole process tree, and `up` first reaps what the previous run left, matched
  by pid AND process start time so a recycled pid is never killed.
- **`muster kill <name>` reported success for a box that does not exist.** `docker rm -f` is
  idempotent, so the broker answered a mistyped name exactly as it answers a real kill — which is how
  a box named `muster-tabtest` survived `kill tabtest` while the terminal said otherwise, and the
  cleanup meant to follow silently did not happen. The broker now reports whether the container was
  there, and the hub fails loudly when it was not.
- **`muster-pinchtab-session --force-new` could not do the one thing it exists for.** The box
  entrypoint exports `PINCHTAB_SESSION`, and pinchtab refuses session management for a session
  credential (`403 session_scope_forbidden`) — so once that session was revoked or expired, the
  documented recovery from `401 invalid or expired` failed at `session create`, and then blamed an
  unreachable server, because its own `health` probe was refused for the same reason. Every call it
  makes now drops the inherited session and authenticates with the box's token.
- **The `claude_box` role did not parse.** The `MUSTER_CONF_DIR` check added moments earlier used a
  nested-quote `tr -d`, which is valid YAML — it sits inside a block scalar, where anything goes —
  and which ansible's argument splitter rejects outright with "failed at splitting arguments",
  pointing at the line *after* the offending one. muster's half of the deploy lives here but RUNS in
  the consuming repository, so nothing caught it until a deploy was already under way. The suite now
  parses every YAML file it ships, and separately runs `ansible-playbook --syntax-check` over a
  one-task playbook importing the role — the same parse a caller's play does, and the only one of the
  two that sees this class of bug.

- **A box that was not running was treated as a box with nothing in it.** The broker's `box_dirty`
  execs into the container and, when that fails, still answers 200 with `{"reachable": false,
  "dirty": [], "head": ""}`. For a retired box the exec always fails — there is no container — so the
  hub read the empty list as "clean" and the empty HEAD as *"VERSION DRIFT: the broker is older than
  this CLI"*, which was both wrong and a diagnosis pointing at a healthy component. Both halves of
  `box_move_blocker` therefore failed open, and `golden retire`'s [m]ove recreated the box with
  `--fresh`, deleting the upper layer — which for a killed box is precisely where unpushed work
  lives, that being the only reason `kill` keeps the directory. `box_probe` now fails on
  `reachable: false`, so every caller's existing not-reachable path is the one that runs, and the
  drift message is left to describe actual drift. `.reachable` absent (a broker predating the field)
  stays truthy, so nothing regresses. None of this was reachable in the test suite until the stub
  broker started counting retired boxes against their golden and restoring a resurrected box's own
  golden, the way the real broker does.

- **`golden migrate` and `golden retire` never tab-completed.** Both completion files kept a
  hand-written `"snapshot seal ls reap"` and neither had learned the two newer subcommands — a list
  that is four-sixths right is indistinguishable from one that works, so it reads as "I have the name
  wrong" rather than "completion is stale". The hub now reads a command's subcommands out of the
  CLI's own nested `case "$sub" in`, exactly as it already read the top-level list; the laptop, which
  cannot see the hub's source, learns them from `muster --help` alongside the flags it already
  scrapes. A test walks the dispatch — top level and every nested case it can find — and fails on any
  word that does not complete, and another bans literal word lists in the hub's completion outright.

- **The live dashboard's title bar printed `$SELF` and wrapped the clock.** `muster q`'s header read
  "`$SELF q · live`": the format string is single-quoted — it has to be, being full of `%` specifiers
  and escape bytes — so the `$SELF` written inside it was never expanded. The same mistake made every
  frame two columns too wide, because the pad subtracted a constant sized for a three-character name
  while the literal `$SELF` is five, so `20:48:07` lost its last two characters to the next row: hour
  and minute on one line, seconds on the next. The name is an argument now and the constant comes
  from `${#SELF}`, which also lines up a hub whose CLI is still called `muster` (that one was three
  columns over). Split out as `watch_title` so a test can measure the rendered width instead of
  hoping the arithmetic and the format string still agree.

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
