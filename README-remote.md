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
node, pinchtab + Google Chrome, the tuicr review TUI, cbx, entrypoint, and the uid-1000 `dev` user), and `claude-box-hub`
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
cp path/to/infostars/docker-claude/mounts.example     mounts
./gen-hub-mounts.sh                                    # renders the hub's volumes -> compose.override.yml
cp path/to/infostars/docker-claude/service-env       service-env   # REQUIRED: compose env_file
cp path/to/infostars/docker-claude/port-forwards.example port-forwards
cp -r path/to/infostars/docker-claude/hub-services.example hub-services  # dev-service manifests
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
| `Dockerfile`, `box-bin/*` | Jenkins build | `claude-box` → `claude-box-infostars` |
| `common-setup.sh` (shared toolchain: node, pinchtab, **tuicr**) | Jenkins build | **both** bases — box *and* hub |
| `box-broker/broker.py`, **`claude-box.sh`** | Jenkins build | `claude-box-broker` |
| `compose.yml`, `.env`, `service-env`, `mounts`, `port-forwards`, `hub-services/*`, `git-identity/*` | file sync (Ansible / rsync) | — |

A change to `mounts` needs one extra step on the host, `./gen-hub-mounts.sh`, which renders the hub's
half of the table into `compose.override.yml` (Ansible does it as part of the files tag).

Two traps in that table. **`claude-box.sh` is `COPY`d into the *broker* image**, not the box image —
a change there needs a broker rebuild. And **each add-on image must be rebuilt after its base**
(`claude-box` before `claude-box-infostars`); rebuilding only the add-on silently keeps the old base.
The Jenkinsfile orders them correctly.

```sh
# 1. images: push to master (or trigger the job) -> Jenkins builds + tags :stable
# 2. files:  ansible-playbook … --tags containers-claude-box-files
# 3. on the server:
cd /virtual_machines/claude-box-docker
./gen-hub-mounts.sh                                 # if `mounts` changed (Ansible already did it)
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
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' infostars-box-broker-1 | grep -E 'MOUNTS_FILE|SERVICE_ENV_FILE'
docker exec infostars-box-broker-1 grep -c SERVICE_ENV_FILE /usr/local/bin/broker.py   # code, not env
docker exec -u dev box-infostars-<name> printenv DB_INFOSTARS_PSQL_URL
docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' box-infostars-<name>
docker logs infostars-hub 2>&1 | grep 'MOUNT DRIFT'     # hub's own mounts vs the `mounts` table
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
- **`cbxfe <box>` / `cbxfe <box> --own`** — project shorthand: open **one agent's** frontend at
  `http://localhost:4211`, with **both** candidate backends tunnelled alongside it — the hub's
  (`:8091`, the default) *and* that box's own (`:<8900+slot>`, what `$FRONTEND_DEV_BACKEND_URL_OWN`
  points at). Several forwards, because `FRONTEND_DEV_BACKEND_URL` is resolved by **your browser**,
  not by the box, and the agent may have switched it to its own backend at any point. Tunnelling both
  means you never have to know which: a missed one shows up only as failing API calls
  (`ERR_CONNECTION_REFUSED` on e.g. `http://localhost:8904/infostarsWeb/rest/config`) on a page that
  otherwise loads fine. `--own` tunnels *only* the box's own backend, leaving `:8091` free on your
  laptop for a backend of your own.
- **`cbxsync [--rebase]`** — take new origin commits onto the dev branch (`cbx pull`) and then tell
  every agent to rebase onto them (`cbx rebase all`). Skips the notify if the pull hit conflicts.
- **`cbxexport <box>`** — pull an agent's work down as **one squashed commit** on your current branch
  (`cbx export` → local `git am`). `cbxexport <box> --show` prints the raw patch instead of applying it.
- **`cbximport <box> [base]`** — the reverse: **replace** an agent's branch with *your* net change and
  tell the box to just note it, not act (`git format-patch` → `cbx import`). See *Editing an agent's
  work by hand* below.
- **`cbxcp <src> <dst>`** — copy a file or a whole directory between a box / the hub and your laptop,
  either direction. Exactly one side is `<box>:<path>` or `hub:<path>`; the other is local, and a
  remote source may drop the destination (defaults to `.`):

  ```sh
  cbxcp work1:/home/dev/repo/build/out.log .      # box    -> laptop
  cbxcp work1:/home/dev/repo/build/libs .         # …a whole directory, same syntax
  cbxcp hub:/work/boxes/work1/state ./state       # hub    -> laptop, renamed on the way
  cbxcp ./fix.patch work1:/home/dev               # laptop -> box
  ```

  Use this for logs, screenshots and build artifacts; use `cbxexport`/`cbximport` for **code**, since
  those move a reviewable git patch rather than loose files. The destination is extracted into if it
  is an existing directory and treated as the new name otherwise — same rule whichever way you copy.
  Everything travels as a tar stream over `docker exec -i`, so modes and symlinks survive, directories
  need no special flag, and nothing is staged on the server in between.
- **`cbxexec <box|hub> <command…>`** — run an arbitrary command in a box or the hub with its output
  clean enough to pipe into your local tools:

  ```sh
  cbxexec work1 gradle -q :infostarsEJB:test | tee test.log
  cbxexec work1 cat /home/dev/repo/build/reports/x.json | jq .failures
  cbxexec hub 'cbx q --text' | grep -i blocked
  cbxexec work1 'grep -rn TODO /home/dev/repo | wc -l'     # …the pipe runs IN the box
  tar -cf - ./seed | cbxexec work1 'tar -C /tmp -xf -'     # …and stdin flows the other way
  ```

  The arguments are joined and handed to `sh -c` inside the container, so **where you put the quotes
  decides where a pipe runs**: unquoted, your local shell takes it and the box's stdout flows into
  your local tool; quoted, the box's own shell does. No PTY on either hop, so stdout is byte-exact,
  stdin is forwarded, and stderr stays on stderr — a local pipe sees only real output. The exit status
  is the command's own. Use `cbxbox` instead when you want the *interactive* tmux attach.

**Export the two variables as their own commands.** Prefixing them to the `source` — `CBX_SERVER=…
CBX_PROJECT=… . cbx.bash_aliases` — does *not* work: assignments prefixed to a command are temporary
in bash, so they are gone by the time an alias runs, and because the file's `:=` defaults did see
them they don't fall back to the placeholder either. The variable simply ends up unset, and ssh then
reports `Could not resolve hostname : Name or service not known`, which looks like a DNS fault. The
aliases now catch this themselves and print the fix.

**Tab completion.** Sourcing the file also registers bash completion: subcommands and flags for `cbx`,
and **live box names** for `cbx review|merge|drop|fix|rebase|kill|recreate|…`, `cbxbox`, `cbxfe` and
`cbxtun` (which completes `hub:` / `<box>:` and leaves the cursor on the colon for the port). Service
names complete for `cbx up|down|logs`.

Names live on the server, so they are fetched once over ssh and cached for **`CBX_COMPLETE_TTL`**
seconds (default 60). **Tab never waits on the network once that cache exists**: past the TTL the
cached list still answers immediately and the refetch is detached into the background for the *next*
Tab. Only the very first completion in a terminal — with nothing to answer from — goes over the wire
synchronously. Run **`cbxrefresh`** after spawning or killing a box when you want the new name now
rather than one Tab later. Concurrent refreshes are collapsed by a lock (held at most 120s, so a
shell killed mid-fetch can't wedge completion permanently). The box list comes from the broker (via `cbx ls`) plus
`refs/agents/*`, so a box that is no longer running but still has a handoff waiting still completes
for `cbx review`. A server that is down or wants a password never hangs your Tab: the fetch is
`BatchMode` with a 5s timeout, and on failure the previous cache stands.

On the one cold-start Tab that does go over the wire, the terminal's own **progress indicator** turns on
for the duration (OSC `9;4`, indeterminate — Ghostty, WezTerm, Windows Terminal, ConEmu; others ignore
it silently). It has to be the terminal's indicator rather than a printed message, because readline
owns the command line while a completion function runs and anything written into the display is
overwritten or leaves debris. `CBX_COMPLETE_PROGRESS=0` turns it off.

**Transport.** Long-lived interactive sessions — **`cbxhub`, `cbxbox`, and `cbx logs`** — default to
**ssh**. Set **`CBX_TRANSPORT=mosh`** (per call or globally) to opt into **mosh** for roaming: it
survives laptop sleep, Wi-Fi→LTE, and IP changes with no frozen-SSH hangs, and composes with the tmux
persistence those already give you. mosh needs **UDP 60000-61000** open to the server — provisioned by
`tasks/firewall.yml` (a UFW rule); on a hand-rolled host, open it yourself. It still uses ssh for the
initial handshake, so key auth is unchanged.

The reason ssh is the default: **mosh can't carry the clipboard.** Terminal copy from claude reaches
your laptop clipboard via an OSC 52 escape sequence, which ssh passes through transparently but mosh's
predictive terminal drops (a long-standing mosh gap). tmux forwards the sequence either way
(`set-clipboard external`), so on ssh a copy from claude lands in your laptop clipboard and on mosh it
vanishes. Use mosh when roaming matters more than copy-paste. Note
that an exported `CBX_TRANSPORT` in your `~/.bashrc` wins over the file default — `echo "$CBX_TRANSPORT"`
if a transport change seems ignored.

**One-shot commands** (`cbx --help`, `cbx ls`, `cbx q --text`, `cbx review …`) always use **ssh**,
regardless of `CBX_TRANSPORT` — their output prints to your terminal and stays in scrollback. mosh is
an alternate-screen app: it would render the output and then wipe it on exit, and it buys nothing for
a sub-second command. The long-lived ones — `cbxhub`, `cbxbox`, `cbx logs` and the bare `cbx q`
dashboard — honor `CBX_TRANSPORT`. **`cbxtun` is always ssh** too — mosh can't port-forward.

The hub container is resolved by its compose labels at call time (so it survives compose's `-1`
suffix and renames); the `$(…)` lookup runs on the server, and trailing args (`up backend`) are
appended to the remote `cbx` automatically. See the file's comments for the per-alias details
(root shell, terminfo for exotic terminals, etc.).

## Daily use

Start dev services on demand and manage boxes — all via the `cbx` alias:

```sh
cbx svcs              # list the dev services declared in hub-services/ + their state
cbx up backend        # start one (any service that has a hub-services/<name> manifest)
cbx up frontend
cbx up pinchtab
cbx logs backend      # attach that service's tmux window to watch logs (Ctrl-b d to detach)
cbx box work1         # spawn an agent box (mounts per the `mounts` table)
cbx ls                # services + boxes
```

### Dev-service manifests (`hub-services/`)

Which services the hub can run is **not baked into the image** — each is one file in the stack's
`hub-services/` directory (bind-mounted read-only into the hub), so adding, editing, or removing a
service is a file sync, never an image rebuild. The **filename is the service name**: `hub-services/backend`
defines `cbx up backend`. `cbx svcs` lists them with their running state and flags.

A manifest is `key=value`, one per line (`#` and blanks ignored):

```sh
# hub-services/backend
description=Spring backend (bootRun) + aspectj javaagent
writes_repo=true          # cbx golden snapshot refuses to run while this is up
autostart=false           # true → started at hub boot (cbx autostart, from the entrypoint)
command=gradle -x test build && gradle :app:bootRun -PbootRunExtraJvmArgs="-javaagent:$(find /home/dev/.gradle/caches /home/dev/.m2/repository -name 'aspectjweaver-*.jar' ... | sort -V | tail -1)"
```

| Field | Meaning |
|---|---|
| `command` | **Required.** The shell cbx runs, via `bash -lc` in a tmux window with cwd = the repo. Everything after the first `=` is **verbatim** — quotes, `&&`, and `$(…)` all reach the launch shell. |
| `workdir` | Optional cwd override (`$VAR` expands). Default is the repo root. |
| `writes_repo` | Optional. `true` → the service writes into the checkout, so `cbx golden snapshot` refuses while it's up (a mid-run snapshot would be torn). This replaced the old hard-coded backend/frontend guard. |
| `autostart` | Optional. `true` → started automatically when the hub boots. |
| `description` | Optional. Shown by `cbx svcs`. |

Two things make this work where the old `*_CMD` env vars did:

- **Substitutions resolve at launch, inside the container.** cbx never parses `command`; it hands it to
  `bash -lc` when you run `cbx up`. So the backend's `-javaagent:$(find … | sort -V | tail -1)` finds the
  aspectjweaver jar *after* the `&&`-chained `build` has pulled it into the cache — a path nobody knows at
  config time — and picks the highest version across the gradle and Jenkins (`~/.m2`) caches.
- **`$VAR` is safe here.** Unlike `service-env` (which compose interpolates against the *host* environment
  as root), a manifest is read only by cbx, so `$REPO`, `$HOME`, and `$(…)` mean what you'd expect. Service
  *settings* (ports, DB, keys) still belong in `service-env` — those are shared with the agent boxes; the
  command that starts a service is the hub's alone.

On the acoveo host these are Ansible-managed: edit `templates/docker-compose/claude-box/hub-services/<name>`
(add the file to the loop in `tasks/containers-claude-box.yml`), not the copy on the server.

### Viewing service logs

Each service (one per `hub-services/` manifest) runs in its own hub tmux window. `cbx logs`
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

**Inside that tmux** (config: `tmux.conf`, installed as `/etc/tmux.conf` by `common-setup.sh`, so it
applies to the hub too) the aim is that claude feels the same as running it locally:

| | |
|---|---|
| `Shift+Enter` | newline in claude's prompt — needs `extended-keys` + the `extkeys` terminal feature, both set |
| `Shift-PgUp` / `Shift-PgDn` | scrollback; PgUp enters copy mode, PgDn leaves it again at the bottom |
| wheel | scrollback too (that's what `mouse on` buys) |
| drag | tmux copy-mode selection → the **tmux paste buffer**, pasted with **middle-click** |
| `Shift`+drag, `Shift`+middle-click | **bypasses** tmux's mouse reporting → your terminal's own X PRIMARY selection and paste |
| `Ctrl-Shift-C` / `Ctrl-Shift-V` | your terminal's clipboard; never reaches tmux at all |

`mouse on` and native X selection are mutually exclusive — with mouse reporting active the terminal
never sees the drag or the middle click, which is why `Shift` (the standard bypass) is the escape
hatch rather than something configurable here. tmux is set to `set-clipboard external`, so a drag
selection stays local and does **not** overwrite your laptop clipboard; only a deliberate copy does.

What the hub and the boxes mount is **project set-up, not a runtime knob**: it lives in the stack's
root-owned `mounts` table (see *One mount table* below), edited on the host and applied by recreating:

```sh
$EDITOR mounts                                  # on the host, as root
./gen-hub-mounts.sh                             # -> compose.override.yml (the hub's side)
docker compose up -d hub && cbx recreate all    # mounts are fixed at container creation
```

## The review workflow

An agent starts on `agent/<box>`, based on the hub's `dev`. When it's done it runs `handoff
"summary"` in its own session, which pushes to `refs/agents/<box>` in the hub repo and attaches the
summary as a git note. Nothing else in the stack can write `dev`.

```sh
cbx q                       # LIVE dashboard: queue + status, and a BELL when something needs you
cbx q --text                # just the queue table, once, as plain text (pipes, scripts)
cbx review work1            # the review TUI: comment on lines, quit, confirm -> sent to the box
cbx review work1 --plain    # …the old pager instead (a diff vs dev, no commenting)
cbx fix    work1 -m "extract the dup mapper, add a test for the null branch"
cbx merge  work1            # merge into dev (--squash for a single commit) + tell the box to rebase
cbx push                    # dev -> origin
```

```
$ cbx q
cbx q — live  (refresh 5s · Enter now · q quits)   14:02:11

== branch ==
  dev @ a1b3f0c — 0 behind, 2 ahead of origin
== queue ==
  BOX          STATUS     AHEAD BEHIND LAST            SUMMARY
  work1        new            4      0 12 minutes ago  Invoice PDF export
  work3        re-review      2      1 40 minutes ago  Fix flaky OrderMapperTest
               ⚠ conflicts with work1: src/pdf/Renderer.java
== boxes ==
  work1        idle      Up 2 hours
  work3        busy      working for 94s
== golden ==
  g-20260726-101500 from a1b3f0c (dev) at 2026-07-26T10:15:00+02:00
== next ==
  cbx review work1
  cbx rebase work3           # 1 commit(s) behind dev
  cbx push                # 2 commit(s) to origin
== while you were watching ==
  14:01:58  work1 stopped working — now idle  (cbx q / cbxbox work1)
  14:02:06  work3 pushed again — re-review  (cbx review work3)
```

- **`cbx q` watches and rings.** It repaints `cbx status` with the queue folded in, and writes a
  terminal BEL when an agent **stops working** (`busy` → anything else — `waiting` means it is asking
  *you* something) or when a **handoff lands or moves** (`refs/agents/<box>` appeared or changed =
  a review request). The bell is a bare byte on stdout, so it rides the `docker exec -it` + `ssh -t`
  PTY to your laptop's terminal — nothing to install, works through the alias. Everything is polled
  from the hub's own files, so the interval is cheap; the origin fetch is throttled separately
  (`CBX_WATCH_FETCH`, 60s). `q` or Ctrl-C quits, Enter refreshes now, `-n SECS` sets the interval
  (`CBX_WATCH_INTERVAL`), `--no-bell` mutes it. Piped or redirected output is never watched — it
  prints the table once, exactly like `--text`.
- **`cbx review` opens a review TUI** — [tuicr](https://tuicr.dev), installed into the hub image by
  `common-setup.sh` — on the branch's work since it **forked** from `dev`
  (`$(git merge-base dev refs/agents/<box>)..refs/agents/<box>`, i.e. what `git diff dev...<box>`
  shows). The fork point rather than `dev` itself, because a TUI's `A..B` is a two-dot *diff*, not
  git's commit range: aimed at `dev..<box>` while the agent is behind, it renders everything `dev`
  gained since the fork as deleted by the agent — a one-commit branch came out as 309 changed files.
  Scroll the diff (`j`/`k`, `]` next hunk, `{`/`}`
  next file), press `c` on a line or `v`…`c` over a range to leave a comment, `C` for a file-level one,
  `?` for the full keymap. Quit with `q` and cbx reads the comments back out. See *The confirm step*
  below — nothing reaches the agent until you say so.
- **`cbx review` is incremental.** It records what you last saw, so after a `cbx fix` round it shows
  a `git range-diff` — only the new work, correct across the amends and rebases a fix round produces.
  `--full` gives the whole branch. That case stays on the **pager**: a range-diff is not a commit
  range, so no TUI can render it, and pointing one at `<last>..<new>` would silently show the whole
  branch again the moment the agent amended rather than appended. cbx says so and prints the
  `--tui` escape hatch. The pager also handles `--net` (one combined diff) and any non-terminal
  output, exactly as before.
- **`cbx fix` types into the agent's claude session** (via the broker, `tmux send-keys`). You never
  attach; the agent fixes and re-runs `handoff`, and the box shows up as `re-review` in `cbx q`.
  It is still there for a one-liner you didn't need the TUI for.
- **Conflicts surface at push time, not merge time.** Every push is test-merged against `dev` *and*
  against every other live agent branch (`git merge-tree`, no worktree touched), so you learn that
  two agents hit the same lines while you can still tell one of them to rebase.
- **`cbx prereview work1`** asks the agent to critique its own diff (`mydiff`) against `CLAUDE.md`
  before you spend a round on it. It is self-review, not an independent reviewer — an ephemeral
  reviewer box is the obvious next step, not built yet.
- `cbx drop work1` discards a branch and tells the box; `cbx rebase all` moves every agent onto the
  current `dev` without a recreate (cheap, use it after merging).
- **What an agent is told to do after a merge or rebase depends on its state**, and cbx decides it
  from `.cbx-state` rather than leaving the agent to infer it. A `busy` box is told to finish the task
  it was already on; anything else is told to rebase and then **stop and wait** — explicitly not to
  start, plan or look for other work. The earlier wording ("then continue with the next task") read to
  an idle agent as permission to find itself something to do, and one went off and did exactly that.

### The confirm step

Quitting the TUI does **not** send anything. cbx reads the comments you left out of tuicr's persisted
session, prints them as the markdown the agent would receive, and asks:

```
── feedback for work1 ───────────────────────────────
1. (overall) — Needs a test for the null branch.
2. `src/pdf/Renderer.java:42` [issue] — 42 is a magic number, name it.
3. `src/pdf/Renderer.java:50-55` — This block could be extracted.
──────────────────────────────────────────────────
[s]end to work1  [e]dit  [d]iscard ?
```

- **`s`** delivers it into the box's claude session (the same one-way channel `cbx fix` uses) with
  "Please address each point on your branch, then run: handoff" appended, and records the review.
  Refused while the agent is `busy`, like every other command that types at an agent.
- **`e`** opens the text in `$EDITOR` first — reword, delete a point, add one the TUI had no anchor
  for. What you save is what is sent.
- **`d`** does **nothing at all**: no feedback, and no review recorded — the queue looks exactly as it
  did before you ran `cbx review`, so the box stays `new`. The comments stay in tuicr, so re-running
  `cbx review <box>` picks the same review back up where you left it.

**Quitting the TUI decides nothing.** The prompt is the only place a review becomes real, which is
what makes "I opened it, read one hunk and backed out" indistinguishable from never having run
`cbx review` — otherwise the box quietly leaves the `new` queue and you lose the one signal that says
nobody has read this yet. Interrupting the TUI (Ctrl-C) is treated the same way: nothing sent,
nothing recorded, no fallback to the pager. If you left no comments at all, the prompt is just
`[m]ark <box> reviewed / [l]eave it unreviewed`. (`--plain` is unchanged — the pager has nothing to
confirm, so it still records on exit.)

Two details worth knowing:

- **Multi-line feedback arrives as ONE prompt.** `cbx fix` uses the broker's `/say`, which types the
  text with `tmux send-keys` — and claude submits its prompt on every newline, so an N-point review
  would land as N half-prompts, each acted on before the next arrived. A review therefore goes
  through `/paste` instead: `tmux load-buffer` + `paste-buffer -p`, i.e. a real **bracketed paste**,
  which claude takes into the composer whole; the Enter after it is the only thing that submits.
- **Sent comments are remembered, in `.git/cbx/<box>.sent`.** A tuicr session is keyed by the commit
  range, so reviewing the *same unchanged* branch twice hands back the comments you already sent —
  cbx filters those out and says "no new comments" instead of sending them again. It records the ids
  on its own side rather than deleting tuicr's session file, because tuicr keeps an `index.json`
  beside those files that would then point at nothing. (After a fix round the sha moves, so the next
  review is a fresh session anyway.) `cbx merge` / `cbx drop` clear the record with the branch.

**Choosing a different TUI, or none.** `CBX_REVIEW_TUI` overrides the command:

| Value | Effect |
|---|---|
| *unset* | `tuicr --no-update-check -r {range}` — the default, comments harvested and confirmed |
| empty or `-` | never a TUI; `cbx review` is the plain delta/less pager, as it was before |
| a command line | that command instead. `{range}` is substituted (appended if the placeholder is absent) |

Only **tuicr**'s comments can be harvested — anything else is treated as a viewer, and you follow it
with `cbx fix -m` as usual. The pager is also the automatic fallback when no TUI is installed, so a
hub built from an older image keeps working; `--tui` on such a hub is an error rather than a silent
downgrade.

To classify comments as issue / suggestion / note / praise (the `[issue]` tag above), give tuicr a
`~/.config/tuicr/config.toml` in the hub with `[[comment_types]]` entries — see
[tuicr's docs](https://tuicr.dev). Untyped comments work fine without it.

Inside a box the agent has three commands: `mydiff` (exactly what it will hand over, its branch
only), `handoff "summary"`, and ordinary git. It has no credentials for the real origin and the
hub's `update` hook rejects any push outside `refs/agents/*`.

### Editing an agent's work by hand

`cbx fix` sends the box *back to work*. Sometimes you'd rather take the wheel — pull the change onto
your laptop, fix it in your own editor, and either keep it there or push your version back as the
authoritative one. Two commands move a changeset over a **plain pipe** (patches, not git transport, so
neither side has to share the other's exact base sha):

```sh
# 1. bring an agent's work down as ONE squashed commit on a review branch
git switch -c review/work1 dev     # a branch OFF dev, not dev itself
cbxexport work1                    # its whole branch, squashed, applied here via `git am`
#    …edit, test, commit as much as you like…

# 2a. keep it local and land it the normal way (merge/push from your laptop), OR
# 2b. push YOUR version back as the agent's branch and tell the box to stand down:
cbximport work1                    # net change of HEAD vs your `dev`, squashed, replaces refs/agents/work1
cbx merge work1                    # …then land it on the hub's dev as usual (it's pre-marked reviewed)
```

- **`cbxexport <box>`** runs `cbx export` on the hub: it assembles the agent's whole branch
  (`dev..refs/agents/<box>`) into a single throwaway commit — carrying the handoff summary as its
  message — and streams it as an mbox. Your side pipes that straight into `git am`, so it lands as one
  commit on whatever branch you're on. Nothing on the hub is touched; re-running it is harmless. Use
  `--show` to eyeball the patch (or redirect it) instead of applying.
- **`cbximport <box> [base]`** is the mirror. It collapses everything on your `HEAD` since `base`
  (default your local **`dev`** branch) into one patch — *the end state*, so it doesn't matter how many
  commits you made or that you built on top of the agent's export — and pipes it to `cbx import`. The
  hub applies it in a throwaway worktree, **repoints `refs/agents/<box>` at your commit**, records it as
  already-reviewed (so `cbx status` offers `cbx merge` straight away), and messages the box:

  > I replaced the changes on your branch with my own commit. `git fetch hub && git reset --hard
  > hub-agents/<box>`. This is FYI only — just **note** that your earlier edits were superseded; do
  > **not** re-apply them or act on this.

  Run `cbximport` from **inside your local checkout, on the branch that holds your final version**.
  Because `base` defaults to `dev`, review on a branch *off* `dev` (as above) — if you `git am` the
  export straight onto `dev` itself, `dev..HEAD` is empty and there's nothing to send. Pass an explicit
  base (`cbximport work1 origin/dev`) when your change sits on top of something else.

Both use `docker exec -i` over ssh with **no PTY** — a pseudo-terminal would translate newlines and
corrupt the patch bytes — which is why they're separate aliases and not the PTY-based `cbx` wrapper.

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

## One mount table (`mounts`)

Everything the hub and the boxes mount — the checkout, the toolchain caches, any extra path — is one
root-owned table in the stack dir, one row per path with **a mode for each side**:

```
# <src>                              <dst>            <hub>  <box>
CHECKOUT                             repo             rw
./data/npm-cache                     .npm             rw     rw
./data/gradle-cache                  .gradle          rw     overlay
/var/jenkins_home/.m2/repository     .m2/repository   ro     ro
docs                                 reference        -      ro
```

`src` is `./x` (stack-relative), `/x` (an absolute host path), or bare `x` (relative to the golden
and confined to it — box-side only). `dst` is always relative to `/home/dev`, on both sides, which is
what keeps hub and box paths identical. Modes are `rw`, `ro`, `overlay` (box-side: `src` as a shared
read-only lower layer with a per-box upper on top — shared content, private writes, upper in
`data/boxes/<box>/ovl-<key>/`) and `-` (not mounted here). `CHECKOUT <dst> <rw|ro>` is the box's
working copy: an overlay of the current golden, or the golden itself read-only.

**Why one file for both sides.** The hub and the boxes must agree path-for-path (installed
dependencies bake absolute paths in), and while the two lists were maintained separately — the hub's
in `compose.yml`, the boxes' in `broker.py` — they drifted: both said "rw at `~/.gradle`", nobody
noticed the two are different *containers*, and the cross-container lock deadlock above followed.
Adding a per-project cache is now a config change, not an image rebuild.

Compose can't read the table, so the hub's column is rendered into `compose.override.yml`:

```sh
$EDITOR mounts                                  # on the host, as root
./gen-hub-mounts.sh                             # -> compose.override.yml
docker compose up -d hub && cbx recreate all    # mounts are fixed at container creation
```

Under Ansible both steps are part of `--tags containers-claude-box-files`. Forgetting either is not
silent: the hub compares its actual mounts against the table at boot and prints `MOUNT DRIFT` lines.

The stack's own plumbing (`data/repo`, the goldens, `data/boxes`, `hub-services`, `data/claude`,
pinchtab, `git-identity`) stays in `compose.yml` — that's the stack's definition, not this project's
environment.


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
- **One claude login for the whole stack:** the hub and every box run with
  `CLAUDE_CONFIG_DIR=/home/dev/.claude`, the single host dir `${STACK_DIR}/data/claude` that compose
  mounts into the hub and the broker mounts into each box. That env var matters because claude keeps
  the *credentials* in `~/.claude/.credentials.json` but the *account and preferences* in
  `~/.claude.json`, one level up — and each box has its own private home anchor. Sharing only
  `~/.claude` therefore shared the token but not the account, so every additional box (and every hub
  recreate) ran the login/onboarding flow again. Pointing `CLAUDE_CONFIG_DIR` at the shared dir puts
  the whole config there, so you log in once. Set on the hub in `compose.yml` (Ansible sync) and on
  boxes in `claude-box.sh`'s headless branch (image rebuild) — both paths must land, see *Deploying*.
- **Isolation:** a box sees its own overlay of the golden plus whatever the `mounts` table adds, has no
  docker socket, no credentials for the real origin, and can't see the hub's filesystem or another
  box's upper layer. Its only shared surface is the network (`hub:8080/4200/9867/9418`).
- **Broker policy:** the hub passes a box NAME — nothing else. Image, uid, network, privileges, the
  socket and the mount list are the broker's; the mounts come from the root-owned `mounts` table,
  which no container can write, and golden-relative sources in it are confined to the golden. It is
  the only socket holder. Its three box-facing operations (`/say`, `/paste`, `/dirty`) run **fixed**
  commands — there is no arbitrary-exec endpoint.
- **git daemon has no auth.** Boxes push over `git://` on the cbx network; the `update` hook in
  `data/repo` (installed by the hub entrypoint) is what bounds that: `refs/agents/*` and
  `refs/notes/cbx` only, so a box can never write `dev` or delete a branch.
- **Sealing a golden is a read-only mount, never file modes.** The hub mounts `data/golden` `ro` and
  prepares in `data/golden-staging`; the broker does the move. File modes cannot be used here:
  overlayfs checks write permission on the merged inode *before* deciding to copy up, so a
  non-writable golden makes every file unwritable inside the box instead of protecting anything.
- **`cbx kill` keeps the box's upper layer** on disk, so `cbx box <same name>` reattaches to its
  uncommitted work. Only `cbx golden snapshot` (and `cbx recreate --fresh`) discards it.
- **One mount table** (`mounts`) — see the section above. The bullet that matters here: `~/.gradle`
  is shared as an **overlay**, never rw. Gradle holds its cache locks for the *whole build* — and
  `bootRun` never finishes — handing them over only when the waiting process pings the holder on
  **localhost**. Between containers that ping cannot arrive, so a `~/.gradle` shared rw with the hub
  blocked every box's gradle *indefinitely* (`Owner PID: <a pid you can't see>`, waiting on
  `caches/journal-1`), and "wait and retry" never helped. Any toolchain cache with long-lived locks
  belongs in `overlay` mode; `~/.npm` is fine shared rw because npm's cacache is content-addressed
  and concurrency-safe.
- **Port forwards (pinchtab browser + own-backend dev loops):** the pinchtab server + Chrome run on
  the **hub**, but each agent runs its OWN dev services inside its box (`ng serve`, and optionally its
  own backend). pinchtab's IDPI allowlist has no wildcard and the browser is in a different netns, so
  the box name / box loopback don't work directly. Instead the **`port-forwards`** manifest (grammar
  `NAME BOX_PORT HUB_BASE_PORT`, like `mounts`) tells the broker to publish each box's services on
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
- **Service commands** are declared as **manifests in `hub-services/`** (one file per service, filename
  = service name), not as `*_CMD` env vars — see *Dev-service manifests* above. Each `command` runs
  through `bash -lc` in a tmux window with the cwd set to the repo, so values may use relative paths
  **and shell substitutions evaluated at launch inside the container** — that is how the backend command
  passes `-javaagent:$(find … aspectjweaver-*.jar …)` for a jar whose path only exists after the build
  (it uses two `gradle` calls so the substitution runs *after* the dependency is resolved). Because a
  manifest is read only by cbx, `$VAR`/`$REPO` are safe in it (unlike `service-env`). Each service runs
  in its own hub tmux window that stays alive after the process exits, so `cbx logs <svc>` can always
  attach to read the output; `writes_repo=true` guards `cbx golden snapshot`, and `autostart=true`
  brings a service up at hub boot.
- **Images** are built by the `Jenkinsfile` (box / hub / box-broker); the stack reuses them by
  default and only builds locally when `COMPOSE_PULL_POLICY=build`. Flip `PUSH_TO_REGISTRY` in the
  Jenkins job to also publish them for pulling on another host.
- The laptop `claude-box.sh` flow is unchanged — the server behavior is all env-gated
  (`CLAUDEBOX_HEADLESS` etc.), off by default.
