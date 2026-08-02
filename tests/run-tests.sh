#!/bin/bash
# run-tests.sh — the muster test suite.
#
#     ./tests/run-tests.sh              # everything
#     ./tests/run-tests.sh minto        # only tests whose name matches
#     KEEP=1 ./tests/run-tests.sh       # keep the scratch fixtures for poking at
#
# WHAT IS ACTUALLY UNDER TEST: `hub/muster` (all of it), `box-bin/muster-box-init`, and `broker.py`'s
# pure-python helpers. Nothing here needs docker, a network, or the real stack — the broker is
# replaced by tests/stub-broker.py (same HTTP contract, records what it was asked) and every git
# operation runs against a scratch repo with a bare "origin" beside it.
#
# The hub's repo is deliberately never checked out anywhere but `dev`: several tests assert that,
# because it is the invariant the whole minto design rests on (goldens are snapshotted from that
# tree). Agent commits are therefore made in throwaway linked worktrees — see commit_on().
#
# Requires: git, jq, curl, python3. tmux is optional (the dev-service tests skip without it), and
# `script` is optional (the interactive editor-loop tests skip without it).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# Overridable so you can point the suite at a modified copy — which is also how the suite itself is
# checked for teeth: mutate a copy, confirm the right test goes red.
MUSTER_BIN="${MUSTER_BIN:-$ROOT/hub/muster}"
BOX_INIT="$ROOT/box-bin/muster-box-init"
BROKER_PY="$ROOT/box-broker/broker.py"
FILTER="${1:-}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbx-tests.XXXXXX")"
STUB_PORT="${STUB_PORT:-$(( 18000 + RANDOM % 2000 ))}"
STUB_LOG="$TMP/stub.log"
: > "$STUB_LOG"

# shellcheck source=lib.sh
. "$HERE/lib.sh"

cleanup() {
	[ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
	if [ -n "${KEEP:-}" ]; then echo "fixtures kept in $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT

# Only run a test whose name matches the filter (substring, case-insensitive).
want() {
	[ -z "$FILTER" ] && return 0
	case "${1,,}" in *"${FILTER,,}"*) return 0 ;; *) return 1 ;; esac
}
run() {                                   # run <name> <function>
	want "$1" || return 0
	t "$1"; fixture; "$2"; [ -n "$CUR" ] && t_end
	return 0
}

STUB_LOG="$STUB_LOG" GOLDEN_DIR="$TMP/unused" GOLDEN_STAGING="$TMP/unused" \
	STUB_PORT="$STUB_PORT" python3 "$HERE/stub-broker.py" &
STUB_PID=$!
# The stub is re-execed per fixture only in the golden tests (they need it pointed at that fixture's
# dirs); everywhere else this single instance serves everything.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	curl -sf -o /dev/null "http://127.0.0.1:$STUB_PORT/box" && break
	sleep 0.2
done

echo "cbx test suite — $MUSTER_BIN"
echo

# =====================================================================  basics

test_syntax() {
	for f in "$MUSTER_BIN" "$BOX_INIT" "$ROOT/gen-hub-mounts.sh" "$ROOT/entrypoint.sh" \
	         "$ROOT/hub/entrypoint.sh" "$ROOT/box-bin/handoff"; do
		[ -f "$f" ] || continue
		OUT="$(bash -n "$f" 2>&1)"; RC=$?
		[ "$RC" = 0 ] || fail "bash -n failed: $f"
	done
	OUT="$(python3 -m py_compile "$BROKER_PY" 2>&1)"; RC=$?
	ok
}

# The bug this guards: help used to be `sed -n '4,52p'`, a hard-coded line range that silently
# stopped covering the usage list as commands were added — `cbx push` had fallen off the end.
test_help_covers_every_command() {
	local dispatch documented missing
	dispatch="$(awk '/^cmd="\$\{1:-\}"/,0' "$MUSTER_BIN" \
		| sed -n 's/^[[:space:]]*\([a-z|]*\))[[:space:]].*/\1/p' | tr '|' '\n' | grep . | sort -u)"
	cbx --help
	documented="$(printf '%s\n' "$OUT" | sed -n 's/^ *muster \([a-z]*\).*/\1/p' | sort -u)"
	# Aliases and `golden` subcommands are documented on their parent's line, not their own.
	missing="$(comm -23 <(printf '%s\n' "$dispatch") <(printf '%s\n' "$documented") \
		| grep -vx 'seal\|snapshot\|reap\|ls\|st\|queue\|services')"
	eq "$missing" "" "these subcommands are not in cbx --help"
	has "muster push"
	has "muster pull"
	has "muster minto"
	has "muster export"
}

test_unknown_command_prints_usage() {
	cbx bogus-subcommand
	notok
	has "muster svcs"
}

# The source tree must stay PROJECT-AGNOSTIC: muster is published on its own, so a project name,
# a private registry or a real credential leaking into a tracked file is a release bug, not a style
# nit. This is the cheap, mechanical half of that check (the rest is the secret scan in
# tools/split-out.sh, which reads history rather than the tip).
test_no_project_defaults() {
	local bad=""
	# Every per-stack file that carries credentials or project wiring ships as an .example; the real
	# one is written by hand or by Ansible and is gitignored. A tracked real file = a leak waiting.
	for f in mounts port-forwards service-env compose.project.yml build-setup.sh .env; do
		[ -e "$ROOT/$f.example" ] || [ "$f" = .env ] || fail "missing example: $f.example"
	done
	exists "$ROOT/.env.example"
	exists "$ROOT/service-env.example"
	exists "$ROOT/compose.project.yml.example"
	exists "$ROOT/muster.bash_aliases.project.example"
	# The build toolchain is the PROJECT's, so muster ships only an example of one. (The real
	# build-setup.sh beside it is not asserted either way: the consuming repo tracks its own, and
	# muster itself must never ship one — which the split's expected-file list enforces.)
	exists "$ROOT/build-setup.sh.example"
	# A public repository needs these; forgetting one is the sort of thing nobody notices until the
	# repo is already out there.
	for f in LICENSE README.md SECURITY.md CONTRIBUTING.md CHANGELOG.md .github/workflows/tests.yml; do
		exists "$ROOT/$f"
	done
	OUT="$(head -3 "$ROOT/LICENSE" 2>/dev/null)"; has "Apache License"
	# ...and the real ones must NOT be in the source tree.
	absent "$ROOT/service-env"
	# compose.yml is the STACK only. The project's own services live in compose.project.yml, so none
	# of these may appear here — the check is on service KEYS at two-space indent, so a comment
	# mentioning them (the example does) is fine.
	for svc in db activemq redis; do
		grep -q "^  ${svc}:" "$ROOT/compose.yml" && bad="$bad compose.yml:$svc"
	done
	[ -z "$bad" ] || fail "compose.yml must not define project services:$bad"
	# The .example files are worked examples, so they carry a FICTIONAL project ('myapp'), not the one
	# this repo happens to deploy — someone else's internal service names, URLs and DB users have no
	# business in a public repo just because they made a convenient sample.
	#
	# No hard-coded private registry, and no project/org/host NAME in anything that ships. The bare
	# names matter, not just the compound ones: an `ARG SETUP_SCRIPT=examples/myapp/build-setup.sh`
	# default once survived a version of this check that only looked for myappFrontend/myappWeb.
	OUT="$(grep -rniE -e 'dockerregistry\.acoveo\.com' -e 'acoveo' "$ROOT/compose.yml" \
		"$ROOT/.env.example" "$ROOT/muster-box.sh" "$ROOT/hub/muster" "$ROOT/muster.bash_aliases" \
		"$ROOT/Dockerfile" "$ROOT/hub/Dockerfile.base" "$ROOT/Dockerfile.addon" \
		"$ROOT/common-setup.sh" "$ROOT/build-setup.sh.example" \
		"$ROOT/service-env.example" "$ROOT/compose.project.yml.example" \
		"$ROOT/muster.bash_aliases.project.example" "$ROOT/hub-services.example" \
		"$ROOT/.gitignore" "$ROOT/README.md" "$ROOT/SECURITY.md" "$ROOT/CONTRIBUTING.md" \
		"$ROOT/CHANGELOG.md" "$ROOT/README-remote.md" "$ROOT/docs" "$ROOT/.github" 2>/dev/null)"
	[ -z "$OUT" ] || fail "project/registry specifics leaked into a generic file"
	# GOLDEN_PREP_CMD defaults to a no-op: muster knows nothing about anyone's build. Asserted on
	# the assignment itself rather than by sourcing cbx, which would run the whole script.
	OUT="$(grep -n '^GOLDEN_PREP_CMD=' "$MUSTER_BIN")"
	eq "$(printf '%s' "$OUT" | sed 's/^[0-9]*://')" 'GOLDEN_PREP_CMD="${GOLDEN_PREP_CMD:-}"' \
		"hub/muster must default GOLDEN_PREP_CMD to empty"
	OUT=""
}

# The box add-on is buildable but must NEVER be part of a deployment: a profiled service is excluded
# from up/down/pull/ps/build unless the profile is switched on. If that profile is ever dropped, a
# `docker compose up -d` on a server would try to BUILD it (and start a stray container), which is
# exactly the surprise the profile exists to prevent.
test_build_only_service_is_profiled() {
	OUT="$(python3 - "$ROOT/compose.yml" <<'PYEOF' 2>&1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
svc = d["services"]
assert "box-image" in svc, "the box add-on build service is gone"
assert svc["box-image"].get("profiles") == ["build"], \
    f"box-image must be profiled 'build', got {svc['box-image'].get('profiles')!r}"
active = [n for n, v in svc.items() if not v.get("profiles")]
assert sorted(active) == ["box-broker", "hub"], f"unprofiled services changed: {sorted(active)}"
# It must build the same add-on Dockerfile as the hub, onto the BOX base.
b = svc["box-image"]["build"]
assert b["dockerfile"] == "Dockerfile.addon", b["dockerfile"]
assert "BOX_BASE_IMAGE" in b["args"]["BASE_IMAGE"], b["args"]["BASE_IMAGE"]
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# =====================================================================  queue / status

test_status_empty() {
	cbx status --no-fetch
	ok
	has "nothing waiting"
	has "no base for boxes to overlay"      # no golden yet
}

test_queue_lists_a_handoff() {
	handoff work1 2 >/dev/null
	cbx q --text
	ok
	has "work1"
	has "work from work1"
	cbx status --no-fetch
	has "muster review work1"
}

test_queue_flags_conflicts_with_dev() {
	local sha
	sha="$(commit_on dev - "agent: touches b" b.txt "agent version")"
	git_ update-ref refs/agents/work1 "$sha"
	commit_on dev refs/heads/dev "dev: touches b" b.txt "dev version" >/dev/null
	cbx q --text
	has "conflicts with dev: b.txt"
	cbx status --no-fetch
	has "CONFLICTS with dev"
}

test_status_reports_behind_origin() {
	# Someone else pushed: origin/dev is ahead of the hub's dev.
	local sha
	sha="$(commit_on dev - "someone else" c.txt "elsewhere")"
	git_ push -q origin "$sha:refs/heads/dev"
	git_ fetch -q origin
	cbx status
	has "behind"
	has "muster pull"
}

# =====================================================================  review

test_review_new_branch_shows_patches() {
	handoff work1 2 >/dev/null
	cbx review work1
	ok
	has "2 commit(s) on top of dev"
	has "diff --git"
	has "reviewed up to"
	exists "$FIX/repo/.git/cbx/work1.reviewed"
}

# The reported bug: after a box pushed MORE commits, the re-review listed their subjects and showed
# no file diffs at all (range-diff only prints a patch for commits it can PAIR, and brand-new commits
# have no counterpart).
test_review_added_commits_shows_their_diffs() {
	local first
	first="$(handoff work1 1)"
	cbx review work1
	ok
	local second
	second="$(commit_on "$first" refs/agents/work1 "agent: second wave" g.txt "second wave")"
	cbx review work1
	ok
	has "added since your last review"
	has "second wave"
	has "diff --git"
	hasnt "1:  "                            # i.e. NOT a range-diff listing
}

# The other half of the same split: an AMENDED branch must still use range-diff, which is the only
# thing that can line the old and new versions of a commit up.
test_review_amended_branch_uses_range_diff() {
	local first wt
	first="$(handoff work1 1)"
	cbx review work1
	wt="$TMP/amend$FIXN"; git_ worktree add -q --detach "$wt" "$first"
	git -C "$wt" config user.email agent@test; git -C "$wt" config user.name agent
	printf 'amended\n' > "$wt/f1.txt"
	git -C "$wt" commit -q --amend -am "agent: change 1"   # same subject, different content
	git_ update-ref refs/agents/work1 "$(git -C "$wt" rev-parse HEAD)"
	git_ worktree remove --force "$wt"
	cbx review work1
	ok
	has "what changed in the commits you already reviewed"
	has "1:  "                              # a range-diff listing, pairing old against new
	hasnt "added since your last review"
}

test_review_full_and_net() {
	local first
	first="$(handoff work1 1)"
	cbx review work1
	commit_on "$first" refs/agents/work1 "agent: more" g.txt more >/dev/null
	cbx review work1 --full
	ok; has "diff --git"; hasnt "added since your last review"
	cbx review work1 --net
	ok; has "diff --git"
}

test_review_of_merged_branch_says_so() {
	local sha
	sha="$(handoff work1 1)"
	git_ update-ref refs/heads/dev "$sha"           # landed by hand
	cbx review work1
	ok
	has "nothing on top of dev"
	has "muster merge work1"
}

test_review_without_notes_ref_has_no_git_warning() {
	handoff work1 1 >/dev/null
	git_ update-ref -d refs/notes/cbx 2>/dev/null
	cbx review work1
	hasnt "warning: notes ref"
}

# =====================================================================  fix / prereview

test_fix_delivers_a_message() {
	handoff work1 1 >/dev/null; box_up work1
	cbx fix work1 -m "extract the mapper"
	ok
	has "sent to work1"
	stub_saw POST "/box/work1/say" || fail "the broker was never asked to say anything"
	case "$(stub_body /box/work1/say)" in *"extract the mapper"*) ;; *) fail "the feedback text did not reach the box" ;; esac
}

test_fix_without_message_is_refused() {
	handoff work1 1 >/dev/null; box_up work1
	cbx fix work1
	notok
	has "needs a message"
}

test_prereview_asks_the_agent() {
	handoff work1 1 >/dev/null; box_up work1
	cbx prereview work1
	ok
	has "self-review"
	stub_saw POST "/box/work1/say" || fail "no message sent"
}

# =====================================================================  merge

test_merge_plain() {
	local sha before
	sha="$(handoff work1 2)"; box_up work1
	before="$(at dev)"
	cbx merge work1
	ok
	has "dev is now"
	ne "$(at dev)" "$before" "dev should have moved"
	eq "$(at refs/agents/work1)" "" "the agent ref should be retired"
	absent "$FIX/repo/.git/cbx/work1.reviewed"
	# The merge commit, plus the agent's two, plus the initial one.
	eq "$(git_ rev-list --count dev)" "4"
	stub_saw POST "/box/work1/say" || fail "the box was never told to rebase"
}

test_merge_squash() {
	handoff work1 3 >/dev/null; box_up work1
	cbx merge work1 --squash
	ok
	eq "$(git_ rev-list --count dev)" "2" "squash should land exactly one commit"
	OUT="$(git_ log -1 --format=%B dev)"
	has "Cbx-Box: work1"
}

test_merge_refuses_stale_dev() {
	handoff work1 1 >/dev/null
	local sha
	sha="$(commit_on dev - "someone else" c.txt elsewhere)"
	git_ push -q origin "$sha:refs/heads/dev"
	cbx merge work1
	notok
	has "refusing to merge onto a stale dev"
	has "muster pull"
	ne "$(at refs/agents/work1)" "" "nothing should have been retired"
}

test_merge_already_contained_closes_out() {
	local sha
	sha="$(handoff work1 1)"
	git_ update-ref refs/heads/dev "$sha"
	cbx merge work1
	ok
	has "already contained in dev"
	eq "$(at refs/agents/work1)" "" "the ref should be retired"
}

test_merge_conflict_leaves_a_way_out() {
	local sha
	sha="$(commit_on dev - "agent: b" b.txt "agent version")"
	git_ update-ref refs/agents/work1 "$sha"
	commit_on dev refs/heads/dev "dev: b" b.txt "dev version" >/dev/null
	cbx merge work1
	notok
	has "merge conflicts"
	# And a second attempt must refuse rather than merge on top of the unresolved index.
	cbx merge work1
	notok
	has "UNRESOLVED conflicts"
	git_ merge --abort 2>/dev/null
}

test_merge_reword_rewrites_messages_only() {
	command -v script >/dev/null || { skip "no 'script' for driving the editor loop"; return 0; }
	local tip
	tip="$(handoff work1 3)"; box_up work1
	local tree; tree="$(git_ rev-parse "$tip^{tree}")"
	cat > "$TMP/ed.sh" <<'EOF'
#!/bin/bash
subj="$(grep -v '^#' "$1" | sed -e '/./,$!d' | head -1)"
printf 'REWORDED: %s\n\nA proper body.\n' "$subj" > "$1"
EOF
	chmod +x "$TMP/ed.sh"
	EDITOR="$TMP/ed.sh" muster_tty "a|m" merge work1 --reword
	ok
	has "reworded 3 commit(s)"
	has "dev is now"
	# The messages changed…
	OUT="$(git_ log --format=%s dev~1..dev^2)"
	has "REWORDED:"
	# …and nothing else did: same tree, same authors, still three commits.
	eq "$(git_ rev-parse 'dev^2^{tree}')" "$tree" "the landed tree must be identical to what was reviewed"
	eq "$(git_ rev-list --count dev~1..dev^2)" "3" "all three commits must survive"
	eq "$(git_ log --format=%ae dev^2 | head -1)" "agent@test" "the agent must stay the author"
	absent "$FIX/repo/.git/cbx/reword/work1"
}

test_merge_reword_keeps_edits_when_you_quit() {
	command -v script >/dev/null || { skip "no 'script' for driving the editor loop"; return 0; }
	local before
	handoff work1 2 >/dev/null; box_up work1
	before="$(at dev)"
	cat > "$TMP/ed2.sh" <<'EOF'
#!/bin/bash
printf 'my own wording\n' > "$1"
EOF
	chmod +x "$TMP/ed2.sh"
	EDITOR="$TMP/ed2.sh" muster_tty "1|q" merge work1 --reword
	has "Your edited messages are kept"
	eq "$(at dev)" "$before" "quitting must not merge anything"
	local kept; kept="$(cat "$FIX"/repo/.git/cbx/reword/work1/* 2>/dev/null)"
	eq "$kept" "my own wording" "the edited message should survive a quit"
}

test_merge_reword_refuses_squash_and_merges() {
	handoff work1 2 >/dev/null
	cbx merge work1 --reword --squash
	notok
	has "opposites"
}

# =====================================================================  drop / rebase

test_drop() {
	handoff work1 1 >/dev/null; box_up work1
	cbx drop work1
	ok
	eq "$(at refs/agents/work1)" ""
	stub_saw POST "/box/work1/say" || fail "the box was not told"
}

test_rebase_asks_the_box() {
	handoff work1 1 >/dev/null; box_up work1
	commit_on dev refs/heads/dev "dev moved" c.txt moved >/dev/null
	cbx rebase work1
	ok
	stub_saw POST "/box/work1/say" || fail "no rebase instruction sent"
	case "$(stub_body /box/work1/say)" in *"git rebase hub/dev"*) ;; *) fail "the rebase command was not in the message" ;; esac
}

# =====================================================================  pull / push

test_push_nothing_to_do() {
	cbx push -y
	ok
	has "nothing to push"
}

test_push_dev() {
	commit_on dev refs/heads/dev "local work" c.txt local >/dev/null
	cbx push -y
	ok
	has "pushed dev to origin"
	eq "$(at refs/remotes/origin/dev)" "$(at dev)"
}

test_push_named_branch() {
	git_ branch staging dev
	git_ push -q origin staging
	commit_on staging refs/heads/staging "staging work" s.txt s >/dev/null
	cbx push staging -y
	ok
	has "pushed staging to origin"
	eq "$(git -C "$FIX/origin.git" rev-parse staging)" "$(at staging)"
}

test_push_rejects_unknown_branch() {
	cbx push no-such-branch
	notok
	has "no local branch"
}

test_pull_fast_forward() {
	local sha
	sha="$(commit_on dev - "someone else" c.txt elsewhere)"
	git_ push -q origin "$sha:refs/heads/dev"
	cbx pull
	ok
	has "fast-forwarded"
	eq "$(at dev)" "$sha"
}

# =====================================================================  export / import

test_export_produces_an_mbox() {
	handoff work1 2 >/dev/null
	OUT="$(bash "$MUSTER_BIN" export work1 2>/dev/null)"; RC=$?
	ok
	has "From "
	has "Subject:"
}

test_import_replaces_the_branch() {
	handoff work1 1 >/dev/null; box_up work1
	local sha patch
	sha="$(commit_on dev - "my own version" f1.txt "hand written")"
	patch="$(git_ format-patch --stdout dev.."$sha")"
	OUT="$(printf '%s' "$patch" | bash "$MUSTER_BIN" import work1 2>&1)"; RC=$?
	ok
	has "now points at your commit"
	exists "$FIX/repo/.git/cbx/work1.reviewed"
	stub_saw POST "/box/work1/say" || fail "the box was not told its branch was replaced"
}

# =====================================================================  boxes (via the stub broker)

test_box_lifecycle() {
	cbx box work1
	ok; has "box 'work1' up"
	cbx ls
	ok; has "work1"
	cbx recreate work1
	ok
	cbx kill work1
	ok; has "killed box 'work1'"
	cbx ls
	hasnt "box-test-work1"
}

test_forwards() {
	box_up work1
	cbx forwards
	ok
	stub_saw POST "/forwards" || fail "the broker was not asked"
}

# Three images from up to three build paths, and nothing forces them to move together. The failures
# when they don't are silent (an old broker ignores query params a new hub sends), so `status` says so.
test_version_drift() {
	MUSTER_VERSION=9.9.9 cbx status --no-fetch
	ok; has "VERSION DRIFT"; has "the broker is"
	# The stub reports its own version as the box image's too, so one mismatch is enough to prove the
	# comparison runs; matching versions must stay silent.
	local v; v="$(curl -s "$BROKER_URL/version" | jq -r .broker)"
	MUSTER_VERSION="$v" cbx status --no-fetch
	ok; hasnt "VERSION DRIFT"
	# An unstamped image cannot tell, and must not cry wolf.
	MUSTER_VERSION=unknown cbx status --no-fetch
	ok; hasnt "VERSION DRIFT"
}

test_broker_unreachable_is_reported_not_fatal() {
	BROKER_URL="http://127.0.0.1:1" cbx status --no-fetch
	ok
	has "broker unreachable"
}

# =====================================================================  golden

test_golden_snapshot_and_reap() {
	# This one needs the stub pointed at THIS fixture's golden dirs, so it gets its own instance.
	local port log pid
	port=$(( STUB_PORT + 1 )); log="$FIX/stub2.log"; : > "$log"
	STUB_LOG="$log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" STUB_PORT="$port" \
		python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	BROKER_URL="http://127.0.0.1:$port" cbx golden snapshot
	ok
	has "sealed"
	exists "$FIX/golden/current/.git/cbx-golden"
	# Hub-only bits must never reach a box.
	absent "$FIX/golden/current/.git/cbx"
	absent "$FIX/golden/current/.git/worktrees"
	absent "$FIX/golden/current/.git/hooks/update"
	# The box's remote is rewritten to the hub's git URL.
	OUT="$(git -C "$FIX/golden/current" remote get-url hub 2>&1)"
	has "$HUB_GIT_URL"
	BROKER_URL="http://127.0.0.1:$port" cbx golden ls
	ok; has "g-"
	BROKER_URL="http://127.0.0.1:$port" cbx golden reap
	ok
	kill "$pid" 2>/dev/null
}

# An unfinished `cbx minto --here` lives in .git/cbx/wt. It must not be baked into a golden, and the
# worktree ADMIN dir must not either — a box inheriting one refuses to check the branch out.
test_golden_snapshot_strips_worktrees() {
	local port pid
	port=$(( STUB_PORT + 2 ))
	STUB_LOG="$FIX/stub3.log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" \
		STUB_PORT="$port" python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	git_ branch staging dev
	git_ worktree add -q "$FIX/repo/.git/cbx/wt/staging" staging
	BROKER_URL="http://127.0.0.1:$port" cbx golden snapshot
	ok
	absent "$FIX/golden/current/.git/worktrees"
	absent "$FIX/golden/current/.git/cbx/wt"
	kill "$pid" 2>/dev/null
}

# =====================================================================  services

test_svcs_lists_manifests() {
	cat > "$FIX/services/backend" <<'EOF'
description=the backend
command=sleep 600
workdir=.
autostart=false
EOF
	cbx svcs
	ok
	has "backend"
	has "the backend"
}

test_service_up_down() {
	command -v tmux >/dev/null || { skip "tmux is not installed"; return 0; }
	cat > "$FIX/services/dummy" <<'EOF'
description=a sleeper
command=sleep 600
EOF
	export TMUX_SESSION="mustertest-$$"
	# `muster up` only ADDS A WINDOW to a server the hub's entrypoint starts at boot; it does not create
	# the session. So the fixture has to stand one up the same way, or tmux fails with a bare
	# "error connecting to /tmp/tmux-<uid>/default". (This is why the test passed for months on a
	# machine without tmux, where it skipped, and failed the moment CI installed it.)
	if ! tmux new-session -d -s "$TMUX_SESSION" -c "$FIX" -n shell 2>/dev/null; then
		unset TMUX_SESSION; skip "no usable tmux server here"; return 0
	fi
	cbx up dummy;   ok; has "started dummy"
	# svc_list's state column is up|down, not running|stopped. Asserted together with the name so a
	# stray "up" anywhere else in the listing cannot satisfy it.
	cbx svcs;       has "dummy        up"
	cbx down dummy; ok; has "stopped dummy"
	cbx svcs;       has "dummy        down"
	tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
	unset TMUX_SESSION
}

# =====================================================================  laptop aliases
#
# These build command STRINGS for ssh; the bugs they can have are quoting and PTY bugs. See
# alias_fixture()/al() in lib.sh — a stub ssh records what would have been run.

test_aliases_forward_to_the_hub() {
	alias_fixture
	al 'cbx ls'
	ssh_has "ssh -t root@test.example docker exec -it"
	ssh_has "label=com.docker.compose.service=hub"
	ssh_has "cbx ls"
}

# `cbx logs` and the live `cbx q` are long-lived and interactive, so they take the mosh-able
# transport; everything else is one-shot and must stay on ssh or its output would be wiped.
test_aliases_transport_split() {
	alias_fixture
	al 'cbx q --text'; ssh_has "ssh -t"; ssh_hasnt "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx q';       ssh_has "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx logs backend'; ssh_has "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx ls';     ssh_hasnt "mosh"   # one-shot: ssh even under mosh
}

test_aliases_quote_hostile_arguments() {
	alias_fixture
	al 'cbx fix work1 -m "a b; rm -rf /"'
	ssh_has 'a\ b\;\ rm\ -rf\ /'
}

test_aliases_box_and_hub_attach() {
	alias_fixture
	al 'cbxbox work1'; ssh_has "docker exec -it -u dev"; ssh_has "box-proj-work1 tmux attach -t main"
	al 'cbxhub';       ssh_has "tmux new-session -A -s cbxhub -c /home/dev/repo"
}

# The patch/binary paths must never allocate a PTY on either hop — it would translate newlines and
# corrupt the payload. This is the one property shared by cbxexec, cbxcp, cbxexport and cbximport.
test_aliases_pipes_never_allocate_a_pty() {
	alias_fixture
	al 'cbxexec work1 echo hi'
	ssh_has "ssh -T"; ssh_has "docker exec -i box-proj-work1"; ssh_hasnt "docker exec -it"
	# the command travels base64-encoded, so quotes/$/backticks survive two shell re-parses
	ssh_has "base64 -d"
	al 'cbxexport work1 --show'
	ssh_has "ssh -T"; ssh_hasnt "-it"
	al 'cbxcp work1:/home/dev/x.log .' >/dev/null 2>&1
	ssh_has "ssh -T"; ssh_has "tar -C '/home/dev' -cf - 'x.log'"
}

test_aliases_exec_runs_in_the_hub_too() {
	alias_fixture
	al 'cbxexec hub "muster q --text"'
	ssh_has "label=com.docker.compose.service=hub"; ssh_has "docker exec -i "
}

test_aliases_tunnel_specs() {
	alias_fixture
	al 'cbxtun work1:4200 hub:8080'
	# One resolution round-trip, then -L per spec against the resolved container IPs.
	ssh_has "bash -s proj"
	ssh_has "ssh -N -L 127.0.0.1:4200:10.0.0."
	ssh_has "-L 127.0.0.1:8080:10.0.0."
	al 'cbxtun 9000'                    # bare PORT means the hub
	ssh_has "-L 127.0.0.1:9000:10.0.0."
	al 'cbxtun 4300:work1:4200'         # LOCAL:TARGET:PORT
	ssh_has "-L 127.0.0.1:4300:10.0.0."
}

test_aliases_refuse_without_a_server() {
	alias_fixture
	AL_SERVER="root@your-server" al 'cbx ls'      # the shipped placeholder
	has "still the placeholder"
	eq "$SSHLOG" "" "nothing may be sent when the server is unconfigured"
	AL_PROJECT="myproject" al 'cbxexec work1 echo hi'
	has "MUSTER_PROJECT"
	eq "$SSHLOG" "" "nothing may be sent when the project is unconfigured"
}

test_aliases_cbxcp_argument_checking() {
	alias_fixture
	al 'cbxcp ./a ./b'; notok; has "neither side names a box"
	al 'cbxcp work1:/a hub:/b'; notok; has "both sides are remote"
	al 'cbxcp'; notok; has "usage:"
	eq "$SSHLOG" ""
}

# The project helpers are generated from the same plumbing, so they get the same PTY treatment.
test_aliases_project_helpers() {
	alias_fixture
	AL_PROJECT_FILE=1 al 'cbxpsql mydb'
	ssh_has "ssh -T"; ssh_has "docker exec -i -u postgres"; ssh_has "psql mydb"
	AL_PROJECT_FILE=1 al 'MUSTER_DB_USER=app cbxpsql mydb -tA'
	ssh_has "psql -U app -tA mydb"
	AL_PROJECT_FILE=1 al 'cbxpsql'; notok; has "usage: cbxpsql"
}

# THE reason the factory exists: two stacks, one shell, no re-sourcing and no cross-talk.
test_aliases_two_stacks_side_by_side() {
	alias_fixture
	al 'muster_stack is root@one.example projone
	    muster_stack lab root@two.example projtwo
	    is ls; lab ls'
	ssh_has "root@one.example"
	ssh_has "root@two.example"
	ssh_has "label=com.docker.compose.project=projone"
	ssh_has "label=com.docker.compose.project=projtwo"
	# …and each family is complete, not just the bare command
	al 'muster_stack is root@one.example projone; isbox work1; ishub; isexec work1 echo hi'
	ssh_has "box-projone-work1 tmux attach"
	ssh_has "tmux new-session -A -s cbxhub"
	ssh_has "docker exec -i box-projone-work1"
	ssh_hasnt "root@test.example"          # the back-compat stack must not leak into the new one
}

# Project helpers are generated per stack from the same factory, so each points at its own server.
test_aliases_project_helpers_are_per_stack() {
	alias_fixture
	al 'muster_stack is root@one.example projone
	    source "'"$ROOT"'/muster.bash_aliases.project.example" is
	    ispsql mydb'
	ssh_has "root@one.example"
	ssh_has "label=com.docker.compose.service=db"
	ssh_has "psql mydb"
	# the usage string names what you typed, not the file it came from
	al 'muster_stack is root@one.example projone
	    source "'"$ROOT"'/muster.bash_aliases.project.example" is
	    ispsql'
	has "usage: ispsql"
	hasnt "usage: cbxpsql"
}

test_aliases_reject_a_bad_prefix() {
	alias_fixture
	al 'muster_stack "9bad" root@x proj'; notok; has "bad prefix"
	al 'muster_stack "a;rm -rf /" root@x proj'; notok; has "bad prefix"
	al 'muster_stack ok root@x'; notok; has "usage: muster_stack"
	eq "$SSHLOG" ""
}

test_aliases_interactive_gets_a_pty() {
	command -v script >/dev/null || { skip "no 'script' for a pseudo-terminal"; return 0; }
	alias_fixture
	AL_PROJECT_FILE=1 TTY=1 al 'cbxpsql mydb'
	ssh_has "ssh -t"; ssh_has "docker exec -it -u postgres"
}

# =====================================================================  minto

test_minto_refuses_dev_itself() {
	cbx minto dev
	notok
	has "IS the source branch"
}

test_minto_fast_forward() {
	git_ branch staging dev
	git_ push -q origin staging
	commit_on dev refs/heads/dev "dev: new work" c.txt new >/dev/null
	cbx minto staging
	ok
	has "fast-forwarding"
	eq "$(at staging)" "$(at dev)"
	eq "$(git_ symbolic-ref --short HEAD)" "dev" "the hub's checkout must not move"
}

test_minto_already_contains() {
	git_ branch staging dev
	git_ push -q origin staging
	cbx minto staging
	ok
	has "already contains"
}

test_minto_clean_merge_never_touches_the_worktree() {
	git_ branch staging dev
	git_ push -q origin staging
	commit_on staging refs/heads/staging "staging: only here" s.txt s >/dev/null
	commit_on dev refs/heads/dev "dev: only here" d.txt d >/dev/null
	# A dirty hub tree, exactly as the real hub carries local setup work.
	printf 'local setup\n' > "$FIX/repo/untracked-setup.txt"
	printf 'modified\n' >> "$FIX/repo/a.txt"
	cbx minto staging
	ok
	has "merged cleanly"
	eq "$(git_ symbolic-ref --short HEAD)" "dev"
	eq "$(git_ rev-list --count staging)" "4" "merge commit + both sides + the initial commit"
	# The dirty tree survived untouched.
	exists "$FIX/repo/untracked-setup.txt"
	OUT="$(cat "$FIX/repo/a.txt")"; has "modified"
	OUT="$(git_ log -1 --format=%B staging)"; has "Cbx-Minto: dev"
}

test_minto_creates_the_branch_from_origin() {
	local sha
	sha="$(commit_on dev - "release line" r.txt release)"
	git_ push -q origin "$sha:refs/heads/release/1.0"
	git_ fetch -q origin
	commit_on dev refs/heads/dev "dev: onwards" d.txt d >/dev/null
	cbx minto release/1.0
	ok
	has "created local release/1.0"
	ne "$(at release/1.0)" "" "the local branch should exist now"
}

test_minto_refuses_a_stale_target() {
	git_ branch staging dev
	git_ push -q origin staging
	local sha
	sha="$(commit_on staging - "someone else on staging" s.txt s)"
	git_ push -q origin "$sha:refs/heads/staging"
	commit_on dev refs/heads/dev "dev: work" d.txt d >/dev/null
	cbx minto staging
	notok
	has "origin/staging has 1 commit"
	has "--pull"
	# …and --pull fixes it.
	cbx minto staging --pull --here
	ok
	has "fast-forwarded staging to origin/staging"
}

test_minto_conflict_is_noninteractive_safe() {
	setup_minto_conflict
	local before; before="$(at staging)"
	cbx minto staging
	notok
	has "conflicted file(s)"
	has "not a terminal"
	eq "$(at staging)" "$before" "nothing may move without an answer"
}

test_minto_here_worktree_roundtrip() {
	setup_minto_conflict
	cbx minto staging --here --intent "integration branch for staging"
	ok
	has "resolve it in"
	exists "$FIX/repo/.git/cbx/wt/staging"
	eq "$(git_ symbolic-ref --short HEAD)" "dev" "the hub's checkout must not move"
	eq "$(git -C "$FIX/repo/.git/cbx/wt/staging" config merge.conflictstyle)" "zdiff3"
	# A second attempt must refuse rather than pile up.
	cbx minto staging
	notok; has "already open on staging"
	# Unresolved -> refused.
	cbx minto staging --landed
	notok; has "UNRESOLVED conflicts"
	# Resolve, but don't commit -> still refused.
	printf 'resolved\n' > "$FIX/repo/.git/cbx/wt/staging/b.txt"
	git -C "$FIX/repo/.git/cbx/wt/staging" add b.txt
	cbx minto staging --landed
	notok; has "NOT committed"
	git -C "$FIX/repo/.git/cbx/wt/staging" -c user.email=h@t -c user.name=h commit -qm "Merge dev into staging"
	cbx minto staging --landed
	ok
	has "worktree removed"
	absent "$FIX/repo/.git/cbx/wt/staging"
	git_ merge-base --is-ancestor dev staging || fail "staging should contain dev now"
	eq "$(git_ symbolic-ref --short HEAD)" "dev"
}

test_minto_abort_leaves_nothing_behind() {
	setup_minto_conflict
	local before; before="$(at staging)"
	cbx minto staging --here
	cbx minto staging --abort
	ok
	has "was never moved"
	absent "$FIX/repo/.git/cbx/wt/staging"
	eq "$(at staging)" "$before"
	cbx minto staging --abort
	has "nothing to abort"
}

test_minto_box_spawn_and_brief() {
	setup_minto_conflict
	cbx minto staging --box --intent "integration branch for the staging server"
	ok
	has "spawning box"
	stub_saw POST "/box/minto-staging?base=staging&merge=dev" || fail "the base/merge spawn params were not sent"
	exists "$FIX/repo/.git/cbx/minto-staging.mergeinto"
	eq "$(sed -n 1p "$FIX/repo/.git/cbx/minto-staging.mergeinto")" "staging"
	eq "$(sed -n 4p "$FIX/repo/.git/cbx/minto-staging.mergeinto")" "integration branch for the staging server"
	local brief; brief="$(stub_body /box/minto-staging/paste)"
	case "$brief" in *"git log --merge"*) ;; *) fail "the briefing must point at git log --merge" ;; esac
	case "$brief" in *"integration branch for the staging server"*) ;; *) fail "the intent must reach the agent" ;; esac
	case "$brief" in *"hub/staging"*) ;; *) fail "the briefing must name both branches" ;; esac
}

test_minto_box_queue_review_and_land() {
	setup_minto_conflict
	cbx minto staging --box --intent "the staging line"
	local tsha; tsha="$(at staging)"
	minto_agent_resolves staging minto-staging
	# The queue measures it against the TARGET, not dev.
	cbx q --text
	has "minto -> staging"
	has "     1 "                            # one commit of its own: the merge
	# …and cbx merge refuses it outright.
	cbx merge minto-staging
	notok
	has "refusing to merge a minto box"
	# The review shows the resolution (the combined diff), not the whole branch.
	cbx review minto-staging
	ok
	has "merge of dev into staging"
	has "THE RESOLUTION"
	has "the staging line"
	# Land it.
	cbx minto staging --land minto-staging
	ok
	has "staging is now"
	ne "$(at staging)" "$tsha" "staging should have moved"
	eq "$(at refs/agents/minto-staging)" "" "the agent ref should be gone"
	absent "$FIX/repo/.git/cbx/minto-staging.mergeinto"
	stub_saw DELETE "/box/minto-staging" || fail "the box should have been retired"
	git_ merge-base --is-ancestor dev staging || fail "staging must contain dev"
	eq "$(git_ symbolic-ref --short HEAD)" "dev"
}

test_minto_land_guards() {
	setup_minto_conflict
	cbx minto staging --box
	minto_agent_resolves staging minto-staging
	cbx minto other-branch --land minto-staging
	notok; has "not 'other-branch'"
	cbx minto staging --land nosuchbox
	notok; has "not resolving a merge"
	# Target moved under us.
	local tsha; tsha="$(at staging)"
	commit_on staging refs/heads/staging "staging moved" z.txt z >/dev/null
	cbx minto staging --land minto-staging
	notok; has "moved since the merge started"
	git_ update-ref refs/heads/staging "$tsha"
	# A branch that does not contain dev (the agent squashed or rebased the merge away).
	local bad; bad="$(commit_on staging - "not a merge" b.txt whatever)"
	git_ update-ref refs/agents/minto-staging "$bad"
	cbx minto staging --land minto-staging
	notok; has "does not contain dev"
}

# Two little scenario builders the minto tests share.
setup_minto_conflict() {
	git_ branch staging dev
	git_ push -q origin staging
	commit_on staging refs/heads/staging "staging: b" b.txt "staging version" >/dev/null
	commit_on dev refs/heads/dev "dev: b" b.txt "dev version" >/dev/null
}

# What the resolving agent does in its box, done here with a worktree: merge dev into the target,
# resolve, commit, "push" to refs/agents/<box> and attach a handoff note.
minto_agent_resolves() {
	local target="$1" box="$2" wt="$TMP/agent$FIXN"
	git_ worktree add -q --detach "$wt" "$target"
	git -C "$wt" config user.email agent@test; git -C "$wt" config user.name "agent-$box"
	git -C "$wt" merge dev >/dev/null 2>&1
	printf 'resolved: both sides\n' > "$wt/b.txt"
	git -C "$wt" add -A
	git -C "$wt" commit -q --no-edit
	git_ update-ref "refs/agents/$box" "$(git -C "$wt" rev-parse HEAD)"
	git_ notes --ref=cbx add -f -m "resolved 1 conflict merging dev into $target" "$(git -C "$wt" rev-parse HEAD)"
	git_ worktree remove --force "$wt"
}

# =====================================================================  muster-box-init

# The box's side of a minto spawn: it must land on the TARGET branch with dev merged and conflicted,
# before claude ever starts — the whole point of doing it in the init command rather than a prompt.
test_box_init_minto_sets_up_the_conflict() {
	setup_minto_conflict
	local box="$FIX/box"
	git clone -q "$FIX/repo" "$box" 2>/dev/null
	git -C "$box" config user.email box@test; git -C "$box" config user.name box
	OUT="$(cd "$box" && MUSTER_BOX=minto-staging MUSTER_HUB_GIT_URL="$FIX/repo" MUSTER_DEV_BRANCH=dev \
		MUSTER_BASE_BRANCH=staging MUSTER_MERGE_BRANCH=dev bash "$BOX_INIT" 2>&1)"; RC=$?
	ok
	has "fresh, based on staging"
	has "WITH CONFLICTS"
	eq "$(git -C "$box" rev-parse --abbrev-ref HEAD)" "agent/minto-staging"
	eq "$(git -C "$box" config merge.conflictstyle)" "zdiff3"
	OUT="$(git -C "$box" status --short)"; has "UU b.txt"
	OUT="$(cat "$box/b.txt")"; has "|||||||"      # zdiff3: the common base is in the hunk
	# A RECREATE mid-conflict must not blow up (`git checkout <current-branch>` fails on an unmerged
	# index, and this script runs under `set -e`).
	OUT="$(cd "$box" && MUSTER_BOX=minto-staging MUSTER_HUB_GIT_URL="$FIX/repo" MUSTER_DEV_BRANCH=dev \
		MUSTER_BASE_BRANCH=staging MUSTER_MERGE_BRANCH=dev bash "$BOX_INIT" 2>&1)"; RC=$?
	ok
	has "a merge is still IN PROGRESS"
}

test_box_init_ordinary_box() {
	local box="$FIX/box"
	git clone -q "$FIX/repo" "$box" 2>/dev/null
	git -C "$box" config user.email box@test; git -C "$box" config user.name box
	OUT="$(cd "$box" && MUSTER_BOX=work1 MUSTER_HUB_GIT_URL="$FIX/repo" MUSTER_DEV_BRANCH=dev \
		bash "$BOX_INIT" 2>&1)"; RC=$?
	ok
	has "fresh, based on dev"
	eq "$(git -C "$box" rev-parse --abbrev-ref HEAD)" "agent/work1"
	eq "$(git -C "$box" rev-parse HEAD)" "$(at dev)"
	OUT="$(git -C "$box" remote 2>&1)"; has "hub"; hasnt "origin"
}

# =====================================================================  broker.py units

test_broker_branch_validation() {
	OUT="$(python3 - "$BROKER_PY" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
good = ["staging", "release/1.0", "feat_x-2"]
bad  = ["a..b", "-x", "", "x" * 200, "main.lock", "he@{2}re", "a b"]
for n in good:
    assert b.valid_branch(n), f"should accept {n!r}"
for n in bad:
    assert not b.valid_branch(n), f"should reject {n!r}"
print("ok")
PY
)"; RC=$?
	ok; has ok
}

test_broker_persists_the_branch_job() {
	OUT="$(python3 - "$BROKER_PY" "$FIX" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d = os.path.join(sys.argv[2], "boxdir"); os.makedirs(d, exist_ok=True)
assert b.box_job(d, "staging", "dev") == {"base": "staging", "merge": "dev"}
# a recreate passes nothing and must get the same job back
assert b.box_job(d, None, None) == {"base": "staging", "merge": "dev"}
d2 = os.path.join(sys.argv[2], "boxdir2"); os.makedirs(d2, exist_ok=True)
assert b.box_job(d2, None, None) == {}
print("ok")
PY
)"; RC=$?
	ok; has ok
}

test_broker_query_params() {
	OUT="$(python3 - "$BROKER_PY" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
class P:
    path = "/box/x?base=release/1.0&merge=dev&fresh=1"
    _param = b.Handler._param
    _flag = b.Handler._flag
p = P()
assert p._param("base") == "release/1.0"
assert p._param("merge") == "dev"
assert p._param("nope") is None
assert p._flag("fresh")
print("ok")
PY
)"; RC=$?
	ok; has ok
}

test_broker_box_mode() {
	OUT="$(MUSTER_BOX_MODE=plan python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
assert b.box_mode_arg() == "--permission-mode plan", b.box_mode_arg()
# the friendly spellings people actually type
for given, want in (("accept-edits","acceptEdits"), ("auto","acceptEdits"), ("bypass","bypassPermissions")):
    b.MUSTER_BOX_MODE = given
    assert b.box_mode_arg() == f"--permission-mode {want}", (given, b.box_mode_arg())
# an unknown mode must NOT reach claude: a rejected flag kills the box at startup, which is far
# harder to diagnose than a mode that quietly did not apply.
b.MUSTER_BOX_MODE = "turbo"
assert b.box_mode_arg() == "", b.box_mode_arg()
b.MUSTER_BOX_MODE = ""
assert b.box_mode_arg() == ""
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

test_broker_box_prompt() {
	OUT="$(python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import base64, importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
os.environ["FROM_THE_ENVIRONMENT"] = "infra-value"
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
b.MUSTER_BOX_PROMPT = "agent $MUSTER_BOX on $MUSTER_BRANCH; env=$FROM_THE_ENVIRONMENT; $NOT_SET stays"
out = base64.b64decode(b.box_prompt("work1", {"MUSTER_BOX": "work1", "MUSTER_BRANCH": "agent/work1"})).decode()
assert "agent work1 on agent/work1" in out, out
assert "env=infra-value" in out, out          # the broker's own environment is in scope
assert "$NOT_SET stays" in out, out           # unknown names are left alone, so prose with $ is safe
# empty prompt -> nothing to pass, not an empty argument
b.MUSTER_BOX_PROMPT = "   "
assert b.box_prompt("work1", {}) == ""
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# =====================================================================  the run

run "syntax: every script parses"                  test_syntax
run "config: no project defaults in the source tree" test_no_project_defaults
run "help: every command is documented"            test_help_covers_every_command
run "help: an unknown command prints usage"        test_unknown_command_prints_usage

run "compose: the box build service is profiled"    test_build_only_service_is_profiled
run "status: empty stack"                          test_status_empty
run "queue: lists a handoff"                       test_queue_lists_a_handoff
run "queue: flags conflicts with dev"              test_queue_flags_conflicts_with_dev
run "status: reports being behind origin"          test_status_reports_behind_origin

run "review: a new branch shows its patches"       test_review_new_branch_shows_patches
run "review: added commits show their diffs"       test_review_added_commits_shows_their_diffs
run "review: an amended branch uses range-diff"    test_review_amended_branch_uses_range_diff
run "review: --full and --net"                     test_review_full_and_net
run "review: an already-merged branch says so"     test_review_of_merged_branch_says_so
run "review: no git warning without a notes ref"   test_review_without_notes_ref_has_no_git_warning

run "fix: delivers the message to the box"         test_fix_delivers_a_message
run "fix: refuses an empty message"                test_fix_without_message_is_refused
run "prereview: asks the agent to self-review"     test_prereview_asks_the_agent

run "merge: plain merge lands and cleans up"       test_merge_plain
run "merge: --squash lands one commit"             test_merge_squash
run "merge: refuses a stale dev"                   test_merge_refuses_stale_dev
run "merge: already-contained closes out"          test_merge_already_contained_closes_out
run "merge: a conflict leaves a way out"           test_merge_conflict_leaves_a_way_out
run "merge: --reword rewrites messages only"       test_merge_reword_rewrites_messages_only
run "merge: --reword keeps edits when you quit"    test_merge_reword_keeps_edits_when_you_quit
run "merge: --reword and --squash are opposites"   test_merge_reword_refuses_squash_and_merges

run "drop: retires the branch and tells the box"   test_drop
run "rebase: asks the box to rebase"               test_rebase_asks_the_box

run "push: nothing to push"                        test_push_nothing_to_do
run "push: dev to origin"                          test_push_dev
run "push: a named branch"                         test_push_named_branch
run "push: rejects an unknown branch"              test_push_rejects_unknown_branch
run "pull: fast-forwards from origin"              test_pull_fast_forward

run "export: produces an mbox"                     test_export_produces_an_mbox
run "import: replaces the agent's branch"          test_import_replaces_the_branch

run "box: spawn / ls / recreate / kill"            test_box_lifecycle
run "forwards: re-establishes them"                test_forwards
run "broker: unreachable is reported, not fatal"   test_broker_unreachable_is_reported_not_fatal
run "version: drift between hub and broker warns"  test_version_drift

run "golden: snapshot, ls, reap"                   test_golden_snapshot_and_reap
run "golden: strips worktrees from the snapshot"   test_golden_snapshot_strips_worktrees

run "svcs: lists the manifests"                    test_svcs_lists_manifests
run "svcs: up and down a service"                  test_service_up_down

run "aliases: forward to the hub"                   test_aliases_forward_to_the_hub
run "aliases: ssh vs mosh transport split"         test_aliases_transport_split
run "aliases: hostile arguments are quoted"        test_aliases_quote_hostile_arguments
run "aliases: attach to a box / the hub"           test_aliases_box_and_hub_attach
run "aliases: pipes never allocate a PTY"          test_aliases_pipes_never_allocate_a_pty
run "aliases: exec into the hub"                   test_aliases_exec_runs_in_the_hub_too
run "aliases: tunnel specs"                        test_aliases_tunnel_specs
run "aliases: refuse an unconfigured stack"        test_aliases_refuse_without_a_server
run "aliases: cbxcp argument checking"             test_aliases_cbxcp_argument_checking
run "aliases: project helpers"                     test_aliases_project_helpers
run "aliases: two stacks side by side"             test_aliases_two_stacks_side_by_side
run "aliases: project helpers are per stack"       test_aliases_project_helpers_are_per_stack
run "aliases: a bad prefix is rejected"            test_aliases_reject_a_bad_prefix
run "aliases: interactive gets a PTY"              test_aliases_interactive_gets_a_pty

run "minto: refuses dev itself"                    test_minto_refuses_dev_itself
run "minto: fast-forward"                          test_minto_fast_forward
run "minto: target already contains dev"           test_minto_already_contains
run "minto: clean merge, worktree untouched"       test_minto_clean_merge_never_touches_the_worktree
run "minto: creates the branch from origin"        test_minto_creates_the_branch_from_origin
run "minto: refuses a stale target, --pull fixes"  test_minto_refuses_a_stale_target
run "minto: a conflict is non-interactive safe"    test_minto_conflict_is_noninteractive_safe
run "minto: --here worktree round trip"            test_minto_here_worktree_roundtrip
run "minto: --abort leaves nothing behind"         test_minto_abort_leaves_nothing_behind
run "minto: --box spawns and briefs the agent"     test_minto_box_spawn_and_brief
run "minto: --box queue, review and land"          test_minto_box_queue_review_and_land
run "minto: --land guards"                         test_minto_land_guards

run "box-init: a minto box opens on the conflict"  test_box_init_minto_sets_up_the_conflict
run "box-init: an ordinary box is unchanged"       test_box_init_ordinary_box

run "broker: branch-name validation"               test_broker_branch_validation
run "broker: the branch job survives a recreate"   test_broker_persists_the_branch_job
run "broker: query parameters"                     test_broker_query_params
run "broker: box mode maps to --permission-mode"   test_broker_box_mode
run "broker: box prompt fills in and base64s"      test_broker_box_prompt

echo
if [ "$TESTS_FAILED" = 0 ]; then
	printf '%s%s passed%s' "$C_G" "$TESTS_RUN" "$C_0"
else
	printf '%s%s of %s failed%s' "$C_R" "$TESTS_FAILED" "$TESTS_RUN" "$C_0"
fi
[ "$TESTS_SKIPPED" = 0 ] || printf ', %s skipped' "$TESTS_SKIPPED"
echo
exit $(( TESTS_FAILED > 0 ))
