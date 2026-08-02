# muster

**Run several coding agents at once, each in its own container on one prepared checkout — the clone,
the `npm ci`, the warm caches exist once — and review their work as real git branches instead of a
diff soup.**

*to muster* — to assemble a force. *to pass muster* — to survive inspection. Both halves of the job.

muster is made for solo devs who don't need pull requests, and who would rather run on their own
infrastructure than drive their agentic dev loop through the GitHub web UI.

Each agent works in its own box: a copy-on-write overlay of one prepared checkout, on its own branch,
with a real `.git`. When it is done it pushes to the hub, and you review it the way you would review a
colleague's pull request — with a diff, line comments, and a merge you control. An agent's
divergence costs only what it actually changed, so ten agents are ten diffs on disk, not ten
checkouts — and none of them waits for a dependency install.

It runs on a machine you already have, driven entirely from your terminal. The surface each agent
works inside is a file you edit; the dev loop it runs is one command away from your browser; and
nothing about the codebase leaves your own infrastructure.

```
                      your laptop
                       │       ▲
                   ssh │       │ http, tunnelled: that box's dev server
                       ▼       │                 running in your browser
                      hub      │      the review desk: the repo, the CLI, dev services
                       │  spawns via the broker
                       ▼       │
                 box  box  box ┘      one agent each, /home/dev/repo = overlay(golden)
                  │    │    │         branch agent/<name>
                  └────┴────┴──push──▶  refs/agents/<name>  ──▶  you review  ──▶  merge into dev
```

## Why not just run agents in one checkout

Because they collide, and you cannot tell who did what. One working tree means one branch, so parallel
agents overwrite each other's edits and arrive as a single unattributable diff. Giving each a full
clone fixes the collisions and costs a full checkout plus a cold cache per agent. muster gives each a
*branch and an overlay*: isolation with the disk cost of the diff, and a review queue that tells you
which agent is waiting on you.

## Quick start

```sh
git clone https://github.com/fhackenberger/muster && cd muster
cp .env.example .env && $EDITOR .env        # REPO_URL, tokens, MUSTER_PREFIX

# No build toolchain? The published images are your images — nothing to build:
docker compose up -d

# Have one (JDK, gradle, whatever)? It is ten lines:
cp build-setup.sh.example build-setup.sh && $EDITOR build-setup.sh
docker compose --profile build build && docker compose up -d
```

Then, from your laptop:

```sh
source /path/to/muster/muster.bash_aliases
muster_stack cbx root@your.server myproject   # -> cbx, cbxhub, cbxbox, cbxtun, …

cbx box work1                                 # spawn an agent
cbx q                                         # live queue: who is working, who wants you
cbx review work1                              # read the diff, leave line comments
cbx merge work1                               # land it and tell the agent to rebase
```

The prefix is yours. Declare several and run several stacks from one shell — `cbx_stack lab
root@other labstack` gives you `lab`, `labhub`, `labbox`, each with its own server and completion.

## What you get

- **You draw the surface the agents see.** One table (`mounts`) describes what exists inside the hub
  and inside every box — the checkout, which caches are shared, which are private, what is read-only,
  what is not there at all. It is one file with a column per side, so the two cannot drift apart, and
  nothing is exposed because somebody forgot it was. Where the boundary sits is a decision you make
  per project, not one the tool makes for you.
- **It is a terminal, not a product.** Everything is `ssh` and shell functions: no web app, no
  account, no third party between you and your code. Which means it composes —
  `muster q --text | grep re-review`, a helper of your own beside the shipped ones, a different set
  per project, a cron job that spawns a box at 6am.
- **One stack per project, several at once.** A stack is per project — its own hub, its own prepared
  checkout, its own boxes and dev services — and your laptop drives as many as you like from a single
  shell: `muster_stack app root@one myapp` and `muster_stack lab root@two labstack` each generate
  their own command family, pointing at their own server, with their own completion cache. The images
  are shared, so a second project costs a compose stack rather than a second installation.
- **Watch the thing it built, not just the diff.** Every box runs its own dev loop, so one command
  tunnels that agent's dev server — and the backend its JavaScript actually calls — to your browser.
  You click through the feature on the branch that built it, before deciding whether it lands.
- **Your hardware, your idle time.** The heavy end runs on a machine you already own and already pay
  for. A build that crawls on a laptop finishes on the server that sits idle overnight, and ten agents
  cost ten diffs of disk rather than ten checkouts — so the turnaround improves at no marginal cost,
  and nothing about your codebase leaves your infrastructure.
- **A review queue, not a chat log.** `muster q` is a live dashboard: which agents are working, which
  have handed off, which conflict with `dev` or with each other, and the one command that moves each
  one forward.
- **Real review.** `muster review <box>` opens a TUI on the agent's branch; line comments go back to
  the agent as a prompt. A re-review shows only what changed since you last looked.
- **Merges you control.** `--squash` for one commit, `--reword` to rewrite every commit message
  without squashing, `minto` to merge `dev` *into* a long-lived branch — with conflicts resolved by
  you in a worktree, or handed to an agent that opens directly onto the conflict with both histories.
- **Isolation that is actually isolated.** Agents never hold credentials for your real origin. They
  push to the hub over `git://` on a private network, and a hook confines them to `refs/agents/*`.

## Documentation

| | |
|---|---|
| [`README-remote.md`](README-remote.md) | the full manual: architecture, deployment, the review workflow, goldens, the mounts table |
| [`docs/adr/`](docs/adr/) | decisions and why: [the overlay-and-branch model](docs/adr/0002-one-overlay-and-a-branch-per-agent.md), [what gets published](docs/adr/0001-image-builds.md) |
| [`tests/README.md`](tests/README.md) | the offline test suite, and how to add to it |
| [`SECURITY.md`](SECURITY.md) | the trust boundaries, and what an agent can and cannot reach |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | how to work on it |

## Requirements

A Linux host with docker and a few GB of disk. The laptop side needs `ssh`, `bash` and `git` (and
`mosh` if you want roaming sessions). muster drives [Claude
Code](https://claude.com/claude-code) inside each box; it is not affiliated with or endorsed by
Anthropic.

## Status

Used daily in production on a private stack since 2026. The interfaces that are documented here are
the ones considered stable; the internals still move.

## Licence

[Apache-2.0](LICENSE).
