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

# EVERY STEP BELOW THAT TOUCHES THE NETWORK IS RETRIED, because a build that fetches from six
# different hosts fails on the flakiest of them, and the failure never looks like what it is: the
# pinchtab postinstall reports an ECONNRESET as "Ensure v0.15.1 is released on GitHub with
# checksums.txt", which sends you to a releases page where the file is sitting there, present and
# correct. A single dropped connection should not cost an image build.
#
# Retries the COMMAND, so a pipeline (curl … | sh) has to be wrapped in a function first — otherwise
# only the first stage would be retried, and it is not the one that reaches the network.
: "${SETUP_RETRIES:=3}"
retry() {
	_retry_n=1
	while :; do
		"$@" && return 0
		if [ "$_retry_n" -ge "$SETUP_RETRIES" ]; then break; fi
		echo "common-setup: '$1' failed (attempt $_retry_n/$SETUP_RETRIES) — retrying in $((_retry_n * 5))s" >&2
		sleep $((_retry_n * 5))
		_retry_n=$((_retry_n + 1))
	done
	echo "common-setup: '$1' still failing after $SETUP_RETRIES attempts — giving up" >&2
	return 1
}

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
retry apt-get update
retry apt-get install -y --no-install-recommends \
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
#
# The `command -v` is not belt and braces: in `curl … | bash` the pipeline's status is BASH's, and a
# curl that dies mid-transfer feeds it a truncated script that exits 0. Without a check for what the
# installer was supposed to leave behind, a failed download is a successful build step.
install_fnm() {
	curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
	command -v fnm >/dev/null || { echo "common-setup: the fnm installer left no fnm" >&2; return 1; }
}
retry install_fnm
retry fnm install "${NODE_VERSION}"
fnm default "${NODE_VERSION}"
ln -s "${FNM_DIR}/node-versions/${NODE_VERSION}/installation/bin/"* /usr/local/bin/
retry npm install -g "npm@${NPM_VERSION}"
node --version && npm --version

# pinchtab: the npm package is a launcher that fetches a self-contained Go binary; install it in a
# throwaway HOME, copy the binary onto PATH system-wide (survives the home bind-mount), drop the
# wrapper. The box uses it as a CLI (no Chrome); the hub runs it as a server (with Chrome libs).
# PINCHTAB_VERSION may be `latest` — the CI resolves it to a number and passes that instead, because
# a `latest` baked into this RUN would be re-resolved only when an earlier layer changes. A local
# build has no such machinery, so `latest` still works here; it is just not reproducible, which is
# what the recorded version below is for.
#
# THE INSTALL AND THE BINARY ARE ONE RETRY UNIT. What fails here is the package's postinstall, which
# is what fetches the Go binary — npm itself has already succeeded by then, and a second
# `npm install` over a package that is already there would not run it again. So each attempt starts
# from an empty throwaway HOME, and the attempt only counts as done once the binary it was supposed
# to download is actually on disk.
install_pinchtab() {
	rm -rf /tmp/pt
	npm rm -g pinchtab >/dev/null 2>&1 || true      # a rolled-back attempt may still be registered
	HOME=/tmp/pt npm install -g "pinchtab@${PINCHTAB_VERSION:-latest}" || return 1
	# TWO PLACES, because pinchtab's postinstall moved the binary in 0.15.2. It used to download into
	# $HOME/.pinchtab/bin/<version>/ — which is the only reason HOME is redirected here at all — and
	# now writes a PACKAGE-RELATIVE .managed-bin/<version>/ inside the installed module instead. Its
	# own platform.js still calls the old path "legacy" and falls back to it, so both are live. Looking
	# only in the old one failed the entire image build with "shipped no linux-amd64 binary" when the
	# install had in fact worked perfectly — we were reading an empty directory. Newest layout first,
	# and the legacy one kept, so pinning an older PINCHTAB_VERSION for a rollback still works.
	_pt_root="$(HOME=/tmp/pt npm root -g 2>/dev/null || true)"
	_pt_bin="$(find "${_pt_root:-/nonexistent}/pinchtab" /tmp/pt/.pinchtab \
		-name 'pinchtab-linux-amd64' -type f 2>/dev/null | head -1 || true)"
	[ -n "$_pt_bin" ] || {
		echo "common-setup: pinchtab installed but no linux-amd64 binary landed in" >&2
		echo "  ${_pt_root:-<npm root -g failed>}/pinchtab/.managed-bin/ or /tmp/pt/.pinchtab/bin/" >&2
		echo "  — its postinstall may have moved again: install it by hand and find the binary." >&2
		return 1
	}
}
retry install_pinchtab
cp "$_pt_bin" /usr/local/bin/pinchtab
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
retry curl -fsSL -o /opt/muster/skills/pinchtab/SKILL.md \
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
# Same pipeline caveat as fnm above: check for the binary, not for the exit status of the `sh` that
# read the script.
install_tuicr() {
	curl -fsSL https://tuicr.dev/install.sh \
		| TUICR_VERSION="${TUICR_VERSION}" TUICR_INSTALL_DIR=/usr/local/bin TUICR_INSTALL_YES=1 sh
	command -v tuicr >/dev/null || { echo "common-setup: the tuicr installer left no tuicr" >&2; return 1; }
}
retry install_tuicr
tuicr --version
