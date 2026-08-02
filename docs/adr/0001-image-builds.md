# 1. What we publish, what everyone builds, and where

**Status:** accepted · **Date:** 2026-08-02

## Context

muster is five images, and they are not the same kind of thing:

| Image | What it carries | Who can build it |
|---|---|---|
| `muster` | box base — node, claude, tuicr, pinchtab, git, tmux, clipboard | anyone |
| `muster-hub-base` | the above + openssh, Chrome, git-ssh, the `muster` CLI, the uid-1000 `dev` user | anyone |
| `muster-broker` | python + the docker CLI + `muster-box.sh`; **no toolchain, ever** | anyone |
| `muster-<project>` | a base + **your** `build-setup.sh` | only you |
| `muster-hub` | the hub base + **your** `build-setup.sh` | only you |

The add-on images are `Dockerfile.addon`, which is **ten lines**. Everything expensive and everything
project-agnostic is below them. The obvious question — "every project needs its own hub and box image
anyway, so why publish anything?" — has the answer backwards: the per-project part is the cheap part.

## Decision

**Publish the three project-agnostic images to GHCR, on a version tag. Never publish the add-ons.
Never make the registry mandatory.**

### Why publish the bases

1. **For many projects the bases *are* the final images.** `compose.yml` already defaults `BOX_IMAGE`
   to `muster:stable` — the base itself. A Node or Python project needs no toolchain at all:
   `common-setup.sh` already provides node, git, tmux and claude. Those users need **zero builds**.
   That is the difference between "clone, edit `.env`, `docker compose up -d`" and "clone, then wait
   while Chrome downloads".

2. **Reproducibility, which matters more than build time.** `common-setup.sh` deliberately resolves
   the *latest* node, claude and tuicr at build time, so it picks up security fixes without a commit.
   The cost is that a commit does **not** identify an artifact: two builds of the same source produce
   different images. A published, version-tagged base is the only thing that pins a *tested
   combination* — which is what a release should mean.

### Why not the add-ons

They are `FROM <base>` plus one `COPY` of a file only you have. There is nothing to share, and
publishing them would invite people to depend on someone else's JDK choice.

### Why the registry is never mandatory

`build.sh` and `docker compose --profile build build` build all five locally from the same
Dockerfiles. Forks, air-gapped sites and anyone who would rather not run our binaries need that path,
and keeping it working keeps the published images honest — they are a convenience, not a lock-in.

### Where

**GitHub Actions → GHCR** (`.github/workflows/images.yml`), triggered by a `v*` tag, gated on the test
suite. It lives with the code and needs no infrastructure of its own. Tags are `v1.2.3`, `1.2`, and a
moving `latest` — deploy from a version, not from `latest`.

While the repository is **private**, two things follow that would not for a public one: Actions
minutes are metered rather than free, so `images.yml` runs on tags only and never on a push; and the
GHCR packages are private too, so anything pulling them — including a server running
`docker compose up -d` — needs `docker login ghcr.io` with a token carrying `read:packages`. Neither
changes the decision, but both are surprises if you meet them at a deploy.

## Consequences

**Building the add-ons is a compose profile.** The box image was the one image compose could not
build: the broker spawns boxes itself and only receives `BOX_IMAGE` as an environment value, so
`docker compose build` produced a hub carrying your toolchain and boxes without it — discovered when
an agent's first build failed. There is now a `box-image` service under `profiles: [build]`:

```sh
docker compose --profile build build      # hub + broker + the box add-on
```

A profiled service is excluded from `up`, `down`, `pull`, `ps` and plain `build` unless the profile is
switched on, so a deployment that pulls prebuilt images never touches it. A test asserts the profile
stays in place, because losing it would make a production `up -d` start building.

**Consumers pin one version.** A project using muster needs the tree in three places — CI (for
`Dockerfile.addon`), the deploy (`compose.yml`, `gen-hub-mounts.sh`), and Ansible (the `claude_box`
role). A git submodule at a tag serves all three from one pin; a `requirements.yml` entry would serve
only the role and leave the other two needing a second mechanism.

**A project's CI builds only its two add-ons**, `FROM` the published bases:

```sh
docker build -f vendor/muster/Dockerfile.addon \
  --build-arg BASE_IMAGE=ghcr.io/fhackenberger/muster:v1.2.3 \
  --build-arg SETUP_SCRIPT=build-setup.sh \
  -t myproject-box:stable <dir containing your build-setup.sh>
```

`-f` may point outside the build context, so the Dockerfile comes from the pinned checkout while
`COPY ${SETUP_SCRIPT}` resolves against a directory in the consuming repo. That seam is what lets the
two repositories stay separate.

**Bases must be built before add-ons**, and rebuilding only an add-on silently keeps the old base.
That was already true; publishing makes it explicit, because the base is now named by a version.

## Alternatives considered

- **Publish nothing.** Simplest, no registry, no CI secrets — but every user pays the Chrome download,
  and "muster v1.2.0" stops identifying anything.
- **Publish everything, including add-ons.** Impossible in general: the add-on needs a file the
  publisher does not have.
- **Build the bases in each consumer's CI.** Works, but re-does expensive, identical work per project
  and leaves every consumer on a different resolved toolchain.
