#!/bin/sh
set -e

# common-setup.sh — the tooling SHARED by the claude-box image (Dockerfile) and the hub base image
# (hub/Dockerfile.base): common base utils, Node + npm via fnm, and the pinchtab binary. Both
# Dockerfiles COPY this and RUN it, so the install logic + version handling live in ONE place
# instead of being duplicated. Version pins arrive as environment variables (passed from build
# args): NODE_VERSION, NPM_VERSION, PINCHTAB_VERSION. FNM_DIR is set by each Dockerfile's ENV.
#
# It installs ONLY what BOTH images need. Image-specific packages stay in their own Dockerfile:
#   claude-box: xclip/xsel/sudo (clipboard proxy) + the claude binary + the clip user & shims
#   hub base:   openssh-client, the Chrome runtime libs, xauth/xvfb, git-ssh, cbx
: "${NODE_VERSION:?common-setup: NODE_VERSION not set (pass --build-arg NODE_VERSION=...)}"
: "${NPM_VERSION:?common-setup: NPM_VERSION not set (pass --build-arg NPM_VERSION=...)}"
: "${PINCHTAB_VERSION:=0.13.2}"
: "${FNM_DIR:=/opt/fnm}"
export FNM_DIR

# Base utilities common to both images. procps=pgrep (dev-loop scripts), jq + python3 for claude,
# tmux for the box's detached session (the broker runs claude inside `tmux new-session`) and the
# hub's on-demand service windows, ncurses-bin for tic/tput/clear (+ compiling the terminfo below),
# bash-completion for git (and other) tab-completion in interactive login shells.
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates curl git bash-completion tmux less unzip libatomic1 procps jq python3 ncurses-bin
rm -rf /var/lib/apt/lists/*

# Ghostty terminfo — the real xterm-ghostty entry (`infocmp -x xterm-ghostty` from a ghostty install,
# shipped as terminfo-ghostty and COPYd to /tmp by the Dockerfile). bookworm/jammy ncurses predate the
# upstream entry, so compile it into /etc/terminfo (on the ncurses search path); attaching with a
# native TERM=xterm-ghostty then works with no -e TERM override. Refresh by re-running that infocmp.
if [ -f /tmp/terminfo-ghostty ]; then
	tic -x -o /etc/terminfo /tmp/terminfo-ghostty
	rm -f /tmp/terminfo-ghostty
fi

# tmux config: install the shipped tmux.conf (COPYd to /tmp by the Dockerfile) to /etc/tmux.conf —
# the SYSTEM config, read by tmux for every user. The box's /home is a bind-mount so a per-user
# ~/.tmux.conf would be shadowed. Add settings by editing tmux.conf, not here.
if [ -f /tmp/tmux.conf ]; then
	cp /tmp/tmux.conf /etc/tmux.conf
	rm -f /tmp/tmux.conf
fi

# Node + npm via fnm, pinned to the host dev versions. fnm and the node install live OUTSIDE the
# home bind mount (system-wide) and node/npm/npx are symlinked onto PATH, so no per-shell fnm hook
# is needed at runtime.
curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
fnm install "${NODE_VERSION}"
fnm default "${NODE_VERSION}"
ln -s "${FNM_DIR}/node-versions/${NODE_VERSION}/installation/bin/"* /usr/local/bin/
npm install -g "npm@${NPM_VERSION}"
node --version && npm --version

# pinchtab: the npm package is a launcher that fetches a self-contained Go binary; install it in a
# throwaway HOME, copy the binary onto PATH system-wide (survives the home bind-mount), drop the
# wrapper. The box uses it as a CLI (no Chrome); the hub runs it as a server (with Chrome libs).
HOME=/tmp/pt npm install -g "pinchtab@${PINCHTAB_VERSION}"
cp "$(find /tmp/pt/.pinchtab -name 'pinchtab-linux-amd64' -type f | head -1)" /usr/local/bin/pinchtab
chmod 0755 /usr/local/bin/pinchtab
npm rm -g pinchtab
rm -rf /tmp/pt
pinchtab --version
