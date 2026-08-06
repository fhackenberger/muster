#!/bin/sh
set -e

# common-setup.sh — the tooling SHARED by the muster image (Dockerfile) and the hub base image
# (hub/Dockerfile.base): common base utils, Node + npm via fnm, and the pinchtab binary. Both
# Dockerfiles COPY this and RUN it, so the install logic + version handling live in ONE place
# instead of being duplicated. Version pins arrive as environment variables (passed from build
# args): NODE_VERSION, NPM_VERSION, PINCHTAB_VERSION, TUICR_VERSION. FNM_DIR is set by each
# Dockerfile's ENV.
#
# It installs ONLY what BOTH images need. Image-specific packages stay in their own Dockerfile:
#   muster: xclip/xsel/sudo (clipboard proxy) + the claude binary + the clip user & shims
#   hub base:   openssh-client, the Chrome runtime libs, xauth/xvfb, git-ssh, cbx
: "${NODE_VERSION:?common-setup: NODE_VERSION not set (pass --build-arg NODE_VERSION=...)}"
: "${NPM_VERSION:?common-setup: NPM_VERSION not set (pass --build-arg NPM_VERSION=...)}"
: "${PINCHTAB_VERSION:=0.13.2}"
: "${TUICR_VERSION:=0.19.1}"
: "${FNM_DIR:=/opt/fnm}"
export FNM_DIR

# Base utilities common to both images. procps=pgrep (dev-loop scripts), jq + python3 for claude,
# tmux for the box's detached session (the broker runs claude inside `tmux new-session`) and the
# hub's on-demand service windows, ncurses-bin for tic/tput/clear (+ compiling the terminfo below),
# bash-completion for git (and other) tab-completion in interactive login shells.
# vim  		useful for editing code
# git-delta	the dandavison 'delta' diff viewer (the apt package is git-delta; it ships /usr/bin/delta —
#       	bare 'delta' is an unrelated package)
# socat		the broker runs it FROM the box image (--entrypoint socat) as each box's frontend
#       	forwarder: it lives in the hub's netns and maps hub 127.0.0.1:<port> -> box:4200 so the
#       	hub pinchtab browser can load the box's dev server as http://localhost:<port>.
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates curl git bash-completion tmux less unzip libatomic1 procps jq python3 ncurses-bin \
	vim git-delta socat
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
# PINCHTAB_VERSION may be `latest` — the CI resolves it to a number and passes that instead, because
# a `latest` baked into this RUN would be re-resolved only when an earlier layer changes. A local
# build has no such machinery, so `latest` still works here; it is just not reproducible, which is
# what the recorded version below is for.
HOME=/tmp/pt npm install -g "pinchtab@${PINCHTAB_VERSION:-latest}"
cp "$(find /tmp/pt/.pinchtab -name 'pinchtab-linux-amd64' -type f | head -1)" /usr/local/bin/pinchtab
chmod 0755 /usr/local/bin/pinchtab
npm rm -g pinchtab
rm -rf /tmp/pt
pinchtab --version
# What actually landed, readable at RUNTIME. With `latest` in play, "which pinchtab is this?" stops
# being answerable from the build args alone — and it is the first question when an endpoint the skill
# documents turns out not to be there.
mkdir -p /opt/muster
pinchtab --version > /opt/muster/pinchtab-version

# …and pinchtab's own Claude skill, so an agent uses the CLI's session/snapshot workflow instead of
# reinventing it from --help. Fetched from upstream at BUILD time rather than vendored: it is
# pinchtab's file, it changes when pinchtab changes, and a copy in this repo would be a fork nobody
# remembers to update. It cannot be baked into ~/.claude — that directory is a bind mount at runtime
# and would hide anything the image left there — so the hub's entrypoint installs it from here.
mkdir -p /opt/muster/skills/pinchtab
curl -fsSL -o /opt/muster/skills/pinchtab/SKILL.md \
	https://raw.githubusercontent.com/pinchtab/pinchtab/main/skills/pinchtab/SKILL.md
# -f already rejects a 404, but a proxy's courtesy page or an empty body would still "succeed". A
# skill starts with YAML frontmatter naming itself; check that rather than just the exit status.
head -1 /opt/muster/skills/pinchtab/SKILL.md | grep -qx -- '---' \
	|| { echo "pinchtab SKILL.md has no frontmatter — not a skill" >&2; exit 1; }
grep -q '^name: pinchtab' /opt/muster/skills/pinchtab/SKILL.md \
	|| { echo "pinchtab SKILL.md is missing 'name: pinchtab'" >&2; exit 1; }

# tuicr (https://tuicr.dev): the code-review TUI `cbx review` opens on an agent's branch — scroll the
# diff, leave line/range comments, quit, and cbx turns the persisted comments into review feedback for
# the box. Installed from the project's own install.sh (its documented method) rather than cargo, so
# no Rust toolchain is needed: it fetches the matching static release binary for this OS/arch.
#   INSTALL_DIR=/usr/local/bin  — system-wide, so it survives the home bind-mount (same reason as
#                                 pinchtab above); the installer's default ~/.local/bin would not.
#   INSTALL_YES=1               — the installer prompts on a readable /dev/tty; a build has none, but
#                                 say so explicitly instead of relying on that.
# It lands in BOTH images: the hub runs the TUI, and in a box `tuicr review add` lets an agent attach
# its own comments to a session. Bump TUICR_VERSION (build arg) to upgrade.
curl -fsSL https://tuicr.dev/install.sh \
	| TUICR_VERSION="${TUICR_VERSION}" TUICR_INSTALL_DIR=/usr/local/bin TUICR_INSTALL_YES=1 sh
tuicr --version
