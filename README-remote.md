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

## One-time host prep (per server)

Docker + the two prebuilt images. No accounts, no toolchain install.

```sh
# postgres + sample DB
docker build -t infostars/dbtest  path/to/infostars/docker-postgre-test
# the box image (build.sh only needs the versions, not node installed)
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
drop an SSH key in `git-identity/` and use a `git@` `REPO_URL`. pinchtab needs its server bound to
`0.0.0.0` with `PT_TOKEN`: drop a `data/pinchtab/config.json` (copy your laptop's, set
`server.bind=0.0.0.0`, `server.port=9867`, `server.token=<PT_TOKEN>`).

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

**Protect the default branch** so the key can't push over it — GitHub deploy keys have no branch
scope of their own, so this is done with a **ruleset**: **Settings → Rules → Rulesets → New branch
ruleset**, enforcement *Active*, target the default branch, enable *Restrict updates* / *Restrict
deletions* / *Block force pushes* (optionally *Require a pull request before merging*). Add the
repo owner/admin to the **Bypass list** as the exception. Note: ruleset bypass actors require the
repo to belong to an **organization** — on a personal repo there's no per-actor exception, so
register the key read-only instead.

Then:

```sh
docker compose build          # hub + box-broker
docker compose up -d          # db, activemq, redis, box-broker, hub (clones the repo on first boot)
```

## Daily use

Everything is driven through `cbx` inside the hub:

```sh
H=myproject-hub
docker exec -it $H cbx up backend        # start dev services on demand
docker exec -it $H cbx up frontend
docker exec -it $H cbx up pinchtab
docker exec -it $H cbx box work1         # spawn an agent box (mounts per box-mounts)
docker exec -it $H cbx ls                # services + boxes
```

Attach / detach a box (from the host shell where your SSH tty lands):

```sh
ssh -t root@server docker exec -it box-myproject-work1 tmux attach -t main   # Ctrl-b d to detach
```

Curate what boxes see (per project, from the hub); recreate the box to apply:

```sh
docker exec -it $H cbx expose src src rw
docker exec -it $H cbx hide  package.json
docker exec -it $H cbx kill work1 && docker exec -it $H cbx box work1
```

Commit the agents' edits from the hub (it has `.git` + your identity; boxes don't):

```sh
docker exec -it $H bash -lc 'cd /work/checkout && git status && git add -A && git commit'
```

Watch the UI yourself: SSH-tunnel the hub's dev server, then open your laptop browser:

```sh
ssh -L 4200:$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' myproject-hub):4200 root@server
```

## Notes

- **Isolation:** a box mounts only what `box-mounts` grants (default: the tree `rw`, `.git`
  hidden), has no git identity and no docker socket, and can't see the hub's filesystem. Its only
  shared surface is the network (`hub:8080/4200/9867`).
- **Broker policy:** the hub passes a box name + the manifest; the broker fixes image/uid/network/
  privileges and confines every mount source under the checkout. It is the only socket holder.
- **Service commands** (`BACKEND_CMD`/`FRONTEND_CMD`/`PINCHTAB_CMD`) are env-overridable in `.env`
  if the defaults don't match your dev loop.
- The laptop `claude-box.sh` flow is unchanged — the server behavior is all env-gated
  (`CLAUDEBOX_HEADLESS` etc.), off by default.
