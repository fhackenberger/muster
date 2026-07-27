# Remote claude-box — per-project compose stack on a shared root server

Run claude-box on a server you SSH into as **root, with no host user accounts**. Each project is
one `docker-compose` stack (bind mounts, like your other stacks). A **hub** container owns the git
repo + identity and runs the dev services (backend, `ng serve`, pinchtab + Chrome) on demand;
**agent boxes** are separate `claude-box` containers spawned by a socket-holding **box-broker**.
You detach/reattach to boxes with tmux over SSH. A second project is just a second copy of the
stack, fully isolated.

Each agent works **on its own branch** in a copy-on-write overlay of one shared, prepared checkout,
and pushes to the hub for review. So the expensive part (clone, `npm ci`, warm caches) exists once,
while each agent's divergence costs only what it actually changed — and you review real git
branches instead of a diff soup from N agents sharing one working tree.

```
compose stack (cbx-<project> network)
  db (dbtest) · activemq (artemis) · redis · box-broker[socket] · hub[services + git repo]
                                                    │ runs claude-box.sh
                                                    ▼
                                       box-<project>-<name>  (claude, uid 1000, no socket)
                                         /home/dev/repo = overlay(golden) + own upper layer
                                         branch agent/<name> ──push──▶ hub refs/agents/<name>

  data/golden/g-<id>/     prepared tree (deps installed) — shared read-only by every box
  data/boxes/<name>/upper/  that box's changes — the only per-agent disk cost
  data/repo/              the hub's repo AND your setup workspace, mounted at /home/dev/repo —
                          the same path the boxes use, so baked-in absolute paths stay valid
```

> **Ansible-managed on the acoveo host.** For the `infostars` stack, everything below is
> automated by `tasks/containers-claude-box.yml` (rsync of this dir to
> `/virtual_machines/claude-box-docker`, the templated `infostars.conf` → `.env` symlink, the
> pinchtab `config.json`, and the GitHub deploy key). The manual steps here document the model and
> apply to a hand-rolled stack.

## One-time host prep (per server)

Docker + the sample-DB image. The **box / hub / box-broker images are built by the `Jenkinsfile`**
(as `claude-box`, `claude-box-hub-base`, `claude-box-hub`, `claude-box-broker`, moving tag
`master→stable`, `build/test→latest`, else `dev`) — Jenkins and the claude-box host are the same
machine, so the stack reuses those local tags directly (no registry round-trip). No accounts, no
toolchain install.

Both the box and the hub are a lean **base** on `debian:trixie-slim` + a project **add-on**:
`claude-box-hub-base` (`hub/Dockerfile.base`) carries the project-agnostic hub tooling (git/ssh, tmux,
node, pinchtab + Google Chrome, cbx, entrypoint, and the uid-1000 `dev` user), and `claude-box-hub`
layers the infostars build toolchain (JDK + gradle + ant) via the **shared `Dockerfile.addon`**
(`--build-arg BASE_IMAGE=claude-box-hub-base --build-arg FINAL_USER=1000`). The box mirrors this:
`claude-box` (base) + `claude-box-infostars` (same `Dockerfile.addon`, `BASE_IMAGE=claude-box`) — the
latter is what the broker spawns. The toolchain lives once in `build-setup.sh`; the add-on Dockerfile
is written once. Jenkins builds each base **before** its add-on.

```sh
# postgres + sample DB
docker build -t infostars/dbtest  path/to/infostars/docker-postgre-test
```

Trigger the **claude-box images** Jenkins job to build them (or, to build the box image by hand
without Jenkins):

```sh
NODE_VERSION=v26.2.0 NPM_VERSION=11.13.0 PINCHTAB_VERSION=0.13.2 \
  path/to/infostars/docker-claude/build.sh
```

## Per-project stack

```sh
mkdir -p /srv/cbx/myproject && cd /srv/cbx/myproject
cp -r path/to/infostars/docker-claude/{compose.yml,box-broker,hub} .
cp path/to/infostars/docker-claude/.env.example      .env
cp path/to/infostars/docker-claude/box-mounts.example box-mounts
cp path/to/infostars/docker-claude/service-env       service-env   # REQUIRED: compose env_file
cp path/to/infostars/docker-claude/port-forwards.example port-forwards
mkdir -p data/{repo,golden,golden-staging,claude,boxes} data/pinchtab git-identity
chown -R 1000:1000 data                                 # boxes + hub run as uid 1000
$EDITOR .env            # set PROJECT_NAME, STACK_DIR=$(pwd), REPO_URL, tokens, API keys
```

Provide the hub's git identity in `git-identity/gitconfig` (referenced via `GIT_CONFIG_GLOBAL`),
e.g.:

```ini
[user]
    name = You
    email = you@example.com
[credential]
    helper = store --file=/home/dev/.gitidentity/git-credentials
```

and put an HTTPS token in `git-identity/git-credentials` (`https://user:token@github.com`) — or
drop an SSH key in `git-identity/` and use a `git@` `REPO_URL` (see the deploy-key section below).

The **image source** is env-driven in `.env`: `COMPOSE_PULL_POLICY=missing` (default) reuses the
Jenkins-built `claude-box-hub` / `claude-box-broker` images; `=build` rebuilds them locally from
this dir; `=always` pulls (point `HUB_IMAGE` / `BOX_BROKER_IMAGE` / `BOX_IMAGE` at registry-qualified
names for a different host). pinchtab needs its server bound to `0.0.0.0:9867` with `PT_TOKEN`:
drop a `data/pinchtab/config.json` (copy your laptop's, set `server.bind=0.0.0.0`,
`server.port=9867`, `server.token=<PT_TOKEN>`). Under Ansible this file is templated from
`templates/docker-compose/claude-box/data/pinchtab/config.json` with the vault token.

### GitHub deploy key (SSH)

When this stack is deployed via Ansible (`tasks/containers-claude-box.yml`,
tag `containers-claude-box-deploy-key`), an ed25519 keypair is generated **on the remote** in
`git-identity/` (never committed to git) and mounted into the hub as `~/.gitidentity`. The play
prints the public key and step-by-step registration instructions during the run. To do it by hand
instead:

```sh
ssh-keygen -t ed25519 -N '' -C "claude-box-deploy-key@$(hostname)" -f git-identity/id_ed25519
cat git-identity/id_ed25519.pub    # paste this on github.com
```

Register the **public** key on the repo: **Settings → Deploy keys → Add deploy key**, paste the
`ssh-ed25519 …` line, and tick *Allow write access* only if the hub needs to push. Then use an
SSH-form `REPO_URL` (`git@github.com:owner/repo.git`) so the hub authenticates with this key.

**Wiring the key into git — baked into the image, nothing to configure.** The hub's first-boot
clone runs non-interactively, so git must know (a) which key to use and (b) that the provider's host
is trusted — otherwise it fails with `Host key verification failed` or `Permission denied
(publickey)`. Both are handled by the hub image, generically:

- `hub/git-ssh` is set as `core.sshCommand` (`git config --system`) and offers **every private key**
  in `~/.gitidentity` — any type (ed25519 / rsa / ecdsa), not a hard-coded filename — with
  `IdentitiesOnly=yes` and `StrictHostKeyChecking=accept-new` (trusts an unseen host on first use).
- `hub/entrypoint.sh` derives the host from `REPO_URL` (any provider — GitHub, Bitbucket, GitLab, a
  self-hosted `ssh://…:port/…`) and `ssh-keyscan`s it into `~/.gitidentity/known_hosts` before the
  clone, so host-key trust is deterministic.

So you only need to drop a private key into `git-identity/` (the Ansible deploy-key task does this)
and register its public half. Verify from inside the hub with, e.g.,
`ssh -o IdentitiesOnly=yes -i ~/.gitidentity/id_ed25519 -T git@github.com` (expect a "successfully
authenticated" greeting). A mounted `~/.gitidentity/gitconfig` can still override `core.sshCommand`
if a stack needs something bespoke.

**Protect the default branch** so the key can't push over it — GitHub deploy keys have no branch
scope of their own, so this is done with a **ruleset**: **Settings → Rules → Rulesets → New branch
ruleset**, enforcement *Active*, target the default branch, enable *Restrict updates* / *Restrict
deletions* / *Block force pushes* (optionally *Require a pull request before merging*). Add the
repo owner/admin to the **Bypass list** as the exception. Note: ruleset bypass actors require the
repo to belong to an **organization** — on a personal repo there's no per-actor exception, so
register the key read-only instead.

Then:

```sh
docker compose up -d          # db, activemq, redis, box-broker, hub (clones the repo on first boot)
                              # reuses the Jenkins-built images by default (see escape hatch below)
```

### Escape hatch: build the images locally

By default (`COMPOSE_PULL_POLICY=missing`) the stack **reuses the Jenkins-built** `claude-box-hub`
and `claude-box-broker` images and never rebuilds them. If you'd rather build from this directory —
e.g. you changed a `Dockerfile`, or Jenkins hasn't run yet — flip the policy in `.env`:

```sh
# in .env
COMPOSE_PULL_POLICY=build     # always (re)build hub + box-broker locally, ignoring prebuilt images
```

Then recreate:

```sh
docker compose up -d --build  # rebuild + restart hub + box-broker
```

Or, without touching `.env`, do a one-off local build (leaves the policy alone):

```sh
docker compose build hub box-broker   # build just these two from this dir
docker compose up -d                  # they now exist locally, so `missing` uses them
```

The hub build layers `Dockerfile.addon` onto `claude-box-hub-base`. Compose pulls that base from the
registry by default, so the above just works when `docker login` has run. To build **fully offline**
(or after editing `hub/Dockerfile.base`), build the base first and point the hub at the local tag:

```sh
docker build -t claude-box-hub-base:local -f hub/Dockerfile.base .   # context = the claude-box dir
HUB_BASE_IMAGE=claude-box-hub-base:local docker compose build hub
```

The **box image** the broker spawns is separate: set `BOX_IMAGE` in `.env` (default
`claude-box:stable`), or build it locally with `build.sh` (see host prep). To go the other way and
pull from the registry on a *different* host, set `COMPOSE_PULL_POLICY=always` and point
`HUB_IMAGE` / `BOX_BROKER_IMAGE` / `BOX_IMAGE` at registry-qualified names.

## Updating a running stack

Changes reach the server by **two independent paths**, and nearly every "I deployed it but nothing
changed" comes from doing one and not the other:

| What you changed | Travels via | Carried by |
|---|---|---|
| `hub/cbx`, `hub/entrypoint.sh`, `hub/git-ssh`, `hub/Dockerfile.base` | Jenkins build | `claude-box-hub-base` → `claude-box-hub` |
| `Dockerfile`, `common-setup.sh`, `box-bin/*` | Jenkins build | `claude-box` → `claude-box-infostars` |
| `box-broker/broker.py`, **`claude-box.sh`** | Jenkins build | `claude-box-broker` |
| `compose.yml`, `.env`, `service-env`, `box-mounts`, `port-forwards`, `git-identity/*` | file sync (Ansible / rsync) | — |

Two traps in that table. **`claude-box.sh` is `COPY`d into the *broker* image**, not the box image —
a change there needs a broker rebuild. And **each add-on image must be rebuilt after its base**
(`claude-box` before `claude-box-infostars`); rebuilding only the add-on silently keeps the old base.
The Jenkinsfile orders them correctly.

```sh
# 1. images: push to master (or trigger the job) -> Jenkins builds + tags :stable
# 2. files:  ansible-playbook … --tags containers-claude-box-files
# 3. on the server:
cd /virtual_machines/claude-box-docker
docker compose up -d --pull always hub box-broker   # RECREATES them — env is fixed at creation
docker compose pull                                 # refresh the box image for the next spawn
cbx recreate all                                    # boxes: new image + new env/mounts
```

- **Recreate, not restart.** Environment variables and mounts are fixed when a container is created,
  so `docker restart` / `docker compose restart` will *not* pick up a changed `compose.yml` or
  `service-env`. `docker compose up -d` recreates when the config hash changed; `cbx recreate` does
  the same for boxes, keeping each box's upper layer and its claude session.
- **No golden snapshot needed** for an image or config update — take one only when the repo *tree*
  changed (deps installed, config files edited in `/home/dev/repo`).
- `cbx recreate all --fresh` additionally discards every box's upper layer. Only use it when you mean
  to throw uncommitted agent work away.

Verify what actually landed, rather than assuming:

```sh
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' infostars-box-broker-1 | grep -E 'M2_REPO|SERVICE_ENV_FILE'
docker exec infostars-box-broker-1 grep -c SERVICE_ENV_FILE /usr/local/bin/broker.py   # code, not env
docker exec -u dev box-infostars-<name> printenv DB_INFOSTARS_PSQL_URL
docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' box-infostars-<name>
```

The first two are the useful pair: env comes from the **file sync**, the code from the **image**, and
they fail in different ways.

## Laptop aliases

Everything is driven through `cbx` inside the hub. Rather than typing the full
`<transport> … docker exec …` each time, the helpers live in **`cbx.bash_aliases`** (next to this
README) — source it from your `~/.bashrc`, setting the server and the stack's `PROJECT_NAME` first
(export them before sourcing, or edit the defaults in the file):

```sh
# in ~/.bashrc
export CBX_SERVER=root@hetzner1.acoveo.com   # the claude-box host
export CBX_PROJECT=infostars                 # PROJECT_NAME of the stack
source /path/to/claude-box/cbx.bash_aliases
```

That gives you:

- **`cbx …`** — run any cbx subcommand on the remote hub (`cbx up backend`, `cbx ls`, `cbx box work1`).
- **`cbxhub`** — a persistent tmux shell in the hub you can detach (Ctrl-b d) / reconnect to.
- **`cbxbox <name>`** — attach an agent box's `main` tmux session (Ctrl-b d to detach).
- **`cbxpsql <dbname>`** — open a psql shell on the stack's `db` (e.g. `cbxpsql infotrack_dev`).
- **`cbxtun [spec…]`** — SSH-tunnel hub and/or agent-box dev ports to your laptop (default `hub:4211`).
- **`cbxfe <box>`** — project shorthand: open **one agent's** frontend at `http://localhost:4211`,
  with that box's own backend tunnelled on the port its JS actually asks for. Two forwards, because
  `FRONTEND_DEV_BACKEND_URL` is resolved by your browser, not by the box.
- **`cbxsync [--rebase]`** — take new origin commits onto the dev branch (`cbx pull`) and then tell
  every agent to rebase onto them (`cbx rebase all`). Skips the notify if the pull hit conflicts.

**Transport.** Long-lived interactive sessions — **`cbxhub`, `cbxbox`, and `cbx logs`** — default to
**ssh**. Set **`CBX_TRANSPORT=mosh`** (per call or globally) to opt into **mosh** for roaming: it
survives laptop sleep, Wi-Fi→LTE, and IP changes with no frozen-SSH hangs, and composes with the tmux
persistence those already give you. mosh needs **UDP 60000-61000** open to the server — provisioned by
`tasks/firewall.yml` (a UFW rule); on a hand-rolled host, open it yourself. It still uses ssh for the
initial handshake, so key auth is unchanged.

The reason ssh is the default: **mosh can't carry the clipboard.** Terminal copy from claude reaches
your laptop clipboard via an OSC 52 escape sequence, which ssh passes through transparently but mosh's
predictive terminal drops (a long-standing mosh gap). So on mosh a mouse-selection clears without
copying; on ssh it lands in your clipboard. Use mosh when roaming matters more than copy-paste. Note
that an exported `CBX_TRANSPORT` in your `~/.bashrc` wins over the file default — `echo "$CBX_TRANSPORT"`
if a transport change seems ignored.

**One-shot commands** (`cbx --help`, `cbx ls`, `cbx q`, `cbx review …`) always use **ssh**,
regardless of `CBX_TRANSPORT` — their output prints to your terminal and stays in scrollback. mosh is
an alternate-screen app: it would render the output and then wipe it on exit, and it buys nothing for
a sub-second command. **`cbxtun` is always ssh** too — mosh can't port-forward.

The hub container is resolved by its compose labels at call time (so it survives compose's `-1`
suffix and renames); the `$(…)` lookup runs on the server, and trailing args (`up backend`) are
appended to the remote `cbx` automatically. See the file's comments for the per-alias details
(root shell, terminfo for exotic terminals, etc.).

## Daily use

Start dev services on demand and manage boxes — all via the `cbx` alias:

```sh
cbx up backend        # start dev services on demand
cbx up frontend
cbx up pinchtab
cbx logs backend      # attach that service's tmux window to watch logs (Ctrl-b d to detach)
cbx box work1         # spawn an agent box (mounts per box-mounts)
cbx ls                # services + boxes
```

### Viewing service logs

Each service (`backend` / `frontend` / `pinchtab`) runs in its own hub tmux window. `cbx logs`
**attaches** that window — it's a live, streaming view, not a one-shot dump:

```sh
cbx logs backend      # attach the backend window and watch it live
```

- **Detach with `Ctrl-b d`** — this leaves the service running. Do **not** press `Ctrl-c`; that
  would kill the process inside the window.
- The window is kept alive even after the process exits (it shows `[cbx] <svc> exited …`), so
  `cbx logs` still works to read the output of a service that crashed on startup — exactly when you
  need it.
- `cbx logs` needs a TTY to attach tmux; the `cbx` alias already provides one (`ssh -t` +
  `docker exec -it`), so it just works.

Attach / detach a box (a box is a separate container, not reached through the hub) — via the
`cbxbox` helper from the aliases above, or the raw command:

```sh
cbxbox work1                                                                                # Ctrl-b d to detach
ssh -t "$CBX_SERVER" docker exec -it -u dev "box-${CBX_PROJECT}-work1" tmux attach -t main   # equivalent, raw
```

Curate EXTRA paths boxes see (the checkout itself is the overlay, see below); recreate to apply:

```sh
cbx expose docs reference ro
cbx hide  docs
cbx recreate work1
```

## The review workflow

An agent starts on `agent/<box>`, based on the hub's `dev`. When it's done it runs `handoff
"summary"` in its own session, which pushes to `refs/agents/<box>` in the hub repo and attaches the
summary as a git note. Nothing else in the stack can write `dev`.

```sh
cbx q                       # the queue: who's waiting, how far ahead, conflicts between agents
cbx review work1            # diff vs dev — on a SECOND look, only what changed since the last one
cbx fix    work1 -m "extract the dup mapper, add a test for the null branch"
cbx merge  work1            # merge into dev (--squash for a single commit) + tell the box to rebase
cbx push                    # dev -> origin
```

```
$ cbx q
BOX           AHEAD LAST           STATUS      SUMMARY
work1             4 12 minutes ago new         Invoice PDF export
work3             2 40 minutes ago re-review   Fix flaky OrderMapperTest
             ⚠ conflicts with work1: src/pdf/Renderer.java
```

- **`cbx review` is incremental.** It records what you last saw, so after a `cbx fix` round it shows
  a `git range-diff` — only the new work, correct across the amends and rebases a fix round produces.
  `--full` gives the whole branch.
- **`cbx fix` types into the agent's claude session** (via the broker, `tmux send-keys`). You never
  attach; the agent fixes and re-runs `handoff`, and the box shows up as `re-review` in `cbx q`.
- **Conflicts surface at push time, not merge time.** Every push is test-merged against `dev` *and*
  against every other live agent branch (`git merge-tree`, no worktree touched), so you learn that
  two agents hit the same lines while you can still tell one of them to rebase.
- **`cbx prereview work1`** asks the agent to critique its own diff (`mydiff`) against `CLAUDE.md`
  before you spend a round on it. It is self-review, not an independent reviewer — an ephemeral
  reviewer box is the obvious next step, not built yet.
- `cbx drop work1` discards a branch and tells the box; `cbx rebase all` moves every agent onto the
  current `dev` without a recreate (cheap, use it after merging).

Inside a box the agent has three commands: `mydiff` (exactly what it will hand over, its branch
only), `handoff "summary"`, and ordinary git. It has no credentials for the real origin and the
hub's `update` hook rejects any push outside `refs/agents/*`.

## Goldens: the shared prepared checkout

`data/golden/g-<id>` is a full, ready-to-build tree — cloned, `npm ci` done, caches warm. Every box
mounts it as an overlayfs `lowerdir` (a docker `local` volume with `type=overlay`, so **no container
needs `CAP_SYS_ADMIN`**) and writes into `data/boxes/<name>/upper`. Six agents cost one golden plus
six diffs, and a spawn is a mount, not an `npm ci`.

Goldens are immutable while boxes run on them (changing a `lowerdir` under a live overlay is
undefined behaviour), so they're versioned with `current` pointing at the newest.

```sh
cbx golden snapshot     # freeze the hub's repo as the new base + move every box onto it
cbx golden snapshot --prep   # ...running GOLDEN_PREP_CMD in the repo first
cbx golden seal <id>    # finish a staged golden you fixed up by hand
cbx golden ls           # snapshots (with provenance), which is current, which boxes reference each
cbx golden reap         # delete snapshots nothing references
```

**Set up in the hub's repo, then freeze it.** `/home/dev/repo` is your workspace: edit config files,
`npm ci`, warm gradle, patch a dependency by hand — whatever makes the tree ready. `cbx golden
snapshot` reflink-copies it (near-free on btrfs), has the broker seal it, then recreates every box
with a **fresh upper layer**.

**The path is the same on both sides — that's the point.** The repo is `/home/dev/repo` on the hub
*and* where every box mounts its overlay. Installed dependencies bake absolute paths in (npm's
`node_modules/.bin` shebangs and `.package-lock.json`, project-local `.gradle` caches, python
venvs), so a tree prepared on the hub only keeps working in a box if it's mounted back at the path
it was prepared at. Nothing is ever built in the staging copy for the same reason — a build there
would record the staging path and be wrong everywhere.

The copy can't be skipped by pointing `lowerdir` straight at the repo: overlayfs requires an
immutable lower layer while boxes are mounted on it, and you keep editing that tree.

Two guards, both worth knowing:

- **It refuses while any box has uncommitted changes.** Recreating discards upper layers, so
  unpushed work would be lost. Agents should `handoff` first; `cbx kill <box>` abandons one.
- **It refuses while `backend`/`frontend` are running**, since they write into the repo while it's
  being copied and you'd get a torn snapshot. `cbx down backend` first.

Whatever is dirty in the repo is baked in and becomes every agent's starting `git status` — that's
how your local setup reaches the boxes, and `snapshot` prints the list so it's never a surprise.
Keeping local-only config in gitignored files avoids it; modified *tracked* files are the ones an
agent can sweep into a commit by accident.

Most days you don't need it: **`cbx rebase all`** moves agents onto a newer `dev` with a `git fetch`
+ `rebase` in each box, no golden and no recreate. Refresh only when dependencies changed.

Watch the UI yourself: SSH-tunnel the dev ports with **`cbxtun`** (from `cbx.bash_aliases`), then open
the app in your laptop browser. Each argument is a forward spec — `PORT` or `hub:PORT` for a hub
service, `<box>:PORT` for an agent box, optionally prefixed `LOCAL:` to change the laptop port. The
laptop listens on `127.0.0.1` at the same port numbers, so a frontend's `http://localhost:PORT`
backend URL resolves in your browser exactly as it does on the hub. Services must bind `0.0.0.0` in
their container (ng serve/bootRun and the box port-forwards already do).

```sh
cbxtun                       # default: hub's dev server on http://localhost:4200
cbxtun work1:4200 hub:8080   # THE case: box 'work1' frontend + hub backend, in one command
                             #   open http://localhost:4200 ; its JS hits http://localhost:8080 -> hub
cbxtun 9867                  # a single hub port (e.g. pinchtab)
cbxtun 4300:work1:4200       # box 'work1' :4200 published on your laptop's :4300
```

The old single-port `cbxui` is renamed to `cbxtun` (re-source `cbx.bash_aliases`; it drops the stale
`cbxui` function on load).

## Notes

- **Agent activity:** each box's claude writes `busy` / `waiting` / `idle` to `$HOME/.cbx-state` via
  `cbx-activity` hooks, which the broker registers in the stack's shared `~/.claude/settings.json`
  (merging — your other settings and hooks are preserved, and an unparseable file is left alone).
  That path is the box's home anchor, which the hub already mounts read-only, so `cbx ls` /
  `cbx status` read it directly. Commands that type into a session (`fix`, `prereview`, `rebase`)
  refuse while an agent is working; `--force` overrides. `waiting` is deliberately not guarded —
  claude is asking *you* something. A `busy` older than `CBX_ACTIVITY_STALE` (default 900s) reads as
  `stale` and does not block, so missing or broken hooks can only cost you the protection, never the
  ability to work.
- **Isolation:** a box sees its own overlay of the golden plus whatever `box-mounts` adds, has no
  docker socket, no credentials for the real origin, and can't see the hub's filesystem or another
  box's upper layer. Its only shared surface is the network (`hub:8080/4200/9867/9418`).
- **Broker policy:** the hub passes a box name + the manifest; the broker fixes image/uid/network/
  privileges, confines every extra mount source under the golden, and owns the overlay volumes. It
  is the only socket holder. Its two box-facing operations (`/say`, `/dirty`) run **fixed** commands
  — there is no arbitrary-exec endpoint.
- **git daemon has no auth.** Boxes push over `git://` on the cbx network; the `update` hook in
  `data/repo` (installed by the hub entrypoint) is what bounds that: `refs/agents/*` and
  `refs/notes/cbx` only, so a box can never write `dev` or delete a branch.
- **Sealing a golden is a read-only mount, never file modes.** The hub mounts `data/golden` `ro` and
  prepares in `data/golden-staging`; the broker does the move. File modes cannot be used here:
  overlayfs checks write permission on the merged inode *before* deciding to copy up, so a
  non-writable golden makes every file unwritable inside the box instead of protecting anything.
- **`cbx kill` keeps the box's upper layer** on disk, so `cbx box <same name>` reattaches to its
  uncommitted work. Only `cbx golden snapshot` (and `cbx recreate --fresh`) discards it.
- **Shared caches:** the hub and every box mount the SAME `data/npm-cache` and `data/gradle-cache`
  (rw) at `~/.npm` and `~/.gradle`, so node/gradle artifacts are downloaded once — no per-box
  duplication on the host. uid 1000 owns them (the `dev`/`gradle` users share it), and npm/gradle
  both lock the cache for concurrent access. `~/.m2/repository` (`MAVEN_REPO_HOST`, Jenkins' cache)
  is shared with both as well, but **read-only** — a build must never mutate it, and it is the one
  shared path that lives outside the stack dir, so a wrong value is silently bound as an empty dir.
- **Port forwards (pinchtab browser + own-backend dev loops):** the pinchtab server + Chrome run on
  the **hub**, but each agent runs its OWN dev services inside its box (`ng serve`, and optionally its
  own backend). pinchtab's IDPI allowlist has no wildcard and the browser is in a different netns, so
  the box name / box loopback don't work directly. Instead the **`port-forwards`** manifest (grammar
  `NAME BOX_PORT HUB_BASE_PORT`, like `box-mounts`) tells the broker to publish each box's services on
  the **hub's loopback**: a box in slot N gets a socat (in the hub's netns, run from the box image)
  mapping hub `127.0.0.1:(HUB_BASE_PORT + N)` → `box:BOX_PORT`. The box receives `PORT_FORWARDS` +
  `PORT_FORWARD_<NAME>_FROM`/`_TO_HUB`, and the **project's own scripts** turn those into e.g.
  `CLAUDEBOX_DEV_URL=http://localhost:$PORT_FORWARD_FRONTEND_TO_HUB` (pinchtab loads the frontend) and
  the frontend's backend URL `http://localhost:$PORT_FORWARD_BACKEND_TO_HUB` (so an agent's frontend
  hits its OWN backend). Everything is `localhost` from the hub browser — allowlisted by default, and
  `Host: localhost` passes ng serve's host-check. Concurrency is bounded by `PORT_FORWARD_SLOTS`
  (default 16); the broker refuses to spawn once slots are exhausted. The slot is stable per box
  (`data/boxes/<name>/slot`), reused across `cbx recreate`. (Project scripts must also bind those
  services to `0.0.0.0` in the box so the forwarder can reach them.)
- **`service-env` configures the hub AND every box.** Project settings a service reads (backend DB /
  ActiveMQ / Redis wiring, API keys, feature flags) live in `service-env`, not in `compose.yml`: the
  hub gets it via compose `env_file:` and the broker passes every entry into each box as
  `-e KEY=VALUE`. That is what makes a backend an *agent* starts behave like the one the hub starts.
  Format is compose's (`KEY=VALUE`, `#` comments, literal values, no `${}` expansion). It is
  **required** — compose refuses to start the hub if the file is missing. Apply with
  `docker compose up -d hub` and `cbx recreate <box>`.
- **Service commands** (`BACKEND_CMD`/`FRONTEND_CMD`/`PINCHTAB_CMD`) are overridden in
  **`service-env`**, not `.env` — `.env` only feeds compose interpolation and never reaches the hub
  container, so an override there is silently ignored. Each runs through `bash -lc` in a tmux window
  with the cwd set to the repo, so values may use relative paths **and shell substitutions evaluated
  at launch inside the container** — that is how the backend command can pass
  `-javaagent:$(find … aspectjweaver-*.jar …)` for a jar whose path only exists after the build
  (note it uses two `gradle` calls so the substitution runs *after* the dependency is resolved).
  Each service runs in its own hub tmux window that stays alive after the process exits, so
  `cbx logs <svc>` can always attach to read the output.
- **Images** are built by the `Jenkinsfile` (box / hub / box-broker); the stack reuses them by
  default and only builds locally when `COMPOSE_PULL_POLICY=build`. Flip `PUSH_TO_REGISTRY` in the
  Jenkins job to also publish them for pulling on another host.
- The laptop `claude-box.sh` flow is unchanged — the server behavior is all env-gated
  (`CLAUDEBOX_HEADLESS` etc.), off by default.
