# Remote claude-box — per-project compose stack on a shared root server

Run claude-box on a server you SSH into as **root, with no host user accounts**. Each project is
one `docker-compose` stack (bind mounts, like your other stacks). A **hub** container owns the
checkout + git identity and runs the dev services (backend, `ng serve`, pinchtab + Chrome) on
demand; **agent boxes** are separate `claude-box` containers spawned by a socket-holding
**box-broker**. You detach/reattach to boxes with tmux over SSH. A second project is just a second
copy of the stack, fully isolated.

```
compose stack (cbx-<project> network)
  db (dbtest) · activemq (artemis) · redis · box-broker[socket] · hub[services + git]
                                                    │ runs claude-box.sh
                                                    ▼
                                       box-<project>-<name>  (claude, uid 1000, no .git, no socket)
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

The hub is built in **two layers**: `claude-box-hub-base` (`hub/Dockerfile.base`) carries the
project-agnostic hub tooling (git/ssh, tmux, node, pinchtab + Chrome libs, cbx, entrypoint) on the
`gradle:8-jdk17-jammy` base (JDK + gradle), and `claude-box-hub` (`hub/Dockerfile`) layers the extra
infostars build deps (ant) on top. Jenkins must build the base **before** the hub; the hub's `FROM`
resolves the base via the `HUB_BASE_IMAGE` build arg (default `…/claude-box-hub-base:stable`).

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
mkdir -p data/{checkout,claude,boxes} data/pinchtab git-identity
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
    helper = store --file=/home/gradle/.gitidentity/git-credentials
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

The hub build layers `hub/Dockerfile` onto `claude-box-hub-base`. Compose pulls that base from the
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
`ssh … docker exec …` each time, drop these into your `~/.bashrc`. Set the two variables to your
server and the stack's `PROJECT_NAME`; the hub container is resolved by its compose labels at call
time (so it survives compose's `-1` suffix and renames):

```sh
CBX_SERVER=root@your-server      # the claude-box host, e.g. root@hetzner1.acoveo.com
CBX_PROJECT=myproject            # PROJECT_NAME of the stack, e.g. infostars

# run any cbx subcommand on the remote hub:  cbx up backend / cbx ls / cbx box work1
alias cbx='ssh -t "$CBX_SERVER" "docker exec -it \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=hub) cbx"'
# drop into a shell inside the hub to look around / debug (add -u root before \$( … ) for root):
alias cbxhub='ssh -t "$CBX_SERVER" "docker exec -it \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=hub) bash -l"'
# attach to an agent box by name (Ctrl-b d to detach):  cbxbox work1
# a function, not an alias — the name lands in the MIDDLE of the command (box-<project>-<name>),
# which a plain alias (trailing args only) can't do. -u dev: claude's tmux session runs under the
# box's 'dev' user, not root (root's tmux socket is empty → "no sessions"). -e TERM=xterm-256color:
# force a TERM the slim box's terminfo knows (a native kitty/ghostty/… TERM gives "does not support clear").
cbxbox() { ssh -t "$CBX_SERVER" docker exec -it -u dev -e TERM=xterm-256color "box-${CBX_PROJECT}-$1" tmux attach -t main; }
```

The `\$(…)` is escaped so the container lookup runs on the server at call time, not when bash loads
the alias; trailing args (`up backend`) are appended to the remote `cbx` automatically.

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
cbxbox work1                                                                                                     # Ctrl-b d to detach
ssh -t "$CBX_SERVER" docker exec -it -u dev -e TERM=xterm-256color "box-${CBX_PROJECT}-work1" tmux attach -t main   # equivalent, raw
```

Curate what boxes see (per project, from the hub); recreate the box to apply:

```sh
cbx expose src src rw
cbx hide  package.json
cbx kill work1 && cbx box work1
```

Commit the agents' edits from the hub (it has `.git` + your identity; boxes don't) — hop in with
`cbxhub`:

```sh
cbxhub                                   # then, inside the hub:
#   cd /work/checkout && git status && git add -A && git commit
```

Watch the UI yourself: SSH-tunnel the hub's dev server, then open your laptop browser:

```sh
ssh -L 4200:$(ssh "$CBX_SERVER" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=hub)"):4200 "$CBX_SERVER"
```

## Notes

- **Isolation:** a box mounts only what `box-mounts` grants (default: the tree `rw`, `.git`
  hidden), has no git identity and no docker socket, and can't see the hub's filesystem. Its only
  shared surface is the network (`hub:8080/4200/9867`).
- **Broker policy:** the hub passes a box name + the manifest; the broker fixes image/uid/network/
  privileges and confines every mount source under the checkout. It is the only socket holder.
- **Service commands** (`BACKEND_CMD`/`FRONTEND_CMD`/`PINCHTAB_CMD`) are env-overridable in `.env`
  if the defaults don't match your dev loop. Each service runs in its own hub tmux window that
  stays alive after the process exits, so `cbx logs <svc>` can always attach to read the output.
- **Images** are built by the `Jenkinsfile` (box / hub / box-broker); the stack reuses them by
  default and only builds locally when `COMPOSE_PULL_POLICY=build`. Flip `PUSH_TO_REGISTRY` in the
  Jenkins job to also publish them for pulling on another host.
- The laptop `claude-box.sh` flow is unchanged — the server behavior is all env-gated
  (`CLAUDEBOX_HEADLESS` etc.), off by default.
