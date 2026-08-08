#!/bin/bash
set -euo pipefail

# muster-hub entrypoint. PID 1 under compose `init: true` (tini reaps zombies).
#
# Brings up cheap: clone the repo on first boot, serve it to the boxes, start an idle tmux server,
# then wait. The heavy dev services (backend / frontend / pinchtab) are started ON DEMAND via
# `cbx up <service>` — see cbx. Reattach the service windows or a shell with:
#   docker exec -it <project>-hub tmux attach
#
# The hub is the git authority: the repo below is the ONLY clone with credentials for the real origin,
# and the only place `dev` is merged. Agent boxes work on their own overlay of a prepared golden tree
# and push to refs/agents/<box> here over git://; an update hook makes that the only ref namespace
# they may write. See README-remote.md.

# The hub's repo + working tree (bind-mounted from the host). This path is also where every box
# mounts its overlay of a golden — goldens are snapshots of THIS tree, and installed dependencies
# bake absolute paths in, so hub and box must agree on the path. Don't change one without the other
# (broker CHECKOUT_DST) or npm/gradle artifacts prepared here break inside the boxes.
: "${CHECKOUT:=/home/dev/repo}"
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

# Does what this container actually HAS match the mounts table every box is built from? The table
# (MOUNTS_FILE) is the single source for both sides, but compose can't read it: gen-hub-mounts.sh
# renders the hub column into compose.override.yml, so the hub's mounts are only correct if that ran
# AND this container was recreated afterwards. Both are easy to forget, and the failure is silent —
# the hub and the boxes quietly end up with different environments, which is exactly how a `~/.gradle`
# shared rw with every box (and its cross-container lock deadlock) survived unnoticed. So: warn, don't
# fail. A drifted mount is a bad boot, not a broken one.
check_mounts() {
	[ -n "${MOUNTS_FILE:-}" ] && [ -r "$MOUNTS_FILE" ] || return 0
	local src dst hub rest want opts actual drift=0
	local mountinfo="${MOUNTINFO:-/proc/self/mountinfo}"   # overridable so this is testable
	while read -r src dst hub rest; do
		case "${src:-}" in ''|'#'*|CHECKOUT) continue ;; esac
		[ -n "${hub:-}" ] || continue
		case "$hub" in -|rw|ro) ;; *) continue ;; esac
		want="/home/dev/$dst"
		# What the KERNEL says, not what compose meant: field 5 is the mount point, field 6 the options.
		opts="$(awk -v p="$want" '$5 == p { o = $6 } END { print o }' "$mountinfo")"
		if [ -z "$opts" ]; then
			[ "$hub" = - ] || { echo "hub: MOUNT DRIFT — $want is NOT mounted, '$MOUNTS_FILE' says '$hub'" >&2; drift=1; }
			continue
		fi
		if [ "$hub" = - ]; then
			echo "hub: MOUNT DRIFT — $want is mounted but '$MOUNTS_FILE' gives the hub nothing there" >&2; drift=1; continue
		fi
		case ",$opts," in *,ro,*) actual=ro ;; *) actual=rw ;; esac
		[ "$actual" = "$hub" ] ||
			{ echo "hub: MOUNT DRIFT — $want is $actual, '$MOUNTS_FILE' says $hub" >&2; drift=1; }
	done < "$MOUNTS_FILE"
	[ "$drift" = 0 ] || echo "hub: fix with  ./gen-hub-mounts.sh && docker compose up -d hub  (on the host)" >&2
}
check_mounts || true

# The stack's own name for the CLI. On the laptop each stack gets its own command family from a prefix
# (`muster_stack app …` -> `app`, `apphub`, `appbox`, …), and it would be a poor joke if the name changed the
# moment you stepped into the hub through `apphub`. So the hub answers to the same word.
#
# A SYMLINK, not a shell alias: it has to work in the tmux service commands, in `docker exec … cbx …`
# from a script, and for the broker's own calls — none of which read a bashrc. `muster` itself always
# stays, so anything that hard-codes it (docs, this entrypoint, older tooling) is unaffected.
#
# CLI below is the name this hub prints in its own hints: the prefix when there is one, `muster`
# otherwise. Never a bare `cbx` — that is one stack's name for the command, and hard-coding it here
# is how a hub whose MUSTER_PREFIX had not been deployed yet failed to autostart its services with
# "cbx: command not found".
CLI=muster
if [ -n "${MUSTER_PREFIX:-}" ] && [ "$MUSTER_PREFIX" != muster ]; then
	case "$MUSTER_PREFIX" in
		[a-z][a-z0-9_]*)
			if ln -sf /usr/local/bin/muster "/usr/local/bin/$MUSTER_PREFIX"; then
				CLI="$MUSTER_PREFIX"
				echo "hub: muster is also available as '$MUSTER_PREFIX'"
			fi ;;
		*) echo "hub: ignoring MUSTER_PREFIX='$MUSTER_PREFIX' — must start with a lowercase letter, then letters/digits/_" >&2 ;;
	esac
else
	echo "hub: no MUSTER_PREFIX in this container's environment — the CLI is 'muster' only." >&2
	echo "     Set it in the stack .env and RECREATE the hub (env is fixed at container creation)." >&2
fi

# Tab-completion for a shell opened with `<prefix>hub` or `docker exec -it … bash`. The script itself
# registers both names (it reads MUSTER_PREFIX); this symlink is what makes bash-completion FIND it
# when the first thing you type is the prefix — its on-demand loader looks for a file named after the
# command. Best-effort: the hub runs as uid 1000, so it is only writable if the image left it so, and
# completion is a convenience, not a boot requirement.
# The system directory first (only writable if this hub runs as root), then the per-user one, which
# bash-completion's loader searches BEFORE the system one — and which the uid-1000 hub can always
# write.
COMPDIR=/usr/share/bash-completion/completions
if [ "$CLI" != muster ] && [ -r "$COMPDIR/muster" ]; then
	ln -sf muster "$COMPDIR/$CLI" 2>/dev/null \
		|| { mkdir -p "$HOME/.local/share/bash-completion/completions" \
		     && ln -sf "$COMPDIR/muster" "$HOME/.local/share/bash-completion/completions/$CLI"; } \
		|| true
fi

# Idle tmux server with a landing window, so `cbx up` has somewhere to add service windows and you
# can always attach a shell. tmux keeps running as long as the session lives.
tmux new-session -d -s "$TMUX_SESSION" -c "$CHECKOUT" -n shell

# Serve the repo to the boxes as git://hub/repo. base-path is the PARENT of the repo, so the URL path
# stays '/repo' regardless of where the tree lives. receive-pack is enabled so boxes can push their
# branches; the update hook above bounds what that means. It runs in its own tmux window so
# `cbx logs gitd` shows the pushes.
GIT_BASE_PATH="$(dirname "$CHECKOUT")"
tmux new-window -t "$TMUX_SESSION" -n gitd -c "$GIT_BASE_PATH" \
	"git daemon --verbose --export-all --enable=receive-pack --reuseaddr \
		--base-path='$GIT_BASE_PATH' --listen=0.0.0.0 --port=${GIT_DAEMON_PORT} '$CHECKOUT'; \
	 echo; echo '[cbx] git daemon exited — press enter to close'; read _"

# The boxes' port-forwards are socat containers running in THIS container's network namespace, so
# they died when this container was replaced. Ask the broker to re-establish them — in the background
# and best-effort, so a slow or absent broker can never delay or fail the hub's boot.
if [ -n "${BROKER_URL:-}" ]; then
	(
		for _ in 1 2 3 4 5; do
			sleep 2
			curl -fsS -m 5 -X POST -H "X-Broker-Token: ${BROKER_TOKEN:-}" "${BROKER_URL}/forwards" \
				>/dev/null 2>&1 && { echo "hub: port-forwards re-established" >&2; break; }
		done
	) &
fi

# PINCHTAB: a config and a token, before anything can autostart the server.
#
# The config is generic — bind, port, the Chrome path this image installs, and an IDPI allowlist of
# loopback only (which is WHY each box's dev server is published on the hub's loopback: that is the
# address the browser can reach). So the image ships one and it is seeded here rather than being a
# file every consumer has to reconstruct from their laptop's copy.
#
# THE TOKEN is the interesting part. It has to match on both sides: the server reads it from this
# config, and every box gets it from the broker as PINCHTAB_TOKEN. Three cases, in order:
#   - a config already there with a real token  -> left completely alone (yours, not ours)
#   - PT_TOKEN set in the stack .env            -> written in, so the two sides agree
#   - neither                                   -> generated here, and the broker reads it back out
#                                                  of this file for the boxes
# That last case is what makes a fresh stack work with no secret to invent.
PT_CONFIG="${PINCHTAB_CONFIG:-$HOME/.pinchtab/config.json}"
if [ -d "$(dirname "$PT_CONFIG")" ]; then
	if [ ! -f "$PT_CONFIG" ] && [ -f /opt/muster/pinchtab-config.json ]; then
		cp /opt/muster/pinchtab-config.json "$PT_CONFIG"
		echo "hub: seeded $PT_CONFIG from the image's default" >&2
	fi
	# The token logic is its own script (hub/pinchtab-token.py): it edits JSON someone may have
	# hand-tuned, so it deserves to be readable and to have a test of its own.
	if [ -f "$PT_CONFIG" ]; then
		PT_TOKEN="${PT_TOKEN:-}" muster-pinchtab-token "$PT_CONFIG" \
			|| echo "hub: could not check the pinchtab token in $PT_CONFIG" >&2
	fi
fi

# A FRESH BROWSER PROFILE ON EVERY HUB BOOT. The profile lives in the bind-mounted ~/.pinchtab, so it
# is the one part of the browser that survives a recreate — and nothing prunes it. On hetzner1 it
# reached 3.4GB (3.0GB of Chrome HTTP cache), which is not merely disk: pinchtab's /health touches the
# profile, so it went from 303ms to 3.0s, and 3s is longer than the deadline every pinchtab CLI
# command gives its preflight. Agents in boxes then got "server at <hub>:9867 is not running" for a
# server that was up, authenticated and driving Chrome fine — and gave up on browser verification,
# which is the exact failure this browser exists to prevent.
#
# Reaping is right beyond the disk: this browser reviews a frontend whose bundles change all day, so a
# cached asset or a surviving service worker means an agent can verify THE WRONG BUILD and report
# success. A profile per hub lifetime makes "what the browser shows" always the build that is running.
# The cost is a Chrome first-run (~1s) and forgetting cookies/history nobody relies on — the stack's
# AnonymousLogin means no session to lose. Set MUSTER_PINCHTAB_KEEP_PROFILE=1 if you do want a
# persistent browser.
#
# ONLY profiles/ — config.json holds the token both sides agree on and sessions.json the boxes' tabs;
# removing ~/.pinchtab wholesale would take those with it. Before `muster autostart` on purpose: that
# is the one moment the server is guaranteed not to be running, so nothing is deleted under it.
PT_PROFILES="$(dirname "$PT_CONFIG")/profiles"
if [ "${MUSTER_PINCHTAB_KEEP_PROFILE:-0}" = 1 ]; then
	echo "hub: keeping the pinchtab browser profile (MUSTER_PINCHTAB_KEEP_PROFILE=1)" >&2
elif [ -d "$PT_PROFILES" ]; then
	echo "hub: reaping the pinchtab browser profile ($(du -sh "$PT_PROFILES" 2>/dev/null | cut -f1)) — it is rebuilt on first use" >&2
	rm -rf "$PT_PROFILES" || echo "hub: could not remove $PT_PROFILES" >&2
fi

# pinchtab's own Claude skill, from the image into the shared ~/.claude every box mounts. Baking it
# straight into that path would be pointless — it is a bind mount, so the image's copy is hidden.
# Overwritten on every boot on purpose: it is upstream's file, versioned with the image, and a local
# edit here would silently outlive the pinchtab it documents. Keep your own under another name.
if [ -d /opt/muster/skills ] && [ -d "$HOME/.claude" ]; then
	mkdir -p "$HOME/.claude/skills"
	cp -r /opt/muster/skills/. "$HOME/.claude/skills/" 2>/dev/null \
		&& echo "hub: installed the bundled skills into $HOME/.claude/skills" >&2 || true
fi

# Start any service whose manifest sets autostart=true (best-effort — a service that fails to launch
# must never wedge the hub's boot). Everything else stays on-demand via `<cli> up`.
muster autostart || true

echo "hub: ready. Services are declared in hub-services/ ($CLI svcs), started on-demand:" >&2
echo "  $CLI up <service> | $CLI down <service> | $CLI svcs   (autostart=true starts one at boot)" >&2
echo "  $CLI box [name] | $CLI ls | $CLI kill <name> (agent boxes, via the broker)" >&2
echo "  $CLI q | $CLI review <box> | $CLI merge <box>  (the review queue)" >&2
echo "  docker exec -it \$HOSTNAME tmux attach     (to watch services / open a shell)" >&2

# Stay alive as long as the tmux server is up.
exec tmux wait-for hub-shutdown
