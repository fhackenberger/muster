# lib.sh — fixtures and assertions for the cbx test suite. Sourced by run-tests.sh.
#
# NOTE deliberately NOT `set -e`: a failing assertion has to fail its TEST and let the run continue,
# not kill the runner. Every helper reports through fail() instead of exiting.

TESTS_RUN=0; TESTS_FAILED=0; TESTS_SKIPPED=0
CUR=""; CUR_FAILED=0
OUT=""; RC=0

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then C_G=; C_R=; C_Y=; C_D=; C_0=; fi

# ---------------------------------------------------------------- test framework

t() {                                    # t <name> — start a test
	CUR="$1"; CUR_FAILED=0
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%s· %s%s\n' "$C_D" "$CUR" "$C_0"
}

t_end() {
	if [ "$CUR_FAILED" = 0 ]; then printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$CUR"
	else TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$CUR"; fi
	CUR=""
}

skip() {                                 # skip <why> — count it, don't run it
	TESTS_RUN=$((TESTS_RUN - 1)); TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
	printf '  %sSKIP%s %s — %s\n' "$C_Y" "$C_0" "$CUR" "$1"
	CUR=""
}

fail() {                                 # fail <message> [detail…]
	CUR_FAILED=1
	printf '    %s✗%s %s\n' "$C_R" "$C_0" "$1"
	shift
	for line in "$@"; do printf '      %s%s%s\n' "$C_D" "$line" "$C_0"; done
	# The command output is nearly always what you need to see; print it once per failure, indented.
	if [ -n "$OUT" ]; then printf '%s\n' "$OUT" | sed 's/^/      | /' | head -25; fi
}

# ---------------------------------------------------------------- running cbx

# Run cbx, capturing stdout+stderr into $OUT and the status into $RC. Never fails the shell.
cbx() {
	OUT="$(bash "$MUSTER_BIN" "$@" </dev/null 2>&1)"; RC=$?
	return 0
}

# Same, but with a PTY and keystrokes fed in with human-ish delays. cbx's prompts read from /dev/tty
# and drop pending input first (tty_flush), so a plain pipe would have its answers eaten before the
# prompt is even drawn — the delay is what makes the input land after each prompt.
muster_tty() {
	local keys="$1"; shift
	local args; printf -v args ' %q' "$@"
	OUT="$( { IFS='|'; for k in $keys; do sleep 0.25; printf '%s\n' "$k"; done; sleep 0.4; } \
		| script -qec "bash $MUSTER_BIN$args" /dev/null 2>&1 | sed 's/\r$//')"; RC=$?
	return 0
}

git_() { git -C "$FIX/repo" "$@"; }

# ---------------------------------------------------------------- assertions

ok()      { [ "$RC" = 0 ] || fail "expected success, got exit $RC"; }
notok()   { [ "$RC" != 0 ] || fail "expected a non-zero exit, got 0"; }
has()     { case "$OUT" in *"$1"*) ;; *) fail "output should contain: $1" ;; esac; }
hasnt()   { case "$OUT" in *"$1"*) fail "output should NOT contain: $1" ;; esac; }
eq()      { [ "$1" = "$2" ] || fail "${3:-values differ}" "expected: $2" "actual:   $1"; }
ne()      { [ "$1" != "$2" ] || fail "${3:-values should differ}" "both:     $1"; }
exists()  { [ -e "$1" ] || fail "should exist: $1"; }
absent()  { [ ! -e "$1" ] || fail "should NOT exist: $1"; }

# The sha a ref points at, or "" — for asserting that a branch did or did not move.
at() { git_ rev-parse -q --verify "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- fixtures

# A fresh world per test: a bare "origin", a hub clone on `dev` with one commit, and empty state
# dirs. Every cbx-visible path is exported here, so no test has to know the variable names.
FIXN=0
fixture() {
	FIXN=$((FIXN + 1))
	FIX="$TMP/fix$FIXN"
	mkdir -p "$FIX"
	git init -q --bare "$FIX/origin.git"
	git clone -q "$FIX/origin.git" "$FIX/repo" 2>/dev/null
	git_ config user.email hub@test; git_ config user.name "hub"
	git_ config commit.gpgsign false
	printf 'line one\n' > "$FIX/repo/a.txt"
	printf 'shared\n'   > "$FIX/repo/b.txt"
	git_ add -A; git_ commit -qm "initial commit"
	git_ branch -M dev
	git_ push -q -u origin dev
	mkdir -p "$FIX/boxes" "$FIX/golden" "$FIX/golden-staging" "$FIX/services"
	export CHECKOUT="$FIX/repo" DEV_BRANCH=dev
	export BOXES_DIR="$FIX/boxes" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging"
	export HUB_SERVICES_DIR="$FIX/services"
	export BROKER_URL="http://127.0.0.1:$STUB_PORT" BROKER_TOKEN=test
	export MUSTER_COLOR=never MUSTER_REVIEW_TUI=- GOLDEN_PREP_CMD=true
	export HUB_GIT_URL="$FIX/repo"
	: > "$STUB_LOG"
}

# Commit on a branch WITHOUT moving the hub's checkout (which must stay on dev — that is a property
# several tests assert). Runs in a throwaway linked worktree, exactly like the real agent boxes are
# separate checkouts.
#   commit_on <branch|sha> <newref|-> <message> <file> <content>  -> prints the new sha
#
# The one exception is the CHECKED-OUT branch: moving that with update-ref would leave the hub's index
# and worktree pointing at the old tree, and every later command would see phantom staged changes
# (which is not a state the real hub is ever in — it commits on dev normally). So commit in place.
commit_on() {
	local start="$1" newref="$2" msg="$3" file="$4" content="$5" wt sha head
	head="$(git_ symbolic-ref -q --short HEAD || true)"
	if [ "$newref" = "refs/heads/$head" ] && [ "$start" = "$head" ]; then
		printf '%s\n' "$content" > "$FIX/repo/$file"
		git_ add -A
		git_ commit -qm "$msg"
		git_ rev-parse HEAD
		return 0
	fi
	wt="$(mktemp -d "$TMP/wt.XXXXXX")"; rm -rf "$wt"
	git_ worktree add -q --detach "$wt" "$start" 2>/dev/null
	git -C "$wt" config user.email agent@test
	git -C "$wt" config user.name "agent"
	printf '%s\n' "$content" > "$wt/$file"
	git -C "$wt" add -A
	git -C "$wt" commit -qm "$msg"
	sha="$(git -C "$wt" rev-parse HEAD)"
	[ "$newref" = - ] || git_ update-ref "$newref" "$sha"
	git_ worktree remove --force "$wt"
	printf '%s' "$sha"
}

# A box that has handed off: N commits on top of dev, pushed to refs/agents/<box>, with a summary
# note — i.e. exactly the state `cbx q` is meant to show as 'new'.
handoff() {
	local box="$1" n="${2:-1}" i sha=dev
	for i in $(seq 1 "$n"); do
		sha="$(commit_on "$sha" - "agent: change $i" "f$i.txt" "content $i")"
	done
	git_ update-ref "refs/agents/$box" "$sha"
	git_ notes --ref=cbx add -f -m "work from $box" "$sha" 2>/dev/null
	printf '%s' "$sha"
}

# Register a box with the stub broker, so `cbx ls`/`kill`/`say` behave as if it were running.
box_up() { curl -s -X POST -H "X-Broker-Token: test" "$BROKER_URL/box/$1" >/dev/null; }

# ---------------------------------------------------------------- the laptop aliases
#
# muster.bash_aliases builds COMMAND STRINGS and hands them to ssh; almost every bug it can have is a
# quoting or a PTY bug in one of those strings. So the harness is a stub `ssh` that records its argv
# and answers the one query the aliases actually parse (cbxtun's container-IP lookup). Nothing needs
# a server, and what a test asserts on is the exact command that WOULD have been run.

alias_fixture() {
	mkdir -p "$FIX/bin"
	SSH_LOG="$FIX/ssh.log"; : > "$SSH_LOG"
	cat > "$FIX/bin/ssh" <<'EOF'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$MUSTER_SSH_LOG"
# cbxtun resolves container IPs with `ssh <server> bash -s <proj> <target…>` and a heredoc on stdin.
# Answer in its format ("<target> <ip>") so the rest of the function runs for real.
prev=""; targets=(); proj=""
for a in "$@"; do
	if [ "$prev" = "-s" ]; then proj="$a"; prev=x; continue; fi
	[ "$a" = "-s" ] && prev=-s
	[ -n "$proj" ] && [ "$a" != "$proj" ] && targets+=("$a")
done
if [ -n "$proj" ]; then
	cat >/dev/null                       # swallow the heredoc
	n=1; for t in "${targets[@]}"; do printf '%s 10.0.0.%s\n' "$t" "$n"; n=$((n + 1)); done
	exit 0
fi
# Deliberately does NOT read stdin otherwise: the real ssh would, but a stub that blocks on an
# inherited terminal hangs the whole suite. A writer upstream (cbximport, cbxcp) just gets EPIPE.
exit 0
EOF
	cat > "$FIX/bin/mosh" <<'EOF'
#!/bin/bash
printf 'mosh %s\n' "$*" >> "$MUSTER_SSH_LOG"
EOF
	chmod +x "$FIX/bin/ssh" "$FIX/bin/mosh"
}

# al '<shell code>' — run code with the aliases sourced against a fake stack.
# $OUT = stdout+stderr, $SSHLOG = every ssh/mosh invocation it made, $RC = status.
# TTY=1 al '…' runs it under a real pseudo-terminal, which is how the `-t`/`-T` decisions are tested.
al() {
	: > "$SSH_LOG"
	local pre="source '$ROOT/muster.bash_aliases';"
	[ -z "${AL_PROJECT_FILE:-}" ] || pre="$pre source '$ROOT/muster.bash_aliases.project.example';"
	local env="PATH=$FIX/bin:$PATH MUSTER_SSH_LOG=$SSH_LOG MUSTER_SERVER=${AL_SERVER:-root@test.example} MUSTER_PROJECT=${AL_PROJECT:-proj}"
	if [ -n "${TTY:-}" ] && command -v script >/dev/null; then
		OUT="$(script -qec "env $env bash -c \"$pre $1\"" /dev/null 2>&1 | sed 's/\r$//')"; RC=$?
	else
		OUT="$(env $env bash -c "$pre $1" </dev/null 2>&1)"; RC=$?
	fi
	SSHLOG="$(cat "$SSH_LOG")"
	return 0
}

# Assertions against the recorded ssh invocations.
ssh_has()   { case "$SSHLOG" in *"$1"*) ;; *) fail "no ssh invocation contained: $1" "log: $SSHLOG" ;; esac; }
ssh_hasnt() { case "$SSHLOG" in *"$1"*) fail "an ssh invocation should NOT contain: $1" "log: $SSHLOG" ;; esac; }

# What the stub was asked. `stub_saw POST /box/x/say` -> 0 if such a request was recorded.
stub_saw() { grep -q "\"method\": \"$1\", \"path\": \"$2\"" "$STUB_LOG"; }
stub_body() { jq -r "select(.path == \"$1\") | .body" < "$STUB_LOG" | head -c 4000; }
