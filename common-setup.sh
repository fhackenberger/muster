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
#   hub base:   openssh-client, tmux, the Chrome runtime libs, xauth/xvfb, git-ssh, cbx
: "${NODE_VERSION:?common-setup: NODE_VERSION not set (pass --build-arg NODE_VERSION=...)}"
: "${NPM_VERSION:?common-setup: NPM_VERSION not set (pass --build-arg NPM_VERSION=...)}"
: "${PINCHTAB_VERSION:=0.13.2}"
: "${FNM_DIR:=/opt/fnm}"
export FNM_DIR

# Base utilities common to both images. procps=pgrep (dev-loop scripts), jq + python3 for claude.
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates curl git less unzip libatomic1 procps jq python3
rm -rf /var/lib/apt/lists/*

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
