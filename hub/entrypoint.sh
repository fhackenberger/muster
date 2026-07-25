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

# First boot: clone into the (empty) checkout using the hub's own git identity + credentials.
if [ -n "$REPO_URL" ] && [ ! -e "$CHECKOUT/.git" ]; then
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
