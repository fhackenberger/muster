#!/bin/bash
set -euo pipefail

# claude-box-hub entrypoint. PID 1 under compose `init: true` (tini reaps zombies).
#
# Brings up cheap: clone the repo on first boot, serve it to the boxes, start an idle tmux server,
# then wait. The heavy dev services (backend / frontend / pinchtab) are started ON DEMAND via
# `cbx up <service>` — see cbx. Reattach the service windows or a shell with:
#   docker exec -it <project>-hub tmux attach
#
# The hub is the git authority: /work/repo is the ONLY clone with credentials for the real origin,
# and the only place `dev` is merged. Agent boxes work on their own overlay of a prepared golden tree
# and push to refs/agents/<box> here over git://; an update hook makes that the only ref namespace
# they may write. See README-remote.md.

: "${CHECKOUT:=/work/repo}"         # the hub's repo + working tree (bind-mounted from the host)
: "${REPO_URL:=}"                   # clone source, from the stack .env (optional)
: "${DEV_BRANCH:=dev}"              # the branch agents base on and you merge into
: "${GIT_DAEMON_PORT:=9418}"
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

# First boot: clone into the (empty) repo dir using the hub's own git identity + credentials.
if [ -n "$REPO_URL" ] && [ ! -e "$CHECKOUT/.git" ]; then
	seed_known_hosts "$REPO_URL"
	echo "hub: cloning $REPO_URL -> $CHECKOUT" >&2
	git clone "$REPO_URL" "$CHECKOUT" || echo "hub: clone failed — clone manually into $CHECKOUT" >&2
fi

if [ -e "$CHECKOUT/.git" ]; then
	# Land on the dev branch agents will base on. If the remote doesn't have it, branch it off whatever
	# was cloned (a fresh project) rather than failing — you can rename it later.
	if ! git -C "$CHECKOUT" rev-parse --verify -q "$DEV_BRANCH" >/dev/null; then
		if git -C "$CHECKOUT" rev-parse --verify -q "origin/$DEV_BRANCH" >/dev/null; then
			git -C "$CHECKOUT" branch --track "$DEV_BRANCH" "origin/$DEV_BRANCH"
		else
			echo "hub: no '$DEV_BRANCH' branch — creating it from the current HEAD" >&2
			git -C "$CHECKOUT" branch "$DEV_BRANCH"
		fi
	fi
	git -C "$CHECKOUT" symbolic-ref -q HEAD >/dev/null && git -C "$CHECKOUT" checkout -q "$DEV_BRANCH" || true

	# Boxes push here over git://, which has NO authentication — the cbx network is the boundary. This
	# hook is what keeps that safe: a box may only write its own agent ref namespace and the shared
	# review-notes ref. It can never touch dev/master or delete a branch, so the worst a compromised
	# box can do is publish garbage on a ref you review before merging.
	mkdir -p "$CHECKOUT/.git/hooks"
	cat > "$CHECKOUT/.git/hooks/update" <<'HOOK'
#!/bin/sh
# Installed by the hub entrypoint. Pushes from agent boxes arrive unauthenticated over git://, so
# restrict them to the refs the review workflow owns.
case "$1" in
	refs/agents/*|refs/notes/cbx) exit 0 ;;
esac
echo "hub: refusing push to $1 — boxes may only write refs/agents/* (use 'handoff')" >&2
exit 1
HOOK
	chmod 0755 "$CHECKOUT/.git/hooks/update"

	# Agents amend and rebase during a fix round, so their own ref must accept a force-push.
	git -C "$CHECKOUT" config receive.denyNonFastForwards false
	git -C "$CHECKOUT" config receive.denyDeletes false
	# Review state (last-reviewed sha per box) lives beside the repo, not in it.
	mkdir -p "$CHECKOUT/.git/cbx"
fi

# Idle tmux server with a landing window, so `cbx up` has somewhere to add service windows and you
# can always attach a shell. tmux keeps running as long as the session lives.
tmux new-session -d -s "$TMUX_SESSION" -c "$CHECKOUT" -n shell

# Serve the repo to the boxes: git://hub/repo (base-path=/work maps that to /work/repo). receive-pack
# is enabled so boxes can push their branches; the update hook above bounds what that means. It runs
# in its own tmux window so `cbx logs gitd` shows the pushes.
tmux new-window -t "$TMUX_SESSION" -n gitd -c /work \
	"git daemon --verbose --export-all --enable=receive-pack --reuseaddr \
		--base-path=/work --listen=0.0.0.0 --port=${GIT_DAEMON_PORT} /work/repo; \
	 echo; echo '[cbx] git daemon exited — press enter to close'; read _"

echo "hub: ready. Services are on-demand:" >&2
echo "  cbx up backend | frontend | pinchtab      (cbx down <svc> to stop)" >&2
echo "  cbx box [name] | cbx ls | cbx kill <name> (agent boxes, via the broker)" >&2
echo "  cbx q | cbx review <box> | cbx merge <box>  (the review queue)" >&2
echo "  docker exec -it \$HOSTNAME tmux attach     (to watch services / open a shell)" >&2

# Stay alive as long as the tmux server is up.
exec tmux wait-for hub-shutdown
