# 2. One overlay and one branch per agent

**Status:** accepted · **Date:** 2026-08-02

## Context

The problem muster exists for: **run several coding agents on one codebase at the same time, and still
be able to review what each of them did.**

Those are two requirements, and the second is the harder one. Agents are not deterministic and not
always right, so their output has to arrive in a form you can read, attribute, reject and merge —
which is to say, as branches. Anything that merges their work before you see it has failed at the
part that matters.

The constraints that shape the answer:

- A prepared checkout is **expensive**: clone, `npm ci`, a warm gradle cache. Minutes, and often
  gigabytes.
- Installed dependencies **bake absolute paths in** — npm writes them into `node_modules/.bin`
  shebangs and `.package-lock.json`, gradle into a project-local cache, python into a venv. A tree
  prepared at one path and used at another is subtly broken.
- Agents run unattended, so isolation is a safety property, not a convenience.

## Decision

**Each agent gets a container whose `/home/dev/repo` is a copy-on-write overlay of one frozen,
prepared checkout — with a real `.git` — working on `agent/<box>` and pushing to `refs/agents/<box>`
on the hub.**

Four parts, each load-bearing:

1. **One prepared tree, shared read-only.** A *golden* is a snapshot of the hub's checkout with
   dependencies installed. Every box mounts it as an overlayfs `lowerdir` and writes into its own
   `upperdir`, so N agents cost N × (their own diff), not N × (a full checkout).

2. **The same absolute path everywhere.** The golden is snapshotted from `/home/dev/repo` on the hub
   and mounted back at `/home/dev/repo` in every box. This is not tidiness — it is the only reason the
   baked-in paths above stay valid. Preparing at one path and mounting at another is the single
   easiest way to break this design.

3. **A real `.git` per box, not patches.** The overlay carries the repository, so an agent commits,
   amends and rebases normally, and `handoff` pushes its branch to the hub. You then review a branch:
   `git log`, a diff, a range-diff after a fix round, line comments, `git merge`. A patch-shuttling
   design would have thrown all of that away.

4. **The hub is the only credentialed clone.** Boxes reach it over `git://` on a private network with
   no authentication at all; an `update` hook confines them to `refs/agents/*`. So an agent can publish
   work and can never touch `dev`, delete a ref, or reach your real origin.

**Goldens are versioned and immutable.** overlayfs requires the lower layer not to change underneath a
live mount, and the hub's checkout changes constantly. So a golden is frozen as `golden/g-<id>`,
`current` points at the newest, and boxes move onto a new one by being recreated. Enforcing that
immutability with *file modes* is the trap: overlayfs checks write permission **before** copy-up, so a
read-only golden makes every file unwritable inside the box. It is enforced by convention and by the
broker performing the seal instead.

## Consequences

- **A refresh cycle exists.** `muster golden snapshot` re-freezes the hub's tree and recreates every
  box onto it. Boxes must have pushed first — recreating discards upper layers — so the command
  refuses while any box has uncommitted work.
- **What a box sees is one table.** Hub and boxes must agree path-for-path, so `mounts` describes both
  sides in one file with a mode per side. Maintaining two lists is how a shared `~/.gradle` once
  deadlocked every box against a long-running build (gradle hands over cache locks only via
  localhost, which cannot work across containers — hence `overlay` mode for lock-taking caches).
- **Review is a queue, not a notification.** Because work arrives as refs, the hub can compute
  something useful: who is new, who was only rebased, who re-pushed after a fix round, and which
  branches conflict with `dev` or with each other — before you merge either of them.
- **Disk grows with divergence, not with agents.** Ten idle boxes are nearly free; one that ran a full
  build is not.
- **An agent is root inside its own box.** Isolation is at the container edge. See `SECURITY.md`.

## Alternatives considered

**One shared checkout, agents coordinate.** The obvious approach, and it fails at the review
requirement: one working tree is one branch, so concurrent edits overwrite each other and the result
is a single unattributable diff. You cannot reject one agent's work without unpicking it from another's.

**A full clone per agent.** Correct, and what most people reach for. It costs a full checkout plus a
cold dependency cache per agent — minutes and gigabytes each — which caps you at two or three agents
on ordinary hardware. That cap is the thing muster removes.

**`git worktree` per agent.** Cheap and branch-per-agent, but they share one `.git`: concurrent
index/ref operations contend, and a `gc` or a rewrite in one affects all. More importantly they share
one filesystem and one machine, so there is no isolation for an unattended agent that can run
arbitrary commands.

**Docker volumes seeded by copying the tree.** Isolated, but back to paying for a full copy per agent,
and with no cheap way to refresh them all onto a newer base.

**A VM per agent.** Stronger isolation than a container, at a cost per agent that makes running ten of
them pointless. If your threat model needs it, muster is the wrong tool.
