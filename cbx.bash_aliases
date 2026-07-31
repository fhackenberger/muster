# cbx laptop aliases — source this from your ~/.bashrc:
#
#     export CBX_SERVER=root@hetzner1.acoveo.com   # optional: override before sourcing
#     export CBX_PROJECT=infostars
#     source /path/to/claude-box/cbx.bash_aliases
#
# The exports must be their OWN commands. `CBX_SERVER=… . cbx.bash_aliases` silently leaves the
# variable unset — see _cbx_need_server below for why. Sourcing also registers bash completion for
# subcommands, flags and live box/service names; `cbxrefresh` re-reads them before the cache TTL.
#
# Everything is driven through `cbx` inside the hub; these wrap the full `<transport> … docker exec …`
# so you don't type it each time. The hub container is resolved by its compose labels at call time (so
# it survives compose's `-1` suffix and renames) — the `$(docker ps …)` lookup runs on the SERVER,
# while $CBX_SERVER / $CBX_PROJECT are substituted locally.
#
# Two kinds of invocation, deliberately on different transports:
#   * one-shot commands (`cbx --help`, `cbx ls`, `cbx q --text`, `cbx review …`) ALWAYS use ssh, so their
#     output prints to your terminal and stays in scrollback. mosh is an alternate-screen app — it
#     would render the output and then WIPE it on exit — and it buys nothing for a sub-second command.
#   * long-lived interactive sessions (`cbxhub`, `cbxbox`, `cbx logs`, `cbx q`) honor CBX_TRANSPORT, default
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
unalias cbx cbxhub cbxbox cbxui cbxtun cbxpsql cbxfe cbxsync cbxexport cbximport cbxcp cbxexec 2>/dev/null || true
unset -f cbxui 2>/dev/null || true          # cbxui was renamed to cbxtun; drop the stale function

# Every entry point below reaches the server as plain "$CBX_SERVER" / "$CBX_PROJECT". Empty, and ssh
# reports `Could not resolve hostname : Name or service not known` — which reads as a DNS problem and
# says nothing about the missing export. The commonest way to end up there is
#     CBX_SERVER=root@host CBX_PROJECT=proj . cbx.bash_aliases
# Assignments prefixed to a command are TEMPORARY in bash (POSIX mode makes them persist for special
# builtins like `.`, but that is not the default), so they are gone by the time a function runs — and
# because the `: "${CBX_SERVER:=…}"` defaults above DID see them, they did not fall back to the
# placeholder either. The variable simply ends up unset. Fail here with the fix instead.
_cbx_need_server() {
	local hint
	printf -v hint '    export CBX_SERVER=root@your-host CBX_PROJECT=yourproject\n    source %s' \
		"${BASH_SOURCE[0]}"
	case "${CBX_SERVER:-}" in
		'')               echo "cbx: CBX_SERVER is not set." >&2 ;;
		root@your-server) echo "cbx: CBX_SERVER is still the placeholder ($CBX_SERVER)." >&2 ;;
		*)
			case "${CBX_PROJECT:-}" in
				''|myproject)
					echo "cbx: CBX_PROJECT is ${CBX_PROJECT:-not set} — it must be the stack's PROJECT_NAME (e.g. infostars)." >&2
					echo "$hint" >&2
					return 1 ;;
			esac
			return 0 ;;
	esac
	echo "cbx: export it as its own command — prefixing the assignment to \`.\`/\`source\` does NOT persist:" >&2
	echo "$hint" >&2
	return 1
}

# One-shot commands: run over ssh so stdout/stderr land on your terminal and persist in scrollback.
# `-t` gives the remote a PTY (proper width/color for `--help` etc.); ssh doesn't use an alternate
# screen, so nothing is wiped on exit.
_cbx_ssh() {
	_cbx_need_server || return 1
	ssh -t "$CBX_SERVER" "$1"
}

# Long-lived interactive sessions: ssh by default, mosh when CBX_TRANSPORT=mosh (roaming). ssh runs
# the string through the remote login shell directly; mosh execs it, so we wrap in `bash -lc` — either
# way exactly one server-side shell parses it, so the $(docker ps …) hub lookup expands there. mosh
# always allocates a PTY (no `-t`); both keep host-key auth via ssh. The `:-ssh` fallback matches the
# `: "${CBX_TRANSPORT:=ssh}"` default above, so an empty value still means ssh, not mosh.
_cbx_session() {
	_cbx_need_server || return 1
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
# `cbx logs` attaches a live tmux window and bare `cbx q` is the live dashboard — both are long-lived
# and interactive → routed through the mosh-able transport; every other subcommand is one-shot text
# output → ssh, so it prints and stays on your terminal. `cbx q --text` is one-shot, so it stays on
# ssh with the rest. Either transport carries the dashboard's bell (it's a plain BEL byte).
cbx() {
	local args='' live=''
	[ "$#" -gt 0 ] && printf -v args ' %q' "$@"
	case "${1:-}" in
		logs) live=1 ;;
		q|queue) case "${2:-}" in --text|--once|-1) ;; *) live=1 ;; esac ;;
	esac
	if [ -n "$live" ]; then
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
	_cbx_need_server || return 1
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
	_cbx_need_server || return 1
	[ "$#" -gt 0 ] || set -- "hub:${CBX_FRONTEND_PORT:-4211}"
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

# ---------------------------------------------------------------------------------------------
# PROJECT-SPECIFIC shorthand (infostars ports): open ONE agent's frontend on your laptop.
#
#   cbxfe work1        -> http://localhost:4211 serves box 'work1' ng serve
#
# More than one forward is needed. The page comes from the box's dev server, but its JS calls
# FRONTEND_DEV_BACKEND_URL — and YOUR BROWSER resolves that URL, so whatever host:port it names has to
# exist on your laptop and lead to the right backend. There are two possibilities and the agent picks
# freely between them at runtime, so we tunnel BOTH rather than make you guess:
#   * the HUB's backend            -> http://localhost:8091   (the default)
#   * the box's OWN backend        -> http://localhost:<8900+slot>, i.e. that box's BACKEND
#                                     port-forward, which is what $FRONTEND_DEV_BACKEND_URL_OWN is
# Getting this wrong is not obvious from the browser: the page loads fine and only its API calls fail
# (ERR_CONNECTION_REFUSED on e.g. http://localhost:8904/infostarsWeb/rest/config), which reads like a
# broken backend rather than a missing tunnel. Hence: forward both, always.
#
# We read the box's own PORT_FORWARD_BACKEND_TO_HUB to learn the 8900+slot number, then tunnel it
# straight to the BOX (the hub-side socat binds the hub's loopback, which ssh -L cannot reach). The
# two backend ports never collide, so both can be up at once.
#
# --own tunnels ONLY the box's own backend, leaving :8091 free on your laptop — for when you are
# running a backend of your own there and cannot give the port up.
#
# Ports come from service-env: FRONTEND_DEV_PORT / SERVER_PORT. Override per call with
# CBX_FRONTEND_PORT / CBX_BACKEND_PORT if a stack uses different ones.
cbxfe() {
	_cbx_need_server || return 1
	local box="" own="" a fe="${CBX_FRONTEND_PORT:-4211}" be="${CBX_BACKEND_PORT:-8091}" hubport
	for a in "$@"; do case "$a" in --own) own=1 ;; *) box="$a" ;; esac; done
	[ -n "$box" ] || { echo "usage: cbxfe <box> [--own]   (--own = the box's own backend only, no :$be)" >&2; return 1; }
	# The box's own BACKEND forward (8900+slot). Set on every running box by claude-box.sh, so an empty
	# result means the box isn't up rather than that it has no such backend.
	hubport=$(ssh "$CBX_SERVER" "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' box-${CBX_PROJECT}-${box} 2>/dev/null | sed -n 's/^PORT_FORWARD_BACKEND_TO_HUB=//p'")
	local -a specs=("${box}:${fe}"); local desc=""
	[ -n "$own" ] || { specs+=("hub:${be}"); desc=" :${be} (hub)"; }
	if [ -n "$hubport" ]; then
		specs+=("${hubport}:${box}:${be}"); desc="${desc} :${hubport} (the box's own)"
	elif [ -n "$own" ]; then
		echo "cbxfe: no BACKEND forward for '$box' (is it running?)" >&2; return 1
	else
		# Non-fatal: the hub backend is still tunneled, and that is the URL the frontend uses by default.
		echo "cbxfe: no BACKEND forward for '$box' (is it running?) — tunneling the hub backend only" >&2
	fi
	echo "cbxfe: $box -> frontend :$fe, backend${desc}" >&2
	cbxtun "${specs[@]}"
}

# take new commits from origin onto the dev branch, then tell every agent to re-base on them:
#
#   cbxsync              # merge origin into the dev branch, then have the agents rebase
#   cbxsync --rebase     # ...rebasing the hub's branch instead of merging
#
# Two steps because they are two different repos: `cbx pull` moves the HUB's branch, `cbx rebase all`
# types a rebase instruction into each agent's claude session (their branches are their own clones).
# Deliberately NOT one remote command: `a && b` in the ssh string would run b on the SERVER rather
# than inside the hub container. Skips the rebase if the pull failed (conflicts to resolve first),
# since rebasing agents onto a half-merged branch only spreads the mess.
cbxsync() {
	cbx pull "$@" || { echo "cbxsync: pull failed — agents NOT notified" >&2; return 1; }
	cbx rebase all
	echo "cbxsync: agents were asked to rebase; they act when they pick the message up. 'cbx status' for the queue." >&2
}

# The `docker exec` into the hub container, resolved by compose labels at call time — same as _cbx_hub
# but with `docker exec -i` (NO -t): the two commands below MOVE A PATCH over the pipe, and a PTY would
# translate newlines and corrupt it. We can't reuse the `cbx()` wrapper for that reason (it uses
# `ssh -t`). ssh runs WITHOUT -t as well, so the byte stream is clean end to end.
_cbx_hub_pipe() {
	printf 'docker exec -i $(docker ps -q -f label=com.docker.compose.project=%s -f label=com.docker.compose.service=hub)' "$CBX_PROJECT"
}

# cbxexport <box> [git am args…] — pull an agent's work onto YOUR checkout as ONE squashed commit.
# Runs `cbx export` on the hub and pipes its mbox straight into `git am` here, in one command. The
# commit carries the agent's handoff summary as its message. Run it from inside your local checkout.
#   cbxexport work1                 # apply the squashed change as a new commit on your branch
#   cbxexport work1 --3way          # …with 3-way fallback if context is fuzzy
# To eyeball the patch instead of applying:  cbxexport work1 --show   (writes it to STDOUT, no am)
cbxexport() {
	_cbx_need_server || return 1
	[ -n "${1:-}" ] || { echo "usage: cbxexport <box> [git am args…]   (run inside your local checkout)" >&2; return 2; }
	local box="$1"; shift
	if [ "${1:-}" = --show ]; then
		ssh -T "$CBX_SERVER" "$(_cbx_hub_pipe) cbx export $box"
		return
	fi
	ssh -T "$CBX_SERVER" "$(_cbx_hub_pipe) cbx export $box" | git am "$@"
}

# cbximport <box> [base-ref] — REPLACE an agent's branch with YOUR change and tell the box to just
# note it (not act). Collapses everything on HEAD since <base-ref> (default 'dev') into ONE patch —
# the net change, exactly as it will land on the hub's dev — and pipes it to `cbx import`. Mirrors
# cbxexport, so it doesn't matter how many commits you made or whether you built on top of the agent's
# export: only the end state travels. Run it from inside your local checkout, on the branch that holds
# your final version. Nothing local is modified.
#   cbximport work1                 # net change of HEAD vs your 'dev' branch replaces the agent branch
#   cbximport work1 origin/dev      # …measuring the net change against origin/dev instead
# The hub repoints refs/agents/<box> at your commit, records it as reviewed, and messages the box.
cbximport() {
	_cbx_need_server || return 1
	[ -n "${1:-}" ] || { echo "usage: cbximport <box> [base-ref]   base defaults to 'dev'   (run inside your checkout)" >&2; return 2; }
	local box="$1" base="${2:-dev}" sq
	git rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1 \
		|| { echo "cbximport: base ref '$base' not found — pass the branch your change sits on top of: cbximport $box <base>" >&2; return 2; }
	# One throwaway commit whose diff is HEAD's whole tree vs <base> — a single net patch that applies on
	# the hub's dev by context. commit-tree writes an object referenced by no branch, so HEAD is untouched.
	sq="$(git commit-tree "HEAD^{tree}" -p "$(git rev-parse "$base")" -m "$(git log -1 --format=%B HEAD)")" \
		|| { echo "cbximport: could not assemble the patch" >&2; return 1; }
	git format-patch --stdout --binary -1 "$sq" \
		| ssh -T "$CBX_SERVER" "$(_cbx_hub_pipe) cbx import $box"
}

# cbxcp <src> <dst> — copy a file or a WHOLE DIRECTORY between a box / the hub and your laptop, in
# either direction. The general-purpose transfer; cbxexport/cbximport above move repo *changes* as a
# git patch, which is the right tool for code but useless for a log, a screenshot or a built artifact.
#
#   cbxcp work1:/home/dev/repo/build/out.log .     # box   -> laptop (into the current dir)
#   cbxcp work1:/home/dev/repo/build/libs .        # …a whole directory, same syntax
#   cbxcp hub:/work/boxes/work1/state ./state      # hub   -> laptop, renaming on the way
#   cbxcp ./fix.patch work1:/home/dev              # laptop -> box
#
# Exactly ONE side carries a `<target>:` prefix — a box name, or `hub`; the other side is local. A
# leading '/' or './' means local, so /tmp/a:b is never mistaken for a target.
#
# Everything moves as a tar stream over `docker exec -i`, which is what makes files and directories
# one code path (modes and symlinks survive) and what avoids a temp copy on the server: there is no
# `docker cp` to the host and then an scp, just one pipe end to end. NO `ssh -t` and no `docker exec
# -t` anywhere — a PTY rewrites newlines and would corrupt any binary payload, the same trap
# _cbx_hub_pipe documents for the patch pipes.
#
# The destination is resolved on the RECEIVING side by $_CBX_CP_RX: extract into it if it is an
# existing directory, otherwise treat it as the new name. Identical semantics whichever way you copy,
# and it needs no extra round-trip to probe the far end first.
_CBX_CP_RX='d=$1; t=$(mktemp -d); tar -C "$t" -xf -; if [ -d "$d" ]; then mv "$t"/* "$d"/; else mkdir -p "$(dirname "$d")"; mv "$t"/* "$d"; fi; rmdir "$t"'
cbxcp() {
	_cbx_need_server || return 1
	local usage="usage: cbxcp <src> <dst>   ONE side is <box>:<path> or hub:<path>, e.g. cbxcp work1:/home/dev/repo/x.log ."
	local re='^([A-Za-z0-9][A-Za-z0-9_.-]*):(.+)$'
	local src="${1:-}" dst="${2:-}" s_t="" s_p="" d_t="" d_p="" ex
	[ -n "$src" ] || { echo "$usage" >&2; return 2; }
	[[ $src =~ $re ]] && { s_t="${BASH_REMATCH[1]}"; s_p="${BASH_REMATCH[2]}"; }
	# A remote source may omit the destination — like `cp x .`, the common "just grab it" case.
	[ -n "$dst" ] || { [ -n "$s_t" ] && dst=.; }
	[ -n "$dst" ] || { echo "$usage" >&2; return 2; }
	[[ $dst =~ $re ]] && { d_t="${BASH_REMATCH[1]}"; d_p="${BASH_REMATCH[2]}"; }
	[ -n "$s_t$d_t" ] || { echo "cbxcp: neither side names a box or the hub — nothing to copy to/from" >&2; echo "$usage" >&2; return 2; }
	[ -z "$s_t" ] || [ -z "$d_t" ] || { echo "cbxcp: both sides are remote ('$s_t' and '$d_t') — copy via your laptop in two steps" >&2; return 2; }
	# The `docker exec -i <container>` prefix, evaluated on the SERVER. The hub is found by its compose
	# labels (it survives renames and compose's -1 suffix); a box is named by convention, as in cbxtun.
	if [ "${s_t:-$d_t}" = hub ]; then ex="$(_cbx_hub_pipe)"; else ex="docker exec -i box-${CBX_PROJECT}-${s_t:-$d_t}"; fi
	if [ -n "$s_t" ]; then
		echo "cbxcp: $s_t:$s_p -> $dst" >&2
		# dirname/basename are pure string work, so they are computed here and the far side just tars.
		ssh -T "$CBX_SERVER" "$ex tar -C '$(dirname "$s_p")' -cf - '$(basename "$s_p")'" \
			| sh -c "$_CBX_CP_RX" sh "$dst"
	else
		[ -e "$src" ] || { echo "cbxcp: no such file or directory: $src" >&2; return 1; }
		echo "cbxcp: $src -> $d_t:$d_p" >&2
		tar -C "$(dirname "$src")" -cf - "$(basename "$src")" \
			| ssh -T "$CBX_SERVER" "$ex sh -c '$_CBX_CP_RX' sh '$d_p'"
	fi
}

# cbxexec <box|hub> <command…> — run ANY command in a box or the hub and get its output here, clean
# enough to pipe into your local tools:
#
#   cbxexec work1 gradle -q :infostarsEJB:test | tee test.log
#   cbxexec work1 cat /home/dev/repo/build/reports/x.json | jq .failures
#   cbxexec hub 'cbx q --text' | grep -i blocked
#   cbxexec work1 'grep -rn TODO /home/dev/repo | wc -l'     # …the pipe runs IN the box
#   tar -cf - ./seed | cbxexec work1 'tar -C /tmp -xf -'     # …and stdin flows the other way
#
# The arguments are joined with spaces and handed to `sh -c` INSIDE the container, so where you put
# the quotes decides where a pipe runs: unquoted, your local shell takes it and the box's stdout flows
# into your local tool (the usual case); quoted, the box's own shell does. Because it is `sh -c`, `cd
# x && …`, redirection and globbing all work as you would type them there.
#
# NO PTY on either hop (`ssh -T`, `docker exec -i`, never -t): stdout stays byte-exact and stdin is
# forwarded, so this pipes in both directions and survives binary payloads. That is the whole
# difference from `cbxbox`, which is the interactive tmux attach and deliberately allocates one.
# stderr stays on stderr, so a local pipe sees only real output — diagnostics still reach your
# terminal. The exit status is the command's own, so `cbxexec work1 test -e /x && …` works.
#
# The command travels base64-encoded. It is decoded on the SERVER and passed to `sh -c` as a single
# argument, which sidesteps the two layers of shell re-parsing (ssh's, then the server's) that would
# otherwise mangle every quote, $ and backtick you send.
cbxexec() {
	_cbx_need_server || return 1
	local tgt="${1:-}" ex b64
	[ -n "$tgt" ] && [ "$#" -ge 2 ] || { echo "usage: cbxexec <box|hub> <command…>   e.g. cbxexec work1 cat /home/dev/repo/build/out.log | less" >&2; return 2; }
	shift
	if [ "$tgt" = hub ]; then ex="$(_cbx_hub_pipe)"; else ex="docker exec -i box-${CBX_PROJECT}-${tgt}"; fi
	b64=$(printf '%s' "$*" | base64 | tr -d '\n')
	ssh -T "$CBX_SERVER" "$ex sh -c \"\$(printf %s $b64 | base64 -d)\""
}

# ---------------------------------------------------------------------------------------------
# BASH COMPLETION for cbx / cbxbox / cbxfe / cbxtun.
#
# Box and service names live on the SERVER, so completing them means an ssh round-trip — far too slow
# to run on every Tab. So the names are fetched once and cached in a file for $CBX_COMPLETE_TTL
# seconds (default 60); every Tab inside that window is a local `awk`. `cbxrefresh` busts the cache
# when you have just spawned or killed a box and don't want to wait the TTL out.
#
# The fetch asks the HUB, not docker, for boxes: `cbx ls` gets its list from the broker (authoritative
# — it knows boxes docker naming conventions wouldn't reveal), and refs/agents/* adds boxes that are
# no longer running but still have a handoff waiting for review, which is exactly when you want to
# complete `cbx review <Tab>`. Output is normalised to "svc <name>" / "box <name>" lines remotely, so
# the laptop side never parses cbx's human-readable table.
#
# BatchMode + ConnectTimeout are load-bearing: without them a server that is down or wants a password
# makes Tab hang the terminal. On any failure we keep the previous cache and complete nothing new.

: "${CBX_COMPLETE_TTL:=60}"

_cbx_cache_file() {
	printf '%s/cbx-complete.%s.%s' "${TMPDIR:-/tmp}" "${CBX_PROJECT:-none}" "${UID:-0}"
}

# Loading indicator for the one Tab in sixty that actually goes over the wire. This CANNOT be a
# printed message: readline owns the line while a completion function runs, so anything written into
# the display gets overwritten or leaves debris. OSC 9;4 is the escape that exists for exactly this —
# it drives the TERMINAL's own progress reporting (taskbar/tab indicator), not the text grid, so the
# command line is never touched. `3` = indeterminate, `0` = clear. Ghostty, WezTerm, Windows Terminal
# and ConEmu implement it; terminals that don't simply ignore the sequence (it's an OSC, so it is
# swallowed, not printed). Writes to /dev/tty because completion's stdout is a capture pipe.
# Set CBX_COMPLETE_PROGRESS=0 to suppress.
_cbx_progress() {
	[ "${CBX_COMPLETE_PROGRESS:-1}" = 1 ] && [ -w /dev/tty ] || return 0
	case "$1" in
		on)  printf '\033]9;4;3;0\033\\' > /dev/tty 2>/dev/null ;;
		off) printf '\033]9;4;0;0\033\\' > /dev/tty 2>/dev/null ;;
	esac
	return 0
}

_cbx_complete_fetch() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 "$CBX_SERVER" bash -s "$CBX_PROJECT" 2>/dev/null <<'REMOTE'
proj="$1"
hub=$(docker ps -q -f label=com.docker.compose.project="$proj" -f label=com.docker.compose.service=hub) || exit 0
[ -n "$hub" ] || exit 0
# `cbx ls` = services table + broker box table. Tag each section's first column and drop anything that
# isn't a bare name, which throws away the "(broker unreachable)" / "(none — drop a manifest …)" lines.
docker exec "$hub" cbx ls 2>/dev/null | awk '
	/^== services/ { sec="svc"; next }
	/^== boxes/    { sec="box"; next }
	/^==/          { sec="";    next }
	sec != "" && $1 ~ /^[A-Za-z0-9][-A-Za-z0-9_]*$/ { print sec, $1 }'
# Boxes with a handoff waiting but no running container — review/merge/drop still apply to them.
docker exec "$hub" git -C /home/dev/repo for-each-ref --format='box %(refname:strip=2)' refs/agents/ 2>/dev/null
REMOTE
}

# Cached names, refreshed when the file is older than the TTL. A failed fetch leaves the old cache in
# place (the write goes to .tmp and is only moved on success), so a brief network blip doesn't wipe
# completion — and the mv is atomic, so a concurrent Tab never reads a half-written file.
_cbx_complete_cache() {
	local f now mtime
	[ -n "${CBX_SERVER:-}" ] && [ -n "${CBX_PROJECT:-}" ] || return 0
	f="$(_cbx_cache_file)"
	now=$(date +%s)
	mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
	# -e, not -s: a failed fetch leaves an EMPTY cache file behind on purpose (see the touch below), and
	# testing for size would make every keystroke retry the ssh that just failed.
	if [ ! -e "$f" ] || [ "$((now - mtime))" -ge "$CBX_COMPLETE_TTL" ]; then
		_cbx_progress on
		if _cbx_complete_fetch > "$f.tmp" 2>/dev/null && [ -s "$f.tmp" ]; then
			mv -f "$f.tmp" "$f"
		else
			rm -f "$f.tmp"
			touch "$f" 2>/dev/null   # don't retry the failing ssh on every keystroke
		fi
		_cbx_progress off
	fi
	cat "$f" 2>/dev/null
}

_cbx_names() { _cbx_complete_cache | awk -v k="$1" '$1==k {print $2}' | sort -u; }

# Force the next Tab to re-fetch — after `cbx box foo`, `cbx kill foo`, or a handoff.
cbxrefresh() { rm -f "$(_cbx_cache_file)"; _cbx_complete_cache >/dev/null; echo "cbx: completion cache refreshed"; }

_cbx_complete() {
	local cur cmd sub
	cur="${COMP_WORDS[COMP_CWORD]}"
	cmd="${COMP_WORDS[1]:-}"
	COMPREPLY=()

	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W "svcs up down logs autostart box kill recreate ls forwards
			status q review fix prereview merge drop rebase export import pull push
			golden expose hide" -- "$cur"))
		return
	fi

	# Flags first: once the word starts with '-' the positional rules below don't apply.
	if [[ $cur == -* ]]; then
		local flags=""
		case "$cmd" in
			review)    flags="--full --net --tui --plain" ;;
			merge)     flags="--squash --edit" ;;
			fix)       flags="-m --force" ;;
			prereview) flags="--force" ;;
			rebase)    flags="--force" ;;
			recreate)  flags="--fresh" ;;
			q|queue)   flags="--text --once --no-bell -n" ;;
			pull)      flags="--rebase" ;;
			golden)    [ "${COMP_WORDS[2]:-}" = snapshot ] && flags="--prep" ;;
		esac
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		return
	fi

	case "$cmd" in
		up|down)   COMPREPLY=($(compgen -W "$(_cbx_names svc)" -- "$cur")) ;;
		logs)      COMPREPLY=($(compgen -W "$(_cbx_names svc) gitd" -- "$cur")) ;;
		# `box` takes a NEW name (nothing to complete); `import`/`export` and every review-queue verb
		# take an existing one.
		kill|forwards|review|fix|prereview|merge|drop|export|import)
		           COMPREPLY=($(compgen -W "$(_cbx_names box)" -- "$cur")) ;;
		recreate|rebase)
		           COMPREPLY=($(compgen -W "$(_cbx_names box) all" -- "$cur")) ;;
		golden)    [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "snapshot seal ls reap" -- "$cur")) ;;
		expose|hide) COMPREPLY=($(compgen -f -- "$cur")) ;;
	esac
	return 0    # a case arm whose last test failed would otherwise make readline see an error
}

_cbx_complete_boxonly() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	if [[ $cur == -* ]]; then
		local flags=""
		case "${COMP_WORDS[0]}" in cbxfe) flags="--own" ;; cbxexport) flags="--show --3way" ;; esac
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		return 0
	fi
	[ "$COMP_CWORD" -eq 1 ] && COMPREPLY=($(compgen -W "$(_cbx_names box)" -- "$cur"))
	return 0
}

# cbximport's second word is a LOCAL base ref (the branch your change sits on top of), so it completes
# from your own checkout rather than from the server — no cache involved.
_cbx_complete_import() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$COMP_CWORD" in
		1) COMPREPLY=($(compgen -W "$(_cbx_names box)" -- "$cur")) ;;
		2) COMPREPLY=($(compgen -W "$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null)" -- "$cur")) ;;
	esac
	return 0
}

# cbxtun specs are TARGET:PORT (or LOCAL:TARGET:PORT). We only complete the target half — the port is
# yours to pick — and suppress the trailing space so you can type the ':PORT' straight on.
_cbx_complete_tun() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$cur" in
		*:*) COMPREPLY=() ;;                        # past the target; ports aren't ours to guess
		*)   COMPREPLY=($(compgen -S : -W "hub $(_cbx_names box)" -- "$cur"))
		     [ "${#COMPREPLY[@]}" -gt 0 ] && compopt -o nospace ;;
	esac
	return 0
}

# cbxcp takes a local path on one side and <target>:<path> on the other, so both are offered at once:
# local files from compgen -f, plus `hub:`/`<box>:` prefixes with the space suppressed so the remote
# path can be typed straight on. Remote paths themselves are not completed — that would need an ssh
# round-trip per Tab, which is exactly what the name cache exists to avoid.
_cbx_complete_cp() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$cur" in
		*:*) COMPREPLY=() ;;                        # past the target; the far side's paths are unknown here
		*)   COMPREPLY=($(compgen -S : -W "hub $(_cbx_names box)" -- "$cur"))
		     [ "${#COMPREPLY[@]}" -gt 0 ] && compopt -o nospace
		     COMPREPLY+=($(compgen -f -- "$cur")) ;;
	esac
	return 0
}

# cbxexec's first word is the target (a box, or the hub); everything after it is the command, which
# only the container could complete — so we complete word 1 and then get out of the way.
_cbx_complete_exec() {
	[ "$COMP_CWORD" -eq 1 ] && COMPREPLY=($(compgen -W "hub $(_cbx_names box)" -- "${COMP_WORDS[1]}"))
	return 0
}

if [ -n "${BASH_VERSION:-}" ]; then
	complete -F _cbx_complete cbx
	complete -F _cbx_complete_boxonly cbxbox cbxfe cbxexport
	complete -F _cbx_complete_import cbximport
	complete -F _cbx_complete_tun cbxtun
	complete -F _cbx_complete_cp cbxcp
	complete -F _cbx_complete_exec cbxexec
	complete -W '--rebase' cbxsync
fi
