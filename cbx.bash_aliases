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
#   * long-lived interactive sessions (`cbxhub`, `cbxbox`, `cbx logs`) honor CBX_TRANSPORT and default
#     to mosh (roaming: survives laptop sleep, Wi-Fi→LTE, IP changes, no frozen sessions). Set
#     CBX_TRANSPORT=ssh to force plain ssh — per call (`CBX_TRANSPORT=ssh cbxhub`) or globally.
# mosh needs UDP 60000-61000 open to the server (see tasks/firewall.yml) and uses ssh only for the
# initial handshake, so key auth is unchanged. `cbxui` is always ssh — mosh can't port-forward.

# Set these — either export them in ~/.bashrc before sourcing, or edit the defaults here.
: "${CBX_SERVER:=root@your-server}"      # the claude-box host, e.g. root@hetzner1.acoveo.com
: "${CBX_PROJECT:=myproject}"            # PROJECT_NAME of the stack, e.g. infostars
: "${CBX_TRANSPORT:=ssh}"               # transport for interactive sessions: mosh | ssh (default)
# TERM handling. `docker exec -it` does NOT propagate your terminal — it hands the container TERM=dumb,
# which has no `clear`, so tmux dies with "terminal does not support clear". So we forward YOUR real
# $TERM explicitly via `-e TERM=…`. That's your actual terminal (e.g. xterm-ghostty, which the box
# bakes), not a forced one. CBX_TERM is an OPT-IN override, unset by default: set it only when the box
# has no terminfo for your terminal (e.g. xterm-kitty) — `export CBX_TERM=xterm-256color` for a
# known-good fallback. If both are empty, no -e is added and docker's dumb default applies.

# Drop any older alias-based definitions (pre-mosh README) so the function definitions below parse —
# bash expands `cbx` as an alias mid-parse otherwise, failing with "syntax error near `('". Harmless
# when none exist; also lets you re-source this file cleanly.
unalias cbx cbxhub cbxbox cbxui 2>/dev/null || true

# One-shot commands: run over ssh so stdout/stderr land on your terminal and persist in scrollback.
# `-t` gives the remote a PTY (proper width/color for `--help` etc.); ssh doesn't use an alternate
# screen, so nothing is wiped on exit.
_cbx_ssh() {
	ssh -t "$CBX_SERVER" "$1"
}

# Long-lived interactive sessions: mosh by default (roaming), ssh when CBX_TRANSPORT=ssh. ssh runs
# the string through the remote login shell directly; mosh execs it, so we wrap in `bash -lc` — either
# way exactly one server-side shell parses it, so the $(docker ps …) hub lookup expands there. mosh
# always allocates a PTY (no `-t`); both keep host-key auth via ssh.
_cbx_session() {
	if [ "${CBX_TRANSPORT:-mosh}" = ssh ]; then
		ssh -t "$CBX_SERVER" "$1"
	else
		mosh "$CBX_SERVER" -- bash -lc "$1"
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

# watch the UI yourself: SSH-tunnel the hub's dev server (default port 4200), then open your laptop
# browser at http://localhost:4200 —  cbxui  (or  cbxui 9867  for another port). ALWAYS ssh: mosh
# has no port forwarding, and the inner lookup captures command output (which mosh can't do).
cbxui() {
	local port="${1:-4200}"
	ssh -L "$port:$(ssh "$CBX_SERVER" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=hub)"):$port" "$CBX_SERVER"
}
