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

# The subcommands of a command that has its OWN dispatch (`golden snapshot`, `golden migrate`, …),
# read out of its nested `case "$sub" in` for exactly the reason the top-level list is read out of
# the CLI: a copy kept here is a list that goes stale in silence. It did — the hand-written one said
# "snapshot seal ls reap" and never learned `migrate` or `retire`, and nothing complained, because a
# completion that offers four words out of six looks precisely like one that works.
#
# Prints nothing for a command with no sub-dispatch, which is how the caller tells the two apart.
_muster_subcommands() {
	local bin parent="$2"
	bin="$(command -v "${1:-muster}" 2>/dev/null)" || return 0
	[ -n "$bin" ] || return 0
	# $parent is whatever the user has typed so far, and it goes into an awk regex: let nothing
	# through but a plain command name.
	case "$parent" in ''|*[!a-z-]*) return 0 ;; esac
	awk -v p="$parent" '
		$0 ~ "^[[:space:]]*" p "\\)[[:space:]]*$" { inparent = 1; next }
		inparent && /case "\$sub" in/ { insub = 1; next }
		insub && /esac/ { exit }
		insub' "$bin" 2>/dev/null \
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

	# Second word of a command that dispatches again (`golden <sub>`). Ahead of the table below and
	# driven by the CLI rather than by a list here, so a new sub-dispatch — or a new subcommand under
	# an existing one — completes the moment it is written, without this file being touched.
	# …unless a flag is being typed, which is never a subcommand and falls through to the scraper.
	if [ "$COMP_CWORD" = 2 ] && [ "${cur:0:1}" != - ]; then
		local subs
		subs="$(_muster_subcommands "${COMP_WORDS[0]}" "$cmd")"
		if [ -n "$subs" ]; then
			mapfile -t COMPREPLY < <(compgen -W "$subs" -- "$cur")
			return 0
		fi
	fi

	case "$cmd" in
		# <box>
		review|merge|fix|drop|rebase|kill|box|recreate|prereview|export|import|say|job|peek|point|hold|release)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_boxes | sort -u)" -- "$cur") ;;
		# <service>
		up|down|logs|restart)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_services)" -- "$cur") ;;
		# <branch>
		minto|push|pull)
			mapfile -t COMPREPLY < <(compgen -W "$(_muster_branches)" -- "$cur") ;;
		# `golden <sub>` is handled above, from the CLI's own nested case.
		# `golden migrate <box>` — the only sub-dispatch argument worth naming.
		golden)
			[ "${COMP_WORDS[2]:-}" = migrate ] &&
				mapfile -t COMPREPLY < <(compgen -W "$(_muster_boxes | sort -u)" -- "$cur") ;;
	esac

	# `--flags` are worth completing wherever they appear, and the header block is where they are
	# documented — so take them from there rather than maintaining a per-command table that would
	# quietly stop matching the CLI.
	#
	# The block is one `#   $SELF <cmd> …` line plus its indented continuations, so: start at that
	# line, stop at the next one that names a command.
	if [ -z "${COMPREPLY[*]}" ] && [ "${cur:0:1}" = - ]; then
		local bin flags what="$cmd"
		# `golden migrate --<TAB>` must find `--golden-wins`, and those flags are documented on the
		# SUBCOMMAND's line — matching the parent alone lands on `golden snapshot` and offers `--prep`
		# for every one of them. Same [a-z-] guard as _muster_subcommands: this goes into a regex.
		if [ "$COMP_CWORD" -gt 2 ]; then
			case "${COMP_WORDS[2]:-}" in
				''|*[!a-z-]*) ;;
				*) [ -n "$(_muster_subcommands "${COMP_WORDS[0]}" "$cmd")" ] &&
					what="$cmd[[:space:]]+${COMP_WORDS[2]}" ;;
			esac
		fi
		bin="$(command -v "${COMP_WORDS[0]}" 2>/dev/null)"
		# An empty $bin would make awk read STDIN and hang the terminal on a Tab press.
		[ -n "$bin" ] || return 0
		flags="$(awk -v c="$what" '
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
