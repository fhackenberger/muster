# cbx laptop aliases — source this from your ~/.bashrc:
#
#     export CBX_SERVER=root@hetzner1.acoveo.com   # optional: override before sourcing
#     export CBX_PROJECT=infostars
#     source /path/to/claude-box/cbx.bash_aliases
#
# Everything is driven through `cbx` inside the hub; these wrap the full `<transport> … docker exec …`
# so you don't type it each time. The hub container is resolved by its compose labels at call time (so
# it survives compose's `-1` suffix and renames) — the `$(docker ps …)` lookup runs on the SERVER,
# while $CBX_SERVER / $CBX_PROJECT are substituted locally.
#
# Two kinds of invocation, deliberately on different transports:
#   * one-shot commands (`cbx --help`, `cbx ls`, `cbx q`, `cbx review …`) ALWAYS use ssh, so their
#     output prints to your terminal and stays in scrollback. mosh is an alternate-screen app — it
#     would render the output and then WIPE it on exit — and it buys nothing for a sub-second command.
#   * long-lived interactive sessions (`cbxhub`, `cbxbox`, `cbx logs`) honor CBX_TRANSPORT, default
#     ssh. Set CBX_TRANSPORT=mosh — per call (`CBX_TRANSPORT=mosh cbxhub`) or globally — for roaming
#     (survives laptop sleep, Wi-Fi→LTE, IP changes, no frozen sessions). Trade-off: mosh can't carry
#     the clipboard (OSC 52), so terminal copy from claude only reaches your laptop clipboard on ssh.
# mosh needs UDP 60000-61000 open to the server (see tasks/firewall.yml) and uses ssh only for the
# initial handshake, so key auth is unchanged. `cbxtun` is always ssh — mosh can't port-forward.
# NOTE: an exported CBX_TRANSPORT in your environment/~/.bashrc WINS over the default set here — the
# `:=` below only assigns when it's unset. `echo "$CBX_TRANSPORT"` if a transport change seems ignored.

# Set these — either export them in ~/.bashrc before sourcing, or edit the defaults here.
: "${CBX_SERVER:=root@your-server}"      # the claude-box host, e.g. root@hetzner1.acoveo.com
: "${CBX_PROJECT:=myproject}"            # PROJECT_NAME of the stack, e.g. infostars
: "${CBX_TRANSPORT:=ssh}"                # transport for interactive sessions: mosh | ssh (default)
# TERM handling. `docker exec -it` does NOT propagate your terminal — it hands the container TERM=dumb,
# which has no `clear`, so tmux dies with "terminal does not support clear". So we forward YOUR real
# $TERM explicitly via `-e TERM=…`. That's your actual terminal (e.g. xterm-ghostty, which the box
# bakes), not a forced one. CBX_TERM is an OPT-IN override, unset by default: set it only when the box
# has no terminfo for your terminal (e.g. xterm-kitty) — `export CBX_TERM=xterm-256color` for a
# known-good fallback. If both are empty, no -e is added and docker's dumb default applies.

# Drop any older alias-based definitions (pre-mosh README) so the function definitions below parse —
# bash expands `cbx` as an alias mid-parse otherwise, failing with "syntax error near `('". Harmless
# when none exist; also lets you re-source this file cleanly.
unalias cbx cbxhub cbxbox cbxui cbxtun cbxpsql 2>/dev/null || true
unset -f cbxui 2>/dev/null || true          # cbxui was renamed to cbxtun; drop the stale function

# One-shot commands: run over ssh so stdout/stderr land on your terminal and persist in scrollback.
# `-t` gives the remote a PTY (proper width/color for `--help` etc.); ssh doesn't use an alternate
# screen, so nothing is wiped on exit.
_cbx_ssh() {
	ssh -t "$CBX_SERVER" "$1"
}

# Long-lived interactive sessions: ssh by default, mosh when CBX_TRANSPORT=mosh (roaming). ssh runs
# the string through the remote login shell directly; mosh execs it, so we wrap in `bash -lc` — either
# way exactly one server-side shell parses it, so the $(docker ps …) hub lookup expands there. mosh
# always allocates a PTY (no `-t`); both keep host-key auth via ssh. The `:-ssh` fallback matches the
# `: "${CBX_TRANSPORT:=ssh}"` default above, so an empty value still means ssh, not mosh.
_cbx_session() {
	if [ "${CBX_TRANSPORT:-ssh}" = mosh ]; then
		mosh "$CBX_SERVER" -- bash -lc "$1"
	else
		ssh -t "$CBX_SERVER" "$1"
	fi
}

# The `-e …` flags every `docker exec` below needs, because docker propagates NOTHING from your
# environment into the container:
#   TERM  docker hands the container TERM=dumb, which has no `clear`, so tmux dies with "terminal does
#         not support clear". We forward YOUR real $TERM (e.g. xterm-ghostty, which the box bakes).
#         CBX_TERM is an opt-in override for terminals the box has no terminfo for (xterm-kitty →
#         `export CBX_TERM=xterm-256color`). Empty $TERM and no CBX_TERM = no flag, docker's default.
#   LANG  without a UTF-8 locale tmux renders every non-ASCII glyph as '_' — claude's logo and box
#         borders come out as underscores. The images now set LANG=C.UTF-8 themselves, so this is
#         belt-and-braces for boxes still running an older image. Override with CBX_LANG.
_cbx_env() {
	local term="${CBX_TERM:-$TERM}" opt=''
	[ -n "$term" ] && opt="-e TERM=$term "
	printf '%s-e LANG=%s ' "$opt" "${CBX_LANG:-C.UTF-8}"
}

# The `docker exec` into the hub, resolved by compose labels at call time. Emitted as a literal
# string (the $(docker ps …) subshell is left for the server to evaluate); $CBX_PROJECT is inlined.
_cbx_hub() {
	printf 'docker exec -it %s$(docker ps -q -f label=com.docker.compose.project=%s -f label=com.docker.compose.service=hub)' "$(_cbx_env)" "$CBX_PROJECT"
}

# run any cbx subcommand on the remote hub:  cbx up backend / cbx ls / cbx box work1 / cbx --help
# %q re-quotes each arg so it survives the server-side shell re-parse (e.g. cbx fix work1 -m "a b c").
# `cbx logs` attaches a live tmux window (interactive) → routed through the mosh-able transport; every
# other subcommand is one-shot text output → ssh, so it prints and stays on your terminal.
cbx() {
	local args=''
	[ "$#" -gt 0 ] && printf -v args ' %q' "$@"
	if [ "${1:-}" = logs ]; then
		_cbx_session "$(_cbx_hub) cbx$args"
	else
		_cbx_ssh "$(_cbx_hub) cbx$args"
	fi
}

# drop into a PERSISTENT shell inside the hub, in tmux, so you can detach (Ctrl-b d) and reconnect
# any time to resume where you left off — `new-session -A` attaches the 'cbxhub' session if it's
# already running, else creates it (tmux starts it as a login shell). It's a dedicated session,
# separate from the 'services' session that `cbx logs` uses. Runs as the hub's uid-1000 'dev' user
# (the owner of the hub tmux server); for a root shell add `-u root` after `exec -it` — but that's a
# separate, empty tmux server, so use `bash -l` instead of the tmux part for root.
cbxhub() {
	_cbx_session "$(_cbx_hub) tmux new-session -A -s cbxhub -c /home/dev/repo"
}

# attach to an agent box by name (Ctrl-b d to detach):  cbxbox work1
# the name lands in the MIDDLE of the command (box-<project>-<name>). -u dev: claude's tmux session
# runs under the box's 'dev' user, not root (root's tmux socket is empty → "no sessions"). The -e
# flags come from _cbx_env (TERM + LANG) — see there for why both are needed.
cbxbox() {
	_cbx_session "docker exec -it -u dev $(_cbx_env)box-${CBX_PROJECT}-$1 tmux attach -t main"
}

# open a psql shell on the stack's postgres (the `db` service) against the DB name given as an arg:
#   cbxpsql infotrack_dev
# The db container is resolved by its compose labels (survives renames), like the hub. psql runs as the
# container's `postgres` OS user, so it connects over the local socket with peer auth — no password.
# Pass CBX_DB_USER to connect as a specific db user instead (psql then prompts; type the password —
# never baked in here). Override the service with CBX_DB_SERVICE. Anything AFTER the dbname is passed
# straight to psql. Both interactive and piped SQL work:
#   cbxpsql infotrack_dev                                      # interactive REPL (clipboard works)
#   echo 'SELECT 1;' | cbxpsql infotrack_dev                   # pipe SQL in
#   cbxpsql infotrack_dev --single-transaction < dump.sql      # load a file atomically (all-or-nothing)
#   cbxpsql infotrack_dev -v ON_ERROR_STOP=1 -tA < q.sql       # stop on first error, tab/unaligned out
# When stdin is a terminal we allocate a TTY (-it / ssh -t); when it's a pipe we don't (-i / ssh -T)
# and stream stdin straight through. Extra args are %q-quoted so they survive the server-side shell
# re-parse; the $(docker ps …) lookup is left for the server to expand.
cbxpsql() {
	[ -n "$1" ] || { echo "usage: cbxpsql <dbname> [psql args…]   (e.g. cbxpsql infotrack_dev --single-transaction < f.sql)" >&2; return 2; }
	local db="$1"; shift
	local u=''; [ -n "${CBX_DB_USER:-}" ] && u="-U $CBX_DB_USER "
	local extra=''; [ "$#" -gt 0 ] && printf -v extra ' %q' "$@"
	local dflags sshflag
	if [ -t 0 ]; then dflags='-it'; sshflag='-t'; else dflags='-i'; sshflag='-T'; fi
	ssh "$sshflag" "$CBX_SERVER" "docker exec $dflags -u postgres \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=${CBX_DB_SERVICE:-db}) psql ${u}${extra} ${db}"
}

# cbxtun — one SSH tunnel to reach hub and/or agent-box (cbox) dev services from your laptop, so you
# can drive the UI in your own browser. ALWAYS ssh (mosh can't port-forward). Each argument is a
# forward spec; combine as many as you like in ONE command:
#     PORT                hub PORT          -> laptop 127.0.0.1:PORT
#     hub:PORT            hub PORT          -> laptop 127.0.0.1:PORT
#     <box>:PORT          box <box> PORT    -> laptop 127.0.0.1:PORT
#     LOCAL:hub:PORT      hub PORT          -> laptop 127.0.0.1:LOCAL
#     LOCAL:<box>:PORT    box <box> PORT    -> laptop 127.0.0.1:LOCAL
# No args = hub:4200 (the old cbxui default). The laptop listens on 127.0.0.1 at the SAME port numbers
# by default, mirroring the hub's localhost layout — so a frontend's `http://localhost:PORT` backend
# URL resolves in your browser exactly as it does on the hub. THE key case, frontend on a box + backend
# on the hub, in one command:
#     cbxtun work1:4200 hub:8080
#     -> open http://localhost:4200 ; its JS calls http://localhost:8080, tunneled to the hub backend.
# Targets are reached at the container's IP, so the service must listen on 0.0.0.0 inside its container
# (ng serve/bootRun and the box port-forward system already bind 0.0.0.0). Ctrl-C closes the tunnel.
cbxtun() {
	[ "$#" -gt 0 ] || set -- hub:4200
	local -a LP TG RP; local spec a b c
	for spec in "$@"; do
		IFS=: read -r a b c <<<"$spec"
		if   [ -n "$c" ]; then LP+=("$a"); TG+=("$b");   RP+=("$c")   # LOCAL:TARGET:PORT
		elif [ -n "$b" ]; then LP+=("$b"); TG+=("$a");   RP+=("$b")   # TARGET:PORT
		else                   LP+=("$a"); TG+=("hub");  RP+=("$a")   # PORT (hub)
		fi
	done
	# Resolve each unique target to a container IP in ONE round-trip — hub via its compose labels, a box
	# by its container name. Quoted heredoc + positional args keep local/remote quoting from clashing.
	local resolved
	resolved=$(ssh "$CBX_SERVER" bash -s "$CBX_PROJECT" $(printf '%s\n' "${TG[@]}" | sort -u) <<'REMOTE'
proj="$1"; shift
for t in "$@"; do
	if [ "$t" = hub ]; then
		ref=$(docker ps -q -f label=com.docker.compose.project="$proj" -f label=com.docker.compose.service=hub)
	else
		ref="box-$proj-$t"
	fi
	ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ref" 2>/dev/null)
	printf '%s %s\n' "$t" "$ip"
done
REMOTE
	) || { echo "cbxtun: could not reach $CBX_SERVER" >&2; return 1; }
	local -a Largs; local i t ip
	for i in "${!TG[@]}"; do
		t="${TG[$i]}"
		ip=$(printf '%s\n' "$resolved" | awk -v t="$t" '$1==t{print $2; exit}')
		[ -n "$ip" ] || { echo "cbxtun: can't resolve '$t' to a running container (hub up? box '$t' spawned?)" >&2; return 1; }
		Largs+=(-L "127.0.0.1:${LP[$i]}:$ip:${RP[$i]}")
		echo "cbxtun: http://localhost:${LP[$i]}  ->  $t:${RP[$i]}  ($ip)" >&2
	done
	echo "cbxtun: tunnel up — Ctrl-C to close" >&2
	ssh -N "${Largs[@]}" "$CBX_SERVER"
}
