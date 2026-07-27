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
                                         /home/dev/checkout = overlay(golden) + own upper layer
                                         branch agent/<name> ──push──▶ hub refs/agents/<name>

  data/golden/g-<id>/     prepared tree (deps installed) — shared read-only by every box
  data/boxes/<name>/upper/  that box's changes — the only per-agent disk cost
  data/repo/              the hub's repo: dev, every refs/agents/*, origin credentials
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
- **`cbxui [port]`** — SSH-tunnel the hub's dev server (default 4200) to your laptop.

**Transport.** These use **mosh by default** (roaming: sessions survive laptop sleep, Wi-Fi→LTE, and
IP changes, with no frozen-SSH hangs — it composes with the tmux persistence `cbxhub`/`cbxbox`
already give you). mosh needs **UDP 60000-61000** open to the server — provisioned by
`tasks/firewall.yml` (a UFW rule); on a hand-rolled host, open it yourself. It still uses ssh for the
initial handshake, so key auth is unchanged. Set `CBX_TRANSPORT=ssh` (per call or globally) to fall
back to plain ssh. **`cbxui` is always ssh** — mosh can't port-forward.

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
cbx golden ls           # snapshots, which is current, which boxes still reference each
cbx golden refresh      # new base at the current dev, with deps rebuilt, and move every box onto it
cbx golden reap         # delete snapshots nothing references
```

`cbx golden refresh` reflink-copies the previous golden (near-free on btrfs, and `node_modules`
comes along so only the delta is rebuilt), updates it to `dev`, runs `GOLDEN_PREP_CMD`, has the
broker seal it, then recreates every box with a **fresh upper layer**. It refuses to run while any
box has uncommitted changes — that's the one destructive step in the workflow, and it's why agents
should `handoff` before you refresh.

Most days you don't need it: **`cbx rebase all`** moves agents onto a newer `dev` with a `git fetch`
+ `rebase` in each box, no golden and no recreate. Refresh only when dependencies changed.

Watch the UI yourself: SSH-tunnel the hub's dev server with **`cbxui`** (from `cbx.bash_aliases`),
then open `http://localhost:4200` in your laptop browser:

```sh
cbxui           # tunnel port 4200 (the default); cbxui 9867 for another port
```

## Notes

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
  uncommitted work. Only `cbx golden refresh` (and `cbx recreate --fresh`) discards it.
- **Shared caches:** the hub and every box mount the SAME `data/npm-cache` and `data/gradle-cache`
  (rw) at `~/.npm` and `~/.gradle`, so node/gradle artifacts are downloaded once — no per-box
  duplication on the host. uid 1000 owns them (the `dev`/`gradle` users share it), and npm/gradle
  both lock the cache for concurrent access. (The `~/.m2` Maven cache is separate: read-only from
  Jenkins.)
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
- **Service commands** (`BACKEND_CMD`/`FRONTEND_CMD`/`PINCHTAB_CMD`) are env-overridable in `.env`
  if the defaults don't match your dev loop. Each service runs in its own hub tmux window that
  stays alive after the process exits, so `cbx logs <svc>` can always attach to read the output.
- **Images** are built by the `Jenkinsfile` (box / hub / box-broker); the stack reuses them by
  default and only builds locally when `COMPOSE_PULL_POLICY=build`. Flip `PUSH_TO_REGISTRY` in the
  Jenkins job to also publish them for pulling on another host.
- The laptop `claude-box.sh` flow is unchanged — the server behavior is all env-gated
  (`CLAUDEBOX_HEADLESS` etc.), off by default.
