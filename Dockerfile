# muster — the LEAN, project-agnostic agent base: debian:trixie-slim + common-setup.sh (node,
# pinchtab, git, socat, …) + Claude + the clipboard proxy. No JDK/gradle — YOUR project's build
# toolchain layers on top via Dockerfile.addon (-> muster-<project>, what the broker spawns).
FROM debian:trixie-slim

# WHICH MUSTER THIS IS. Baked in so the pieces can check they agree at runtime: the hub, the broker
# and the boxes are three images from three build paths, and nothing else stops a stack from running
# a 0.2 broker against a 0.1 hub. The ADD-ON images inherit this ENV from their base, so a
# project's own toolchain layer carries the version of the muster it was built on — which is exactly
# the number that has to match. `dev` when built by hand; CI passes the release tag.
ARG MUSTER_VERSION=dev
ENV MUSTER_VERSION=${MUSTER_VERSION}

# Minimal deps needed just to install Claude below (ca-certificates + curl). The rest of the shared
# runtime (git, node/npm, pinchtab, base utils) is installed later by common-setup.sh — see below.
# Claude is installed EARLY (before common-setup) because its layer is the slow one: keeping it above
# the version-pinned toolchain means bumping NODE_VERSION/pinchtab doesn't bust the Claude cache.
RUN apt-get update && apt-get install -y --no-install-recommends \
		ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/*

# Install the native Claude binary SYSTEM-WIDE (survives the home bind-mount) and disable the
# self-updater so it never rewrites itself into the mounted home.
# Claude install takes very long, so we do this early
ENV DISABLE_AUTOUPDATER=1
RUN curl -fsSL https://claude.ai/install.sh | bash \
	&& cp "$(HOME=/root command -v claude || echo /root/.local/bin/claude)" /usr/local/bin/claude \
	&& chmod 0755 /usr/local/bin/claude
# Gate: fail the build if the binary is not relocatable (runtime HOME differs from build HOME).
RUN mkdir -p /tmp/rc && HOME=/tmp/rc /usr/local/bin/claude --version && rm -rf /tmp/rc

# Refresh layer: pull the latest Claude WITHOUT re-running the slow install step above. Bump
# CLAUDE_REFRESH (e.g. --build-arg CLAUDE_REFRESH=$(date +%s), wired through build.sh) to force
# ONLY this layer to re-run; an unchanged value is a cache hit and a no-op. DISABLE_AUTOUPDATER
# disables only the background check — an explicit `claude update` still works. The updater writes
# into the per-user install dir, so we run it in a throwaway HOME and re-copy the refreshed binary
# system-wide (skipped if it already updated /usr/local/bin in place), then re-gate relocatability.
ARG CLAUDE_REFRESH=0
RUN export HOME=/tmp/cu PATH="/tmp/cu/.local/bin:$PATH" \
	&& mkdir -p "$HOME/.local/bin" \
	&& claude update \
	&& src="$(command -v claude)" \
	&& { [ "$src" = /usr/local/bin/claude ] || cp "$src" /usr/local/bin/claude; } \
	&& chmod 0755 /usr/local/bin/claude \
	&& rm -rf /tmp/cu
RUN mkdir -p /tmp/rc && HOME=/tmp/rc /usr/local/bin/claude --version && rm -rf /tmp/rc

# Keep ~/.local/bin (claude's recorded native-install dir) on PATH for LOGIN shells too. The
# entrypoint exports it for the main process; /etc/profile resets PATH before sourcing profile.d,
# so this re-affirms it afterwards. Idempotent (no duplicate entry), runtime-HOME aware.
RUN printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' \
		> /etc/profile.d/00-local-bin.sh \
	&& chmod 0644 /etc/profile.d/00-local-bin.sh

# Shared tooling (base utils, Node + npm via fnm, the pinchtab CLI) — installed by common-setup.sh,
# the SAME script the hub base uses, so the toolchain is defined in one place. Version pins come from
# build args (build.sh captures them from the host; the Jenkins pipeline passes them explicitly).
ARG NODE_VERSION=v26.2.0
ARG NPM_VERSION=11.13.0
ARG PINCHTAB_VERSION=0.13.2
ARG TUICR_VERSION=0.19.1
ENV FNM_DIR=/opt/fnm
COPY common-setup.sh terminfo-ghostty tmux.conf /tmp/
RUN NODE_VERSION="${NODE_VERSION}" NPM_VERSION="${NPM_VERSION}" PINCHTAB_VERSION="${PINCHTAB_VERSION}" \
		TUICR_VERSION="${TUICR_VERSION}" \
		sh /tmp/common-setup.sh \
	&& rm /tmp/common-setup.sh

# Box-specific: the clipboard bridge (xclip/xsel) + sudo, which drives the unprivileged clip proxy.
# Everything else the box shares with the hub came from common-setup.sh above.
RUN apt-get update && apt-get install -y --no-install-recommends \
		xclip xsel sudo \
	&& rm -rf /var/lib/apt/lists/*

# Disable Angular CLI analytics + its first-run "share usage data?" prompt. The CLI normally
# persists this in ~/.config/angular, but the container's home is bind-mounted so that wouldn't
# survive — the env var lives in the image and suppresses the prompt for every run.
ENV NG_CLI_ANALYTICS=false

# UTF-8 locale. debian-slim configures none, so LANG would be unset (C/POSIX) — and in server mode
# claude runs inside tmux, which then replaces every non-ASCII glyph with '_' (claude's logo and box
# borders come out as underscores). C.UTF-8 is built into glibc, so this needs no locales package
# and no locale-gen. Your terminal's own locale can't fix it: `docker exec` doesn't propagate the
# host environment, so the setting has to live in the image.
ENV LANG=C.UTF-8

# Unprivileged identity that is the ONLY X client authorized to touch the clipboard. The UID
# here is just a placeholder — the entrypoint resets it at startup to the runtime CLIP_UID,
# so changing the UID needs no rebuild, only the settings file + a matching host account.
ARG CLIP_USER=muster-clip
RUN useradd -r -u 60001 -M -s /usr/sbin/nologin ${CLIP_USER} \
	&& groupadd clipusers

# sudo rule keyed on the 'clipusers' GROUP (not a fixed username), so the dynamic runtime user
# only needs to be added to it (the entrypoint does that). Members may run ONLY xclip/xsel and
# only AS the clip user, no password. Keep DISPLAY (env_reset strips it); never allocate a pty
# (its line discipline would corrupt binary PNG data on stdout); don't require a tty.
RUN printf '%s\n' \
		'Defaults:%clipusers !requiretty, !use_pty' \
		'Defaults:%clipusers env_keep += "DISPLAY"' \
		'%clipusers ALL=('"${CLIP_USER}"') NOPASSWD: /usr/bin/xclip, /usr/bin/xsel' \
		> /etc/sudoers.d/muster-clip \
	&& chmod 0440 /etc/sudoers.d/muster-clip \
	&& visudo -cf /etc/sudoers.d/muster-clip

# Transparent shims: identical CLI to the real tools (argv, stdin/stdout, exit code all pass
# straight through), routed through the unprivileged clip user. /usr/local/bin precedes /usr/bin
# on PATH, so bare 'xclip'/'xsel' resolve here while the real binaries stay at /usr/bin.
RUN for t in xclip xsel; do \
		printf '#!/bin/sh\nexec sudo -n -u %s /usr/bin/%s "$@"\n' "${CLIP_USER}" "$t" > /usr/local/bin/$t \
		&& chmod 0755 /usr/local/bin/$t; \
	done

# Agent-side git CLIs (server mode only; harmless on a laptop box, where MUSTER_BOX is unset):
#   muster-box-init  puts the box on its own agent/<box> branch against the hub (run by muster-box.sh
#                 via MUSTER_INIT_CMD before claude starts)
#   handoff       push the branch to the hub for review, with a summary as a git note
#   mydiff        exactly what this box will hand over (its branch vs the hub's dev)
#   muster-activity  Claude Code hook: records busy/idle/waiting for the hub (see cbx ls / cbx status)
COPY box-bin/muster-box-init box-bin/handoff box-bin/mydiff box-bin/muster-activity /usr/local/bin/
RUN chmod 0755 /usr/local/bin/muster-box-init /usr/local/bin/handoff /usr/local/bin/mydiff \
	/usr/local/bin/muster-activity

# Root entrypoint: materialize the runtime user from HOST_USER/UID/GID, then drop privileges.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
