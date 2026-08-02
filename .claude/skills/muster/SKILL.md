---
name: muster
description: Working on the muster agent stack — this repo (hub, box-broker, box images, cbx CLI, goldens, the mounts table, service-env, port-forwards). Use for any change to those files, or when debugging why a change "didn't take".
---

# muster

Agents run in per-project boxes; you review their branches from the hub. Full docs:
`README-remote.md` (read it before designing anything non-trivial).

## Model

- **hub** owns `/home/dev/repo` — the only clone with origin credentials, your setup workspace, and
  the git server (`git://hub/repo`) boxes push to. Runs `cbx`.
- **box** = overlayfs of a *golden* (frozen snapshot of the hub's repo) at **the same path**,
  `/home/dev/repo`, plus its own upper layer. Works on `agent/<box>`, pushes `refs/agents/<box>`.
- **box-broker** = only holder of the docker socket; spawns boxes via `muster-box.sh`.
- Review loop: `cbx status | q | review | fix | merge | push`; `cbx golden snapshot` refreshes the base.
- `cbx minto <branch>` is the OTHER direction (dev → staging/release). It never checks out the target
  on the hub: clean merges go through `merge-tree`/`commit-tree`, hand-resolved ones through a linked
  worktree in `.git/cbx/wt`. A conflict can spawn a box (`?base=&merge=` → `muster-box-init` sets the
  merge up before claude starts); `$STATE/<box>.mergeinto` is what makes the queue measure that box
  against the target instead of dev — and makes `cbx merge` refuse it.

## Tests

`tests/run-tests.sh` — offline (stub broker + scratch repo), covers cbx,
muster-box-init and broker.py. **Run it after any change to those three**; it also runs in Jenkins before
the images build. `./tests/run-tests.sh <substring>` filters; `tests/README.md` explains the helpers.

## Deployment: two independent paths

This is the #1 source of "I deployed it and nothing changed".

| Changed | Reaches the server via |
|---|---|
| `hub/*`, `Dockerfile*`, `common-setup.sh`, `box-bin/*`, `broker.py`, **`muster-box.sh`** | the image build pipeline |
| `compose.yml`, `compose.project.yml`, `service-env`, `mounts`, `port-forwards`, `.env`, `git-identity/*` | Ansible sync (`ansible/roles/claude_box` + the consuming repo's task file and templates) |

`muster-box.sh` lives in the **broker** image, not the box. Bases build before add-ons
(`muster` → `muster-<project>`; `muster-hub-base` → `muster-hub`).

Apply: `docker compose up -d --pull always hub box-broker` then `cbx recreate all`.
**Recreate, never restart** — env and mounts are fixed at container creation.

## Rules that bite

- **Same absolute path on hub and box** (`/home/dev/repo`). Installed deps bake absolute paths in;
  never prepare a tree at one path and mount it at another.
- **`service-env`** configures hub (compose `env_file`) *and* boxes (broker `-e`). **Never use
  `$VAR`** — compose interpolates it against the *host* as root, the broker doesn't, so the two
  diverge silently. `$(…)` is safe and expands at launch inside the container.
- **Goldens are immutable** while boxes are on them; the hub mounts them `ro` and the broker does the
  seal. Never enforce that with file modes — overlayfs checks write permission *before* copy-up, so a
  read-only golden makes every file unwritable in the box.
- **`mounts` is the ONE mount table** — hub *and* box, one row per path (`<src> <dst> <hub> <box>`,
  modes `rw|ro|overlay|-`; `CHECKOUT <dst> <rw|ro>` is the box's golden overlay). Root-owned, no
  runtime edits. The broker reads the box column; `gen-hub-mounts.sh` renders the hub column into
  `compose.override.yml` — **run it after editing `mounts`**, then recreate. The hub prints
  `MOUNT DRIFT` at boot if its own mounts disagree with the table.
- **Never share a gradle home rw across containers.** Gradle holds its cache locks for the whole
  build (`bootRun` = forever) and only hands them over when the waiter pings the holder on
  *localhost* — impossible between containers, so it wedges forever. Hence `overlay` mode: shared
  lower layer, per-box upper (`data/boxes/<n>/ovl-<key>/`). Same for any lock-taking toolchain cache.
- **Agent commands are async prompts** typed into a tmux session (`fix`, `rebase`, `prereview`), not
  RPC. Nothing has happened when the command returns.
- **`hub/cbx` runs `set -euo pipefail`.** A failing command inside `$( )` (e.g. `git notes show` with
  no note) kills the whole command silently. End such helpers with `|| true`.
- Ports in `port-forwards` (`BOX_PORT`) must match what `service-env` makes the services bind.

## Verify what actually landed

```sh
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' <project>-box-broker-1 | grep X  # from the sync
docker exec <project>-box-broker-1 grep -c X /usr/local/bin/broker.py                          # from the image
```

Env missing → file sync didn't run. Code missing → Jenkins didn't rebuild. They fail differently.
