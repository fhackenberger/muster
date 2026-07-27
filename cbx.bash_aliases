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
# Transport is mosh by default (roaming: survives laptop sleep, Wi-Fi→LTE, IP changes, and no frozen
# sessions). Set CBX_TRANSPORT=ssh to fall back to plain ssh — per call (`CBX_TRANSPORT=ssh cbxhub`)
# or globally. mosh needs UDP 60000-61000 open to the server (see tasks/firewall.yml) and uses ssh
# only for the initial handshake, so your existing key auth is unchanged. Note: `cbxui` ALWAYS uses
# ssh — mosh can't port-forward.

# Set these — either export them in ~/.bashrc before sourcing, or edit the defaults here.
: "${CBX_SERVER:=root@your-server}"      # the claude-box host, e.g. root@hetzner1.acoveo.com
: "${CBX_PROJECT:=myproject}"            # PROJECT_NAME of the stack, e.g. infostars
: "${CBX_TRANSPORT:=mosh}"               # mosh (default) | ssh

# Drop any older alias-based definitions (pre-mosh README) so the function definitions below parse —
# bash expands `cbx` as an alias mid-parse otherwise, failing with "syntax error near `('". Harmless
# when none exist; also lets you re-source this file cleanly.
unalias cbx cbxhub cbxbox cbxui 2>/dev/null || true

# _cbx_run <remote-command>: run one command string interactively on the server via the chosen
# transport. ssh runs it through the remote login shell directly; mosh execs it, so we wrap in
# `bash -lc` — either way the string is parsed by exactly one server-side shell, so the $(docker ps …)
# hub lookup expands there. mosh always allocates a PTY (no `-t` needed); ssh needs `-t` for docker's
# `-it`. Both keep host-key auth via ssh.
_cbx_run() {
	if [ "${CBX_TRANSPORT:-mosh}" = ssh ]; then
		ssh -t "$CBX_SERVER" "$1"
	else
		mosh "$CBX_SERVER" -- bash -lc "$1"
	fi
}

# The `docker exec` into the hub, resolved by compose labels at call time. Emitted as a literal
# string (the $(docker ps …) subshell is left for the server to evaluate); $CBX_PROJECT is inlined.
_cbx_hub() {
	printf 'docker exec -it $(docker ps -q -f label=com.docker.compose.project=%s -f label=com.docker.compose.service=hub)' "$CBX_PROJECT"
}

# run any cbx subcommand on the remote hub:  cbx up backend / cbx ls / cbx box work1
# %q re-quotes each arg so it survives the server-side shell re-parse (e.g. cbx fix work1 -m "a b c").
cbx() {
	local args=''
	[ "$#" -gt 0 ] && printf -v args ' %q' "$@"
	_cbx_run "$(_cbx_hub) cbx$args"
}

# drop into a PERSISTENT shell inside the hub, in tmux, so you can detach (Ctrl-b d) and reconnect
# any time to resume where you left off — `new-session -A` attaches the 'cbxhub' session if it's
# already running, else creates it (tmux starts it as a login shell). It's a dedicated session,
# separate from the 'services' session that `cbx logs` uses. Runs as the hub's uid-1000 'dev' user
# (the owner of the hub tmux server); for a root shell add `-u root` after `exec -it` — but that's a
# separate, empty tmux server, so use `bash -l` instead of the tmux part for root.
cbxhub() {
	_cbx_run "$(_cbx_hub) tmux new-session -A -s cbxhub -c /work/repo"
}

# attach to an agent box by name (Ctrl-b d to detach):  cbxbox work1
# the name lands in the MIDDLE of the command (box-<project>-<name>). -u dev: claude's tmux session
# runs under the box's 'dev' user, not root (root's tmux socket is empty → "no sessions"). The box
# bakes an xterm-ghostty terminfo entry so a native ghostty TERM works; for a terminal the box
# doesn't know (e.g. kitty) add `-e TERM=xterm-256color`, or bake its terminfo like ghostty
# (common-setup.sh).
cbxbox() {
	_cbx_run "docker exec -it -u dev box-${CBX_PROJECT}-$1 tmux attach -t main"
}

# watch the UI yourself: SSH-tunnel the hub's dev server (default port 4200), then open your laptop
# browser at http://localhost:4200 —  cbxui  (or  cbxui 9867  for another port). ALWAYS ssh: mosh
# has no port forwarding, and the inner lookup captures command output (which mosh can't do).
cbxui() {
	local port="${1:-4200}"
	ssh -L "$port:$(ssh "$CBX_SERVER" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$(docker ps -q -f label=com.docker.compose.project=$CBX_PROJECT -f label=com.docker.compose.service=hub)"):$port" "$CBX_SERVER"
}
