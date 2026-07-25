#!/bin/bash
set -euo pipefail

# claude-box-hub entrypoint. PID 1 under compose `init: true` (tini reaps zombies).
#
# Brings up cheap: clone the repo on first boot, start an idle tmux server, then wait. The heavy
# dev services (backend / frontend / pinchtab) are started ON DEMAND via `cbx up <service>` — see
# cbx. Reattach the service windows or a shell with:  docker exec -it <project>-hub tmux attach

: "${CHECKOUT:=/work/checkout}"     # the repo working tree (bind-mounted from the host)
: "${REPO_URL:=}"                   # clone source, from the stack .env (optional)
: "${TMUX_SESSION:=services}"
: "${GIT_IDENTITY_DIR:=$HOME/.gitidentity}"

# Cert step: auto-accept the git host's SSH key so the non-interactive clone below can't stall on an
# "unknown host" prompt (which would fail with "Host key verification failed"). Provider-agnostic —
# the host is derived from REPO_URL and scanned into the identity known_hosts (idempotent; the baked
# git-ssh wrapper also trusts new hosts on first use, so this just makes it deterministic).
seed_known_hosts() {
	url="$1" host="" port="22"
	case "$url" in
		ssh://*)                                   # ssh://[user@]host[:port]/path
			rest="${url#ssh://}"; rest="${rest#*@}"
			hostport="${rest%%/*}"; host="${hostport%%:*}"
			case "$hostport" in *:*) port="${hostport##*:}" ;; esac ;;
		*://*) return 0 ;;                          # http(s)/git:// — TLS handled by the CA store
		*@*:*) host="${url#*@}"; host="${host%%:*}" ;;   # scp-like user@host:path
		*) return 0 ;;                              # local path — nothing to scan
	esac
	[ -n "$host" ] || return 0
	mkdir -p "$GIT_IDENTITY_DIR"; touch "$GIT_IDENTITY_DIR/known_hosts"
	# Already trusted? (try both hashed/plain and the [host]:port form for non-22 ports.)
	if ssh-keygen -F "$host" -f "$GIT_IDENTITY_DIR/known_hosts" >/dev/null 2>&1 \
	   || ssh-keygen -F "[$host]:$port" -f "$GIT_IDENTITY_DIR/known_hosts" >/dev/null 2>&1; then
		return 0
	fi
	echo "hub: scanning host key for $host:$port" >&2
	if [ "$port" = 22 ]; then
		ssh-keyscan "$host" >> "$GIT_IDENTITY_DIR/known_hosts" 2>/dev/null || true
	else
		ssh-keyscan -p "$port" "$host" >> "$GIT_IDENTITY_DIR/known_hosts" 2>/dev/null || true
	fi
}

# First boot: clone into the (empty) checkout using the hub's own git identity + credentials.
if [ -n "$REPO_URL" ] && [ ! -e "$CHECKOUT/.git" ]; then
	seed_known_hosts "$REPO_URL"
	echo "hub: cloning $REPO_URL -> $CHECKOUT" >&2
	git clone "$REPO_URL" "$CHECKOUT" || echo "hub: clone failed — clone manually into $CHECKOUT" >&2
fi

# Idle tmux server with a landing window, so `cbx up` has somewhere to add service windows and you
# can always attach a shell. tmux keeps running as long as the session lives.
tmux new-session -d -s "$TMUX_SESSION" -c "$CHECKOUT" -n shell

echo "hub: ready. Services are on-demand:" >&2
echo "  cbx up backend | frontend | pinchtab      (cbx down <svc> to stop)" >&2
echo "  cbx box [name] | cbx ls | cbx kill <name> (agent boxes, via the broker)" >&2
echo "  docker exec -it \$HOSTNAME tmux attach     (to watch services / open a shell)" >&2

# Stay alive as long as the tmux server is up.
exec tmux wait-for hub-shutdown
