# Remote muster — per-project compose stack on a shared root server

Run muster on a server you SSH into as **root, with no host user accounts**. Each project is
one `docker-compose` stack (bind mounts, like your other stacks). A **hub** container owns the git
repo + identity and runs the dev services (backend, `ng serve`, pinchtab + Chrome) on demand;
**agent boxes** are separate `muster` containers spawned by a socket-holding **box-broker**.
You detach/reattach to boxes with tmux over SSH. A second project is just a second copy of the
stack, fully isolated.

Each agent works **on its own branch** in a copy-on-write overlay of one shared, prepared checkout,
and pushes to the hub for review. So the expensive part (clone, `npm ci`, warm caches) exists once,
while each agent's divergence costs only what it actually changed — and you review real git
branches instead of a diff soup from N agents sharing one working tree.

```
compose stack (cbx-<project> network)
  db (dbtest) · activemq (artemis) · redis · box-broker[socket] · hub[services + git repo]
                                                    │ runs muster-box.sh
                                                    ▼
                                       box-<project>-<name>  (claude, uid 1000, no socket)
                                         /home/dev/repo = overlay(golden) + own upper layer
                                         branch agent/<name> ──push──▶ hub refs/agents/<name>

  data/golden/g-<id>/     prepared tree (deps installed) — shared read-only by every box
  data/boxes/<name>/upper/  that box's changes — the only per-agent disk cost
  data/repo/              the hub's repo AND your setup workspace, mounted at /home/dev/repo —
                          the same path the boxes use, so baked-in absolute paths stay valid
```

> **Deploying with a config-management tool?** `ansible/roles/claude_box` in this repository does
> everything below for you: the directory layout and its uid-1000 ownership, the rsync of this tree,
> `gen-hub-mounts.sh`, the `.env` symlink and the GitHub deploy key. It takes the project-specific
> files (the env, `mounts`, `service-env`, `hub-services/`, the pinchtab config) as a variable, so the
> generic half stays generic. The manual steps here document the model, and are what you follow for a
> hand-rolled stack.

## One-time host prep (per server)

Docker + the sample-DB image. The **box / hub / box-broker images are built by the `Jenkinsfile`**
(as `muster`, `muster-hub-base`, `muster-hub`, `muster-broker`, moving tag
`master→stable`, `build/test→latest`, else `dev`) — Jenkins and the muster host are the same
machine, so the stack reuses those local tags directly (no registry round-trip). No accounts, no
toolchain install.

Both the box and the hub are a lean **base** on `debian:trixie-slim` + a project **add-on**:
`muster-hub-base` (`hub/Dockerfile.base`) carries the project-agnostic hub tooling (git/ssh, tmux,
node, pinchtab + Google Chrome, the tuicr review TUI, cbx, entrypoint, and the uid-1000 `dev` user), and `muster-hub`
layers the myapp build toolchain (JDK + gradle + ant) via the **shared `Dockerfile.addon`**
(`--build-arg BASE_IMAGE=muster-hub-base --build-arg FINAL_USER=1000`). The box mirrors this:
`muster` (base) + `muster-myapp` (same `Dockerfile.addon`, `BASE_IMAGE=muster`) — the
latter is what the broker spawns. The toolchain lives once in a **setup script of your own**, named by
`--build-arg SETUP_SCRIPT=<path in the build context>`, defaulting to `build-setup.sh` — your own
file, made from the shipped `build-setup.sh.example`; the add-on Dockerfile is written once. Jenkins builds each base
**before** its add-on.

```sh
# postgres + sample DB
docker build -t myapp/dbtest  path/to/myapp/docker-postgre-test
```

Trigger the **muster images** Jenkins job to build them (or, to build the box image by hand
without Jenkins):

```sh
NODE_VERSION=v26.2.0 NPM_VERSION=11.13.0 PINCHTAB_VERSION=0.13.2 \
  path/to/myapp/docker-claude/build.sh
```

## Per-project stack

```sh
mkdir -p /srv/cbx/myproject && cd /srv/cbx/myproject
cp -r path/to/muster/{compose.yml,box-broker,hub} .
cp path/to/muster/.env.example      .env
cp path/to/myapp/docker-claude/mounts.example     mounts
./gen-hub-mounts.sh                                    # renders the hub's volumes -> compose.override.yml
cp path/to/muster/service-env.example      service-env   # REQUIRED: compose env_file
cp path/to/muster/compose.project.yml.example compose.project.yml  # YOUR db/cache/queue, if any
cp path/to/myapp/docker-claude/port-forwards.example port-forwards
cp -r path/to/myapp/docker-claude/hub-services.example hub-services  # YOUR dev services
                                                                     # (pinchtab is built in)
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
Jenkins-built `muster-hub` / `muster-broker` images; `=build` rebuilds them locally from
this dir; `=always` pulls (point `HUB_IMAGE` / `BOX_BROKER_IMAGE` / `BOX_IMAGE` at registry-qualified
names for a different host).

**pinchtab** ([pinchtab/pinchtab](https://github.com/pinchtab/pinchtab)) — the headless-Chrome bridge
agents use to look at what they built — needs **nothing**. The hub seeds `data/pinchtab/config.json`
from the image on first boot and fills in a token: `PT_TOKEN` from `.env` when you set one, otherwise
a generated one, which the broker reads back out of that same file for the boxes. So both sides agree
without a secret for anyone to invent, and `autostart=true` in the shipped manifest means the server
is up before an agent reaches for it.

A config that is already there is never overwritten, and neither is a token that is already real — so
dropping in your own is still the way to change anything. The shipped one is bound to `0.0.0.0:9867`
so boxes on the stack network can reach it, points at the Chrome the hub image installs, and carries
an IDPI allowlist of `localhost`/`127.0.0.1` only. That allowlist has no wildcard, which is precisely
why each box's dev server is published on the **hub's** loopback rather than reached by container
name: the browser is on the hub, so that is the address it can resolve.

Under Ansible the file is templated from
`templates/docker-compose/claude-box/data/pinchtab/config.json` instead, which exists purely to
substitute the vault token.

The **service manifest is built into the image** (`hub/services/pinchtab`), so pinchtab exists on a
stack whose `hub-services/` holds only your own services — it is part of the setup, not an example
someone has to notice and copy. Override it by putting a file called `pinchtab` in the stack's
`hub-services/`: the stack's copy wins by filename, which is also how you turn it off.

muster also installs **pinchtab's own Claude skill** into the shared `~/.claude/skills` at hub boot,
fetched from upstream at image-build time — so an agent uses the CLI's session/snapshot workflow
instead of reconstructing it from `--help`.

### GitHub deploy key (SSH)

When this stack is deployed via Ansible (the `claude_box` role,
tag `containers-claude-box-deploy-key`), an ed25519 keypair is generated **on the remote** in
`git-identity/` (never committed to git) and mounted into the hub as `~/.gitidentity`. The play
prints the public key and step-by-step registration instructions during the run. To do it by hand
instead:

```sh
ssh-keygen -t ed25519 -N '' -C "muster-deploy-key@$(hostname)" -f git-identity/id_ed25519
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

### The stack is two compose files

`compose.yml` is **muster itself** — the hub and the box-broker, identical for every project.
Anything your project needs beside them (a database, a message queue, a cache, seed data) goes in
**`compose.project.yml`** (copy `compose.project.yml.example`), merged via `COMPOSE_FILE` in `.env`:

```sh
COMPOSE_FILE=compose.yml:compose.project.yml:compose.override.yml
```

**Note the third entry.** Setting `COMPOSE_FILE` at all *disables* compose's automatic loading of
`compose.override.yml` — the file `gen-hub-mounts.sh` renders the hub's half of the `mounts` table
into. Leave it out and the hub starts with no `~/.npm`, `~/.gradle` or `~/.m2` at all, and the only
symptom is a `MOUNT DRIFT` line in its boot log.

Then:

```sh
docker compose up -d          # box-broker + hub (clones the repo on first boot), plus whatever
                              # compose.project.yml adds. Reuses the locally built images by
                              # default (see escape hatch below)
```

### Escape hatch: build the images locally

By default (`COMPOSE_PULL_POLICY=missing`) the stack **reuses the Jenkins-built** `muster-hub`
and `muster-broker` images and never rebuilds them. If you'd rather build from this directory —
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

The hub build layers `Dockerfile.addon` onto `muster-hub-base`. Compose pulls that base from the
registry by default, so the above just works when `docker login` has run. To build **fully offline**
(or after editing `hub/Dockerfile.base`), build the base first and point the hub at the local tag:

```sh
docker build -t muster-hub-base:local -f hub/Dockerfile.base .   # context = the muster dir
HUB_BASE_IMAGE=muster-hub-base:local docker compose build hub
```

The **box image** the broker spawns is separate: set `BOX_IMAGE` in `.env` (default
`muster:stable`), or build it locally with `build.sh` (see host prep). To go the other way and
pull from the registry on a *different* host, set `COMPOSE_PULL_POLICY=always` and point
`HUB_IMAGE` / `BOX_BROKER_IMAGE` / `BOX_IMAGE` at registry-qualified names.

## Updating a running stack

Changes reach the server by **two independent paths**, and nearly every "I deployed it but nothing
changed" comes from doing one and not the other:

| What you changed | Travels via | Carried by |
|---|---|---|
| `hub/muster`, `hub/entrypoint.sh`, `hub/git-ssh`, `hub/Dockerfile.base` | Jenkins build | `muster-hub-base` → `muster-hub` |
| `Dockerfile`, `box-bin/*` | Jenkins build | `muster` → `muster-myapp` |
| `common-setup.sh` (shared toolchain: node, pinchtab, **tuicr**) | Jenkins build | **both** bases — box *and* hub |
| `box-broker/broker.py`, **`muster-box.sh`** | Jenkins build | `muster-broker` |
| `compose.yml`, `compose.project.yml`, `.env`, `service-env`, `mounts`, `port-forwards`, `hub-services/*`, `git-identity/*` | file sync (Ansible / rsync) | — |

A change to `mounts` needs one extra step on the host, `./gen-hub-mounts.sh`, which renders the hub's
half of the table into `compose.override.yml` (Ansible does it as part of the files tag).

Two traps in that table. **`muster-box.sh` is `COPY`d into the *broker* image**, not the box image —
a change there needs a broker rebuild. And **each add-on image must be rebuilt after its base**
(`muster` before `muster-myapp`); rebuilding only the add-on silently keeps the old base.
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
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' myapp-box-broker-1 | grep -E 'MOUNTS_FILE|SERVICE_ENV_FILE'
docker exec myapp-box-broker-1 grep -c SERVICE_ENV_FILE /usr/local/bin/broker.py   # code, not env
docker exec -u dev box-myapp-<name> printenv DB_MYAPP_PSQL_URL
docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' box-myapp-<name>
docker logs myapp-hub 2>&1 | grep 'MOUNT DRIFT'     # hub's own mounts vs the `mounts` table
```

The first two are the useful pair: env comes from the **file sync**, the code from the **image**, and
they fail in different ways.

## Laptop aliases

Everything is driven through `cbx` inside the hub. Rather than typing the full
`<transport> … docker exec …` each time, the helpers live in **`muster.bash_aliases`** (next to this
README) — source it from your `~/.bashrc`, setting the server and the stack's `PROJECT_NAME` first
(export them before sourcing, or edit the defaults in the file). Project-specific helpers (`cbxpsql`,
`cbxfe` — they know your db and your dev ports) are a **separate** file: copy
`muster.bash_aliases.project.example`, edit it, and source it *after* the generic one:

```sh
# in ~/.bashrc
export MUSTER_SERVER=root@cbx.example.com   # the muster host
export MUSTER_PROJECT=myapp                 # PROJECT_NAME of the stack
source /path/to/muster/muster.bash_aliases
source /path/to/muster/muster.bash_aliases.project   # optional: cbxpsql / cbxfe / your own
```

That gives you:

- **`cbx …`** — run any cbx subcommand on the remote hub (`cbx up backend`, `cbx ls`, `cbx box work1`).
- **`cbxhub`** — a persistent tmux shell in the hub you can detach (Ctrl-b d) / reconnect to.
- **`cbxbox <name>`** — attach an agent box's `main` tmux session (Ctrl-b d to detach).
- **`cbx purge <box>`** — remove a box for good: container, upper layer, warm caches, session id. `kill`
  keeps all of that so `cbx box <same name>` can reattach; `cbx ls` now lists what has accumulated
  (with its size on disk) under **retired**. Purge refuses while the box's handoff is still unreviewed
  — `--force` overrides, and `cbx drop` is the deliberate way to bin the work first.
- **`cbx golden retire <id>`** — free a golden that boxes are still overlaid on. `reap` skips those on
  purpose (a golden is the lowerdir of every box on it), so the question is what happens to its boxes,
  and it asks: **[m]ove** them onto the current golden — `recreate` respawns a box on whatever golden
  is current, keeping its own upper layer, so a box really can be ported — or **[p]urge** them. Then
  it reaps. The current golden is never retirable; take a snapshot first.
- **`cbx box [name]`** — spawn an agent **and attach to it**, which was always the next thing you
  typed. `--no-attach` (or `MUSTER_BOX_ATTACH=0`) spawns and returns; so does a non-terminal stdout,
  since `cbx box x | cat` waiting for a tmux session is a hang rather than a feature. With no name the
  hub invents one and the alias reads it back out of the spawn message to know what to attach to.
- **`cbxpsql <dbname>`** — open a psql shell on the stack's `db` (e.g. `cbxpsql myapp_dev`).
- **`cbxtun [spec…]`** — SSH-tunnel hub and/or agent-box dev ports to your laptop (default `hub:4211`).
- **`cbxfe <box>` / `cbxfe <box> --own`** — project shorthand: open **one agent's** frontend at
  `http://localhost:4211`, with **both** candidate backends tunnelled alongside it — the hub's
  (`:8091`, the default) *and* that box's own (`:<8900+slot>`, what `$FRONTEND_DEV_BACKEND_URL_OWN`
  points at). Several forwards, because `FRONTEND_DEV_BACKEND_URL` is resolved by **your browser**,
  not by the box, and the agent may have switched it to its own backend at any point. Tunnelling both
  means you never have to know which: a missed one shows up only as failing API calls
  (`ERR_CONNECTION_REFUSED` on e.g. `http://localhost:8904/myappWeb/rest/config`) on a page that
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
  cbxexec work1 gradle -q :myappEJB:test | tee test.log
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

**Tab completion, on both sides.** On the laptop the alias family completes subcommands, flags, box
names, service names and branches from a cache it refreshes in the background over ssh. The
subcommands and flags are parsed from the **deployed hub's own `muster --help`**, not from a list in
the alias file: the two are deployed by different paths and drift apart for weeks, and a completion
that has never heard of `minto` reads as "that command does not exist". Flags complete at any
position — `merge --squash <box>` and `merge <box> --squash` are both valid, so both complete. Inside the hub — through `cbxhub`
or a plain `docker exec -it <hub> bash` — the same completion is available for `muster` *and* for your
prefix, from `/usr/share/bash-completion/completions/muster` in the hub image. That one reads the
filesystem only (the service manifests, `/work/boxes`, `refs/agents/*`), never the broker, so a Tab
press cannot block on a timeout.

**The prefix is a name, not a dependency.** `MUSTER_PREFIX` makes the hub symlink `muster` to your
word for it, so the command is spelled the same from either side. But the laptop aliases do not
*call* that symlink: they run `muster` — which is in every image — and pass the name you typed as
`MUSTER_SELF`, which is what the CLI prints in its hints. So `cbx merge work1` works on a hub whose
`.env` predates the variable, and the day the symlink is missing you get the usual output, not
`"cbx": executable file not found in $PATH`.

**Export the two variables as their own commands.** Prefixing them to the `source` — `MUSTER_SERVER=…
MUSTER_PROJECT=… . muster.bash_aliases` — does *not* work: assignments prefixed to a command are temporary
in bash, so they are gone by the time an alias runs, and because the file's `:=` defaults did see
them they don't fall back to the placeholder either. The variable simply ends up unset, and ssh then
reports `Could not resolve hostname : Name or service not known`, which looks like a DNS fault. The
aliases now catch this themselves and print the fix.

**Tab completion.** Sourcing the file also registers bash completion: subcommands and flags for `cbx`,
and **live box names** for `cbx review|merge|drop|fix|rebase|kill|recreate|…`, `cbxbox`, `cbxfe` and
`cbxtun` (which completes `hub:` / `<box>:` and leaves the cursor on the colon for the port). Service
names complete for `cbx up|down|logs`.

Names live on the server, so they are fetched once over ssh and cached for **`MUSTER_COMPLETE_TTL`**
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
overwritten or leaves debris. `MUSTER_COMPLETE_PROGRESS=0` turns it off.

**Transport.** Long-lived interactive sessions — **`cbxhub`, `cbxbox`, and `cbx logs`** — default to
**ssh**. Set **`MUSTER_TRANSPORT=mosh`** (per call or globally) to opt into **mosh** for roaming: it
survives laptop sleep, Wi-Fi→LTE, and IP changes with no frozen-SSH hangs, and composes with the tmux
persistence those already give you. mosh needs **UDP 60000-61000** open to the server — provisioned by
`tasks/firewall.yml` (a UFW rule); on a hand-rolled host, open it yourself. It still uses ssh for the
initial handshake, so key auth is unchanged.

The reason ssh is the default: **mosh can't carry the clipboard.** Terminal copy from claude reaches
your laptop clipboard via an OSC 52 escape sequence, which ssh passes through transparently but mosh's
predictive terminal drops (a long-standing mosh gap). tmux forwards the sequence either way
(`set-clipboard external`), so on ssh a copy from claude lands in your laptop clipboard and on mosh it
vanishes. Use mosh when roaming matters more than copy-paste. Note
that an exported `MUSTER_TRANSPORT` in your `~/.bashrc` wins over the file default — `echo "$MUSTER_TRANSPORT"`
if a transport change seems ignored.

**One-shot commands** (`cbx --help`, `cbx ls`, `cbx q --text`, `cbx review …`) always use **ssh**,
regardless of `MUSTER_TRANSPORT` — their output prints to your terminal and stays in scrollback. mosh is
an alternate-screen app: it would render the output and then wipe it on exit, and it buys nothing for
a sub-second command. The long-lived ones — `cbxhub`, `cbxbox`, `cbx logs` and the bare `cbx q`
dashboard — honor `MUSTER_TRANSPORT`. **`cbxtun` is always ssh** too — mosh can't port-forward.

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
cbx logs backend --tail 200   # …or just PRINT the output — what you want when it failed to start
cbx logs backend --file       # the path of the captured log, for grep/less/cbxcp
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

If you deploy with the bundled Ansible role, these are templated: edit them in your own repository
and let the deploy write them, rather than editing the copy on the server.

### Viewing service logs

Each service (one per `hub-services/` manifest) runs in its own hub tmux window. `cbx logs`
**attaches** that window — it's a live, streaming view, not a one-shot dump:

```sh
cbx logs backend      # attach the backend window and watch it live
```

- **Detach with `Ctrl-b d`** — this leaves the service running. Do **not** press `Ctrl-c`; that
  would kill the process inside the window.
- The window is kept alive even after the process exits — it shows `[muster] <svc> exited (status N)`
  and the path of its captured output — so `cbx logs` still works after a service crashed on startup.
- **When it failed, `--tail` is the one you want.** Everything a service prints is copied to a file as
  it runs (`tmux pipe-pane`, which touches neither the process nor its tty, so gradle and `ng serve`
  keep their colours), at `.git/cbx/logs/<svc>.log` in the hub's repo:

  ```sh
  cbx logs backend --tail 200    # print it here, into YOUR scrollback
  cbx logs backend --file        # just the path — for grep, less, or cbxcp
  ```

  Attaching a pane is the wrong tool for a failure: with a tmux around your ssh the scroll keys go to
  the *outer* tmux, and the window is gone the moment you dismiss it. `--tail` prints into the
  terminal you are already in, and the file outlives the window.
- `cbx logs` needs a TTY to attach tmux; the `cbx` alias already provides one (`ssh -t` +
  `docker exec -it`), so it just works.

Attach / detach a box (a box is a separate container, not reached through the hub) — via the
`cbxbox` helper from the aliases above, or the raw command:

```sh
cbxbox work1                                                                                # Ctrl-b d to detach
ssh -t "$MUSTER_SERVER" docker exec -it -u dev "box-${MUSTER_PROJECT}-work1" tmux attach -t main   # equivalent, raw
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
cbx merge  work1            # merge into dev (--squash for one commit, --reword to fix the messages)
cbx push                    # dev -> origin
cbx minto  staging          # the other direction: dev -> a long-lived branch (see below)
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
  (`MUSTER_WATCH_FETCH`, 60s). `q` or Ctrl-C quits, Enter refreshes now, `-n SECS` sets the interval
  (`MUSTER_WATCH_INTERVAL`), `--no-bell` mutes it. Piped or redirected output is never watched — it
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
  It is still there for a one-liner you didn't need the TUI for. Every such message is aimed at the
  **pane claude runs in**, resolved from its window name — not at the session, which tmux delivers to
  whichever window is current. Open a second window in a box you attached to, and a session-targeted
  message lands in *that* shell instead: sent, never received, and no error on either side.
- **`cbx merge <box> --undo`** puts `dev` back and the branch back in the queue. It works because
  merge uses `--no-ff`: the agent's tip is the merge commit's *second parent*, so the handoff is still
  in the history (the deleted `refs/agents/<box>` reflog is not a way back — git drops a reflog with
  its ref). It refuses when the merge is no longer the tip, or when origin already has it, naming
  `git revert -m 1 <merge>` instead; and after a `--squash` there is no second parent, so it rewinds
  `dev` and tells you to re-`handoff` from the box, which still has the commits. The rewind is
  `git reset --keep`, so uncommitted work in the hub's checkout survives — or stops the undo, rather
  than being silently overwritten.
- **`cbx merge <box> --edit` seeds the editor with what the agent wrote**, never a blank buffer, and
  never git's `SQUASH_MSG` (which wraps every message in `Squashed commit of the following:` and
  indents it four spaces under a `commit`/`Author:`/`Date:` header — a log to read, not a message to
  edit). A **one-commit** branch opens that commit's own message, so you start typing straight away;
  this holds with or without `--squash`, and the agent stays the author. **Several commits** open all
  of them verbatim and unindented, separated by a `# ── 2/3 · <sha> ──` banner; git drops `#` lines on
  save, so leaving the buffer untouched gives you the messages one blank line apart and no banners.
- **`cbx merge <box> --reword` keeps every commit and rewrites only the messages.** `--squash --edit`
  gives you one commit you can word yourself, but a branch that is genuinely three changes should land
  as three. `--reword` opens a small loop over the commits instead:

  ```
  ── work1: 3 commit(s) to land on dev ─────────────────
     1. 51aeab2 wip
     2. dff7652 REWORDED: cache the widget lookup per request
     3. acb3eb6 fix thing
  ────────────────────────────────────────────────────
  (green = your wording)  [1-3] edit  [a]ll  [d]<n> diff  [r]<n> revert  [m]erge  [q]uit ?
  ```

  Edit them in any order, as many times as you like; `d<n>` pages that commit's diff when you need to
  remember what it did, `r<n>` puts the agent's wording back. **Nothing is rewritten until you press
  `m`** — and quitting doesn't lose your work: the messages are kept per commit sha under
  `.git/cbx/reword/<box>/`, so re-running `--reword` picks them up (they're keyed by sha, so if the
  agent pushes again in the meantime the stale ones are simply ignored). The rewrite is object-store
  only: every commit keeps its **tree** — what lands is byte-for-byte what you reviewed — and its
  original **author** and author date. Only the message and the parent chain change, so the patches
  are identical and the box's follow-up `git rebase hub/dev` skips them cleanly by patch-id.
  Refused on a branch containing a merge commit (replaying that as a linear chain would silently drop
  one side) — use `--squash --edit` there.
- **A branch whose work is already in `dev` shows up as `merged`.** `cbx q` lists it with `0` ahead and
  the one action that applies (`cbx merge <box>` — which does only bookkeeping), and `cbx review <box>`
  says so instead of paging an empty range-diff at you. Without that, a box left over from a
  hand-finished merge sits in the queue as `re-review` forever with no way out.
- **A conflicted `cbx merge` is finished by re-running it.** When the merge hits conflicts, cbx stops
  and leaves them in the hub's repo for you — which means it also never got to retire
  `refs/agents/<box>` or clear the review state. So after you resolve and commit, run **`cbx merge
  <box>` again**: it sees the branch is already contained in `dev`, skips straight to the bookkeeping
  (drop the ref, clear the state, tell the box to rebase, say whether origin still needs a push) and
  the queue finally lets go. Without that, `cbx q` keeps offering a merge that answers "nothing was
  merged" every time. If you resolved it as a **squash or a hand-written commit** the agent's commits
  are not ancestors of `dev` and nothing can prove it landed — say so with **`cbx merge <box>
  --landed`**. Re-running while conflicts are still unresolved is refused, with both ways out named.
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

**Choosing a different TUI, or none.** `MUSTER_REVIEW_TUI` overrides the command:

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

### Merging dev *into* another branch (`cbx minto`)

Everything above moves work **into** `dev`. `cbx minto <branch>` is the other direction — getting `dev`
out into a long-lived branch (a staging integration branch, a release line):

```sh
cbx minto staging          # fast-forward, or a merge; asks only if it conflicts
cbx push staging           # same preview + confirm as `cbx push`, for any branch
```

Two rules shape it, and they're worth knowing because they're what make it safe to run casually:

- **The hub's checkout never moves.** It stays on `dev`, dirty with your local setup work — that tree
  is what goldens are snapshotted from, so a `git checkout staging` here would change what every new
  box starts from. A clean merge is therefore computed **in the object store** (`git merge-tree` →
  `commit-tree` → `update-ref`); no index, no worktree, nothing to clean up if it fails.
- **`refs/heads/<target>` doesn't move until the merge is finished.** Every path either lands a
  finished commit or leaves the branch exactly as it was, so `--abort` is always free.

The target has to exist as a **local** branch (minto creates it from `origin/<branch>` if needed) and
must not be behind origin — `--pull` fast-forwards it first. A branch that's ahead of origin is fine.

**On conflict** it asks what the branch is *for* — remembered per branch, and used to decide the
resolution — then offers two ways out:

```
cbx: 3 conflicted file(s):
    src/a.kt src/b.kt build.gradle
cbx: what is staging FOR? (guides how conflicts get resolved)
  [integration branch for the staging server] > 
cbx: [b]ox — an agent resolves it  [h]ere — a worktree, you resolve it  [a]bort ?
```

**`[b]ox`** spawns an agent that opens **onto the conflicted tree**: the broker takes
`?base=<target>&merge=<dev>` and `muster-box-init` does the checkout and the merge in the box's tmux
window *before claude starts* — setup is never left to a prompt, which is advisory and asynchronous.
The agent gets both branches (`hub/<target>`, `hub/dev`), `merge.conflictstyle=zdiff3` so every hunk
shows the common **base** and not just the two sides, and a briefing built around `git log --merge`,
which lists the commits *from both sides* behind each conflicted file. It is told to flag a conflict
it can't resolve rather than guess, and that its golden came from `dev` so the tree may not compile
if `<target>` differs in build config.

```sh
cbx q                              # BOX  ... STATUS  SUMMARY: [minto -> staging] resolved 3 conflicts…
cbx review minto-staging           # the RESOLUTION alone — `git show --cc`, hunks matching neither side
cbx fix minto-staging -m '…'       # not convinced? send it back, same as any box
cbx minto staging --land minto-staging
cbx push staging
```

`--land` verifies before it moves anything: the target is still where it was, and the agent's commit
contains **both** `<target>` and `dev` (i.e. it really is that merge, not a rebase or a squash). Then
it fast-forwards the branch, keeps the handoff summary as a `cbx` note on the merge commit, drops the
agent ref and retires the box. **`cbx merge` refuses a minto box outright** — merging it into `dev`
would drag the whole target branch's history in, which is the one destructive mistake available here.

**`[h]ere`** gives you a **linked worktree** under `.git/cbx/wt/<branch>` instead. It lives inside
`.git` deliberately: that survives a hub container replacement (it's in the bind-mounted repo), and
`cbx golden snapshot` already strips `.git/cbx`, so a half-finished merge can never leak into a
golden. Committing there moves the branch (a linked worktree owns the branch it holds), so
`cbx minto staging --landed` only verifies and tears the worktree down. An unfinished one shows up in
`cbx status` — it has no box and no agent ref, so nothing else would remind you.

`cbx minto <branch> --abort` drops whichever of the two is open. The branch was never moved.

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

Watch the UI yourself: SSH-tunnel the dev ports with **`cbxtun`** (from `muster.bash_aliases`), then open
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

The old single-port `mustertun` is renamed to `cbxtun` (re-source `muster.bash_aliases`; it drops the stale
`mustertun` function on load).

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


## Tests

```sh
./tests/run-tests.sh              # everything (~40s), no docker and no network needed
./tests/run-tests.sh minto        # only tests whose name matches
```

`hub/muster`, `box-bin/muster-box-init` and the broker's pure helpers are covered by an offline suite: the
broker is replaced by a stub with the same HTTP contract (which records what cbx asked it to do), and
every git operation runs against a scratch repo with a bare "origin" beside it. It runs in the
Jenkins pipeline **before** any image is built — a broken `cbx` should never reach an image. See
[`tests/README.md`](tests/README.md) for how to add one.

## Notes

- **Agent activity:** each box's claude writes `busy` / `waiting` / `idle` to `$HOME/.cbx-state` via
  `muster-activity` hooks, which the broker registers in the stack's shared `~/.claude/settings.json`
  (merging — your other settings and hooks are preserved, and an unparseable file is left alone).
  That path is the box's home anchor, which the hub already mounts read-only, so `cbx ls` /
  `cbx status` read it directly. Commands that type into a session (`fix`, `prereview`, `rebase`)
  refuse while an agent is working; `--force` overrides. `waiting` is deliberately not guarded —
  claude is asking *you* something. A `busy` older than `MUSTER_ACTIVITY_STALE` (default 900s) reads as
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
  boxes in `muster-box.sh`'s headless branch (image rebuild) — both paths must land, see *Deploying*.
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
  `MUSTER_DEV_URL=http://localhost:$PORT_FORWARD_FRONTEND_TO_HUB` (pinchtab loads the frontend) and
  the frontend's backend URL `http://localhost:$PORT_FORWARD_BACKEND_TO_HUB` (so an agent's frontend
  hits its OWN backend). Everything is `localhost` from the hub browser — allowlisted by default, and
  `Host: localhost` passes ng serve's host-check. Concurrency is bounded by `PORT_FORWARD_SLOTS`
  (default 16); the broker refuses to spawn once slots are exhausted. The slot is stable per box
  (`data/boxes/<name>/slot`), reused across `cbx recreate`. (Project scripts must also bind those
  services to `0.0.0.0` in the box so the forwarder can reach them.)
- **The other direction — a box reaching the HUB's services:** by the hub's **name on the compose
  network**, never by `localhost`. Every URL in `service-env` is written for a *browser*
  (`http://localhost:8091/...` is the hub's backend as tunnelled to your laptop), and a
  `..._TO_HUB` port is a box's own service as published on the **hub's** loopback. In a box,
  `localhost` is the box: both connect to nothing, `curl` reports `000`, and an agent reasonably
  concludes the backend is down. Two things address that:
  - **`MUSTER_HUB_HOST`** — the hub's service name (from `HUB_GIT_URL`), in every box's environment.
  - **`box-env`** — the project's own per-box environment (see below), where `FRONTEND_DEV_BACKEND_URL`
    and friends are rewritten to point at `$MUSTER_HUB_HOST` for boxes only.
- **`box-env` — the project's per-box environment.** `service-env` is fed verbatim to the hub *and*
  every box, which is why it must never contain `$VAR`. `box-env` is the opposite: read only by the
  broker, expanded per box, applied **after** `service-env`, so a key repeated there is **overridden
  for boxes only**. That override is the whole point — the same URL is correct on the hub and wrong in
  a box. Substitutable: `$MUSTER_HUB_HOST`, `$MUSTER_BOX`, `$MUSTER_BRANCH`, `$MUSTER_DEV_BRANCH`,
  `$MUSTER_PROJECT`, `$MUSTER_WORKDIR`, `$MUSTER_GOLDEN`, `$MUSTER_SLOT`, every
  `$PORT_FORWARD_<NAME>_FROM`/`_TO_HUB`, and every key from `service-env`. Unknown `$name`s survive
  untouched (`safe_substitute`), so a token with a `$` in it cannot fail a spawn. See
  `box-env.example`. muster deliberately knows none of these variable names itself.
- **The box memo.** The broker keeps a fenced block in the shared `~/.claude/CLAUDE.md` — the one file
  claude loads as memory without being asked — describing that `localhost` is the box, how to reach
  the hub, the forward table, which keys `box-env` sets, and **how pinchtab works**: the browser runs
  on the *hub*, so the URL you hand it is resolved there and the `_TO_HUB` port is the right one —
  the same port that is useless to `curl` from inside the box. That pairing is the whole reason both
  columns exist, and an agent told only half of it concludes a service is down. It names the
  *variables*, never their values: that `.claude` is one directory shared by the hub and every box, so
  anything box-specific in it would be rewritten by whichever box spawned last. Everything outside the
  markers is left alone, and a stack with no pinchtab is not told about one.
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
- The laptop `muster-box.sh` flow is unchanged — the server behavior is all env-gated
  (`MUSTER_HEADLESS` etc.), off by default.
