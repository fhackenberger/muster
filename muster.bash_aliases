# cbx laptop aliases — source this from your ~/.bashrc, then declare one line per stack:
#
#     source /path/to/muster/muster.bash_aliases
#     muster_stack cbx root@your.server myproject        # -> cbx, cbxhub, cbxbox, cbxtun, cbxexec, …
#     source /path/to/muster/muster.bash_aliases.project cbx    # optional project helpers
#
# THE PREFIX IS YOURS TO CHOOSE, and you can declare as many stacks as you like — that is the point.
# The commands are shell functions, so before the factory a second stack could only be reached by
# re-sourcing this file and losing the first:
#
#     muster_stack app root@server1 myapp        # -> app, apphub, appbox, apptun, …
#     muster_stack lab root@server2 labstack     # -> lab, labhub, labbox, labtun, …
#
# Each family carries its own server and project, so `app q` and `lab q` talk to different hubs from
# the same shell, with separate completion caches. Set MUSTER_PREFIX in a stack's .env to the same value
# and the hub symlinks its own CLI to that name too, so `app q` works identically once you are inside
# `apphub`. See muster_stack at the bottom of this file.
#
# THE OLD FORM STILL WORKS: export MUSTER_SERVER/MUSTER_PROJECT and source this file, and it registers the
# `cbx…` family for you. The exports must be their OWN commands — `MUSTER_SERVER=… . muster.bash_aliases`
# silently leaves the variable unset, see _muster_need_server below for why.
#
# Sourcing also registers bash completion for subcommands, flags and live box/service names;
# `<prefix>refresh` re-reads them before the cache TTL.
#
# Everything is driven through `cbx` inside the hub; these wrap the full `<transport> … docker exec …`
# so you don't type it each time. The hub container is resolved by its compose labels at call time (so
# it survives compose's `-1` suffix and renames) — the `$(docker ps …)` lookup runs on the SERVER,
# while $MUSTER_SERVER / $MUSTER_PROJECT are substituted locally.
#
# Two kinds of invocation, deliberately on different transports:
#   * one-shot commands (`cbx --help`, `cbx ls`, `cbx q --text`, `cbx review …`) ALWAYS use ssh, so their
#     output prints to your terminal and stays in scrollback. mosh is an alternate-screen app — it
#     would render the output and then WIPE it on exit — and it buys nothing for a sub-second command.
#   * long-lived interactive sessions (`cbxhub`, `cbxbox`, `cbx logs`, `cbx q`) honor MUSTER_TRANSPORT, default
#     ssh. Set MUSTER_TRANSPORT=mosh — per call (`MUSTER_TRANSPORT=mosh cbxhub`) or globally — for roaming
#     (survives laptop sleep, Wi-Fi→LTE, IP changes, no frozen sessions). Trade-off: mosh can't carry
#     the clipboard (OSC 52), so terminal copy from claude only reaches your laptop clipboard on ssh.
# mosh needs UDP 60000-61000 open to the server (see tasks/firewall.yml) and uses ssh only for the
# initial handshake, so key auth is unchanged. `cbxtun` is always ssh — mosh can't port-forward.
# NOTE: an exported MUSTER_TRANSPORT in your environment/~/.bashrc WINS over the default set here — the
# `:=` below only assigns when it's unset. `echo "$MUSTER_TRANSPORT"` if a transport change seems ignored.

# BACK-COMPAT: the config variables were CBX_* before the project was named muster. A ~/.bashrc that
# still exports the old names keeps working — each is copied to its MUSTER_ counterpart if that one is
# unset — with one notice per shell so it does not nag. Delete this block once your ~/.bashrc and every
# stack .env have moved over.
_muster_compat_vars() {
	local v new seen=""
	for v in ${!CBX_@}; do
		new="MUSTER_${v#CBX_}"
		[ -n "${!new:-}" ] && continue
		printf -v "$new" '%s' "${!v}"; export "$new"
		seen="$seen $v"
	done
	[ -z "$seen" ] || echo "muster: using deprecated${seen} — rename to MUSTER_* (same values)" >&2
}
_muster_compat_vars
unset -f _muster_compat_vars

# The factory was cbx_stack before the rename; keep the old spelling working.
cbx_stack() { muster_stack "$@"; }

# Set these — either export them in ~/.bashrc before sourcing, or edit the defaults here.
: "${MUSTER_SERVER:=root@your-server}"      # the muster host, e.g. root@cbx.example.com
: "${MUSTER_PROJECT:=myproject}"            # PROJECT_NAME of the stack, e.g. myproject
: "${MUSTER_TRANSPORT:=ssh}"                # transport for interactive sessions: mosh | ssh (default)
# TERM handling. `docker exec -it` does NOT propagate your terminal — it hands the container TERM=dumb,
# which has no `clear`, so tmux dies with "terminal does not support clear". So we forward YOUR real
# $TERM explicitly via `-e TERM=…`. That's your actual terminal (e.g. xterm-ghostty, which the box
# bakes), not a forced one. MUSTER_TERM is an OPT-IN override, unset by default: set it only when the box
# has no terminfo for your terminal (e.g. xterm-kitty) — `export MUSTER_TERM=xterm-256color` for a
# known-good fallback. If both are empty, no -e is added and docker's dumb default applies.

# Drop any older alias-based definitions (pre-mosh README) so the function definitions below parse —
# bash expands `cbx` as an alias mid-parse otherwise, failing with "syntax error near `('". Harmless
# when none exist; also lets you re-source this file cleanly.
unalias cbx cbxhub cbxbox mustertun cbxtun cbxsync cbxexport cbximport cbxcp cbxexec 2>/dev/null || true
unset -f mustertun 2>/dev/null || true          # mustertun was renamed to cbxtun; drop the stale function

# Every entry point below reaches the server as plain "$MUSTER_SERVER" / "$MUSTER_PROJECT". Empty, and ssh
# reports `Could not resolve hostname : Name or service not known` — which reads as a DNS problem and
# says nothing about the missing export. The commonest way to end up there is
#     MUSTER_SERVER=root@host MUSTER_PROJECT=proj . muster.bash_aliases
# Assignments prefixed to a command are TEMPORARY in bash (POSIX mode makes them persist for special
# builtins like `.`, but that is not the default), so they are gone by the time a function runs — and
# because the `: "${MUSTER_SERVER:=…}"` defaults above DID see them, they did not fall back to the
# placeholder either. The variable simply ends up unset. Fail here with the fix instead.
_muster_need_server() {
	local hint
	printf -v hint '    export MUSTER_SERVER=root@your-host MUSTER_PROJECT=yourproject\n    source %s' \
		"${BASH_SOURCE[0]}"
	case "${MUSTER_SERVER:-}" in
		'')               echo "cbx: MUSTER_SERVER is not set." >&2 ;;
		root@your-server) echo "cbx: MUSTER_SERVER is still the placeholder ($MUSTER_SERVER)." >&2 ;;
		*)
			case "${MUSTER_PROJECT:-}" in
				''|myproject)
					echo "cbx: MUSTER_PROJECT is ${MUSTER_PROJECT:-not set} — it must be the stack's PROJECT_NAME (e.g. myproject)." >&2
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
_muster_ssh() {
	_muster_need_server || return 1
	ssh -t "$MUSTER_SERVER" "$1"
}

# Long-lived interactive sessions: ssh by default, mosh when MUSTER_TRANSPORT=mosh (roaming). ssh runs
# the string through the remote login shell directly; mosh execs it, so we wrap in `bash -lc` — either
# way exactly one server-side shell parses it, so the $(docker ps …) hub lookup expands there. mosh
# always allocates a PTY (no `-t`); both keep host-key auth via ssh. The `:-ssh` fallback matches the
# `: "${MUSTER_TRANSPORT:=ssh}"` default above, so an empty value still means ssh, not mosh.
_muster_session() {
	_muster_need_server || return 1
	if [ "${MUSTER_TRANSPORT:-ssh}" = mosh ]; then
		mosh "$MUSTER_SERVER" -- bash -lc "$1"
	else
		ssh -t "$MUSTER_SERVER" "$1"
	fi
}

# The `-e …` flags every `docker exec` below needs, because docker propagates NOTHING from your
# environment into the container:
#   TERM  docker hands the container TERM=dumb, which has no `clear`, so tmux dies with "terminal does
#         not support clear". We forward YOUR real $TERM (e.g. xterm-ghostty, which the box bakes).
#         MUSTER_TERM is an opt-in override for terminals the box has no terminfo for (xterm-kitty →
#         `export MUSTER_TERM=xterm-256color`). Empty $TERM and no MUSTER_TERM = no flag, docker's default.
#   LANG  without a UTF-8 locale tmux renders every non-ASCII glyph as '_' — claude's logo and box
#         borders come out as underscores. The images now set LANG=C.UTF-8 themselves, so this is
#         belt-and-braces for boxes still running an older image. Override with MUSTER_LANG.
_muster_env() {
	local term="${MUSTER_TERM:-$TERM}" opt=''
	[ -n "$term" ] && opt="-e TERM=$term "
	printf '%s-e LANG=%s ' "$opt" "${MUSTER_LANG:-C.UTF-8}"
}

# The `docker exec` into the hub, resolved by compose labels at call time. Emitted as a literal
# string (the $(docker ps …) subshell is left for the server to evaluate); $MUSTER_PROJECT is inlined.
# Any arguments are extra `docker exec` flags, inserted before the container id.
_muster_hub() {
	local extra=''; [ "$#" -gt 0 ] && extra="$* "
	printf 'docker exec -it %s%s%s' "$(_muster_env)" "$extra" "$(muster_service_cid hub)"
}

# run any cbx subcommand on the remote hub:  cbx up backend / cbx ls / cbx box work1 / cbx --help
# %q re-quotes each arg so it survives the server-side shell re-parse (e.g. cbx fix work1 -m "a b c").
# `cbx logs` attaches a live tmux window and bare `cbx q` is the live dashboard — both are long-lived
# and interactive → routed through the mosh-able transport; every other subcommand is one-shot text
# output → ssh, so it prints and stays on your terminal. `cbx q --text` is one-shot, so it stays on
# ssh with the rest. Either transport carries the dashboard's bell (it's a plain BEL byte).
#
# IT RUNS `muster`, NOT THE PREFIX. `muster` is in every image; the prefix is a symlink the hub's
# entrypoint makes from MUSTER_PREFIX, so it exists only once that variable has actually reached the
# container — and until the stack's .env has been redeployed it has not. That is a `docker exec`
# failing with `"cbx": executable file not found in $PATH`, from a laptop where everything looks
# configured. MUSTER_SELF carries the name you typed instead, so the usage and error messages still
# say `cbx merge`, and nothing depends on a symlink existing.
_muster_run() {
	local args='' live='' self="${_MUSTER_SELF:-muster}"
	[ "$#" -gt 0 ] && printf -v args ' %q' "$@"
	case "${1:-}" in
		# `logs <svc>` ATTACHES a tmux window — long-lived and interactive, so it honours the transport.
		# `logs <svc> --tail|--file` PRINTS and exits, so it must go over ssh like every other one-shot:
		# on mosh it would be rendered and then wiped, which is the opposite of the point. That matters
		# most here, because mosh has no scrollback AT ALL — attaching a failed service's window over
		# mosh gives you a pane you can never scroll back through, whatever tmux binds.
		logs)
			live=1
			case " $* " in *" --tail "*|*" --file "*) live='' ;; esac ;;
		q|queue) case "${2:-}" in --text|--once|-1) ;; *) live=1 ;; esac ;;
		# SPAWN THEN ATTACH. `box` is a one-shot that prints two lines and leaves you in front of an
		# agent you cannot see; attaching was always the next thing you typed. So it happens here, on
		# the LAPTOP side, where the interactive transport and the PTY already are — the hub cannot do
		# it, having no terminal of yours to hand the session to.
		box) _muster_box_spawn "$@"; return ;;
	esac
	if [ -n "$live" ]; then
		_muster_session "$(_muster_hub "-e MUSTER_SELF=$self") muster$args"
	else
		_muster_ssh "$(_muster_hub "-e MUSTER_SELF=$self") muster$args"
	fi
}

# `<prefix> box [name] [--no-attach]` — spawn, then attach to the agent that was created.
#
# --no-attach (or MUSTER_BOX_ATTACH=0) keeps the old behaviour, for a script that wants a box and not
# a session. Attaching is also skipped when stdout is not a terminal, because `box x | cat` asking
# tmux for a session is a hang, not a feature.
#
# THE NAME COMES FROM THE OUTPUT when you did not pass one: the hub invents a short id, and it is only
# knowable from the line it prints ("box 'abc123' up as …"). Parsing the message we print anyway beats
# a second round trip to ask what just happened.
_muster_box_spawn() {
	local self="${_MUSTER_SELF:-muster}" attach=1 name='' args='' a out rc
	local -a keep=()
	for a in "$@"; do
		case "$a" in
			--no-attach) attach=0 ;;
			-*) keep+=("$a") ;;
			*) keep+=("$a"); [ -n "$name" ] || [ "$a" = box ] || name="$a" ;;
		esac
	done
	[ "${MUSTER_BOX_ATTACH:-1}" = 1 ] || attach=0
	[ -t 1 ] || attach=0
	printf -v args ' %q' "${keep[@]}"
	# Captured rather than streamed so the box name can be read back out of it; a spawn prints its two
	# lines at the end anyway, so nothing is lost by showing them a moment later.
	out="$(_muster_ssh "$(_muster_hub "-e MUSTER_SELF=$self") muster$args")"; rc=$?
	printf '%s\n' "$out"
	[ "$rc" = 0 ] || return "$rc"
	[ "$attach" = 1 ] || return 0
	[ -n "$name" ] || name="$(printf '%s' "$out" | sed -n "s/.*box '\([^']*\)' up as.*/\1/p" | head -1)"
	[ -n "$name" ] || { echo "$self: spawned, but could not tell which box to attach to — use ${self}box <name>" >&2; return 0; }
	_muster_box_attach "$name"
}

# drop into a PERSISTENT shell inside the hub, in tmux, so you can detach (Ctrl-b d) and reconnect
# any time to resume where you left off — `new-session -A` attaches the 'cbxhub' session if it's
# already running, else creates it (tmux starts it as a login shell). It's a dedicated session,
# separate from the 'services' session that `cbx logs` uses. Runs as the hub's uid-1000 'dev' user
# (the owner of the hub tmux server); for a root shell add `-u root` after `exec -it` — but that's a
# separate, empty tmux server, so use `bash -l` instead of the tmux part for root.
_muster_hub_attach() {
	_muster_session "$(_muster_hub) tmux new-session -A -s cbxhub -c /home/dev/repo"
}

# attach to an agent box by name (Ctrl-b d to detach):  cbxbox work1
# the name lands in the MIDDLE of the command (box-<project>-<name>). -u dev: claude's tmux session
# runs under the box's 'dev' user, not root (root's tmux socket is empty → "no sessions"). The -e
# flags come from _muster_env (TERM + LANG) — see there for why both are needed.
_muster_box_attach() {
	_muster_session "docker exec -it -u dev $(_muster_env)box-${MUSTER_PROJECT}-$1 tmux attach -t main"
}

# cbxtun — one SSH tunnel to reach hub and/or agent-box (cbox) dev services from your laptop, so you
# can drive the UI in your own browser. ALWAYS ssh (mosh can't port-forward). Each argument is a
# forward spec; combine as many as you like in ONE command:
#     PORT                hub PORT          -> laptop 127.0.0.1:PORT
#     hub:PORT            hub PORT          -> laptop 127.0.0.1:PORT
#     <box>:PORT          box <box> PORT    -> laptop 127.0.0.1:PORT
#     LOCAL:hub:PORT      hub PORT          -> laptop 127.0.0.1:LOCAL
#     LOCAL:<box>:PORT    box <box> PORT    -> laptop 127.0.0.1:LOCAL
# No args = hub:4200 (the old mustertun default). The laptop listens on 127.0.0.1 at the SAME port numbers
# by default, mirroring the hub's localhost layout — so a frontend's `http://localhost:PORT` backend
# URL resolves in your browser exactly as it does on the hub. THE key case, frontend on a box + backend
# on the hub, in one command:
#     cbxtun work1:4200 hub:8080
#     -> open http://localhost:4200 ; its JS calls http://localhost:8080, tunneled to the hub backend.
# Targets are reached at the container's IP, so the service must listen on 0.0.0.0 inside its container
# (ng serve/bootRun and the box port-forward system already bind 0.0.0.0). Ctrl-C closes the tunnel.
_muster_tun() {
	_muster_need_server || return 1
	[ "$#" -gt 0 ] || set -- "hub:${MUSTER_FRONTEND_PORT:-4211}"
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
	resolved=$(ssh "$MUSTER_SERVER" bash -s "$MUSTER_PROJECT" $(printf '%s\n' "${TG[@]}" | sort -u) <<'REMOTE'
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
	) || { echo "${_MUSTER_SELF}: could not reach $MUSTER_SERVER" >&2; return 1; }
	local -a Largs; local i t ip
	for i in "${!TG[@]}"; do
		t="${TG[$i]}"
		ip=$(printf '%s\n' "$resolved" | awk -v t="$t" '$1==t{print $2; exit}')
		[ -n "$ip" ] || { echo "${_MUSTER_SELF}: can't resolve '$t' to a running container (hub up? box '$t' spawned?)" >&2; return 1; }
		Largs+=(-L "127.0.0.1:${LP[$i]}:$ip:${RP[$i]}")
		echo "${_MUSTER_SELF}: http://localhost:${LP[$i]}  ->  $t:${RP[$i]}  ($ip)" >&2
	done
	echo "${_MUSTER_SELF}: tunnel up — Ctrl-C to close" >&2
	ssh -N "${Largs[@]}" "$MUSTER_SERVER"
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
_muster_sync() {
	_muster_run pull "$@" || { echo "${_MUSTER_SELF}: pull failed — agents NOT notified" >&2; return 1; }
	_muster_run rebase all
	echo "${_MUSTER_SELF}: agents were asked to rebase; they act when they pick the message up. 'cbx status' for the queue." >&2
}

# The `docker exec` into the hub container, resolved by compose labels at call time — same as _muster_hub
# but with `docker exec -i` (NO -t): the two commands below MOVE A PATCH over the pipe, and a PTY would
# translate newlines and corrupt it. We can't reuse the `cbx()` wrapper for that reason (it uses
# `ssh -t`). ssh runs WITHOUT -t as well, so the byte stream is clean end to end.
_muster_hub_pipe() {
	printf 'docker exec -i %s' "$(muster_service_cid hub)"
}

# cbxexport <box> [git am args…] — pull an agent's work onto YOUR checkout as ONE squashed commit.
# Runs `cbx export` on the hub and pipes its mbox straight into `git am` here, in one command. The
# commit carries the agent's handoff summary as its message. Run it from inside your local checkout.
#   cbxexport work1                 # apply the squashed change as a new commit on your branch
#   cbxexport work1 --3way          # …with 3-way fallback if context is fuzzy
# To eyeball the patch instead of applying:  cbxexport work1 --show   (writes it to STDOUT, no am)
_muster_export() {
	_muster_need_server || return 1
	[ -n "${1:-}" ] || { echo "usage: ${_MUSTER_SELF} <box> [git am args…]   (run inside your local checkout)" >&2; return 2; }
	local box="$1"; shift
	if [ "${1:-}" = --show ]; then
		ssh -T "$MUSTER_SERVER" "$(_muster_hub_pipe) cbx export $box"
		return
	fi
	ssh -T "$MUSTER_SERVER" "$(_muster_hub_pipe) cbx export $box" | git am "$@"
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
_muster_import() {
	_muster_need_server || return 1
	[ -n "${1:-}" ] || { echo "usage: ${_MUSTER_SELF} <box> [base-ref]   base defaults to 'dev'   (run inside your checkout)" >&2; return 2; }
	local box="$1" base="${2:-dev}" sq
	git rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1 \
		|| { echo "${_MUSTER_SELF}: base ref '$base' not found — pass the branch your change sits on top of: cbximport $box <base>" >&2; return 2; }
	# One throwaway commit whose diff is HEAD's whole tree vs <base> — a single net patch that applies on
	# the hub's dev by context. commit-tree writes an object referenced by no branch, so HEAD is untouched.
	sq="$(git commit-tree "HEAD^{tree}" -p "$(git rev-parse "$base")" -m "$(git log -1 --format=%B HEAD)")" \
		|| { echo "${_MUSTER_SELF}: could not assemble the patch" >&2; return 1; }
	git format-patch --stdout --binary -1 "$sq" \
		| ssh -T "$MUSTER_SERVER" "$(_muster_hub_pipe) cbx import $box"
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
# _muster_hub_pipe documents for the patch pipes.
#
# The destination is resolved on the RECEIVING side by $_MUSTER_CP_RX: extract into it if it is an
# existing directory, otherwise treat it as the new name. Identical semantics whichever way you copy,
# and it needs no extra round-trip to probe the far end first.
_MUSTER_CP_RX='d=$1; t=$(mktemp -d); tar -C "$t" -xf -; if [ -d "$d" ]; then mv "$t"/* "$d"/; else mkdir -p "$(dirname "$d")"; mv "$t"/* "$d"; fi; rmdir "$t"'
_muster_cp() {
	_muster_need_server || return 1
	local usage="usage: cbxcp <src> <dst>   ONE side is <box>:<path> or hub:<path>, e.g. cbxcp work1:/home/dev/repo/x.log ."
	local re='^([A-Za-z0-9][A-Za-z0-9_.-]*):(.+)$'
	local src="${1:-}" dst="${2:-}" s_t="" s_p="" d_t="" d_p="" ex
	[ -n "$src" ] || { echo "$usage" >&2; return 2; }
	[[ $src =~ $re ]] && { s_t="${BASH_REMATCH[1]}"; s_p="${BASH_REMATCH[2]}"; }
	# A remote source may omit the destination — like `cp x .`, the common "just grab it" case.
	[ -n "$dst" ] || { [ -n "$s_t" ] && dst=.; }
	[ -n "$dst" ] || { echo "$usage" >&2; return 2; }
	[[ $dst =~ $re ]] && { d_t="${BASH_REMATCH[1]}"; d_p="${BASH_REMATCH[2]}"; }
	[ -n "$s_t$d_t" ] || { echo "${_MUSTER_SELF}: neither side names a box or the hub — nothing to copy to/from" >&2; echo "$usage" >&2; return 2; }
	[ -z "$s_t" ] || [ -z "$d_t" ] || { echo "${_MUSTER_SELF}: both sides are remote ('$s_t' and '$d_t') — copy via your laptop in two steps" >&2; return 2; }
	# The `docker exec -i <container>` prefix, evaluated on the SERVER. The hub is found by its compose
	# labels (it survives renames and compose's -1 suffix); a box is named by convention, as in cbxtun.
	if [ "${s_t:-$d_t}" = hub ]; then ex="$(_muster_hub_pipe)"; else ex="docker exec -i box-${MUSTER_PROJECT}-${s_t:-$d_t}"; fi
	if [ -n "$s_t" ]; then
		echo "${_MUSTER_SELF}: $s_t:$s_p -> $dst" >&2
		# dirname/basename are pure string work, so they are computed here and the far side just tars.
		ssh -T "$MUSTER_SERVER" "$ex tar -C '$(dirname "$s_p")' -cf - '$(basename "$s_p")'" \
			| sh -c "$_MUSTER_CP_RX" sh "$dst"
	else
		[ -e "$src" ] || { echo "${_MUSTER_SELF}: no such file or directory: $src" >&2; return 1; }
		echo "${_MUSTER_SELF}: $src -> $d_t:$d_p" >&2
		tar -C "$(dirname "$src")" -cf - "$(basename "$src")" \
			| ssh -T "$MUSTER_SERVER" "$ex sh -c '$_MUSTER_CP_RX' sh '$d_p'"
	fi
}

# cbxexec <box|hub> <command…> — run ANY command in a box or the hub and get its output here, clean
# enough to pipe into your local tools:
#
#   cbxexec work1 gradle -q :app:test | tee test.log
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
_muster_exec() {
	_muster_need_server || return 1
	local tgt="${1:-}" ex b64
	[ -n "$tgt" ] && [ "$#" -ge 2 ] || { echo "usage: ${_MUSTER_SELF} <box|hub> <command…>   e.g. cbxexec work1 cat /home/dev/repo/build/out.log | less" >&2; return 2; }
	shift
	if [ "$tgt" = hub ]; then ex="$(_muster_hub_pipe)"; else ex="docker exec -i box-${MUSTER_PROJECT}-${tgt}"; fi
	b64=$(printf '%s' "$*" | base64 | tr -d '\n')
	ssh -T "$MUSTER_SERVER" "$ex sh -c \"\$(printf %s $b64 | base64 -d)\""
}

# ---------------------------------------------------------------------------------------------
# BUILDING BLOCKS FOR PROJECT HELPERS
#
# Everything a project helper needs that is NOT project-specific. Without these, each one re-derives
# the same three fiddly things — how a container is addressed on the server, when to allocate a PTY,
# and how to survive the two layers of shell re-parsing between here and there — and gets one of them
# subtly wrong. Public names (no leading underscore) because your own file calls them.
#
# THE RE-PARSING RULE, since it explains the shape of all of this: an ssh command is a STRING that the
# server's login shell parses again. So anything that must run THERE (`$(docker ps …)`) is emitted as
# literal text, and anything that comes from HERE is %q-quoted so quotes, spaces and $ survive intact.

# The compose service's container, as a server-side expression. Resolved by compose LABELS rather than
# by name, so it survives a container rename or a project prefix you did not expect.
muster_service_cid() {
	printf '$(docker ps -q -f label=com.docker.compose.project=%s -f label=com.docker.compose.service=%s)' \
		"$MUSTER_PROJECT" "${1:?usage: muster_service_cid <service>}"
}

# An agent box's container name. Boxes are named by convention (box-<project>-<name>) rather than
# labelled, because the broker — not compose — creates them.
muster_box_cid() { printf 'box-%s-%s' "$MUSTER_PROJECT" "${1:?usage: muster_box_cid <box>}"; }

# Run a command in one of the stack's SERVICE containers (db, redis, …):
#     muster_service_exec db psql mydb
#     muster_service_exec --user postgres db psql -v ON_ERROR_STOP=1 mydb < dump.sql
#
# The PTY decision is the part worth having in one place. A REPL needs one on both hops (docker -it,
# ssh -t) or you get no prompt and no line editing; a pipe must NOT have one on either (-i, ssh -T) or
# the PTY translates newlines and mangles whatever you are streaming in. Deciding from `[ -t 0 ]`
# means the same helper is correct interactively AND in `echo 'SELECT 1;' | …`, which is exactly the
# distinction a hand-written helper tends to get wrong in one direction or the other.
muster_service_exec() {
	_muster_need_server || return 1
	local user='' svc=''
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--user) user="${2:?--user needs a name}"; shift 2 ;;
			--) shift; break ;;
			-*) echo "muster_service_exec: unknown option '$1'" >&2; return 2 ;;
			*) svc="$1"; shift; break ;;
		esac
	done
	[ -n "$svc" ] && [ "$#" -gt 0 ] \
		|| { echo "usage: muster_service_exec [--user U] <service> <command…>" >&2; return 2; }
	local cmd; printf -v cmd '%q ' "$@"
	local dflags sshflag
	if [ -t 0 ]; then dflags='-it'; sshflag='-t'; else dflags='-i'; sshflag='-T'; fi
	ssh "$sshflag" "$MUSTER_SERVER" \
		"docker exec $dflags ${user:+-u $user }$(muster_service_cid "$svc") $cmd"
}

# One environment variable of a running box, or empty. Ports a box was given (PORT_FORWARD_*_TO_HUB),
# the golden it is on, anything service-env put there — the box's own environment is the authoritative
# answer to "which port did this box get", and guessing from a slot number is how that goes wrong.
#
# EMPTY MEANS "NOT RUNNING" AT LEAST AS OFTEN AS IT MEANS "NOT SET": the caller has to decide which,
# and should say "is it running?" in the error either way.
muster_box_env() {
	_muster_need_server || return 1
	local box="${1:?usage: muster_box_env <box> <VAR>}" var="${2:?usage: muster_box_env <box> <VAR>}"
	local inspect="docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}'"
	ssh "$MUSTER_SERVER" "$inspect $(muster_box_cid "$box") 2>/dev/null | sed -n 's/^${var}=//p'"
}

# Give your helper the same box-name Tab completion the built-ins have, plus its own flags:
#     muster_complete_box "$p" fe --own          # -> box names + `--own` for <prefix>fe
# Takes the stack prefix and the suffix, not a finished command name, because the command name only
# exists once muster_define has generated it — and completion has to go through the dispatcher so the
# callback knows which stack it is completing for. Safe in a non-bash shell (does nothing).
muster_complete_box() {
	[ -n "${BASH_VERSION:-}" ] || return 0
	local p="${1:?usage: muster_complete_box <prefix> <suffix> [flags…]}" sfx="$2"; shift 2
	_MUSTER_BOXONLY_FLAGS["${p}${sfx}"]="$*"
	muster_complete_for "$p" "$sfx" _muster_complete_boxonly
}

# ---------------------------------------------------------------------------------------------
# PROJECT-SPECIFIC helpers (a psql shell on your stack's db, a one-command frontend tunnel, …) are
# NOT here: they depend on your ports, your service names and your dev loop. Copy
# muster.bash_aliases.project.example next to this file, edit it, and source it AFTER this one — it
# reuses the plumbing above (_muster_need_server, cbxtun, the completion cache, and the building blocks
# just above).
# ---------------------------------------------------------------------------------------------
# BASH COMPLETION for cbx / cbxbox / cbxtun / cbxcp / cbxexec.
#
# Box and service names live on the SERVER, so completing them means an ssh round-trip — far too slow
# to run on every Tab. So the names are fetched once and cached in a file for $MUSTER_COMPLETE_TTL
# seconds (default 60); every Tab inside that window is a local `awk`. `cbxrefresh` busts the cache
# when you have just spawned or killed a box and don't want to wait the TTL out.
#
# Once there IS a cache, Tab never waits again: an expired cache is still used for the answer and the
# refetch is detached into the background for the NEXT Tab (see _muster_refresh_bg). Only the very first
# completion in a terminal — with no cache file to answer from — goes over the wire synchronously.
#
# The fetch asks the HUB, not docker, for boxes: `cbx ls` gets its list from the broker (authoritative
# — it knows boxes docker naming conventions wouldn't reveal), and refs/agents/* adds boxes that are
# no longer running but still have a handoff waiting for review, which is exactly when you want to
# complete `cbx review <Tab>`. Output is normalised to "svc <name>" / "box <name>" lines remotely, so
# the laptop side never parses cbx's human-readable table.
#
# BatchMode + ConnectTimeout are load-bearing: without them a server that is down or wants a password
# makes Tab hang the terminal. On any failure we keep the previous cache and complete nothing new.

: "${MUSTER_COMPLETE_TTL:=60}"

_muster_cache_file() {
	printf '%s/cbx-complete.%s.%s' "${TMPDIR:-/tmp}" "${MUSTER_PROJECT:-none}" "${UID:-0}"
}

# Loading indicator for the one Tab in sixty that actually goes over the wire. This CANNOT be a
# printed message: readline owns the line while a completion function runs, so anything written into
# the display gets overwritten or leaves debris. OSC 9;4 is the escape that exists for exactly this —
# it drives the TERMINAL's own progress reporting (taskbar/tab indicator), not the text grid, so the
# command line is never touched. `3` = indeterminate, `0` = clear. Ghostty, WezTerm, Windows Terminal
# and ConEmu implement it; terminals that don't simply ignore the sequence (it's an OSC, so it is
# swallowed, not printed). Writes to /dev/tty because completion's stdout is a capture pipe.
# Set MUSTER_COMPLETE_PROGRESS=0 to suppress.
_muster_progress() {
	[ "${MUSTER_COMPLETE_PROGRESS:-1}" = 1 ] && [ -w /dev/tty ] || return 0
	case "$1" in
		on)  printf '\033]9;4;3;0\033\\' > /dev/tty 2>/dev/null ;;
		off) printf '\033]9;4;0;0\033\\' > /dev/tty 2>/dev/null ;;
	esac
	return 0
}

_muster_complete_fetch() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 "$MUSTER_SERVER" bash -s "$MUSTER_PROJECT" 2>/dev/null <<'REMOTE'
proj="$1"
hub=$(docker ps -q -f label=com.docker.compose.project="$proj" -f label=com.docker.compose.service=hub) || exit 0
[ -n "$hub" ] || exit 0
# `muster ls` = services table + broker box table. Tag each section's first column and drop anything
# that isn't a bare name, which throws away the "(broker unreachable)" / "(none — drop a manifest …)"
# lines. `muster` and not the prefix: the prefix is a runtime symlink and completion must not be the
# thing that discovers it is missing.
docker exec "$hub" muster ls 2>/dev/null | awk '
	/^== services/ { sec="svc"; next }
	/^== boxes/    { sec="box"; next }
	/^==/          { sec="";    next }
	sec != "" && $1 ~ /^[A-Za-z0-9][-A-Za-z0-9_]*$/ { print sec, $1 }'
# Boxes with a handoff waiting but no running container — review/merge/drop still apply to them.
docker exec "$hub" git -C /home/dev/repo for-each-ref --format='box %(refname:strip=2)' refs/agents/ 2>/dev/null
# Branches, for the commands that take one (minto, push, pull).
docker exec "$hub" git -C /home/dev/repo for-each-ref --format='branch %(refname:strip=2)' refs/heads/ 2>/dev/null
# SUBCOMMANDS AND FLAGS, FROM THE HUB'S OWN HELP. Not from a list kept here: this file and the hub
# image are deployed by different paths and drift apart for weeks at a time, and a completion that
# has never heard of `minto` is worse than none — it looks like the command does not exist. `muster
# --help` IS the header block of the CLI that is actually installed, so whatever that hub can do is
# exactly what completes.
#
# One `<self> <cmd>` line opens a block; its indented continuation lines belong to the same command,
# which is where flags like [--reword|-r] live.
docker exec "$hub" muster --help 2>/dev/null | awk '
	match($0, /^[[:space:]]+muster[[:space:]]+[a-z][a-z0-9]*/) { split($0, w, " "); cmd = w[2]; print "cmd", cmd }
	cmd != "" {
		line = $0
		while (match(line, /--[a-z][a-z-]*/)) {
			print "flag", cmd, substr(line, RSTART, RLENGTH)
			line = substr(line, RSTART + RLENGTH)
		}
	}'
REMOTE
}

# Refresh the cache in the BACKGROUND, for the next Tab. Detached from this shell entirely, so the
# completion that triggered it returns immediately.
#
# The lock is a directory because mkdir is the atomic test-and-set every filesystem agrees on: hold
# Tab down and you get ONE refresher, not one per keystroke. It is also stale-swept — a shell killed
# mid-fetch would otherwise leave the lock behind and no Tab would ever refresh again, which is the
# worst kind of bug here (silent, permanent, and it looks like the server is stuck).
_muster_refresh_bg() {
	local f="$1" lock now lockage
	lock="$f.lock"
	now=$(date +%s)
	if [ -d "$lock" ]; then
		lockage=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")
		[ "$((now - lockage))" -lt 120 ] && return 0     # a refresh really is in flight
		rmdir "$lock" 2>/dev/null                        # …or a dead one left this behind
	fi
	mkdir "$lock" 2>/dev/null || return 0
	# Stamp the cache NOW so the Tabs during this fetch see a fresh file and don't queue more work.
	touch "$f" 2>/dev/null
	{
		if _muster_complete_fetch > "$f.tmp" 2>/dev/null && [ -s "$f.tmp" ]; then
			mv -f "$f.tmp" "$f"
		else
			rm -f "$f.tmp"
		fi
		rmdir "$lock" 2>/dev/null
	} >/dev/null 2>&1 &
	disown 2>/dev/null || true
	return 0
}

# Cached names. CACHE FIRST: if we have a list at all, Tab answers from it immediately and any refresh
# happens in the background — so exactly one Tab in the life of a terminal can ever block on ssh (the
# first, when there is nothing to answer with). The old behaviour re-fetched synchronously the moment
# the TTL expired, which meant a laggy Tab every minute for a list that changes when YOU spawn a box.
#
# A failed fetch leaves the old cache in place (the write goes to .tmp and is only moved on success),
# so a brief network blip doesn't wipe completion — and the mv is atomic, so a concurrent Tab never
# reads a half-written file.
_muster_complete_cache() {
	local f now mtime
	[ -n "${MUSTER_SERVER:-}" ] && [ -n "${MUSTER_PROJECT:-}" ] || return 0
	f="$(_muster_cache_file)"
	now=$(date +%s)
	mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
	# -e, not -s: a failed fetch leaves an EMPTY cache file behind on purpose (see the touch below), and
	# testing for size would make every keystroke retry the ssh that just failed.
	if [ ! -e "$f" ]; then
		# Cold start only: nothing to complete from, so this one has to wait for the wire.
		_muster_progress on
		if _muster_complete_fetch > "$f.tmp" 2>/dev/null && [ -s "$f.tmp" ]; then
			mv -f "$f.tmp" "$f"
		else
			rm -f "$f.tmp"
			touch "$f" 2>/dev/null   # don't retry the failing ssh on every keystroke
		fi
		_muster_progress off
	elif [ "$((now - mtime))" -ge "$MUSTER_COMPLETE_TTL" ]; then
		_muster_refresh_bg "$f"         # answer from what we have; the next Tab gets the new list
	fi
	cat "$f" 2>/dev/null
}

_muster_names() { _muster_complete_cache | awk -v k="$1" '$1==k {print $2}' | sort -u; }
# Flags are cached as `flag <cmd> <--flag>`, so they need the extra column.
_muster_flags() { _muster_complete_cache | awk -v c="$1" '$1=="flag" && $2==c {print $3}' | sort -u; }

# Force the next Tab to re-fetch — after `cbx box foo`, `cbx kill foo`, or a handoff.
_muster_refresh() { rm -f "$(_muster_cache_file)"; _muster_complete_cache >/dev/null; echo "${_MUSTER_SELF:-cbx}: completion cache refreshed"; }

_muster_complete() {
	local cur cmd sub
	cur="${COMP_WORDS[COMP_CWORD]}"
	cmd="${COMP_WORDS[1]:-}"
	COMPREPLY=()

	# THE COMMAND LIST AND THE FLAGS COME FROM THE HUB (cached with the box/service names): they are
	# parsed from the `muster --help` of the image that is actually deployed, so a command added there
	# completes here without this file being redeployed — the two travel by different paths and drift
	# apart for weeks. The literals below are the fallback for a cold cache or an older hub that does
	# not emit them; they are a floor, not the list.
	if [ "$COMP_CWORD" -eq 1 ]; then
		# sort -u: the cache and the fallback overlap, and readline shows duplicates verbatim.
		COMPREPLY=($(compgen -W "$(_muster_names cmd)
			svcs up down logs autostart box kill recreate ls forwards
			status q review fix prereview merge drop rebase minto export import pull push
			golden expose hide" -- "$cur" | sort -u))
		return
	fi

	# Flags first: once the word starts with '-' the positional rules below don't apply. This is
	# deliberately independent of POSITION — `merge --squash <box>` and `merge <box> --squash` are both
	# valid, so both must complete.
	if [[ $cur == -* ]]; then
		local flags
		flags="$(_muster_flags "$cmd")"
		# Short flags and anything the help block spells in prose rather than as [--flag].
		case "$cmd" in
			merge)     flags="$flags --squash --edit --landed --reword -r" ;;
			review)    flags="$flags --full --net --tui --plain" ;;
			minto)     flags="$flags --here --box --intent --land --landed --abort --pull" ;;
			fix)       flags="$flags -m --force" ;;
			prereview) flags="$flags --force" ;;
			rebase)    flags="$flags --force" ;;
			recreate)  flags="$flags --fresh" ;;
			q|queue)   flags="$flags --text --once --no-bell -n" ;;
			pull)      flags="$flags --rebase" ;;
			golden)    [ "${COMP_WORDS[2]:-}" = snapshot ] && flags="$flags --prep" ;;
		esac
		COMPREPLY=($(compgen -W "$flags" -- "$cur" | sort -u))
		return
	fi

	case "$cmd" in
		up|down)   COMPREPLY=($(compgen -W "$(_muster_names svc)" -- "$cur")) ;;
		logs)      COMPREPLY=($(compgen -W "$(_muster_names svc) gitd" -- "$cur")) ;;
		# `box` takes a NEW name (nothing to complete); `import`/`export` and every review-queue verb
		# take an existing one.
		kill|forwards|review|fix|prereview|merge|drop|export|import)
		           COMPREPLY=($(compgen -W "$(_muster_names box)" -- "$cur")) ;;
		recreate|rebase)
		           COMPREPLY=($(compgen -W "$(_muster_names box) all" -- "$cur")) ;;
		# Branch arguments. `minto <branch>` merges dev INTO it, `push`/`pull` name one explicitly.
		minto|push) COMPREPLY=($(compgen -W "$(_muster_names branch)" -- "$cur")) ;;
		golden)    [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "snapshot seal ls reap" -- "$cur")) ;;
		expose|hide) COMPREPLY=($(compgen -f -- "$cur")) ;;
	esac
	return 0    # a case arm whose last test failed would otherwise make readline see an error
}

# Flags offered by each box-name-completing command. A project extras file (see
# muster.bash_aliases.project.example) adds its own commands with e.g.
#     muster_complete_box cbxfe --own          # the helper; sets the entry below and calls `complete`
declare -A _MUSTER_BOXONLY_FLAGS=([cbxexport]="--show --3way")

_muster_complete_boxonly() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	if [[ $cur == -* ]]; then
		local flags="${_MUSTER_BOXONLY_FLAGS[${COMP_WORDS[0]}]:-}"
		COMPREPLY=($(compgen -W "$flags" -- "$cur"))
		return 0
	fi
	[ "$COMP_CWORD" -eq 1 ] && COMPREPLY=($(compgen -W "$(_muster_names box)" -- "$cur"))
	return 0
}

# cbximport's second word is a LOCAL base ref (the branch your change sits on top of), so it completes
# from your own checkout rather than from the server — no cache involved.
_muster_complete_import() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$COMP_CWORD" in
		1) COMPREPLY=($(compgen -W "$(_muster_names box)" -- "$cur")) ;;
		2) COMPREPLY=($(compgen -W "$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null)" -- "$cur")) ;;
	esac
	return 0
}

# cbxtun specs are TARGET:PORT (or LOCAL:TARGET:PORT). We only complete the target half — the port is
# yours to pick — and suppress the trailing space so you can type the ':PORT' straight on.
_muster_complete_tun() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$cur" in
		*:*) COMPREPLY=() ;;                        # past the target; ports aren't ours to guess
		*)   COMPREPLY=($(compgen -S : -W "hub $(_muster_names box)" -- "$cur"))
		     [ "${#COMPREPLY[@]}" -gt 0 ] && compopt -o nospace ;;
	esac
	return 0
}

# cbxcp takes a local path on one side and <target>:<path> on the other, so both are offered at once:
# local files from compgen -f, plus `hub:`/`<box>:` prefixes with the space suppressed so the remote
# path can be typed straight on. Remote paths themselves are not completed — that would need an ssh
# round-trip per Tab, which is exactly what the name cache exists to avoid.
_muster_complete_cp() {
	local cur="${COMP_WORDS[COMP_CWORD]}"
	case "$cur" in
		*:*) COMPREPLY=() ;;                        # past the target; the far side's paths are unknown here
		*)   COMPREPLY=($(compgen -S : -W "hub $(_muster_names box)" -- "$cur"))
		     [ "${#COMPREPLY[@]}" -gt 0 ] && compopt -o nospace
		     COMPREPLY+=($(compgen -f -- "$cur")) ;;
	esac
	return 0
}

# cbxexec's first word is the target (a box, or the hub); everything after it is the command, which
# only the container could complete — so we complete word 1 and then get out of the way.
_muster_complete_exec() {
	[ "$COMP_CWORD" -eq 1 ] && COMPREPLY=($(compgen -W "hub $(_muster_names box)" -- "${COMP_WORDS[1]}"))
	return 0
}

# ---------------------------------------------------------------------------------------------
# THE STACK FACTORY
#
# One machine, several stacks. The commands are shell FUNCTIONS, so a second `source` of this file
# would simply overwrite the first stack's — and the config they read (MUSTER_SERVER, MUSTER_PROJECT) is a
# pair of globals that can only describe one stack at a time. So nothing here defines a command:
# `muster_stack` generates a whole family per stack, each carrying its own config.
#
#     muster_stack app root@server1 myapp         # -> app, apphub, appbox, apptun, appexec, …
#     muster_stack lab root@server2 labstack      # -> lab, labhub, labbox, …
#
# HOW THE CONFIG REACHES THE IMPLEMENTATIONS — the one trick worth understanding. The generated
# wrapper declares MUSTER_SERVER/MUSTER_PROJECT as LOCALS. Bash locals are dynamically scoped, so every
# function called from that wrapper sees this stack's values, and the implementations below did not
# have to change at all: they still just read $MUSTER_SERVER. (Dynamic scoping is usually the thing that
# bites you in bash; here it is exactly the right tool.) It also means an environment override still
# works per call — `MUSTER_TRANSPORT=mosh apphub` — because those are read the same way.
#
# The generated names are the ONLY thing that goes through `eval`, and the prefix is validated first.
# Server and project are never eval'd: they are looked up from these arrays at call time.
declare -A _MUSTER_SERVER=() _MUSTER_PROJECT=()
# command name -> which stack it belongs to / which completion function to run. Completion callbacks
# get no wrapper, so this is how a callback works out which stack it is completing for.
declare -A _MUSTER_COMP_PREFIX=() _MUSTER_COMP_FN=()

# suffix:implementation. '-' is the bare prefix itself (`is`), everything else appends (`ishub`).
_MUSTER_FAMILY=(
	-:_muster_run  hub:_muster_hub_attach  box:_muster_box_attach  tun:_muster_tun  sync:_muster_sync
	export:_muster_export  import:_muster_import  cp:_muster_cp  exec:_muster_exec  refresh:_muster_refresh
)
# suffix:completion-function, for the ones that complete more than nothing.
_MUSTER_FAMILY_COMP=(
	-:_muster_complete  box:_muster_complete_boxonly  export:_muster_complete_boxonly
	import:_muster_complete_import  tun:_muster_complete_tun  cp:_muster_complete_cp  exec:_muster_complete_exec
)

# muster_define <prefix> <suffix> <implementation> — generate ONE command for a stack. Project helper
# files use this for their own additions (see muster.bash_aliases.project.example):
#     muster_define "$1" psql _myproject_psql
# The implementation is called with the stack's config already in scope, and $_MUSTER_SELF set to the
# name the user actually typed, so its messages and usage strings say `apppsql`, not `cbxpsql`.
muster_define() {
	local p="${1:?usage: muster_define <prefix> <suffix> <implementation>}" sfx="$2" impl="$3"
	case "$p" in [a-z]*) ;; *) echo "muster_define: bad prefix '$p'" >&2; return 2 ;; esac
	eval "${p}${sfx}() {
		local MUSTER_SERVER=\"\${_MUSTER_SERVER[$p]}\" MUSTER_PROJECT=\"\${_MUSTER_PROJECT[$p]}\"
		local _MUSTER_SELF=${p}${sfx} _MUSTER_PREFIX=$p
		$impl \"\$@\"
	}"
}

# muster_complete_for <prefix> <suffix> <completion-function> — same, for Tab completion.
muster_complete_for() {
	[ -n "${BASH_VERSION:-}" ] || return 0
	local p="$1" sfx="$2" fn="$3" name="$1$2"
	_MUSTER_COMP_PREFIX["$name"]="$p"; _MUSTER_COMP_FN["$name"]="$fn"
	complete -F _muster_complete_dispatch "$name"
}

# Every generated command completes through here: look up which stack the word belongs to, put that
# stack's config in scope (same dynamic-scoping trick as the wrappers — the cache file is keyed on
# MUSTER_PROJECT, so without this two stacks would share one cache), then run the real completion.
_muster_complete_dispatch() {
	local name="${COMP_WORDS[0]}" p
	p="${_MUSTER_COMP_PREFIX[$name]:-}"
	local MUSTER_SERVER="${_MUSTER_SERVER[$p]:-}" MUSTER_PROJECT="${_MUSTER_PROJECT[$p]:-}"
	"${_MUSTER_COMP_FN[$name]:-:}"
}

# muster_stack <prefix> <server> <project> — the whole family for one stack.
muster_stack() {
	local p="${1:-}" server="${2:-}" project="${3:-}" entry sfx impl
	if ! [[ "$p" =~ ^[a-z][a-z0-9_]{0,15}$ ]]; then
		echo "muster_stack: bad prefix '${p}' — lowercase letter first, then letters/digits/_ (max 16)" >&2
		echo "usage: muster_stack <prefix> <user@server> <project>    e.g. muster_stack app root@host myapp" >&2
		return 2
	fi
	[ -n "$server" ] && [ -n "$project" ] || {
		echo "usage: muster_stack $p <user@server> <project>" >&2; return 2; }
	_MUSTER_SERVER["$p"]="$server"; _MUSTER_PROJECT["$p"]="$project"
	for entry in "${_MUSTER_FAMILY[@]}"; do
		sfx="${entry%%:*}"; impl="${entry#*:}"
		[ "$sfx" = - ] && sfx=""
		muster_define "$p" "$sfx" "$impl"
	done
	for entry in "${_MUSTER_FAMILY_COMP[@]}"; do
		sfx="${entry%%:*}"; impl="${entry#*:}"
		[ "$sfx" = - ] && sfx=""
		muster_complete_for "$p" "$sfx" "$impl"
	done
	if [ -n "${BASH_VERSION:-}" ]; then
		_MUSTER_BOXONLY_FLAGS["${p}export"]="--show --3way"
		complete -W '--rebase' "${p}sync"
	fi
}

# Back-compat: a ~/.bashrc that exports MUSTER_SERVER/MUSTER_PROJECT and sources this file — the way it
# worked before there was a factory — still gets the `cbx…` family it always had. Registering the
# stack under the prefix `cbx` is exactly equivalent, and `muster_stack` can add more beside it.
if [ -n "${MUSTER_SERVER:-}" ] && [ -n "${MUSTER_PROJECT:-}" ]; then
	muster_stack cbx "$MUSTER_SERVER" "$MUSTER_PROJECT"
fi
