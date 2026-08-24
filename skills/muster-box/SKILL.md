---
name: muster-box
description: "Use this skill when you need something you wrote to still exist later — notes to yourself, scratch output, a downloaded fixture, a write-up of an approach that failed, a log you want to compare against tomorrow — or when you are deciding whether to commit a file to your branch. It covers what in a muster box survives a recreate, what does not, and where the one durable directory is."
---

# What survives, and where to put it

You are working in a **box**: a container of your own that your reviewer can recreate at any time
(`cbx recreate`, a new image, a fresh golden) without warning you first. Recreating is routine, not
exceptional — it is how a box picks up a new base or a fixed image.

Almost nothing you write survives that. There is exactly one directory that does:

```sh
~/keep          # also $MUSTER_KEEP — use the variable in scripts
```

## The rule

| Where you wrote it | What happens on a recreate |
|---|---|
| `~/keep` | **Kept.** Survives recreate, kill, and `--fresh`. |
| your checkout (`$MUSTER_WORKDIR`) | Replaced. Committed work survives only because you **pushed** it. |
| anywhere else in `~` | Gone with the container. |
| `/tmp`, `/var/tmp` | Gone with the container. |

Only `cbx purge` removes `~/keep`, and that is your reviewer deliberately throwing this box away for
good — it asks first, and it is the one irreversible command in the workflow.

## What belongs there

Anything that is **yours to remember**, rather than the project's to keep:

- notes to yourself across a long task — what you have already ruled out, and why
- the write-up of an approach that did **not** work, so you (or the next box) do not retry it
- scratch output: a profile, a long log, a large diff you want to compare against later
- fixtures or sample data you downloaded and would rather not fetch again
- a copy of something before a risky rewrite

## What does NOT belong there

Anything the project should have. `~/keep` is invisible to your reviewer and to every other box — it
is not backed up, not reviewed, and not shared. If a file matters to the codebase, it goes in the
repo, in a commit, with a message.

## The mistake this exists to prevent

Do **not** commit scratch files to your branch to stop losing them. Your branch is exactly what your
reviewer reads: notes, dumps and half-finished experiments in it cost them time, and removing them
costs you another round. That trade — "commit junk or lose it" — is the one `~/keep` removes. If you
catch yourself writing `git add notes.md`, write it to `~/keep` instead.

Nothing in `~/keep` is secret. It sits on the host in the stack's data directory, readable by whoever
administers the server, and it is not a place for credentials — those come from the environment.

## Handing something over

`~/keep` is per box and nobody else can see it. To give your reviewer something, put it where they
already look:

- **code** — commit it and `handoff`
- **an explanation** — the handoff summary, or a comment reply
- **a file they need to see** — say so in the handoff; they can `cbxcp <box>:<path> .` from their
  laptop, including out of `~/keep`
