#!/bin/bash
set -euo pipefail

# Builds the claude-box image. The clip UID is NOT baked in — it's applied at container start
# from the settings file — so this is a plain build and you only need to rebuild when the
# Dockerfile/entrypoint change, not when you change the UID. docker is elevated automatically
# if the daemon needs it.
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-box/config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
IMAGE="${CLAUDEBOX_IMAGE:-claude-box}"

# Capture the node/npm versions currently active on the host (typically via fnm) and pin the
# container's toolchain to match. Override by exporting NODE_VERSION / NPM_VERSION before building.
NODE_VERSION="${NODE_VERSION:-$(node --version 2>/dev/null || true)}"
NPM_VERSION="${NPM_VERSION:-$(npm --version 2>/dev/null || true)}"
if [ -z "$NODE_VERSION" ] || [ -z "$NPM_VERSION" ]; then
	echo "claude-box: node/npm not found on PATH — cannot pin the container toolchain" >&2
	echo "claude-box: activate your fnm node (or set NODE_VERSION / NPM_VERSION) and retry" >&2
	exit 1
fi

# Pin the in-container pinchtab CLI to the host version (mirrors the node/npm pinning). Non-fatal,
# but check explicitly and WARN rather than silently falling back: without pinchtab on the build
# host's PATH the container can't be pinned to the host version and the Dockerfile ARG default
# applies instead.
if command -v pinchtab >/dev/null 2>&1; then
	PINCHTAB_VERSION="${PINCHTAB_VERSION:-$(pinchtab --version 2>/dev/null | awk '{print $NF}')}"
fi
if [ -z "${PINCHTAB_VERSION:-}" ]; then
	echo "claude-box: pinchtab not found on PATH — not pinning the container CLI; using the Dockerfile default version." >&2
fi

BUILD_ARGS=(
	--build-arg NODE_VERSION="$NODE_VERSION"
	--build-arg NPM_VERSION="$NPM_VERSION"
)
[ -n "$PINCHTAB_VERSION" ] && BUILD_ARGS+=(--build-arg PINCHTAB_VERSION="$PINCHTAB_VERSION")

# Refresh Claude to the latest release WITHOUT rebuilding the expensive install layer: bump the
# CLAUDE_REFRESH value (e.g. `CLAUDE_REFRESH=$(date +%s) ./build.sh`) and only the lightweight
# `claude update` layer in the Dockerfile re-runs. Unset -> cache hit, no refresh.
[ -n "${CLAUDE_REFRESH:-}" ] && BUILD_ARGS+=(--build-arg CLAUDE_REFRESH="$CLAUDE_REFRESH")

DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

echo "claude-box: building '$IMAGE' (node ${NODE_VERSION} / npm ${NPM_VERSION} / pinchtab ${PINCHTAB_VERSION:-default}${CLAUDE_REFRESH:+ / claude-refresh ${CLAUDE_REFRESH}})" >&2
exec $DOCKER build "${BUILD_ARGS[@]}" -t "$IMAGE" "$HERE"
