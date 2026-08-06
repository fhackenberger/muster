# Bash completion for the muster CLI, ON THE HUB. Installed by hub/Dockerfile.base as
# /usr/share/bash-completion/completions/muster, which bash-completion loads the first time you press
# Tab after `muster`; the entrypoint symlinks the stack's prefix (MUSTER_PREFIX, e.g. `cbx`) to the
# same file so both names complete, and the `complete` line at the bottom registers both.
#
# It reads the FILESYSTEM only — the service manifests, the box directories, the repo's refs. Nothing
# here talks to the broker: a Tab press must never block on an HTTP timeout, and completion that
# stops working because a container is down is worse than no completion.
#
# The laptop side is separate (muster.bash_aliases, which completes over ssh with a cached box list);
# they share no code because they cannot share a machine.

# Subcommands, read out of the dispatch `case` in the CLI itself rather than kept in a list here —
# the one list that cannot go stale, and the same trick the test suite uses to check `--help`.
_muster_commands() {
	local bin
	bin="$(command -v "${1:-muster}" 2>/dev/null)" || return 0
	[ -n "$bin" ] || return 0
	awk '/^cmd="\$\{1:-\}"/,0' "$bin" 2>/dev/null \
		| sed -n 's/^[[:space:]]*\([a-z|-]*\))[[:space:]].*/\1/p' | tr '|' '\n' | grep .
}

# Every box name we can name without asking anyone: the ones with a container directory, and the ones
# that have handed off (which may have no container at all — review/merge/drop still apply to them).
_muster_boxes() {
	local d
	for d in "${BOXES_DIR:-/work/boxes}"/*; do
		[ -d "$d" ] && printf '%s\n' "${d##*/}"
	done
	git -C "${CHECKOUT:-/home/dev/repo}" for-each-ref --format='%(refname:strip=2)' refs/agents/ 2>/dev/null
}

_muster_services() {
	local f
	for f in "${HUB_SERVICES_DIR:-/work/hub-services}"/*; do
		[ -f "$f" ] && printf '%s\n' "${f##*/}"
	done
}

_muster_branches() {
	git -C "${CHECKOUT:-/home/dev/repo}" for-each-ref --format='%(refname:strip=2)' refs/heads/ 2>/dev/null
}

_muster_complete() {
	local cur prev cmd words=("${COMP_WORDS[@]}")
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"
	cmd="${COMP_WORDS[1]:-}"
	COMPREPLY=()

	# First word: the subcommand.
	if [ "$COMP_CWORD" -le 1 ]; then
		mapfile -t COMPREPLY < <(compgen -W "$(_muster_commands "${COMP_WORDS[0]}")" -- "$cur")
		return 0
	fi

	case "$cmd" in
		# <box>
		review|merge|fix|drop|rebase|kill|box|recreate|prereview|export|import|say|peek|point|hold|release)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_boxes | sort -u)" -- "$cur") ;;
		# <service>
		up|down|logs|restart)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_services)" -- "$cur") ;;
		# <branch>
		minto|push|pull)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_branches)" -- "$cur") ;;
		golden)
			[ "$COMP_CWORD" = 2 ] &&
				mapfile -t COMPREPLY < <(compgen -W "snapshot seal ls reap" -- "$cur") ;;
	esac

	# `--flags` are worth completing wherever they appear, and the header block is where they are
	# documented — so take them from there rather than maintaining a per-command table that would
	# quietly stop matching the CLI.
	#
	# The block is one `#   $SELF <cmd> …` line plus its indented continuations, so: start at that
	# line, stop at the next one that names a command.
	if [ -z "${COMPREPLY[*]}" ] && [ "${cur:0:1}" = - ]; then
		local bin flags
		bin="$(command -v "${COMP_WORDS[0]}" 2>/dev/null)"
		flags="$(awk -v c="$cmd" '
			p && /\$SELF/ { exit }
			$0 ~ "^#.*\\$SELF[[:space:]]+" c "([[:space:]]|$)" { p = 1 }
			p && /^#/ { print }
			p && !/^#/ { exit }' "$bin" 2>/dev/null \
			| grep -o -- '--[a-z][a-z-]*' | sort -u)"
		mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
	fi
	return 0
}

# Both names. MUSTER_PREFIX is the stack's own word for the command (`cbx`), set in the container's
# environment; ${VAR:+"$VAR"} expands to NOTHING when it is unset, rather than to an empty argument
# that `complete` would reject.
complete -F _muster_complete muster ${MUSTER_PREFIX:+"$MUSTER_PREFIX"}
