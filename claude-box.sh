#!/bin/bash
set -euo pipefail

# claude-box.sh — launch Claude Code inside the sandboxed claude-box container.
#
# The container never sees your real home: only ~/.claude (sessions/config/creds, so resume
# works), ~/.gitconfig (your commit identity), and the nearest enclosing git repo are bind-
# mounted in at their real paths. It starts as root, recreates your host user inside, then
# drops to it. Clipboard access is brokered through an unprivileged proxy user so the tool
# can paste images but cannot keylog / screenshot / inject input.
#
# Usage:
#   claude-box.sh                  # run claude (default)
#   claude-box.sh --shell          # drop into a bash shell inside the container instead
#   claude-box.sh -s               #   (short form of --shell)
#   claude-box.sh --root           # drop into a bash shell as root (no privilege drop)
#   claude-box.sh -- <args...>     # run claude with those flags, e.g. -- --resume <id>
#   claude-box.sh <cmd> [args...]  # run any explicit command in the container verbatim
#
# By default the box runs the centrally-built image from the acoveo registry, pulled on first use
# (so a laptop needs only `docker login dockerregistry.acoveo.com` + this script — no local build).
# build.sh is only for hacking on the image locally. Set CLAUDEBOX_PULL=1 to refresh to the latest
# pushed build. Settings (clip-proxy UID, shared dir, image name) live in ~/.config/claude-box/config
# — created with defaults on first run.
#
# The host is reachable within the container on the hostname: host.docker.internal
# for e.g. connecting to a backend service while running the frontend for testing
# within the container. Remember you need a firewall rule like:
# $ sudo ufw allow in on docker0 from 172.17.0.0/16 to any port 8080 proto tcp
#
# pinchtab: the box ships only the pinchtab CLI and drives the pinchtab server + Chrome
# running on the HOST. This script wires the CLI to the host server (PINCHTAB_SERVER /
# PINCHTAB_TOKEN, token read from ~/.pinchtab/config.json) and publishes the container's
# Angular dev server to a free host port (CLAUDEBOX_DEV_URL) so the host Chrome can load it.
# The pinchtab server stays bound to 127.0.0.1 — we do NOT rebind it. Instead a short-lived
# socat relay on the docker-bridge gateway only (172.17.0.1, never the LAN) forwards into the
# loopback server for this session, gated by the pinchtab token and a docker0 ufw rule (same
# pattern as the :8080 note above, on the pinchtab port).
#
# SERVER / HEADLESS mode (set CLAUDEBOX_HEADLESS=1, used by the box-broker on a shared server):
# everything that assumes a local X server + interactive TTY is skipped — the clipboard proxy
# and its host account, xhost, DISPLAY/X11, the pinchtab socat relay, the dev-port publish, and
# the shared-anchor sudo mount. The box then reaches the project's services (pinchtab, backend,
# dev server) over a docker network by name instead of via host.docker.internal. All of this is
# env-gated, so with the CLAUDEBOX_* server vars unset the laptop flow is byte-for-byte unchanged.
# Server-mode env (all optional, defaulting to the laptop behavior):
#   CLAUDEBOX_HEADLESS=1              skip X/clip/xhost/DISPLAY/relay/publish/sudo-mount
#   CLAUDEBOX_DETACH=1               docker run -d (no --rm), CMD wrapped in a tmux session
#   CLAUDEBOX_USER / _UID / _GID     identity materialized inside (default: the invoking host user)
#   CLAUDEBOX_NAME / _NETWORK        docker --name / --network
#   CLAUDEBOX_CLAUDE_DIR             the ~/.claude to mount (default: $HOME/.claude)
#   CLAUDEBOX_WORKDIR                container workdir (default: cwd; headless: the home anchor)
#   CLAUDEBOX_PINCHTAB_SERVER/_TOKEN point the box's pinchtab CLI straight at a server (no relay)
#   CLAUDEBOX_DEV_URL                the dev-server URL to expose to the box
#   CLAUDEBOX_CLAUDE_ARGS            extra args appended to the detached `claude` (e.g. --resume <id>)
#   CLAUDEBOX_EXTRA_MOUNTS           newline-separated src:dst[:ro] binds (broker-validated)

# Settings live in one simple shell file shared with build.sh, so the clip UID (which must
# match host account + image build + this script) is configured in a single place. Created
# with defaults on first run.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-box"
CONFIG_FILE="$CONFIG_DIR/config"
if [ ! -f "$CONFIG_FILE" ]; then
	mkdir -p "$CONFIG_DIR"
	cat > "$CONFIG_FILE" <<'EOF'
# claude-box settings — sourced by claude-box.sh and build.sh (plain shell assignments).
#
# UID of the unprivileged clipboard-proxy user. Applied at container start (no rebuild).
# It must match the host account:
#   sudo useradd -r -u <UID> -s /usr/sbin/nologin -M claude-box-clip
# After changing it here, just recreate that host account with the new UID.
CLIP_UID=60001

# Optional overrides (uncomment to use):
#CLIP_USER=claude-box-clip
#CLAUDEBOX_SHARED="$HOME/claudebox"
# Image to run. Default: the centrally-built image from the acoveo registry, pulled on first use.
# To hack on the image locally, build it with build.sh and switch to the local tag:
#CLAUDEBOX_IMAGE=claude-box
EOF
	echo "claude-box: wrote default settings to $CONFIG_FILE" >&2
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# Server/headless mode. When on, all X/interactive/host-relay machinery below is skipped and the
# box is wired to talk to project services over a docker network instead. Off (default) = laptop.
HEADLESS="${CLAUDEBOX_HEADLESS:-0}"
DETACH="${CLAUDEBOX_DETACH:-0}"

# Empty anchor dir mounted as the container's home (/home/<user>). The container does NOT
# see your real home — only what is bind-mounted below. On the laptop this anchor is a SHARED
# (rslave) mount, so you can later expose parts of your home at matching paths, e.g.:
#   sudo mount --bind /home/<user>/projects/x  "$SHARED_DIR/projects/x"
#       -> appears in the container at /home/<user>/projects/x
# In server mode the broker instead passes the curated content via CLAUDEBOX_EXTRA_MOUNTS.
SHARED_DIR="${CLAUDEBOX_SHARED:-$HOME/claudebox}"
IMAGE="${CLAUDEBOX_IMAGE:-dockerregistry.acoveo.com/acoveo/claude-box:stable}"

# Identity materialized inside the container. Defaults to the invoking host user (laptop); the
# broker overrides these to a synthetic non-root uid (e.g. dev/1000/1000) so Claude never runs as
# uid 0 and the mounted files line up with a numeric owner (no host account required).
USER_NAME="${CLAUDEBOX_USER:-$(id -un)}"
HOST_UID_VAL="${CLAUDEBOX_UID:-$(id -u)}"
HOST_GID_VAL="${CLAUDEBOX_GID:-$(id -g)}"
HOME_IN="/home/${USER_NAME}"
ORIG_PWD="$(pwd)"

# The ~/.claude to bind-mount (sessions/config/credentials — resume works). Defaults to the host
# user's; the broker points every box at one shared dir so a single login covers all boxes.
CLAUDE_DIR="${CLAUDEBOX_CLAUDE_DIR:-$HOME/.claude}"

# Per-box identity. Several boxes can bind-mount and `ng serve` THIS repo at once; the frontend
# dev loop keys its Angular manualRebuild trigger file off CLAUDEBOX_ID (see
# infostarsFrontend/scripts/frontend-dev-lib.sh) so forcing a rebuild in one box never fires every
# other box's dev server. Each container already gets a private /tmp, so this just guarantees a
# distinct trigger name per box. Generated fresh per run; uuid with a pid fallback.
CLAUDEBOX_ID="$(cut -c1-12 /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s' "$$")"

# Unprivileged identity that is the ONLY X client authorized for clipboard access. Claude
# (your UID) is never authorized to the X server directly — so it can paste images via the
# xclip/xsel shims but cannot keylog, screenshot, or inject input. The X server resolves
# this NAME against the HOST passwd, so the account must exist on the host with the same UID
# the image was built for (CLIP_UID, from the settings file above; default 60001). CLIP_UID is
# still passed to the container in server mode (the entrypoint sets the in-container clip user's
# uid; it only must differ from HOST_UID), but the host-account checks below are laptop-only.
CLIP_USER="${CLIP_USER:-claude-box-clip}"
CLIP_UID_EXPECTED="${CLAUDEBOX_CLIP_UID:-${CLIP_UID:-60001}}"

if [ "$HEADLESS" != 1 ]; then
	clip_line="$(getent passwd "$CLIP_USER" 2>/dev/null || true)"
	if [ -z "$clip_line" ]; then
		cat >&2 <<EOF
claude-box: required host user '$CLIP_USER' is missing.

It is an unprivileged, no-login account that acts as the clipboard proxy: it is the only
identity allowed to reach your X server, so Claude (uid $(id -u)) can paste images without
being able to keylog / screenshot / inject input. Create it once:

    sudo useradd -r -u $CLIP_UID_EXPECTED -s /usr/sbin/nologin -M $CLIP_USER

then re-run this script.
EOF
		exit 1
	fi

	host_clip_uid="$(printf '%s' "$clip_line" | cut -d: -f3)"
	if [ "$host_clip_uid" != "$CLIP_UID_EXPECTED" ]; then
		cat >&2 <<EOF
claude-box: host user '$CLIP_USER' has uid $host_clip_uid but the image expects uid $CLIP_UID_EXPECTED.
The X-server authorization matches by uid, so these must agree. Recreate it:

    sudo userdel $CLIP_USER && sudo useradd -r -u $CLIP_UID_EXPECTED -s /usr/sbin/nologin -M $CLIP_USER

(or rebuild the image with --build-arg CLIP_UID=$host_clip_uid and set CLAUDEBOX_CLIP_UID=$host_clip_uid).
EOF
		exit 1
	fi
fi

# Mount the nearest enclosing git repo (walk up for .git) at its REAL path, then launch inside
# the original cwd — gives Claude the whole repo + working git, paths copy/paste 1:1. In server
# mode there is no single repo to auto-mount: the broker curates what the box sees (typically the
# working tree WITHOUT .git) via CLAUDEBOX_EXTRA_MOUNTS, so we skip this.
CODE_DIR=""
if [ "$HEADLESS" != 1 ]; then
	CODE_DIR="$(git -C "$ORIG_PWD" rev-parse --show-toplevel 2>/dev/null || true)"
	if [ -z "$CODE_DIR" ]; then
		CODE_DIR="$ORIG_PWD"
		echo "claude-box: no .git found above $ORIG_PWD — mounting the current dir only." >&2
	else
		echo "claude-box: mounting git repo  $CODE_DIR  (launching in $ORIG_PWD)" >&2
	fi
fi

mkdir -p "$SHARED_DIR"

# Laptop: make the anchor a shared mount so dirs bind-mounted under it on the host later
# propagate into the running container. Server: creation-time curated mounts instead, so we skip
# the (privileged) sudo mount entirely.
if [ "$HEADLESS" != 1 ]; then
	echo "claude-box: configuring the shared mount (may prompt for your sudo password)..." >&2
	if ! mountpoint -q "$SHARED_DIR"; then
		sudo mount --bind "$SHARED_DIR" "$SHARED_DIR"
	fi
	sudo mount --make-rshared "$SHARED_DIR"
fi

# Selective home mounts: real ~/.claude (sessions/config/credentials — resume works) and, on the
# laptop, ~/.gitconfig (read-only, so commits use your identity) + the repo at its real path.
# In server mode the box gets NO git identity (only the hub commits) and the repo content comes
# from the broker-validated CLAUDEBOX_EXTRA_MOUNTS instead.
MOUNTS=(-v "$CLAUDE_DIR:$HOME_IN/.claude:rw")
# Optional tmpfs overlays (server mode): empty in-container dirs that shadow whatever a bind mount
# placed underneath — used to hide .git inside a whole-tree mount. Newline-separated paths.
TMPFS_ARGS=()
if [ -n "${CLAUDEBOX_EXTRA_TMPFS:-}" ]; then
	while IFS= read -r _t; do
		[ -n "$_t" ] && TMPFS_ARGS+=(--tmpfs "$_t")
	done <<< "$CLAUDEBOX_EXTRA_TMPFS"
fi
if [ "$HEADLESS" = 1 ]; then
	MOUNTS+=(-v "$SHARED_DIR:$HOME_IN")
	if [ -n "${CLAUDEBOX_EXTRA_MOUNTS:-}" ]; then
		while IFS= read -r _m; do
			[ -n "$_m" ] && MOUNTS+=(-v "$_m")
		done <<< "$CLAUDEBOX_EXTRA_MOUNTS"
	fi
else
	MOUNTS+=(
		-v "/tmp/.X11-unix:/tmp/.X11-unix:rw"
		-v "$SHARED_DIR:$HOME_IN:rslave"
		-v "$CODE_DIR:$CODE_DIR:rw"
	)
	[ -f "$HOME/.claude.json" ] && MOUNTS+=(-v "$HOME/.claude.json:$HOME_IN/.claude.json:rw")
	[ -f "$HOME/.gitconfig" ]   && MOUNTS+=(-v "$HOME/.gitconfig:$HOME_IN/.gitconfig:ro")
fi

# pinchtab control channel. Server mode: the broker points us straight at the project's pinchtab
# server on the docker network (no host relay). Laptop mode: relay the box to the host's loopback
# server via an ephemeral socat on the docker-bridge gateway only.
PT_ENV=(); PT_RELAY_PID=""
if [ "$HEADLESS" = 1 ]; then
	if [ -n "${CLAUDEBOX_PINCHTAB_SERVER:-}" ]; then
		PT_ENV=(
			-e PINCHTAB_SERVER="$CLAUDEBOX_PINCHTAB_SERVER"
			-e PINCHTAB_TOKEN="${CLAUDEBOX_PINCHTAB_TOKEN:-}"
		)
	fi
else
	# The token and port are read from the host config; we never start a server in the box.
	PT_CFG="$HOME/.pinchtab/config.json"
	PT_TOKEN=""; PT_SRV_PORT="9867"
	if [ -f "$PT_CFG" ]; then
		PT_TOKEN="$(grep -oP '"token"\s*:\s*"\K[^"]+' "$PT_CFG" 2>/dev/null | head -1 || true)"
		cfg_port="$(grep -oP '"port"\s*:\s*"\K[^"]*' "$PT_CFG" 2>/dev/null | head -1 || true)"
		[ -n "${cfg_port:-}" ] && PT_SRV_PORT="$cfg_port"
	fi

	# The pinchtab server stays bound to 127.0.0.1 (we never rebind it). To reach it from the
	# container WITHOUT exposing it on every interface, run an ephemeral relay on the docker-bridge
	# gateway only (172.17.0.1) that forwards to the loopback server. It is reachable on docker0 (not
	# the LAN), exists only for this box session, and the pinchtab token remains the auth boundary.
	# The container then talks to host.docker.internal -> that gateway -> the relay -> loopback.
	if [ -n "$PT_TOKEN" ]; then
		PT_ENV=(
			-e PINCHTAB_SERVER="http://host.docker.internal:${PT_SRV_PORT}"
			-e PINCHTAB_TOKEN="$PT_TOKEN"
		)
		DOCKER_GW="$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)"
		DOCKER_GW="${DOCKER_GW:-172.17.0.1}"
		if ! command -v socat >/dev/null 2>&1; then
			echo "claude-box: socat not found — cannot relay pinchtab into the box (install: sudo apt install socat)." >&2
		elif (exec 3<>"/dev/tcp/${DOCKER_GW}/${PT_SRV_PORT}") 2>/dev/null; then
			exec 3>&- 3<&- 2>/dev/null || true
			echo "claude-box: reusing existing pinchtab relay on ${DOCKER_GW}:${PT_SRV_PORT}." >&2
		else
			socat "TCP4-LISTEN:${PT_SRV_PORT},bind=${DOCKER_GW},reuseaddr,fork" "TCP4:127.0.0.1:${PT_SRV_PORT}" &
			PT_RELAY_PID=$!
			echo "claude-box: pinchtab relay ${DOCKER_GW}:${PT_SRV_PORT} -> 127.0.0.1:${PT_SRV_PORT} (pid ${PT_RELAY_PID}, this session only)" >&2
		fi
		echo "claude-box: pinchtab CLI -> host.docker.internal:${PT_SRV_PORT} (needs: ufw allow in on docker0 from 172.17.0.0/16 to any port ${PT_SRV_PORT} proto tcp)" >&2
	else
		echo "claude-box: no pinchtab config at $PT_CFG — skipping pinchtab wiring." >&2
	fi
fi

# pinchtab data channel. Laptop: publish the container's Angular dev server (4200) to the next
# free host loopback port so the host Chrome can load it. Server: the dev server + Chrome live in
# the hub, so we only pass the URL the broker gave us (Chrome loads it directly on the network).
pick_free_port() {
	local base=8930 p
	for p in $(seq "$base" $((base+99))); do
		(exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3>&- 3<&-; continue; }
		printf '%s\n' "$p"; return 0
	done
	return 1
}
DEV_ENV=(); DEV_PUBLISH=()
if [ "$HEADLESS" = 1 ]; then
	[ -n "${CLAUDEBOX_DEV_URL:-}" ] && DEV_ENV=(-e FRONTEND_DEV_HOST=0.0.0.0 -e CLAUDEBOX_DEV_URL="$CLAUDEBOX_DEV_URL")
elif DEV_PORT="$(pick_free_port)"; then
	DEV_PUBLISH=(-p "127.0.0.1:${DEV_PORT}:4200")
	DEV_ENV=(
		-e FRONTEND_DEV_HOST=0.0.0.0
		-e CLAUDEBOX_DEV_URL="http://localhost:${DEV_PORT}"
	)
	echo "claude-box: dev server publishes to http://localhost:${DEV_PORT} (CLAUDEBOX_DEV_URL in the box)" >&2
else
	echo "claude-box: no free host port in 8930-9029 — dev server not published." >&2
fi

# Command to run in the container:
#   --root              -> bash AS ROOT (entrypoint skips the setpriv drop; for in-box admin)
#   --shell / -s        -> bash, to explore the box
#   -- <args...>        -> claude WITH those flags, e.g. `-- --resume <id>` / `-- --continue`
#   any other args      -> run that command verbatim (e.g. `claude-box.sh ls -la`)
#   (no args)           -> claude
ROOT_ENV=()
if [ "${1:-}" = "--root" ]; then
	shift
	ROOT_ENV=(-e CLAUDEBOX_ROOT=1)
	RUN_CMD=(bash)
elif [ "${1:-}" = "--shell" ] || [ "${1:-}" = "-s" ]; then
	shift
	RUN_CMD=(bash)
elif [ "${1:-}" = "--" ]; then
	shift
	RUN_CMD=(claude "$@")
elif [ "$#" -gt 0 ]; then
	RUN_CMD=("$@")
else
	RUN_CMD=(claude)
fi

# Detached/server box: run in the background with a tmux session holding claude, so you reattach
# with `docker exec -it <name> tmux attach`. No --rm, so the box survives detach until it is
# explicitly removed (cbx kill). Overrides the command chosen above (the broker passes no args).
# claude runs in the named session 'main'; when it exits (you quit it, or it crashes) the window
# drops to a login shell instead of the session vanishing — so you can just type `claude` to
# relaunch, and a crash leaves a readable shell rather than "no sessions". CLAUDEBOX_CLAUDE_ARGS is
# appended to the claude command (the broker passes --session-id/--resume so each box keeps its own
# conversation across recreates); empty on the laptop, so the command is unchanged there.
if [ "$DETACH" = 1 ]; then
	_claude="claude${CLAUDEBOX_CLAUDE_ARGS:+ ${CLAUDEBOX_CLAUDE_ARGS}}"
	RUN_CMD=(bash -lc "tmux new-session -d -s main -n claude \"${_claude}; echo; echo claude exited - type claude to relaunch; exec bash -l\"; exec sleep infinity")
fi

# Single cleanup on any exit (normal or signal): revoke the X-server grant (laptop only) and tear
# down the ephemeral pinchtab relay (if this session started one).
cleanup() {
	[ "$HEADLESS" != 1 ] && xhost "-SI:localuser:${CLIP_USER}" >/dev/null 2>&1 || true
	[ -n "${PT_RELAY_PID:-}" ] && kill "$PT_RELAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Authorize ONLY the clip user on the X server (not Claude's UID). Revoked by cleanup() on exit.
# Server mode has no X server, so there is nothing to grant.
if [ "$HEADLESS" != 1 ]; then
	xhost "+SI:localuser:${CLIP_USER}" >/dev/null
fi

# The container starts as root so the entrypoint can materialize this identity in /etc/passwd,
# then drops to it. Your real home is never mounted — only the dirs in MOUNTS above.
RUN_FLAGS=(--init)
if [ "$DETACH" = 1 ]; then
	RUN_FLAGS+=(-d)
else
	RUN_FLAGS+=(--rm -it)
fi

NAME_NET=()
[ -n "${CLAUDEBOX_NAME:-}" ]    && NAME_NET+=(--name "$CLAUDEBOX_NAME")
[ -n "${CLAUDEBOX_NETWORK:-}" ] && NAME_NET+=(--network "$CLAUDEBOX_NETWORK")

DISPLAY_ENV=()
[ "$HEADLESS" != 1 ] && DISPLAY_ENV=(-e DISPLAY="$DISPLAY")

WORKDIR="$ORIG_PWD"
[ "$HEADLESS" = 1 ] && WORKDIR="${CLAUDEBOX_WORKDIR:-$HOME_IN}"

DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# Ensure the image is present. The default IMAGE is the centrally-built acoveo-registry image, so
# pull it when it's missing locally (or when CLAUDEBOX_PULL=1 forces a refresh to the latest push).
# A local-only tag that's already present (e.g. build.sh's 'claude-box') skips the pull.
if [ "${CLAUDEBOX_PULL:-0}" = 1 ] || ! $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "claude-box: pulling $IMAGE ..." >&2
	if ! $DOCKER pull "$IMAGE"; then
		if $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
			echo "claude-box: pull failed — using the local copy of $IMAGE." >&2
		else
			echo "claude-box: cannot pull $IMAGE and no local copy exists." >&2
			echo "claude-box:   - for the acoveo registry, run: docker login dockerregistry.acoveo.com" >&2
			echo "claude-box:   - or build locally with build.sh and set CLAUDEBOX_IMAGE=claude-box in $CONFIG_FILE" >&2
			exit 1
		fi
	fi
fi

$DOCKER run "${RUN_FLAGS[@]}" \
	--hostname "${CLAUDEBOX_NAME:-claudebox}" \
	--add-host=host.docker.internal:host-gateway \
	"${NAME_NET[@]}" \
	-e HOST_USER="$USER_NAME" \
	-e HOST_UID="$HOST_UID_VAL" \
	-e HOST_GID="$HOST_GID_VAL" \
	-e CLAUDEBOX_ID="$CLAUDEBOX_ID" \
	-e CLIP_UID="$CLIP_UID_EXPECTED" \
	"${DISPLAY_ENV[@]}" \
	-e TERM="${TERM:-xterm-256color}" \
	-e COLORTERM="${COLORTERM:-truecolor}" \
	-e DISABLE_AUTOUPDATER=1 \
	"${ROOT_ENV[@]}" \
	"${PT_ENV[@]}" \
	"${DEV_ENV[@]}" \
	"${DEV_PUBLISH[@]}" \
	"${MOUNTS[@]}" \
	"${TMPFS_ARGS[@]}" \
	-w "$WORKDIR" \
	"$IMAGE" "${RUN_CMD[@]}"
