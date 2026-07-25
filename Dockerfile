FROM debian:bookworm-slim

# Minimal runtime + sudo (drives the unprivileged clipboard proxy) + clipboard tools.
# (setpriv, used by the entrypoint to drop privileges, ships with util-linux in the base.)
# We add procps for pgrep (used in dev loop scripts) and jq & python3 for claude.
RUN apt-get update && apt-get install -y --no-install-recommends \
		ca-certificates curl git xclip xsel less sudo unzip libatomic1 \
		procps jq python3 \
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

# Node + npm via fnm, pinned to the versions the host dev box is currently using (captured by
# build.sh and passed in as build args) so the container's toolchain matches the host exactly.
# fnm and the node install live OUTSIDE the home bind mount (system-wide, like the claude binary
# below), and node/npm/npx are symlinked onto PATH so no per-shell fnm hook is needed at runtime.
ARG NODE_VERSION=v26.2.0
ARG NPM_VERSION=11.13.0
ENV FNM_DIR=/opt/fnm
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell \
	&& fnm install "${NODE_VERSION}" \
	&& fnm default "${NODE_VERSION}" \
	&& ln -s "${FNM_DIR}/node-versions/${NODE_VERSION}/installation/bin/"* /usr/local/bin/ \
	&& npm install -g "npm@${NPM_VERSION}" \
	&& node --version && npm --version

# pinchtab CLI ONLY (no Chrome) — the box is a thin client that drives the pinchtab server +
# Chrome running on the HOST (reached via host.docker.internal; wired up in claude-box.sh). The
# npm package is just a launcher that downloads a self-contained Go binary; we run its installer
# in a throwaway HOME, copy that binary onto PATH system-wide (survives the home bind-mount, like
# the claude binary), and drop the wrapper. Pinned to the host version (captured by build.sh).
ARG PINCHTAB_VERSION=0.11.0
RUN HOME=/tmp/pt npm install -g "pinchtab@${PINCHTAB_VERSION}" \
	&& cp "$(find /tmp/pt/.pinchtab -name 'pinchtab-linux-amd64' -type f | head -1)" /usr/local/bin/pinchtab \
	&& chmod 0755 /usr/local/bin/pinchtab \
	&& npm rm -g pinchtab \
	&& rm -rf /tmp/pt \
	&& pinchtab --version

# Unprivileged identity that is the ONLY X client authorized to touch the clipboard. The UID
# here is just a placeholder — the entrypoint resets it at startup to the runtime CLIP_UID,
# so changing the UID needs no rebuild, only the settings file + a matching host account.
ARG CLIP_USER=claude-box-clip
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
		> /etc/sudoers.d/claude-box-clip \
	&& chmod 0440 /etc/sudoers.d/claude-box-clip \
	&& visudo -cf /etc/sudoers.d/claude-box-clip

# Transparent shims: identical CLI to the real tools (argv, stdin/stdout, exit code all pass
# straight through), routed through the unprivileged clip user. /usr/local/bin precedes /usr/bin
# on PATH, so bare 'xclip'/'xsel' resolve here while the real binaries stay at /usr/bin.
RUN for t in xclip xsel; do \
		printf '#!/bin/sh\nexec sudo -n -u %s /usr/bin/%s "$@"\n' "${CLIP_USER}" "$t" > /usr/local/bin/$t \
		&& chmod 0755 /usr/local/bin/$t; \
	done

# Disable Angular CLI analytics + its first-run "share usage data?" prompt. The CLI normally
# persists this in ~/.config/angular, but the container's home is bind-mounted so that wouldn't
# survive — the env var lives in the image and suppresses the prompt for every run.
ENV NG_CLI_ANALYTICS=false

# Root entrypoint: materialize the runtime user from HOST_USER/UID/GID, then drop privileges.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
