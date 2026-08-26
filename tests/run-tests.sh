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
# Overridable like MUSTER_BIN above, so a test can be checked for teeth by running it against a
# mutated copy: BROKER_PY=/tmp/broken.py ./tests/run-tests.sh broker:
BROKER_PY="${BROKER_PY:-$ROOT/box-broker/broker.py}"
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
	ok                                        # asking for help is not an error
	documented="$(printf '%s\n' "$OUT" | sed -n 's/^ *muster \([a-z]*\).*/\1/p' | sort -u)"
	# Aliases and `golden` subcommands are documented on their parent's line, not their own.
	missing="$(comm -23 <(printf '%s\n' "$dispatch") <(printf '%s\n' "$documented") \
		| grep -vx 'seal\|snapshot\|reap\|retire\|migrate\|ls\|st\|queue\|services')"
	eq "$missing" "" "these subcommands are not in cbx --help"
	has "muster push"
	has "muster pull"
	has "muster minto"
	has "muster export"
}

test_unknown_command_prints_usage() {
	cbx bogus-subcommand
	notok
	has "unknown command 'bogus-subcommand'"   # say which word, not just the listing
	has "muster svcs"
	# `help` is a synonym, and neither spelling may exit non-zero: a CI check or a `set -e` script
	# that runs it would otherwise fail on a successful call.
	cbx help; ok; has "muster svcs"
}

# The source tree must stay PROJECT-AGNOSTIC: muster is published on its own, so a project name,
# a private registry or a real credential leaking into a tracked file is a release bug, not a style
# nit. This is the cheap, mechanical half of that check (the rest is the secret scan in
# tools/split-out.sh, which reads history rather than the tip).
# Two halves that only work together: a skill directory is useless if the image does not carry it, and
# the COPY is dead weight if the skill is not a skill. Both are static facts about the tree, so they
# are cheap to assert and exactly the kind of thing a rename breaks silently.
test_skills_ship() {
	local f="$ROOT/skills/muster-pinchtab/SKILL.md"
	exists "$f"
	OUT="$(head -1 "$f")"; has "---"
	OUT="$(cat "$f")"
	has "name: muster-pinchtab"
	# Every skill under skills/ ships the same way, so every skill must be shaped the same way — a
	# missing front-matter name is a file claude silently ignores.
	local s
	for s in "$ROOT"/skills/*/SKILL.md; do
		[ -f "$s" ] || continue
		OUT="$(head -1 "$s")"; has "---"
		OUT="$(cat "$s")"
		has "name: $(basename "$(dirname "$s")")"
		has "description:"
	done
	OUT="$(cat "$ROOT/skills/muster-pinchtab/SKILL.md")"
	# It ADDS to upstream's pinchtab skill rather than replacing it — a different name, and it says so.
	has "pinchtab"
	hasnt "name: pinchtab\n"
	# The hub image must actually carry /opt/muster/skills, next to the copy common-setup.sh fetches
	# from upstream; the entrypoint installs the whole directory into the shared ~/.claude.
	OUT="$(cat "$ROOT/hub/Dockerfile.base")"
	has "COPY skills /opt/muster/skills"
	OUT="$(cat "$ROOT/hub/entrypoint.sh")"
	has "/opt/muster/skills"
}

test_no_project_defaults() {
	local bad=""
	# Every per-stack file that carries credentials or project wiring ships as an .example; the real
	# one is written by hand or by Ansible and is gitignored. A tracked real file = a leak waiting.
	for f in mounts port-forwards service-env box-env compose.project.yml build-setup.sh .env; do
		[ -e "$ROOT/$f.example" ] || [ "$f" = .env ] || fail "missing example: $f.example"
	done
	exists "$ROOT/.env.example"
	exists "$ROOT/service-env.example"
	exists "$ROOT/box-env.example"
	# The working pinchtab server config: the browser half of the stack is muster's to ship, not
	# something every consumer should have to reconstruct from its laptop's copy.
	exists "$ROOT/pinchtab-config.json.example"
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

# Tab-completion INSIDE the hub (hub/muster-completion.bash — the laptop's lives in
# muster.bash_aliases and is tested separately). It reads the filesystem only, so the ordinary
# fixture is all it needs: BOXES_DIR, HUB_SERVICES_DIR and CHECKOUT already point at one.
#
# Driven by calling _muster_complete the way bash does — COMP_WORDS + COMP_CWORD in, COMPREPLY out.
test_hub_completion() {
	fixture
	mkdir -p "$FIX/boxes/work1" "$FIX/services"
	: > "$FIX/services/backend"
	git_ update-ref refs/agents/handed-off HEAD
	OUT="$(MUSTER_PREFIX=cbx bash -c '
		PATH="'"$(dirname "$MUSTER_BIN")"'":$PATH
		source "'"$ROOT"'/hub/muster-completion.bash"
		try() { COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); _muster_complete; echo "${COMPREPLY[*]}"; }
		echo "REGISTERED: $(complete -p muster cbx 2>&1 | grep -c _muster_complete)"
		echo "CMDS: $(try muster "")"
		echo "BOXES: $(try muster review "")"
		echo "SVCS: $(try muster up "")"
		echo "FLAGS: $(try muster merge work1 --)"
	' 2>&1)"; RC=$?
	ok
	# Both names complete: `muster` from the script itself, the stack's prefix from MUSTER_PREFIX.
	has "REGISTERED: 2"
	has "merge"                     # subcommands come from the dispatch case, so this cannot go stale
	# A box with a container directory AND one that only has a handoff ref — review/merge/drop apply
	# to the second too, and it is the one a hand-written list of running containers would miss.
	case "$OUT" in *"BOXES: "*work1*) ;; *) fail "a box directory should complete" ;; esac
	case "$OUT" in *handed-off*) ;; *) fail "a box with only refs/agents/<box> should complete" ;; esac
	case "$OUT" in *"SVCS: backend"*) ;; *) fail "service manifests should complete" ;; esac
	# Flags are scraped from the header block, which is also what --help prints.
	case "$OUT" in *--squash*--reword*|*--reword*--squash*) ;; *) fail "merge flags should complete" ;; esac
	OUT=""
}

# THE IMAGE NAME IS A CONTRACT ACROSS TWO REPOSITORIES. A consumer pins muster as a submodule and
# asks GHCR for `git describe` of the commit it pinned; this workflow has to name the image the same
# way, or the consumer 404s on a server long after everything here looked green. Only muster's half
# can be tested here, so test that half.
test_images_workflow_names_images_by_describe() {
	local wf="$ROOT/.github/workflows/images.yml"
	exists "$wf" || return 0
	OUT="$(cat "$wf")"
	has "describe --tags --always"
	# The default branch must publish, or consuming any unreleased change needs a version tag
	# invented for it. muster's default branch is master, not main — getting that wrong is a
	# workflow that never runs and a `dev` tag that never appears.
	has "branches: [master]"
	has "type=raw,value=dev,enable={{is_default_branch}}"
	# MUSTER_VERSION must come from that describe step and NOT from metadata-action: on a branch push
	# metadata's version output is the branch name, so every master image would call itself "master" and
	# version_drift() would go blind exactly where things move fastest.
	has 'MUSTER_VERSION=${{ steps.ver.outputs.version }}'
	hasnt 'MUSTER_VERSION=${{ steps.meta.outputs.version }}'
	# `latest` stays on releases: it is what a first-time reader pulls. Asserted on the flavor line
	# rather than by banning the string, which the comment above it legitimately mentions.
	has "flavor: latest=false"
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
# NOTHING a deployment starts may carry a `build:`. With one, `docker compose up` silently BUILDS when
# the image is missing — a typo'd tag or a registry that was never pushed to becomes minutes of
# surprise work on a server, ending in a hub running an image nobody published and nobody can
# reproduce. Building belongs to the build profile, where you ask for it.
for n in active:
    assert "build" not in svc[n], f"{n} is startable AND buildable; move its build: to a [build] profile"
assert svc["hub-image"]["profiles"] == ["build"], svc["hub-image"]
assert "HUB_BASE_IMAGE" in svc["hub-image"]["build"]["args"]["BASE_IMAGE"]
assert svc["hub-image"]["build"]["args"]["FINAL_USER"] == "1000", "the hub runs as uid 1000"
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# The stack directory IS a build context (compose.yml uses `context: .`), so .dockerignore is what
# stops a build ON A SERVER from tarring up data/ — the goldens, every box's overlay, and the shared
# claude home, which holds the LOGIN — and handing it to the docker daemon. It is not a copy of
# .gitignore: build-setup.sh is gitignored and MUST be in the context, so the two files disagree on
# purpose and a well-meaning "sync them up" would break every add-on build.
test_dockerignore_protects_the_stack_dir() {
	OUT="$(python3 - "$ROOT" <<'PYEOF' 2>&1
import sys, os, re, pathlib
root = pathlib.Path(sys.argv[1])
pats = [l.split("#")[0].strip() for l in (root / ".dockerignore").read_text().splitlines()]
pats = [p for p in pats if p]

def ignored(path):
    """Would docker drop this path? Enough of the semantics for the two questions below:
    an exact match, or any parent directory listed (with or without a trailing slash)."""
    parts = path.split("/")
    for i in range(1, len(parts) + 1):
        head = "/".join(parts[:i])
        if head in pats or head + "/" in pats:
            return True
    return False

# 1. THE POINT OF THE FILE.
for must in ("data", "data/claude", "data/golden/current", "git-identity", ".env", "service-env"):
    assert ignored(must), f".dockerignore no longer excludes {must!r} — a server build would ship it"

# 2. NOTHING A DOCKERFILE READS MAY BE EXCLUDED. Sources are read from the COPY lines themselves, so
#    this keeps working when a Dockerfile grows one.
copies = []
for df in ("Dockerfile", "Dockerfile.addon", "hub/Dockerfile.base", "box-broker/Dockerfile"):
    text = (root / df).read_text()
    text = re.sub(r"\\\n", " ", text)          # join continuations
    for line in text.splitlines():
        m = re.match(r"\s*COPY\s+(.*)", line)
        if not m:
            continue
        args = [a for a in m.group(1).split() if not a.startswith("--")]
        copies += args[:-1]                       # last arg is the destination
srcs = set()
for c in copies:
    c = c.replace("${SETUP_SCRIPT}", "build-setup.sh")   # the default; a stack may point it elsewhere
    if "$" in c:
        continue
    srcs.add(c)
assert "build-setup.sh" in srcs, "the add-on COPY vanished; this test is checking nothing"
for s in sorted(srcs):
    assert not ignored(s), f".dockerignore excludes {s!r}, which a Dockerfile COPYs — the build will fail"
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# muster-ask is an inference endpoint that untrusted text flows into (a classifieds ad, a scraped
# page), so its whole value is what it REFUSES. These exercise build_argv() directly — no server, no
# claude, no network — because the refusals are the contract:
#   * a request may name a dir KEY, never a PATH (the broker's "callers don't choose mounts", in the
#     small);
#   * a request may only use tools the stack allow-listed, and never Bash/Write/Edit however it is
#     configured — that is the difference between a bounded inference and an agent with a shell;
#   * --permission-mode is not a parameter at all.
test_ask_refuses_what_it_should() {
	OUT="$(ASK_TOKEN=x ASK_DIRS="images=/tmp,other=/var/tmp" ASK_TOOLS="Read,Glob" \
	       python3 - "$ROOT/ask/muster-ask" <<'PYEOF' 2>&1
import sys, importlib.util, importlib.machinery
spec = importlib.util.spec_from_loader("ask", importlib.machinery.SourceFileLoader("ask", sys.argv[1]))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def refused(req, why):
    try:
        m.build_argv(req)
    except m.AskError:
        return
    raise AssertionError(f"ACCEPTED {why}: {req!r}")

def accepted(req):
    return m.build_argv(req)[0]

# A path is not a key, however plausible it looks.
refused({"prompt": "x", "dir": "/etc"}, "an absolute path as dir")
refused({"prompt": "x", "dir": "/tmp"}, "a configured path spelled as a path")
refused({"prompt": "x", "dir": "../images"}, "traversal as dir")
refused({"prompt": "x", "dir": "nope"}, "an unconfigured key")
# Tools outside the allow-list, and the never-allowed ones.
refused({"prompt": "x", "tools": ["Bash"]}, "Bash")
refused({"prompt": "x", "tools": ["Write"]}, "Write")
refused({"prompt": "x", "tools": ["Read", "Bash"]}, "Bash smuggled beside Read")
refused({"prompt": "x", "tools": ["WebFetch"]}, "WebFetch")
refused({"prompt": ""}, "an empty prompt")
refused({"prompt": "x", "tools": "Read"}, "tools as a bare string")

# The happy path resolves the KEY to the configured path, and pins the dangerous flags.
argv = accepted({"prompt": "hello", "dir": "images", "tools": ["Read"]})
assert "--add-dir" in argv and argv[argv.index("--add-dir") + 1] == "/tmp", argv
assert argv[argv.index("--permission-mode") + 1] == "dontAsk", argv
assert argv[argv.index("--output-format") + 1] == "json", argv
assert argv[argv.index("--allowedTools") + 1] == "Read", argv
# No dir asked for, none granted: a text-only call sees nothing.
assert "--add-dir" not in accepted({"prompt": "hello"})
# --permission-mode is NOT A PARAMETER. A request that tries to set it must be ignored rather than
# honoured -- that flag is the whole difference between a bounded inference and an agent.
argv = accepted({"prompt": "x", "permission_mode": "bypassPermissions",
                 "permissionMode": "bypassPermissions", "output_format": "text"})
assert argv.count("--permission-mode") == 1, argv
assert argv[argv.index("--permission-mode") + 1] == "dontAsk", argv
assert "bypassPermissions" not in argv, argv
assert argv[argv.index("--output-format") + 1] == "json", argv
# The timeout is clamped to the ceiling rather than believed.
assert m.build_argv({"prompt": "x", "timeout": 99999})[1] == m.MAX_TIMEOUT
print("ok")
PYEOF
)"; RC=$?
	ok; has ok

	# AND AGAIN WITH ASK_TOOLS DELIBERATELY MISCONFIGURED. The block above only proves the allow-list
	# works; this proves FORBIDDEN_TOOLS overrides it, so an operator who types Bash into ASK_TOOLS —
	# or a stack that inherits a careless default — still cannot get a shell out of untrusted text.
	OUT="$(ASK_TOKEN=x ASK_TOOLS="Read,Bash,Write" \
	       python3 - "$ROOT/ask/muster-ask" <<'PYEOF' 2>&1
import sys, importlib.util, importlib.machinery
spec = importlib.util.spec_from_loader("ask2", importlib.machinery.SourceFileLoader("ask2", sys.argv[1]))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.ALLOWED_TOOLS == ["Read"], f"ASK_TOOLS=Read,Bash,Write must reduce to [Read], got {m.ALLOWED_TOOLS}"
try:
    m.build_argv({"prompt": "x", "tools": ["Bash"]})
except m.AskError:
    print("ok")
else:
    raise AssertionError("ACCEPTED Bash even though FORBIDDEN_TOOLS lists it")
PYEOF
)"; RC=$?
	ok; has ok
}

# ASK_TOKEN is the only thing between an inference endpoint and everything else on the stack network,
# so "no token" must be a refusal to START, not a service that runs open. Checked by running main()
# with the variable unset and requiring a non-zero exit that says so.
test_ask_refuses_to_run_without_a_token() {
	OUT="$(cd "$ROOT" && env -u ASK_TOKEN python3 ask/muster-ask 2>&1)"; RC=$?
	notok
	has "ASK_TOKEN is required"
}

# THE HALF THE GUARD USED TO MISS. `golden snapshot` recreates every box with a fresh upper layer, and
# the box's .git is IN that layer — so an agent that committed its work and never ran `handoff` has a
# clean `git status` and commits that exist nowhere else. The old check ran `git status --porcelain`
# and nothing more, so it waved that box straight through to being deleted, while its own error
# message told you to "commit + handoff". Both halves are checked now.
test_golden_snapshot_leaves_unsafe_boxes_behind() {
	local port pid unknown ahead
	port=$(( STUB_PORT + 6 ))
	unknown="0123456789abcdef0123456789abcdef01234567"   # a sha the hub has certainly never seen

	# …and a commit the hub DOES have, but which is ahead of what the box last handed off.
	git -C "$FIX/repo" update-ref "refs/agents/aheadbox" "$(git -C "$FIX/repo" rev-parse "$DEV_BRANCH")"
	echo "later" >> "$FIX/repo/a.txt"
	git -C "$FIX/repo" add a.txt
	git -C "$FIX/repo" -c user.name=t -c user.email=t@x commit -qm "one more"
	ahead="$(git -C "$FIX/repo" rev-parse HEAD)"
	git -C "$FIX/repo" reset -q --hard HEAD^

	STUB_LOG="$FIX/stub6.log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" \
		STUB_PORT="$port" \
		STUB_BOX_STATE="{\"newbox\": {\"head\": \"$unknown\"}, \"dirtybox\": {\"dirty\": [\" M a.txt\"], \"head\": \"$ahead\"}}" \
		python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	export BROKER_URL="http://127.0.0.1:$port"

	# COMMITTED, NEVER HANDED OFF — the half the guard used to miss entirely. `git status` is clean, so
	# the old check waved this box through to having its commits deleted.
	cbx box newbox >/dev/null 2>&1
	cbx golden snapshot
	ok                                        # the snapshot still happens — that is the new deal
	has "never seen"
	has "stayed on their old golden"
	has "golden migrate"
	# …and it was NOT moved: no recreate for it.
	grep -q '"/recreate/newbox' "$FIX/stub6.log" && fail "a box that is not ready was moved anyway"

	# UNCOMMITTED FILES — the half that was always checked. Same outcome now: left behind, not refused.
	cbx box dirtybox >/dev/null 2>&1
	cbx golden snapshot
	ok
	has "uncommitted changes"
	has "stayed on their old golden"

	# --force moves them across regardless, and says what that costs.
	cbx golden snapshot --force
	ok
	has "work that was not handed off is GONE"
	# With nothing left blocked, the code takes the recreate-ALL route (one image pull for the lot),
	# so the evidence is /recreate?fresh=1 rather than a per-box call.
	grep -q '"path": "/recreate?fresh=1"' "$FIX/stub6.log" || fail "--force did not move the blocked boxes"

	unset BROKER_URL
	kill "$pid" 2>/dev/null
}


# `golden migrate` is how a box with UNCOMMITTED work crosses onto a new golden: its working tree is
# captured into ~/keep (the one part of a box that outlives the overlay), the box is recreated fresh,
# and the patch is re-applied. What matters here is the ORDER and the refusals — the patch mechanics
# live in box-bin/muster-migrate, inside the box.
test_golden_migrate() {
	local port pid ahead
	port=$(( STUB_PORT + 7 ))
	git -C "$FIX/repo" update-ref "refs/agents/carry" "$(git -C "$FIX/repo" rev-parse "$DEV_BRANCH")"
	echo "hub-side edit" >> "$FIX/repo/a.txt"          # the hub's own dirty file -> baked into the golden
	ahead="$(git -C "$FIX/repo" rev-parse HEAD)"

	STUB_LOG="$FIX/stub7.log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" \
		STUB_PORT="$port" \
		STUB_BOX_STATE="{\"carry\": {\"dirty\": [\" M b.txt\"], \"head\": \"$ahead\"}, \"clash\": {\"dirty\": [\" M a.txt\"], \"head\": \"$ahead\"}, \"unpushed\": {\"head\": \"0000000000000000000000000000000000000000\"}}" \
		python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	export BROKER_URL="http://127.0.0.1:$port"
	cbx golden snapshot >/dev/null 2>&1                # a golden that carries the hub's dirty a.txt

	# 1. A box with commits nobody has: refused, because a patch cannot carry commits. Finding that
	#    out AFTER the recreate would be the worst possible moment.
	cbx box unpushed >/dev/null 2>&1
	cbx golden migrate unpushed
	has "never seen"
	has "handoff in the box first"
	grep -q '"/box/unpushed/migrate/stash' "$FIX/stub7.log" && fail "it stashed a box it had refused"

	# 2. The ordinary case: stash, recreate FRESH, apply — in that order. The order is the whole
	#    correctness argument: capture before the layer is deleted, re-apply after.
	cbx box carry >/dev/null 2>&1
	cbx golden migrate carry
	ok
	has "carrying"
	has "b.txt"
	stub_order "$FIX/stub7.log" "/box/carry/migrate/stash" "/recreate/carry?fresh=1" "/box/carry/migrate/apply"

	# 3. A path that is ALSO uncommitted in the new golden. Non-interactive and no --force: skipped,
	#    and named — this collision is what the command exists to show you before it happens.
	cbx box clash >/dev/null 2>&1
	cbx golden migrate clash
	has "ALSO uncommitted in the new golden"
	has "a.txt"
	has "skipped"
	grep -q '"/recreate/clash' "$FIX/stub7.log" && fail "a clashing box was moved without being asked"

	# …and --force takes it across anyway.
	cbx golden migrate clash --force
	ok
	grep -q '"/recreate/clash' "$FIX/stub7.log" || fail "--force did not move the clashing box"

	unset BROKER_URL
	kill "$pid" 2>/dev/null
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

# UNDOING A MERGE. It is possible at all because merge uses --no-ff: the agent's tip is the merge
# commit's SECOND parent, so the handoff is still in the history and the queue entry is one update-ref
# away. The deleted ref's reflog is not a way back — git removes a reflog with its ref — which is why
# this reads the parent instead.
test_merge_undo() {
	local sha before
	sha="$(handoff work1 2)"; box_up work1
	before="$(at dev)"
	cbx merge work1; ok
	cbx merge work1 --undo
	ok
	eq "$(at dev)" "$before" "dev must be back where it was"
	eq "$(at refs/agents/work1)" "$sha" "the agent's branch must be back in the queue, at its own tip"
	has "back at"
	# The box is told, because it was told to rebase when the merge finished and the ground just moved.
	stub_saw POST "/box/work1/say" || fail "the box was never told the merge was undone"
	# And it really is in the queue again.
	cbx q --text; has "work1"
}

# Refusals, both of which exist so an undo cannot take something else with it.
test_merge_undo_refuses() {
	handoff work1 1 >/dev/null; box_up work1
	cbx merge work1; ok
	# Something landed after the merge: undoing would remove that too.
	git_ commit -q --allow-empty -m "a later commit"
	cbx merge work1 --undo
	notok; has "not the tip"; has "revert -m 1"
	eq "$(git_ log -1 --format=%s dev)" "a later commit" "dev must not have moved"
	# …and once it is on origin, rewinding would need a force-push.
	git_ reset --hard HEAD~1 -q 2>/dev/null || git_ reset --hard HEAD~1
	git_ update-ref refs/remotes/origin/dev "$(at dev)"
	cbx merge work1 --undo
	notok; has "already on origin"; has "revert -m 1"
	git_ update-ref -d refs/remotes/origin/dev
	# With that out of the way it works.
	cbx merge work1 --undo; ok
}

# A --squash merge has ONE parent, so the branch cannot be restored from it. Say so rather than
# leaving the queue looking right and the commits gone.
test_merge_undo_after_squash() {
	handoff work1 2 >/dev/null; box_up work1
	local before; before="$(at dev)"
	cbx merge work1 --squash; ok
	cbx merge work1 --undo
	ok
	eq "$(at dev)" "$before" "dev must still be rewound"
	eq "$(at refs/agents/work1)" "" "there is nothing to restore the ref from"
	has "no second parent"
	has "handoff"
}

test_merge_squash() {
	handoff work1 3 >/dev/null; box_up work1
	cbx merge work1 --squash
	ok
	eq "$(git_ rev-list --count dev)" "2" "squash should land exactly one commit"
	OUT="$(git_ log -1 --format=%B dev)"
	has "Cbx-Box: work1"
}

# FLAGS ANYWHERE. `merge --squash <box>` used to die with "unknown option '<box>'", because every
# command took $1 as its positional and treated the rest as flags — so the order that reads naturally
# was the one that failed. Asserted per command, not on the helper alone: the bug was never in the
# parsing, it was in which functions got wired to it.
test_flags_before_the_positional() {
	# review first: it needs a box that has handed off, and the merge below consumes one.
	handoff work2 1 >/dev/null; box_up work2
	cbx review --plain work2
	ok

	handoff work1 3 >/dev/null; box_up work1
	cbx merge --squash work1
	ok
	eq "$(git_ rev-list --count dev)" "2" "--squash before the name should still squash"

	# A value-taking flag keeps its value when it moves ahead of the positional. --intent is only
	# consulted when there is a conflict to resolve — that is the whole point of it — so this needs the
	# conflict fixture rather than a clean merge.
	setup_minto_conflict
	cbx minto --intent "integration branch for the staging server" --box staging
	ok
	eq "$(sed -n 4p "$FIX/repo/.git/cbx/minto-staging.mergeinto")" \
	   "integration branch for the staging server" "the value must travel with its flag"

	# --tail takes an OPTIONAL count, so the reordering must not let it swallow the service name.
	# Asserted on the parse, not the outcome: no service has ever run in the fixture, so both spellings
	# get as far as "nothing captured for 'web'" — which is exactly how far we need them to get.
	cbx logs --tail 5 web
	notok
	has "no captured output for 'web'"
	hasnt "unknown option"
	cbx logs --tail web
	notok
	has "no captured output for 'web'"
	hasnt "unknown option"
}

# THE BOX'S SESSION TOKEN IS THE WHOLE ADDRESS. Everything in this family works by running pinchtab as
# the box — same session, therefore same tab — so the one thing worth asserting hardest is that the
# token actually reaches the call, and that a box without one fails with an explanation instead of
# silently capturing somebody else's tab.
test_peek_uses_the_box_session() {
	stub_pinchtab
	box_pt_session work1 ses_work1token
	cbx peek work1
	ok
	OUT="$(pt_log)"
	has "session=ses_work1token"
	has "screenshot"

	# --snap is text: it prints the tree rather than writing a file.
	cbx peek work1 --snap
	ok
	has "button"
	OUT="$(pt_log)"; has "args=snap"

	# point draws the overlay FIRST, then captures — the labels are in the DOM, so they are in the image.
	: > "$FIX/pinchtab.log"
	cbx point work1 --selector '#pricing'
	ok
	OUT="$(pt_log)"
	has "annotate --selector #pricing"
	has "screenshot"
	case "$(pt_log)" in *annotate*screenshot*) ;; *) fail "annotate must run before the screenshot" ;; esac
}

test_peek_without_a_session_explains() {
	stub_pinchtab
	cbx peek work1
	notok
	has "no pinchtab session"
	# The fix, not just the fault.
	has "muster-pinchtab-session"
	OUT="$(pt_log)"; hasnt "screenshot"
}

# hold/release go over HTTP rather than the CLI: `pinchtab tab handoff` wants a tab id, while the
# shorthand route acts on the session's CURRENT tab, which is the tab we mean.
test_hold_pauses_with_a_timeout() {
	stub_pinchtab
	box_pt_session work1
	mkdir -p "$FIX/bin"
	cat > "$FIX/bin/curl" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >> "$FIX/curl.log"
exit 0
EOF
	chmod +x "$FIX/bin/curl"
	: > "$FIX/curl.log"
	cbx hold work1 --reason 'setting up the cart' --timeout 30
	ok
	has "PAUSED"
	OUT="$(cat "$FIX/curl.log")"
	has "/handoff"
	has "Authorization: Session ses_deadbeef"
	# Milliseconds, and always present: a tab paused forever is a box you have to remember to release.
	has '"timeoutMs":30000'
	has "setting up the cart"

	cbx release work1
	OUT="$(cat "$FIX/curl.log")"; has "/resume"
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

# A DIRTY HUB TREE THE MERGE WOULD WRITE OVER. The hub's checkout is dirty by design — it is what
# goldens are snapshotted from — and merge-tree's preflight is blind to it: branch-to-branch the merge
# is clean, and then git refuses to start ("Your local changes to the following files would be
# overwritten by merge"). The old code printed a note promising it would abort "only if it would
# overwrite one" and left you to find out which way it went by running it, then reported the refusal
# as conflicts and pointed at --landed — which would have retired the branch with nothing merged.
test_merge_refuses_over_dirty_files() {
	local before
	commit_on dev refs/agents/work1 "agent: a" a.txt "agent version" >/dev/null
	before="$(at dev)"
	printf 'work in progress\n' > "$FIX/repo/a.txt"         # tracked, modified, and in the merge's way
	cbx merge work1
	notok
	has "uncommitted changes"
	has "a.txt"
	has "nothing has been touched"
	hasnt "--landed"                                        # nothing landed, so never suggest it
	hasnt "merge conflicts"                                 # and it is not a conflict
	eq "$(at dev)" "$before" "dev must not move"
	ne "$(at refs/agents/work1)" "" "the branch must stay in the queue"
	# An UNTRACKED file the merge would ADD is refused by git just the same, so it counts too.
	git_ checkout -q -- a.txt
	printf 'mine\n' > "$FIX/repo/new.txt"
	commit_on "$(at refs/agents/work1)" refs/agents/work1 "agent: new" new.txt "theirs" >/dev/null
	cbx merge work1
	notok; has "new.txt"; has "uncommitted changes"
	eq "$(at dev)" "$before" "dev must not move for an untracked collision either"
	# A dirty file the merge does NOT touch is none of its business: the merge goes through and the
	# local change survives it. That is the everyday state of the hub's tree.
	rm -f "$FIX/repo/new.txt"
	printf 'unrelated wip\n' > "$FIX/repo/b.txt"
	box_up work1
	cbx merge work1
	ok
	ne "$(at dev)" "$before" "an unrelated dirty file must not block the merge"
	eq "$(cat "$FIX/repo/b.txt")" "unrelated wip" "the local change must survive the merge"
}

# A MERGE THAT FAILS TO START IS NOT A CONFLICT. Still reachable with the preflight above, because
# that only speaks for merges merge-tree can compute: when the branches themselves conflict there is
# no merged tree to compare the dirty files against, so a non-terminal run says "merging anyway" and
# git refuses over the local change instead. Nothing is merged and nothing is left half-done — which
# is what the old "resolve them, then --landed" advice was most wrong about, since --landed would have
# retired the branch and told the box its work had landed.
test_merge_failure_is_not_always_a_conflict() {
	local before sha
	sha="$(commit_on dev - "agent: b" b.txt "agent version")"
	git_ update-ref refs/agents/work1 "$sha"
	commit_on dev refs/heads/dev "dev: b" b.txt "dev version" >/dev/null
	before="$(at dev)"
	printf 'and mine too\n' > "$FIX/repo/b.txt"             # dirty, and both sides changed it
	cbx merge work1
	notok
	has "would CONFLICT in"                                 # the preflight still says its piece…
	has "NOTHING was merged"                                # …and the failure is reported honestly
	hasnt "merge conflicts"
	hasnt "--landed"
	eq "$(at dev)" "$before" "dev must not move"
	eq "$(git_ ls-files --unmerged)" "" "nothing may be left half-merged"
}

# ASK BEFORE THE MESS. A merge that will conflict is worth knowing about while dev is still untouched:
# the usual answer is "stop and rebase the agent first", and that decision is much cheaper before a
# half-merged worktree than after one.
test_merge_conflict_asks_first() {
	command -v script >/dev/null || { skip "no 'script' for driving the prompt"; return 0; }
	local sha before
	sha="$(commit_on dev - "agent: b" b.txt "agent version")"
	git_ update-ref refs/agents/work1 "$sha"
	commit_on dev refs/heads/dev "dev: b" b.txt "dev version" >/dev/null
	box_up work1
	before="$(at dev)"
	# [r] — rebase instead: the box is told, dev is untouched, the branch stays in the queue.
	muster_tty "r" merge work1
	ok
	has "would CONFLICT in"
	has "b.txt"
	eq "$(at dev)" "$before" "dev must not move when you choose to rebase"
	ne "$(at refs/agents/work1)" "" "the branch must stay in the queue"
	stub_saw POST "/box/work1/say" || fail "the box was never asked to rebase"
	# [q] — quit changes nothing either.
	muster_tty "q" merge work1
	notok; has "not merged"
	eq "$(at dev)" "$before" "quitting must not move dev"
	# [m] — merge anyway, which lands you in the conflict you were warned about.
	muster_tty "m" merge work1
	notok; has "merge conflicts"
	git_ merge --abort 2>/dev/null || git_ reset --merge 2>/dev/null || true
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

# A REBASE CANNOT START ON A DIRTY TREE, and the agent is the one standing there when it refuses.
# Left unsaid, the recoveries it invents are not equivalent: `git stash` puts work somewhere a
# conflict can lose it, and `git add -A` commits the files a project keeps untracked on purpose. So
# both prompts that ask for a rebase have to carry the by-path instruction — and ask to be told what
# was committed, because a commit made on the agent's own judgement should not be a surprise later.
test_rebase_prompt_covers_a_dirty_tree() {
	handoff work1 1 >/dev/null; box_up work1
	commit_on dev refs/heads/dev "dev moved" c.txt moved >/dev/null
	cbx rebase work1
	ok
	local msg; msg="$(stub_body /box/work1/say)"
	case "$msg" in *"working tree is dirty"*) ;; *) fail "the dirty-tree case is not covered" ;; esac
	case "$msg" in *"'git add' the specific paths"*) ;; *) fail "committing BY PATH is not spelled out" ;; esac
	case "$msg" in *"git add -A"*) ;; *) fail "'git add -A' is not ruled out" ;; esac
	case "$msg" in *"git stash"*) ;; *) fail "'git stash' is not ruled out" ;; esac
	case "$msg" in *"Say in one line what you committed"*) ;; *) fail "the agent is not asked to report the commit" ;; esac
}

# The same instruction, on the OTHER prompt that asks for a rebase: the one merge sends when it has
# just landed the box's work. Same tree, same refusal, same wrong recoveries.
test_merge_rebase_prompt_covers_a_dirty_tree() {
	handoff work1 1 >/dev/null; box_up work1
	cbx merge work1 >/dev/null
	ok
	case "$(stub_body /box/work1/say)" in *"working tree is dirty"*) ;; *) fail "merge's rebase prompt lost the dirty-tree case" ;; esac
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
	# -y means "no prompt AND none of the exposition that leads up to it". The listing exists to inform
	# an answer already given, it goes through the PAGER (so a scripted push on a tty could sit in
	# `less` waiting for a keypress nobody will press), and the commit subject is what gives it away.
	hasnt "local work"
	hasnt "would go to origin"
}

# …and without -y the preview is still there: that is the last chance to notice a stray file or a
# second box's work before the one irreversible step in the loop.
test_push_shows_the_preview_when_asking() {
	commit_on dev refs/heads/dev "visible work" c.txt visible >/dev/null
	# Not a terminal, so the confirm is skipped and the push proceeds — the preview must still print.
	cbx push
	ok
	has "would go to origin"
	has "visible work"
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

# A REFUSAL HAS TO BE READABLE. The broker's reasons are sentences; the hub used to print the JSON
# they arrived in, so you read `{"error": "box name 'x' is 50 characters…"}` and parsed it yourself.
test_box_name_rejection_is_readable() {
	local long
	long="$(printf 'a%.0s' $(seq 1 60))"
	cbx box "$long"
	notok
	has "is 60 characters"        # the sentence survived
	has "the limit is"
	hasnt '{"error"'              # …without the wrapper it came in
	# A name at the limit is not refused — the boundary belongs to the usable side.
	cbx box "$(printf 'b%.0s' $(seq 1 54))"
	ok
}

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

# A KILLED BOX IS STILL THERE, and until now nothing said so: kill keeps the directory (unpushed work
# + warm caches, and `box <same name>` reattaches to it), so they accumulate unseen — holding disk, and
# once upon a time holding port slots too. `ls` lists them; `purge` is the way to actually be rid of one.
test_box_retired_and_purge() {
	cbx box gone; ok
	cbx kill gone; ok
	cbx ls
	ok
	has "retired"
	has "gone"
	has "on disk"                       # a size, because deciding what to purge is a size question
	# Purging refuses while the box's work is still sitting in the review queue unlooked-at.
	git_ update-ref refs/agents/gone "$(at dev)"
	cbx purge gone
	notok; has "still has a handoff"; has "--force"
	git_ update-ref -d refs/agents/gone
	# With nothing waiting, it goes — and the state files go with it.
	mkdir -p "$FIX/repo/.git/cbx"; : > "$FIX/repo/.git/cbx/gone.reviewed"
	cbx purge gone
	ok; has "purged"
	absent "$FIX/repo/.git/cbx/gone.reviewed"
	cbx ls; ok; hasnt "gone"
	# --force is the override for a box you have already decided about.
	cbx box gone2; ok; cbx kill gone2; ok
	git_ update-ref refs/agents/gone2 "$(at dev)"
	cbx purge gone2 --force
	ok; has "purged"
	git_ update-ref -d refs/agents/gone2 2>/dev/null || true
}

# MEASURING RETIRED BOXES COSTS SECONDS, so only the command that prints the number asks for it.
# dir_size walks a retired box's whole upper layer — checkout + node_modules + gradle caches + build
# output. On the stack this was written for that came to 347,200 files across 34 retired boxes: 2.4s
# per request, on the endpoint the live dashboard polls twice per 5-second repaint, for a number the
# dashboard does not display. `cbx ls` prints it and is typed by a person who can wait; nothing else.
test_retired_sizes_only_ls_pays_for_them() {
	cbx box sizebox; ok
	cbx kill sizebox; ok
	: > "$STUB_LOG"
	cbx ls; ok
	has "retired"; has "on disk: 11M"          # the stub's 12345678 bytes, so a size really arrived
	stub_saw GET "/box?sizes=1" || fail "ls must ask for the retired sizes — it is what prints them"
	# The dashboard: same listing, no sizes. Assert on the REQUEST, not the output — a hub that asks
	# and then ignores the answer has not stopped paying for it.
	: > "$STUB_LOG"
	cbx status --no-fetch; ok
	stub_saw GET "/box" || fail "the dashboard still needs the box listing"
	if grep -q sizes "$STUB_LOG"; then
		fail "the dashboard must not ask for retired sizes" "it walks every file of every retired box"
	fi
}

# A size the broker did not send must not print as '0B'. An older broker, or a newer one that ignored
# ?sizes=1, leaves the field absent — and "0B" reads as "empty, nothing to lose" about a directory
# that may be holding an agent's unpushed work. '?' says only what we know.
test_retired_size_unknown_prints_a_question_mark() {
	cbx box nosize; ok
	cbx kill nosize; ok
	: > "$STUB_LOG.ignore-sizes"                # the stub now answers as a broker that has no sizes
	cbx ls; RC_SAVED=$RC
	rm -f "$STUB_LOG.ignore-sizes"
	RC=$RC_SAVED; ok
	has "nosize"; has "on disk: ?"
	hasnt "on disk: 0B"
}

# ONE BOX LISTING PER DASHBOARD FRAME. A frame needs it twice (activity_snapshot for the bell,
# status_overview for the table) and each runs in its own subshell, so the watch loop fetches it into
# BOX_LIST_CACHE and both read that. Set = "a frame is in progress"; unset = "go and ask".
test_box_list_is_fetched_once_per_frame() {
	box_up work1
	: > "$STUB_LOG"
	BOX_LIST_CACHE='{"boxes":[],"retired":[]}' cbx status --no-fetch; ok
	if grep -q '"path": "/box"' "$STUB_LOG"; then
		fail "status_overview must reuse the frame's listing, not request its own"
	fi
	# …and with no frame in progress it still asks, exactly once, so one-shot commands are unaffected.
	# The unset is not decoration: a var assignment prefixed to a FUNCTION call outlives it in bash.
	unset BOX_LIST_CACHE
	: > "$STUB_LOG"
	cbx status --no-fetch; ok
	eq "$(grep -c '"path": "/box"' "$STUB_LOG")" "1" "a one-shot status should make one /box request"
}

# The same property end to end, through the live dashboard that actually fills the cache: one frame,
# one request. Before this, every repaint asked twice.
test_q_frame_makes_one_box_request() {
	command -v script >/dev/null || { skip "no 'script' to give q a terminal"; return 0; }
	box_up work1
	: > "$STUB_LOG"
	# -n 9 so the 2s window holds exactly one frame however slow the machine is; q dies mid-wait.
	timeout 2 script -qec "bash '$MUSTER_BIN' q -n 9 --no-bell" /dev/null >/dev/null 2>&1 || true
	eq "$(grep -c '"path": "/box"' "$STUB_LOG")" "1" "one dashboard frame should make one /box request"
}

# THE FIRST FRAME MUST NOT FETCH. `git fetch` is the one network call in a frame and it runs before
# anything is printed, so paying it on frame one is 1-2 seconds of blank screen between typing `q`
# and seeing anything — the worst moment to spend them, for the least urgent numbers on the screen.
# FETCH_HEAD is the evidence: git writes it on every fetch and on nothing else.
test_q_first_frame_does_not_fetch() {
	command -v script >/dev/null || { skip "no 'script' to give q a terminal"; return 0; }
	rm -f "$FIX/repo/.git/FETCH_HEAD"
	timeout 2 script -qec "bash '$MUSTER_BIN' q -n 9 --no-bell" /dev/null >/dev/null 2>&1 || true
	absent "$FIX/repo/.git/FETCH_HEAD"
	# TEETH: the same overview fetches when it is NOT frame one of the dashboard, so the assertion
	# above is about when we fetch, not about a fetch that could never have happened here.
	cbx status; ok
	exists "$FIX/repo/.git/FETCH_HEAD"
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

# HOW FAR the golden trails dev, not just that it does. Every box overlays that tree, so the number is
# the gap each new agent starts with and has to rebase across — and "dev has moved" reads identically
# after one merge and after thirty.
test_q_shows_golden_drift() {
	local port pid
	port=$(( STUB_PORT + 3 ))
	STUB_LOG="$FIX/stub4.log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" \
		STUB_PORT="$port" python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	BROKER_URL="http://127.0.0.1:$port" cbx golden snapshot >/dev/null 2>&1
	# `status` renders the same overview the live `q` dashboard does (q --text is the bare table), so
	# it is what a one-shot test can assert on.
	# Fresh: no drift line at all.
	BROKER_URL="http://127.0.0.1:$port" cbx status
	ok
	hasnt "commit(s) behind"
	# Three commits later it says three.
	# Real file changes, because the point of the message is how much a new box would copy up.
	local i
	for i in 1 2 3; do commit_on dev refs/heads/dev "later $i" "later$i.txt" "$(printf 'x%.0s' $(seq 400))" >/dev/null; done
	BROKER_URL="http://127.0.0.1:$port" cbx status
	ok
	has "3 commit(s) behind"
	# …and WHAT that costs, since the boxes' git state is current either way: the copy-up.
	has "copies up"
	has "file(s)"
	hasnt "fresher base"
	# With no boxes on the golden there is nothing to multiply by, and it says nothing about totals.
	hasnt "duplicated across"
	# Two boxes on it (one running, one killed — both keep a directory and an upper layer), one on an
	# older golden that must not be counted.
	local gid; gid="$(printf '%s\n' "$OUT" | sed -n 's/^  \(g-[^ ]*\) from .*/\1/p' | head -1)"
	mkdir -p "$FIX/boxes/one" "$FIX/boxes/two" "$FIX/boxes/elsewhere"
	printf '%s\n' "$gid" > "$FIX/boxes/one/golden"
	printf '%s\n' "$gid" > "$FIX/boxes/two/golden"
	printf '%s\n' "g-ancient" > "$FIX/boxes/elsewhere/golden"
	BROKER_URL="http://127.0.0.1:$port" cbx status
	ok
	has "2 box(es) sit on it"
	has "duplicated across"
	kill "$pid" 2>/dev/null
}

# RETIRING A GOLDEN THAT BOXES ARE STILL ON. `reap` skips those on purpose — a golden is the lowerdir
# of every box overlaid on it — so the question is never "can I delete it" but "what happens to its
# boxes". Moving is real: a box is an overlay, so recreate respawns it on the CURRENT golden with its
# own upper layer (its unpushed work) intact.
test_golden_retire() {
	command -v script >/dev/null || { skip "no 'script' for driving the prompt"; return 0; }
	local port pid old cur
	port=$(( STUB_PORT + 4 ))
	STUB_LOG="$FIX/stub5.log" GOLDEN_DIR="$FIX/golden" GOLDEN_STAGING="$FIX/golden-staging" \
		STUB_PORT="$port" python3 "$HERE/stub-broker.py" & pid=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$port/box" && break; sleep 0.2; done
	export BROKER_URL="http://127.0.0.1:$port"
	cbx golden snapshot >/dev/null 2>&1            # g1 becomes current
	cbx golden ls; old="$(printf '%s\n' "$OUT" | sed -n 's/^current: //p' | head -1)"
	cbx box onold; ok                              # …and this box overlays it
	# A second `golden snapshot` would MOVE that box onto the new golden (that is what snapshot does),
	# leaving nothing to retire. The state this command is for — a box left behind on an older golden —
	# is what a seal produces: it flips `current` and touches no box.
	cur=g-newer
	mkdir -p "$FIX/golden-staging/$cur"
	curl -sf -X POST -H "X-Broker-Token: test" "$BROKER_URL/golden/seal/$cur" >/dev/null
	ne "$old" "$cur" "the fixture needs two goldens"
	# The CURRENT golden can never be retired: every new box overlays it.
	cbx golden retire "$cur"
	notok; has "CURRENT golden"
	# Non-interactive: refuses rather than guessing what to do with the box.
	cbx golden retire "$old"
	notok; has "still overlaid"; has "not a terminal"
	# [q] does nothing.
	muster_tty "q" golden retire "$old"
	notok; has "nothing done"
	# [m] moves the box onto the current golden, then reaps.
	muster_tty "m" golden retire "$old"
	ok; has "moving"
	# The golden must actually be GONE — "reaped:" alone is printed even when the list is empty, which
	# is exactly what a move that did not move would produce.
	case "$OUT" in *reaped*"$old"*) ;; *) fail "the old golden was not reaped" "$OUT" ;; esac
	absent "$FIX/golden/$old"
	unset BROKER_URL
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

# MUSTER SHIPS SOME SERVICES ITSELF. pinchtab is not an example a consumer has to notice and copy —
# without a browser an agent verifies against fixtures and reports success — so its manifest lives in
# the image, and the stack's own hub-services/ overrides one by FILENAME.
test_svcs_builtin_and_override() {
	fixture
	export HUB_SERVICES_BUILTIN="$ROOT/hub/services"
	cbx svcs
	ok
	has "pinchtab"                                   # present with an EMPTY stack hub-services dir
	has "headless Chrome bridge"
	# The stack's own file wins, by filename…
	cat > "$FIX/services/pinchtab" <<-'EOF'
		description=ours instead
		command=sleep 600
	EOF
	cbx svcs
	ok
	has "ours instead"
	hasnt "headless Chrome bridge"
	# …and the name is listed ONCE, not once per directory it appears in.
	eq "$(printf '%s\n' "$OUT" | grep -c 'pinchtab')" "1" "an overridden service must be listed once"
	unset HUB_SERVICES_BUILTIN
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

# A SERVICE THAT FAILS TO START MUST LEAVE ITS OUTPUT SOMEWHERE READABLE. The window says "backend
# exited" and waits — and by then the error can be unreachable: a laptop tmux around the ssh swallows
# the scroll keys, and pressing enter closes the window for good. So every service's output is copied
# to a file as it runs (tmux pipe-pane, which touches neither the process nor its tty), and `logs
# --tail` prints it into YOUR terminal, where your own scrollback keeps it.
test_service_output_is_captured() {
	command -v tmux >/dev/null || { skip "tmux is not installed"; return 0; }
	cat > "$FIX/services/failer" <<-'EOF'
		description=fails the way a build does
		command=echo compiling; echo "BUILD FAILED in 18s" >&2; false
	EOF
	export TMUX_SESSION="mustertest-$$"
	if ! tmux new-session -d -s "$TMUX_SESSION" -c "$FIX" -n shell 2>/dev/null; then
		unset TMUX_SESSION; skip "no usable tmux server here"; return 0
	fi
	cbx up failer; ok
	# pipe-pane copies asynchronously, so give the file a moment to appear.
	local f i; f="$FIX/repo/.git/cbx/logs/failer.log"
	for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$f" ] && break; sleep 0.3; done
	cbx logs failer --tail 50
	ok
	has "BUILD FAILED in 18s"          # the error itself, with nothing to attach to
	has "exited (status 1)"            # …and why the window is sitting there
	cbx logs failer --file; ok; has "failer.log"
	cbx logs failer --tail; ok         # N defaults rather than erroring
	cbx logs never-started --tail 5; notok; has "no captured output"
	cbx logs failer --wat; notok; has "unknown option"
	tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
	unset TMUX_SESSION
}

# A SERVICE THAT DIED MUST NOT REPORT AS UP. The window outlives the command on purpose (the failure
# has to stay readable), so "a window called pinchtab exists" and "pinchtab is serving" are different
# facts — and treating them as one is how a crashed pinchtab kept `svcs` saying up while agents got
# "server at hub:9867 is not running", with `up pinchtab` answering "already running" and doing
# nothing. It also unblocks golden snapshots, which refuse while a writes_repo service is "running".
test_service_dead_window_is_not_up() {
	command -v tmux >/dev/null || { skip "tmux is not installed"; return 0; }
	cat > "$FIX/services/dier" <<-'EOF'
		description=dies like a crashed server
		command=echo serving; false
	EOF
	export TMUX_SESSION="mustertest-$$"
	if ! tmux new-session -d -s "$TMUX_SESSION" -c "$FIX" -n shell 2>/dev/null; then
		unset TMUX_SESSION; skip "no usable tmux server here"; return 0
	fi
	cbx up dier; ok; has "started dier"
	# The wrapper writes the exit status as the command dies; wait for it rather than race it.
	local f i; f="$FIX/repo/.git/cbx/logs/dier.exit"
	for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$f" ] && break; sleep 0.3; done
	[ -s "$f" ] || fail "no exit status was recorded for a service whose command died"
	# NOT up — with the status, so the listing itself says what happened.
	cbx svcs; has "dier         DEAD(1)"
	# …and `up` starts it again instead of refusing. This is the recovery path an agent needs.
	cbx up dier; ok; has "had exited (status 1)"; has "started dier"
	tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
	unset TMUX_SESSION
}

# RUNNING IS NOT USABLE. A process can hold its port, answer most endpoints and still be no use to a
# client with a deadline — a pinchtab whose /health took 3s was up, authenticated and driving Chrome
# while every agent box was told "server is not running", and nothing on the hub disagreed because
# nothing on the hub had ever asked. `ready=` asks. It REPORTS ONLY: no waiting, no restarting.
test_service_ready_probe() {
	command -v tmux >/dev/null || { skip "tmux is not installed"; return 0; }
	cat > "$FIX/services/quick" <<-'EOF'
		description=answers at once
		command=sleep 600
		ready=true
	EOF
	cat > "$FIX/services/sick" <<-'EOF'
		description=running, but not serving
		command=sleep 600
		ready=false
	EOF
	# The case that matters: the probe RETURNS, just too late to be any use.
	cat > "$FIX/services/slow" <<-'EOF'
		description=answers, slowly
		command=sleep 600
		ready=sleep 1
		ready_warn_ms=200
		ready_timeout=5
	EOF
	# …and one that never returns at all: it must be SLOW, not a hung `svcs`.
	cat > "$FIX/services/hung" <<-'EOF'
		description=never answers
		command=sleep 600
		ready=sleep 30
		ready_timeout=1
	EOF
	export TMUX_SESSION="mustertest-$$"
	if ! tmux new-session -d -s "$TMUX_SESSION" -c "$FIX" -n shell 2>/dev/null; then
		unset TMUX_SESSION; skip "no usable tmux server here"; return 0
	fi
	cbx up quick >/dev/null; cbx up sick >/dev/null; cbx up slow >/dev/null; cbx up hung >/dev/null
	cbx svcs; ok
	has "quick        up"
	has "sick         up(UNREADY)"
	has "slow         up(SLOW"
	has "hung         up(SLOW"
	# A service with no ready= is reported exactly as before — this must not turn "no probe" into a fault.
	cat > "$FIX/services/plain" <<-'EOF'
		description=no probe declared
		command=sleep 600
	EOF
	cbx up plain >/dev/null; cbx svcs; has "plain        up"
	# `ready <svc>`: the number, and a non-zero status a script can branch on.
	cbx ready quick; ok; has "ready=ok"
	cbx ready sick;  notok; has "ready=UNREADY"
	cbx ready slow;  notok; has "ready=SLOW"; has "ANSWERS, just slowly"
	cbx ready plain; ok;    has "declares no ready="
	# A DOWN service is not probed into looking ready.
	cbx down sick >/dev/null; cbx ready sick; notok; has "is down"
	tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
	unset TMUX_SESSION
}

# The dashboard repaints on a timer, so the probe is memoised — otherwise `q` would run every
# service's ready= command every few seconds, which for a browser probe is a real load.
test_service_ready_is_cached() {
	command -v tmux >/dev/null || { skip "tmux is not installed"; return 0; }
	# The probe APPENDS a line, so the file counts how many times it actually ran.
	cat > "$FIX/services/counted" <<-EOF
		description=counts its probes
		command=sleep 600
		ready=echo x >> $FIX/probes.txt
	EOF
	export TMUX_SESSION="mustertest-$$"
	if ! tmux new-session -d -s "$TMUX_SESSION" -c "$FIX" -n shell 2>/dev/null; then
		unset TMUX_SESSION; skip "no usable tmux server here"; return 0
	fi
	: > "$FIX/probes.txt"
	cbx up counted >/dev/null
	# Two overview renders run the probe once; `svcs` forces a fresh one. `st` IS the overview the live
	# dashboard repaints (status_overview) — `q --text` is deliberately the bare table and never probes.
	OUT="$(cbx st 2>&1)"; RC=$?
	OUT="$(cbx st 2>&1)"; RC=$?
	ok
	eq "$(wc -l < "$FIX/probes.txt")" "1" "a cached read must not re-run the probe"
	cbx svcs >/dev/null
	eq "$(wc -l < "$FIX/probes.txt")" "2" "svcs must force a fresh probe"
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
	ssh_has "-t root@test.example docker exec -it"
	ssh_has "label=com.docker.compose.service=hub"
	# THE REMOTE BINARY IS `muster`, NEVER THE PREFIX. `muster` is in every image; the prefix is a
	# symlink the hub entrypoint makes from MUSTER_PREFIX, so it only exists once that variable has
	# reached the container — and calling it before then is `"cbx": executable file not found in
	# $PATH`, from a laptop where everything looks configured. MUSTER_SELF carries the name that was
	# typed, so the CLI's own hints still read `cbx …`.
	ssh_has "muster ls"
	ssh_has "-e MUSTER_SELF=cbx"
	ssh_hasnt " cbx ls"
}

# `box` SPAWNS AND THEN ATTACHES. Attaching was always the next thing you typed, and it has to happen
# on this side: the hub has no terminal of yours to hand a session to. The name is taken from the
# arguments when you gave one and parsed out of the spawn message when you did not — the hub invents a
# short id in that case, and the line it prints is the only place it exists.
test_aliases_box_spawn_attaches() {
	alias_fixture
	# The stub ssh answers a spawn the way the hub does, so the name can be parsed back out.
	cat >> "$FIX/bin/ssh" <<-'EOF'
	EOF
	cat > "$FIX/bin/ssh" <<-'EOF'
		#!/bin/bash
		printf 'ssh %s\n' "$*" >> "$MUSTER_SSH_LOG"
		case "$*" in
		  *"muster box"*) echo "muster: box 'abc123' up as 'box-proj-abc123' on branch agent/abc123 (golden g-1)." ;;
		  *FAILSPAWN*) exit 1 ;;
		esac
		exit 0
	EOF
	chmod +x "$FIX/bin/ssh"
	TTY=1 al 'cbx box work1'
	ssh_has "muster box work1"
	ssh_has "box-proj-work1 tmux attach -t main"     # the name you gave
	TTY=1 al 'cbx box'
	ssh_has "box-proj-abc123 tmux attach"            # …or the one the hub invented, parsed from its output
	# Opting out, both ways.
	TTY=1 al 'cbx box work1 --no-attach'
	ssh_has "muster box work1"; ssh_hasnt "tmux attach"
	ssh_hasnt "--no-attach"                          # the flag is ours; the hub never sees it
	TTY=1 al 'MUSTER_BOX_ATTACH=0 cbx box work1'
	ssh_hasnt "tmux attach"
	# No terminal: `box x | cat` asking tmux for a session is a hang, not a feature.
	al 'cbx box work1'
	ssh_hasnt "tmux attach"
}

# `cbx logs` and the live `cbx q` are long-lived and interactive, so they take the mosh-able
# transport; everything else is one-shot and must stay on ssh or its output would be wiped.
test_aliases_transport_split() {
	alias_fixture
	al 'cbx q --text'; ssh_has "-t root@test.example"; ssh_hasnt "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx q';       ssh_has "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx logs backend'; ssh_has "mosh"
	al 'MUSTER_TRANSPORT=mosh cbx ls';     ssh_hasnt "mosh"   # one-shot: ssh even under mosh
	# `logs <svc>` ATTACHES a window: long-lived and interactive, so it honours the transport. But
	# `logs --tail/--file` PRINTS and exits — one-shot text must go over ssh or mosh renders it and
	# wipes it on the way out. It matters more here than anywhere: mosh has no scrollback at all, so a
	# failed service read through it could never be scrolled back through.
	MUSTER_TRANSPORT=mosh al 'cbx logs backend'
	ssh_has "mosh "
	MUSTER_TRANSPORT=mosh al 'cbx logs backend --tail 200'
	ssh_has "-t root@test.example"; ssh_hasnt "mosh "
	MUSTER_TRANSPORT=mosh al 'cbx logs backend --file'
	ssh_has "-t root@test.example"; ssh_hasnt "mosh "
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
	# -n before -N: the tunnel must never hold your terminal's stdin. Without it, suspending the
	# tunnel leaves a stopped process attached to the tty that eats what you type afterwards.
	ssh_has "ssh -n -N"
	ssh_has "-L 127.0.0.1:4200:10.0.0."
	# NOT through a multiplexed master: it would install the forwards on a connection that outlives
	# your Ctrl-C, leaving the ports bound by a process you cannot see and the next tunnel refused
	# with "Address already in use".
	ssh_has "ControlPath=none"
	ssh_has "ControlMaster=no"
	# …and a forward that cannot bind must fail loudly, not leave a tunnel that lies about itself.
	ssh_has "ExitOnForwardFailure=yes"
	ssh_has "-L 127.0.0.1:8080:10.0.0."
	al 'cbxtun 9000'                    # bare PORT means the hub
	ssh_has "-L 127.0.0.1:9000:10.0.0."
	al 'cbxtun 4300:work1:4200'         # LOCAL:TARGET:PORT
	ssh_has "-L 127.0.0.1:4300:10.0.0."
}

# cbxpaste: a screenshot is the fastest way to say what is wrong with a page, and it was the one
# thing that could not be handed to an agent without saving it, copying it and typing a path.
test_aliases_paste_an_image() {
	alias_fixture
	# A Wayland clipboard holding a PNG. The stub answers both calls cbxpaste makes: what types are
	# offered, and the bytes for the one it picked.
	cat > "$FIX/bin/wl-paste" <<'EOF'
#!/bin/bash
[ "$1" = "--list-types" ] && { printf 'text/html\nimage/png\n'; exit 0; }
printf 'PNGDATA'
EOF
	chmod +x "$FIX/bin/wl-paste"
	WAYLAND_DISPLAY=wl-0 al 'cbxpaste work1'
	ok
	# The transfer goes through cbxcp's pipe — one tar into `docker exec -i`, no temp copy on the host.
	ssh_has "docker exec -i box-proj-work1"
	# TYPED, not sent: send-keys -l leaves the cursor after the path so you can say what is wrong with
	# the image. An Enter here would make claude act on a bare path, which asks nothing.
	ssh_has "tmux send-keys -t main -l"
	ssh_has "/home/dev/keep/pasted/"
	ssh_hasnt "send-keys -t main Enter"
	# Nobody is attached (the ssh stub prints nothing), so it drops you into the box.
	ssh_has "tmux attach -t main"
	has "attaching"
	# A box name is required — the whole command is "in front of WHICH agent".
	al 'cbxpaste'
	notok; has "usage:"
}

# The other half of the decision: when you already have that session open, saying so is better than
# stealing the terminal you are looking at.
test_aliases_paste_when_already_attached() {
	alias_fixture
	cat > "$FIX/bin/wl-paste" <<'EOF'
#!/bin/bash
[ "$1" = "--list-types" ] && { printf 'image/jpeg\n'; exit 0; }
printf 'JPGDATA'
EOF
	chmod +x "$FIX/bin/wl-paste"
	# `tmux list-clients | wc -l` is the question; make the stub answer "one client".
	cat > "$FIX/bin/ssh" <<'EOF'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$MUSTER_SSH_LOG"
case "$*" in *list-clients*) echo 1 ;; esac
exit 0
EOF
	chmod +x "$FIX/bin/ssh"
	WAYLAND_DISPLAY=wl-0 al 'cbxpaste work1'
	ok
	has "waiting in the session you have open"
	ssh_hasnt "tmux attach -t main"
	# The extension follows the clipboard's type, so the agent's tooling sees a real .jpg.
	ssh_has "/home/dev/keep/pasted/"
	has ".jpg"
}

# No clipboard reader at all is a different message from an empty clipboard: one says install
# something, the other says copy something. Getting that wrong sends you looking in the wrong place.
test_aliases_paste_without_a_clipboard_reader() {
	alias_fixture
	OUT="$(cd "$FIX" && env -u WAYLAND_DISPLAY -u DISPLAY PATH="$FIX/bin:/usr/bin:/bin" \
		MUSTER_SSH_LOG="$SSH_LOG" MUSTER_SERVER=root@test.example MUSTER_PROJECT=proj \
		bash -c "source '$ROOT/muster.bash_aliases'; cbxpaste work1" 2>&1)"; RC=$?
	notok
	case "$(uname -s)" in
		Darwin) has "pngpaste" ;;
		*)      has "no clipboard reader" ; has "wl-clipboard" ; has "xclip" ;;
	esac
	eq "$(cat "$SSH_LOG")" "" "nothing may be sent when there is no image to send"
}

# THE BOX NAME FIRST. A row of terminal tabs truncates hard, so a title that begins with the same
# word for every agent tells you nothing — which is what the terminal's own "name the tab after the
# command line" default gives you.
test_aliases_set_the_tab_title() {
	alias_fixture
	TTY=1 al 'cbxbox work1'
	ok
	has "]2;work1 box"                  # OSC 2, box name leading
	hasnt "]2;cbx box work1"
	has "[22;2t"                        # pushed…
	has "[23;2t"                        # …and popped again on the way out
	# The hub gets the same treatment, named by stack.
	TTY=1 al 'cbxhub'
	ok; has "]2;proj hub"
	# Opt-out, for a terminal or a workflow that manages its own titles.
	TTY=1 al 'MUSTER_TITLE=0 cbxbox work1'
	ok; hasnt "]2;work1 box"
	# …and never into a pipe, where the escape would land in whatever is reading.
	al 'cbxbox work1 | cat'
	hasnt "]2;"
}

# A DROPPED SESSION LEAVES THE TERMINAL SWITCHED ON. The TUI at the far end enables SGR mouse motion
# reporting and the kitty keyboard protocol and turns both off as it exits — but when ssh dies (idle
# timeout, hub restart) nothing sends the "off" sequences, and the terminal keeps reporting into a
# shell that prints the reports as text: `35;62;35M…`, `9;1:3u…`. Only this side can clean up.
test_aliases_restore_the_terminal_after_a_session() {
	command -v script >/dev/null || { skip "no 'script' for a pseudo-terminal"; return 0; }
	alias_fixture
	TTY=1 al 'cbxbox work1'
	ok
	has "[?1003l"        # any-motion mouse reporting off — the one that produces the flood
	has "[?1006l"        # …and its SGR encoding
	has "[<u"            # the kitty keyboard stack, popped
	has '[?1049$p'       # and the alternate screen ASKED about, not assumed — see the next test
	# One-shots go through the same door: `cbx review` runs a TUI over ssh -t, and a drop there leaves
	# exactly the same mess behind.
	TTY=1 al 'cbx ls'
	ok; has "[?1003l"
	# Keepalives, so the idle-timeout half of the problem stops happening in the first place.
	ssh_has "ServerAliveInterval=30"
	ssh_has "ServerAliveCountMax=3"
}

# ?1049l IS NOT A PLAIN SWITCH. xterm's ctlseqs defines 1049l as "use normal screen buffer AND
# restore the cursor as in DECRC" — the cursor half fires whether or not you were on the alternate
# screen. Sent blind after every command it drags the cursor back to wherever a pager saved it, and
# the next command's output prints over text still on screen ("To github.com:you/repo.gitompleted
# with 66 local objects."). So it may go out only when the terminal SAYS it is on the alternate
# screen, and the terminal is asked with DECRQM: CSI ?1049$p → CSI ?1049;<1=set|2=reset>$y.
#
# The pty is fed the reply here (see AL_TTY_INPUT), which is the only way to test this without a real
# terminal on the other end. Note what each case asserts: "[?1049l" as SENT text can never be
# confused with the fed-in reply, which contains "[?1049;1$y".
test_aliases_leave_the_alternate_screen_only_when_it_is_set() {
	command -v script >/dev/null || { skip "no 'script' for a pseudo-terminal"; return 0; }
	alias_fixture
	# A TUI really did die fullscreen: the terminal answers "set", so the escape goes out.
	AL_TTY_INPUT=$'\033[?1049;1$y' TTY=1 al 'cbxbox work1'
	ok; has '[?1049$p'; has "[?1049l"
	# The normal case — nothing was fullscreen. Answering "reset" must leave the cursor ALONE.
	AL_TTY_INPUT=$'\033[?1049;2$y' TTY=1 al 'cbxbox work1'
	ok; has '[?1049$p'; hasnt "[?1049l"
	# A terminal that doesn't implement DECRQM says nothing at all. No answer means no: leaving a
	# normal screen alone costs nothing, guessing "yes" is the corruption above.
	TTY=1 al 'cbxbox work1'
	ok; hasnt "[?1049l"
	# Typeahead is not a reply. A reply always starts with ESC, so anything else stops the read then
	# and there — and must not be mistaken for one.
	AL_TTY_INPUT='hello' TTY=1 al 'cbxbox work1'
	ok; hasnt "[?1049l"
	# `<prefix>tty` is the escape hatch for a terminal that cannot answer, so THERE it is sent blind —
	# you have said out loud that the state is wrong.
	TTY=1 al 'cbxtty'
	has "[?1049l"
}

# The escapes must never reach STDOUT: _muster_ssh is also called inside command substitutions, where
# a printf would be captured as part of the output the caller parses — the box name, in the case that
# matters, which `cbx box` reads back out of the spawn message to know what to attach to.
test_aliases_terminal_restore_never_touches_stdout() {
	command -v script >/dev/null || { skip "no 'script' for a pseudo-terminal"; return 0; }
	alias_fixture
	# In a FILE, dot-sourced. TTY mode passes the code through a double-quoted `script -qec "…"`, so a
	# $( ) written inline here would be expanded by THIS shell long before cbx ever ran.
	cat > "$FIX/capture.sh" <<'EOF'
out="$(cbx ls)"
case "$out" in *1003l*) echo POLLUTED ;; *) echo CLEAN ;; esac
EOF
	TTY=1 al ". $FIX/capture.sh"
	ok; has "CLEAN"; hasnt "POLLUTED"
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

# LAPTOP-SIDE COMPLETION. Subcommands and flags come from the cache — i.e. from the `muster --help` of
# the hub that is actually deployed — with a hard-coded floor for a cold cache. That is the fix for
# the failure this test exists to prevent: `minto` shipped in the CLI and stayed missing from a
# hand-kept list here, so `cbx minto <TAB>` completed nothing and read as "no such command".
test_aliases_completion() {
	alias_fixture
	cat > "$FIX/complete-cache" <<-'EOF'
		svc backend
		box work1
		branch dev
		branch release/2025
		rbox wasKilled
		cmd minto
		cmd afutureverb
		flag merge --squash
		flag merge --reword
		flag minto --here
		flag afutureverb --brandnew
	EOF
	# One shell: stub the cache, then ask for several completions and label each answer. The word being
	# completed is passed SEPARATELY from the line, because it is usually empty ("what can follow
	# this?") and an empty trailing word does not survive word-splitting one string.
	al "_muster_complete_cache() { cat '$FIX/complete-cache'; };
	    try() { local w=(\$1); COMP_WORDS=(\"\${w[@]}\" \"\$3\"); COMP_CWORD=\${#w[@]};
	            _muster_complete; echo \"\$2: \${COMPREPLY[*]}\"; };
	    try 'cbx'              FIRSTWORD   'mint';
	    try 'cbx minto'        BRANCHES    '';
	    try 'cbx minto'        MINTOFLAGS  '--';
	    try 'cbx merge'        FLAGSBEFORE '--';
	    try 'cbx merge work1'  FLAGSAFTER  '--';
	    try 'cbx afutureverb'  FROMHUB     '--';
	    try 'cbx box'          RESPAWNABLE '';
	    try 'cbx kill'         LIVE        ''"
	has "FIRSTWORD: minto"
	has "BRANCHES: dev release/2025"
	case "$OUT" in *"MINTOFLAGS: "*--here*) ;; *) fail "minto flags should complete" ;; esac
	# BOTH orders: `merge --squash <box>` and `merge <box> --squash` are both valid command lines.
	case "$OUT" in *"FLAGSBEFORE: "*--reword*) ;; *) fail "flags must complete BEFORE the box name" ;; esac
	case "$OUT" in *"FLAGSAFTER: "*--reword*) ;; *) fail "flags must complete after the box name" ;; esac
	# A verb this file has never heard of, taken from the hub's help — the whole point of caching them.
	has "FROMHUB: --brandnew"
	# `box <name>` is a NEW name or one that was killed and can be brought back — offering a box that
	# is already running would be offering a no-op.
	has "RESPAWNABLE: wasKilled"
	# That ONE line, not the whole output — a `*RESPAWNABLE:*work1*` glob matches the LIVE line further
	# down and would pass whatever `box` offered.
	case "$(printf '%s\n' "$OUT" | sed -n 's/^RESPAWNABLE: //p')" in
		*work1*) fail "box should not offer a box that is already running" ;;
	esac
	has "LIVE: work1"
}

# COMPLETION MUST KNOW WHAT JUST HAPPENED. Spawning or killing a box changes exactly one line of what
# completion knows, and waiting out the cache TTL to learn it means `kill <TAB>` offering a box you
# just killed. So those commands patch the cache — and a killed box moves to the RETIRED key rather
# than vanishing, because `box <name>` brings it back and that is the one thing worth completing there.
test_aliases_cache_follows_boxes() {
	alias_fixture
	cat > "$FIX/bin/ssh" <<-'EOF'
		#!/bin/bash
		printf 'ssh %s\n' "$*" >> "$MUSTER_SSH_LOG"
		case "$*" in
		  *FAILME*) exit 1 ;;
		  *"muster box"*) echo "muster: box 'newbox' up as 'box-proj-newbox' on branch agent/newbox (golden g-1)." ;;
		esac
		exit 0
	EOF
	chmod +x "$FIX/bin/ssh"
	local cache="$FIX/cbx-complete.proj.$UID"
	seed() { printf 'box live1\nbox live2\nrbox retired1\nsvc backend\n' > "$cache"; }
	# TMPDIR points the alias's cache at our file; AL_PROJECT keeps the name in step with it.
	run_al() { seed; TMPDIR="$FIX" al "$1"; }

	run_al 'cbx box newbox --no-attach'
	grep -qx 'box newbox' "$cache" || fail "a spawned box should be completable at once" "$(cat "$cache")"
	run_al 'cbx kill live1'
	grep -qx 'rbox live1' "$cache" || fail "a killed box should move to the retired key" "$(cat "$cache")"
	grep -qx 'box live1'  "$cache" && fail "…and stop being listed as live" "$(cat "$cache")"
	run_al 'cbx purge retired1'
	grep -q 'retired1' "$cache" && fail "a purged box should be gone from both keys" "$(cat "$cache")"
	# A command that FAILED changed nothing on the server, so it must change nothing here.
	run_al 'cbx kill FAILME'
	grep -qx 'box live1' "$cache" || fail "a failed kill must leave the cache alone" "$(cat "$cache")"
	unset -f seed run_al
	return 0
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
	ssh_has "-t root@test.example"; ssh_has "docker exec -it -u postgres"
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

# THE REBASE VERDICT IS CACHED, because it is the expensive question on the dashboard: two
# `git log -p | git patch-id` runs over whole branches (~0.5s each on a real project), asked again
# for every box on every 5-second repaint, where the answer cannot have changed unless one of four
# shas did. Those four shas ARE the key, so any handoff, rebase, review or move of the base
# invalidates it by construction and nothing else can.
test_rebase_verdict_is_cached() {
	local sha
	sha="$(handoff work1 2)"
	# Reviewed at an earlier ref, so box_status has to tell 'rebased' from 're-review' — the only
	# path that runs the patch-id comparison at all.
	mkdir -p "$FIX/repo/.git/cbx"
	printf '%s %s' "$(at dev)" "$(at dev)" > "$FIX/repo/.git/cbx/work1.reviewed"
	cbx status --no-fetch; ok
	has "re-review"
	exists "$FIX/repo/.git/cbx/work1.rebase"
	# The NEGATIVE is cached too — 're-review' is the common verdict, so caching only the hits would
	# leave the busy dashboard recomputing every miss forever.
	OUT="$(cat "$FIX/repo/.git/cbx/work1.rebase")"; has " no"
	# Now prove the cache is READ rather than merely written: flip the stored verdict, leaving the key
	# alone, and the dashboard must believe it. (Only a test may do this; nothing else writes it.)
	local key; key="$(awk '{print $1, $2, $3, $4}' "$FIX/repo/.git/cbx/work1.rebase")"
	printf '%s yes\n' "$key" > "$FIX/repo/.git/cbx/work1.rebase"
	cbx status --no-fetch; ok
	has "rebased"
	# And that a moved branch invalidates it: same box, new sha, so the poisoned entry is ignored and
	# the real comparison runs again.
	handoff work1 3 >/dev/null
	cbx status --no-fetch; ok
	has "re-review"
	OUT="$(cat "$FIX/repo/.git/cbx/work1.rebase")"; has " no"
	# The key really is the four shas, not the box name.
	ne "$(awk '{print $4}' "$FIX/repo/.git/cbx/work1.rebase")" "$sha" "the cache key must follow the ref"
}

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

# The box half of the mount-parent fix. A box's /home/dev IS a bind mount, so the image cannot
# pre-create anything there — the broker has to, in the anchor, before docker invents the parents as
# root. Existing directories are re-owned rather than skipped, so `cbx recreate` repairs a box that
# already has the root-owned version instead of it needing a purge.
test_broker_creates_home_mount_parents() {
	OUT="$(python3 - "$BROKER_PY" "$FIX" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

anchor = os.path.join(sys.argv[2], "anchor"); os.makedirs(anchor, exist_ok=True)
b.BOX_UID = b.BOX_GID = str(os.getuid())      # chown to ourselves: the suite is not root
b.ensure_home_parents(anchor, [
    "/home/dev/.local/share/chezmoi",         # nested: both parents must appear
    "/home/dev/repo",                         # top-level: nothing to create
    "/somewhere/else/entirely",               # outside the home: not the anchor's business
    "",
])
assert os.path.isdir(os.path.join(anchor, ".local", "share")), "the nested parents were not created"
assert not os.path.exists(os.path.join(anchor, ".local", "share", "chezmoi")), \
    "the destination itself must be left to docker"
assert not os.path.exists(os.path.join(anchor, "repo")), "a top-level dst needs no parent"
assert not os.path.exists(os.path.join(anchor, "somewhere")), "a dst outside the home was created"
assert not os.path.exists(os.path.join(anchor, "home")), \
    "the absolute /home/dev prefix was not stripped — it was recreated inside the anchor"
print("ok")
PY
)"; RC=$?
	ok; has ok
}

# THE ONE DIRECTORY A BOX KEEPS. Everything else an agent writes is in the repo (reviewed, or gone
# with the branch) or in a layer a recreate discards — so scratch notes had nowhere to live, and the
# workaround was committing them to the branch, which is what review exists to catch.
test_broker_box_keeps_a_durable_dir() {
	OUT="$(python3 - "$BROKER_PY" "$FIX" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
os.environ["BOXROOT"] = os.path.join(sys.argv[2], "boxroot2")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

# It is under the HOME, so `cd ~/keep` needs no explanation and `ls ~` shows it.
assert b.KEEP_DST == "/home/dev/keep", b.KEEP_DST
# …and it is named in the environment, so a script never has to hard-code the path.
assert "MUSTER_KEEP" in open(sys.argv[1]).read()
print("ok")
PY
)"; RC=$?
	ok; has ok
	# The lifetime is the BOX's, not the container's: kill keeps the box dir, and nothing but purge
	# removes it. Asserted on the code paths that delete things, so a future cleanup cannot quietly
	# start taking it with them.
	OUT="$(sed -n '/^def kill_box/,/^def /p' "$BROKER_PY")"
	hasnt '"keep"'
	OUT="$(sed -n '/^def purge_box/,/^def /p' "$BROKER_PY")"
	has "rmtree"                      # purge takes the whole box dir, keep included — the one way out
	# It is created, chowned to the box user, and mounted — every spawn, whatever else the spawn does.
	OUT="$(sed -n '/^def create_box/,/^def [a-z_]/p' "$BROKER_PY")"
	has 'keep = os.path.join(box_dir, "keep")'
	has "os.makedirs(keep, exist_ok=True)"
	has "{keep}:{KEEP_DST}"
	# --fresh means "a clean tree", not "forget what you learned", so NOTHING may delete it: the whole
	# broker names that directory exactly once, and it is the line above that creates it.
	eq "$(grep -c 'box_dir, "keep"' "$BROKER_PY")" "1" "only create_box may name the keep dir"
}

# The broker half of the same fix: dir_size runs only when the caller asked for it.
test_broker_retired_sizes_are_opt_in() {
	OUT="$(python3 - "$BROKER_PY" "$FIX" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
root = os.path.join(sys.argv[2], "boxroot")
os.makedirs(os.path.join(root, "retired1"), exist_ok=True)
open(os.path.join(root, "retired1", "big"), "w").write("x" * 1000)
os.environ["BOXROOT"] = root
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

# No containers, so the one directory is retired.
class R:
    stdout = ""
b.subprocess.run = lambda *a, **k: R()

# THE POINT: dir_size is not merely absent from the output, it is not CALLED. That is the cost —
# a walk of every file under every retired box, on an endpoint the dashboard polls twice a frame.
calls = []
real = b.dir_size
b.dir_size = lambda p: (calls.append(p), real(p))[1]

out = b.list_boxes()
assert out["retired"] == [{"box": "retired1", "golden": ""}], out
assert calls == [], f"dir_size must not run unless asked: {calls}"

out = b.list_boxes(sizes=True)
assert out["retired"][0]["size"] >= 1000, out
assert len(calls) == 1, calls
print("ok")
PY
)"; RC=$?
	ok; has ok
}

# BOX NAMES ARE AS LONG AS THE HOSTNAME ALLOWS, and the limit is derived from the project rather than
# picked. The old cap was 31 — a number from the first commit with no reasoning attached — which
# rejects names like 'legacy-features-migration-2026' that say what a box is for.
test_broker_box_name_limit_follows_the_hostname() {
	OUT="$(python3 - "$BROKER_PY" <<'PY' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
os.environ["PROJECT_NAME"] = "infostars"
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

# box-infostars- is 14 characters, and a hostname label is 63.
assert b.NAME_MAX == 63 - len("box-infostars-"), b.NAME_MAX
assert b.NAME_MAX == 49, b.NAME_MAX
assert b.valid_name("a" * 49), "the limit itself must be usable"
assert not b.valid_name("a" * 50), "one over the limit must be refused"
# The name that prompted this: 48 characters, and now fine.
assert b.valid_name("my-really-long-box-name-that-is-sometimes-useful")
# …and the whole container name really does fit in a hostname label.
assert len(f"box-infostars-{'a' * b.NAME_MAX}") <= 63

# EVERY REJECTION SAYS WHICH RULE, because "bad box name" left you guessing between the two.
long = b.name_problem("a" * 50)
assert "50 characters" in long and "49" in long and "infostars" in long, long
assert "hostname" in long, long
bad = b.name_problem("Work1")
assert "lowercase" in bad, bad
assert "characters" not in bad, "a charset error must not read as a length error: " + bad
assert b.name_problem("") and b.name_problem("-lead") and b.name_problem("has space")
assert b.name_problem("work1") is None

# A longer project name costs its boxes exactly those characters — the reason this is computed.
os.environ["PROJECT_NAME"] = "customer-portal-staging"
spec2 = importlib.util.spec_from_file_location("b2", sys.argv[1])
b2 = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(b2)
assert b2.NAME_MAX == 63 - len("box-customer-portal-staging-"), b2.NAME_MAX
assert b2.NAME_MAX < b.NAME_MAX
print("ok")
PY
)"; RC=$?
	ok; has ok
	# The prefix the limit is derived from must be the one muster-box.sh actually sets as the hostname,
	# or the arithmetic above is measuring nothing.
	OUT="$(grep -A1 -- '--hostname' "$ROOT/muster-box.sh" | head -2)"
	has 'MUSTER_NAME'
	OUT="$(grep -n 'return f"box-{PROJECT}-{name}"' "$BROKER_PY")"
	has "box-{PROJECT}-{name}"
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

# A KILLED BOX THAT COMES BACK IS THE SAME BOX. Its upper layer, its branch and its work all survive
# the kill; the conversation that produced them has to survive too, or you bring back an agent that
# has to be told everything again. The spawn route is the one that brings a killed box back, and it
# never asked for a resume — every re-up silently started a new session and orphaned the old one.
test_broker_session_resume() {
	OUT="$(python3 - "$BROKER_PY" "$FIX" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
fix = sys.argv[2]
os.environ["CLAUDE_HOME"] = os.path.join(fix, "claude")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

d = os.path.join(fix, "sbox"); os.makedirs(d, exist_ok=True)
wd = "/home/dev/repo"

# A fresh box: a new id, recorded, and nothing to resume.
first = b.session_args(d, resume=False, workdir=wd)
assert first.startswith("--session-id "), first
sid = first.split()[1]
assert open(os.path.join(d, "session-id")).read().strip() == sid

# Re-up with no transcript on disk: SAME id, still a new conversation — --resume would fail at
# startup and leave the box with no agent at all.
again = b.session_args(d, resume=True, workdir=wd)
assert again == f"--session-id {sid}", again

# Now claude has written one. The re-up resumes it.
t = b.transcript_path(wd, sid)
os.makedirs(os.path.dirname(t), exist_ok=True)
open(t, "w").write("{}")
assert b.session_args(d, resume=True, workdir=wd) == f"--resume {sid}", "should resume"

# A spawn that does not ask to resume still keeps the box's id — the id is the BOX's.
assert b.session_args(d, resume=False, workdir=wd) == f"--session-id {sid}"

# The path claude actually uses: cwd with every slash turned into a dash.
assert b.transcript_path("/home/dev/repo", "abc").endswith("/projects/-home-dev-repo/abc.jsonl")
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# The route that brings a killed box back is POST /box/<name>, not recreate — so that is where the
# resume has to be asked for.
test_broker_spawn_route_resumes() {
	OUT="$(grep -c 'create_box(name, resume=True, base=base, merge=merge)' "$BROKER_PY")"; RC=$?
	ok
	eq "$OUT" "1" "the spawn route must ask create_box to resume"
}

# A NAME THAT IS ALREADY UP IS A REATTACH. Spawning over a live box used to surface docker's name
# conflict ("the container name /box-<project>-<box> is already in use"), which reads like a broken
# stack — but `muster box <name>` on a box you already have is just "put me back in it". The response
# has to be the SAME SHAPE as a spawn's, because the alias attaches to whatever comes back.
#
# `docker` is shimmed rather than assumed: box_state() shells out to it, and the suite must run
# where there is no docker at all (Jenkins, which is exactly where this test started dying with
# FileNotFoundError). Letting the real docker answer would also make the result depend on whether the
# machine happens to have a container of that name. The shim reports whatever DOCKER_SHIM_STATE says
# for the box's own container and answers like docker does for anything else, so both branches of
# box_state — a live box and no box — are covered here rather than only the empty one.
test_broker_box_already_up() {
	fixture
	mkdir -p "$FIX/boxes/work1" "$FIX/bin"
	printf 'g-001\n' > "$FIX/boxes/work1/golden"
	printf '2\n'     > "$FIX/boxes/work1/slot"
	printf 'FRONTEND 4211 4300\nBACKEND  8091 8900\n' > "$FIX/port-forwards"
	cat > "$FIX/bin/docker" <<-'EOF'
		#!/bin/bash
		# Stand-in for docker(1): only `inspect -f {{.State.Status}} <container>` is used here.
		[ "$1" = inspect ] || { echo "docker shim: unexpected: $*" >&2; exit 64; }
		if [ "${!#}" = "box-myapp-work1" ] && [ -n "${DOCKER_SHIM_STATE:-}" ]; then
			echo "$DOCKER_SHIM_STATE"; exit 0
		fi
		echo "Error: No such object: ${!#}" >&2; exit 1
	EOF
	chmod +x "$FIX/bin/docker"
	OUT="$(PATH="$FIX/bin:$PATH" BOXROOT="$FIX/boxes" PORT_FORWARDS_FILE="$FIX/port-forwards" PROJECT_NAME=myapp \
		python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
info = b.existing_box("work1")
assert info["existing"] is True, info
assert info["container"] == "box-myapp-work1", info      # the same container, not a new one
assert info["branch"] == "agent/work1", info
assert info["golden"] == "g-001", info                   # its OWN golden, not the current one
# The forwards are the box's actual hub ports (base + its slot), so `cbxfe` keeps working after a
# reattach — a reattach that reported slot 0's ports would send the reviewer to another box.
assert info["slot"] == 2, info
assert info["forwards"] == {"FRONTEND": 4302, "BACKEND": 8902}, info
# No container of that name: nothing to reattach to, and the spawn route falls through to create_box.
assert b.box_state("work1") == "", b.box_state("work1")
# One that IS up reports its state, which is what sends the route down the reattach branch.
os.environ["DOCKER_SHIM_STATE"] = "running"
assert b.box_state("work1") == "running", b.box_state("work1")
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# ...and the route has to CONSULT that before creating anything, or the conflict is back.
test_broker_spawn_route_reattaches() {
	OUT="$(grep -c 'state = box_state(name)' "$BROKER_PY")"; RC=$?
	ok
	eq "$OUT" "1" "the spawn route must check for an existing container first"
	OUT="$(grep -c 'self._reply(200, existing_box(name))' "$BROKER_PY")"; RC=$?
	ok
	eq "$OUT" "1" "an existing RUNNING box must be answered with existing_box"
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

# The permission mode reaches claude VERBATIM. muster must not own this vocabulary: the levels are
# claude's, they change when claude changes, and translating them is exactly how `auto` — claude's
# mode, in which a small model judges each command — silently became acceptEdits, a different policy
# from the one the deployment asked for.
test_broker_box_mode() {
	OUT="$(MUSTER_CLAUDE_PERMISSION_MODE=plan python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
assert b.box_mode_arg() == "--permission-mode plan", b.box_mode_arg()
# Every documented mode goes through unchanged: no aliasing, no case-folding, no mapping.
for given in ("default", "plan", "acceptEdits", "bypassPermissions", "auto"):
    b.MUSTER_CLAUDE_PERMISSION_MODE = given
    assert b.box_mode_arg() == f"--permission-mode {given}", (given, b.box_mode_arg())
# A mode muster has never heard of is passed on ANYWAY, and only warned about: claude adds modes on
# its own schedule, and needing a muster release before you can use one is the worse failure.
b.MUSTER_CLAUDE_PERMISSION_MODE = "somethingNew"
assert b.box_mode_arg() == "--permission-mode somethingNew", b.box_mode_arg()
b.MUSTER_CLAUDE_PERMISSION_MODE = ""
assert b.box_mode_arg() == ""
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# settings.json lives in the stack's DATA dir, so it outlives every image and accumulates whatever
# past versions of muster wrote into it. After the rename that meant every box started with
#   SessionStart:startup hook error … cbx-activity: not found
# because the pre-rename hook was still registered and claude dutifully ran it. Adding the new entry
# does not remove the old one — this is that removal, and it must not touch anything else in a file
# that also holds the login and the user's own hooks.
test_broker_activity_hooks() {
	fixture
	mkdir -p "$FIX/claude"
	cat > "$FIX/claude/settings.json" <<-'EOF'
		{
		  "model": "opus",
		  "hooks": {
		    "SessionStart": [
		      {"hooks": [{"type": "command", "command": "cbx-activity idle"}]},
		      {"hooks": [{"type": "command", "command": "my-own-hook"}]}
		    ],
		    "UserPromptSubmit": [
		      {"hooks": [{"type": "command", "command": "cbx-activity busy"},
		                 {"type": "command", "command": "keep-me"}]}
		    ]
		  }
		}
	EOF
	# A BOX_UID nobody here can chown to. The broker IS root in production, but the suite is not — and
	# on a CI runner (uid 1001) even 1000:1000 raises EPERM, which failed this test after the file had
	# already been written correctly. Handing the file over is best-effort; writing it is not.
	OUT="$(CLAUDE_HOME="$FIX/claude" BOX_UID=4242 BOX_GID=4242 python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, json, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
b.ensure_activity_hooks()
d = json.load(open(os.path.join(os.environ["CLAUDE_HOME"], "settings.json")))
cmds = [h["command"] for v in d["hooks"].values() for g in v for h in g["hooks"]]
assert not [c for c in cmds if c.startswith("cbx-activity")], cmds
assert "my-own-hook" in cmds and "keep-me" in cmds, cmds        # other people's hooks survive
assert d.get("model") == "opus", d                              # and so does everything else
assert "muster-activity idle" in cmds, cmds
# Running it twice must not duplicate anything — the broker calls it on every spawn.
b.ensure_activity_hooks()
d2 = json.load(open(os.path.join(os.environ["CLAUDE_HOME"], "settings.json")))
c2 = [h["command"] for v in d2["hooks"].values() for g in v for h in g["hooks"]]
assert sorted(c2) == sorted(cmds), (cmds, c2)
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# THE STACK'S OWN CLAUDE SETTINGS. A statusLine or a model is project policy, but it has to land in
# claude's settings.json — the file that holds the login, that claude rewrites itself, and that every
# box shares. So it is merged, never templated, and the whole test here is about what the merge must
# NOT take with it.
test_broker_claude_settings() {
	fixture
	mkdir -p "$FIX/claude"
	cat > "$FIX/claude/settings.json" <<-'EOF'
		{
		  "model": "opus",
		  "permissions": {"defaultMode": "plan", "allow": ["Bash(ls:*)"]},
		  "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "my-own-hook"}]}]}
		}
	EOF
	cat > "$FIX/claude-settings.json" <<-'EOF'
		// a whole-line comment, because a config nobody may annotate is one nobody dares change
		{
		  "statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"},
		  "permissions": {"defaultMode": "acceptEdits"}
		}
	EOF
	OUT="$(CLAUDE_HOME="$FIX/claude" CLAUDE_SETTINGS_FILE="$FIX/claude-settings.json" \
		BOX_UID=4242 BOX_GID=4242 python3 - "$BROKER_PY" "$FIX" <<'PYEOF' 2>&1
import importlib.util, json, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
FIX = sys.argv[2]
S = os.path.join(os.environ["CLAUDE_HOME"], "settings.json")
load = lambda: json.load(open(S))

b.ensure_claude_settings()
d = load()
assert d["statusLine"]["command"] == "bash ~/.claude/statusline-command.sh", d
# A NESTED key merges into its object instead of replacing it: setting defaultMode must not silently
# throw away the permissions someone allowed.
assert d["permissions"] == {"defaultMode": "acceptEdits", "allow": ["Bash(ls:*)"]}, d
assert d["model"] == "opus", d                                    # untouched keys stay untouched
assert d["hooks"]["SessionStart"][0]["hooks"][0]["command"] == "my-own-hook", d

# Idempotent: this runs on every single spawn.
b.ensure_claude_settings()
assert load() == d, (d, load())

# The activity hooks go on AFTER, so a project's `hooks` block can never switch off the hub's view of
# what a box is doing.
b.ensure_activity_hooks()
cmds = [h["command"] for v in load()["hooks"].values() for g in v for h in g["hooks"]]
assert "muster-activity idle" in cmds and "my-own-hook" in cmds, cmds

# REMOVING a key from the project file removes it from settings.json — otherwise the file only ever
# grows, and a setting you deleted keeps applying with no way to be rid of it short of the server.
open(os.path.join(FIX, "claude-settings.json"), "w").write('{"permissions": {"defaultMode": "acceptEdits"}}')
b.ensure_claude_settings()
d = load()
assert "statusLine" not in d, d
assert d["permissions"] == {"defaultMode": "acceptEdits", "allow": ["Bash(ls:*)"]}, d
assert d["model"] == "opus" and d["hooks"], d      # and takes nothing else with it

# ...but only while the value is still OURS. Once someone has changed it by hand, it is theirs:
# silently reverting an edit is the worse of the two surprises.
d["permissions"]["defaultMode"] = "bypassPermissions"
json.dump(d, open(S, "w"))
open(os.path.join(FIX, "claude-settings.json"), "w").write('{}')
b.ensure_claude_settings()
assert load()["permissions"]["defaultMode"] == "bypassPermissions", load()

# A BROKEN project file applies nothing and touches nothing — a stack without its statusLine beats a
# stack whose settings.json (and login) we just rewrote.
before = open(S).read()
open(os.path.join(FIX, "claude-settings.json"), "w").write('{"statusLine": nope}')
b.ensure_claude_settings()
assert open(S).read() == before, "a syntax error must not reach settings.json"
# Same the other way round: settings.json is the file with the login in it.
open(S, "w").write("{ not json at all")
open(os.path.join(FIX, "claude-settings.json"), "w").write('{"model": "sonnet"}')
b.ensure_claude_settings()
assert open(S).read() == "{ not json at all", "an unparseable settings.json must be left alone"

# No project file at all is not an error — most stacks will not have one.
os.remove(os.path.join(FIX, "claude-settings.json"))
b.ensure_claude_settings()
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# THE PROJECT'S PER-BOX ENVIRONMENT. muster must not know what FRONTEND_DEV_BACKEND_URL means — it
# used to build a sibling of it here, under a name it could only have copied from one project. What
# it does know is forward names and port numbers; box-env is where a project turns those into its own
# variables, and the override of a service-env value is the case that made it necessary: the same URL
# is right on the hub and wrong in a box, where localhost is the box.
test_broker_box_env() {
	fixture
	cat > "$FIX/box-env" <<-'EOF'
		# comments and blanks are ignored
		FRONTEND_DEV_BACKEND_URL=http://$MUSTER_HUB_HOST:$SERVER_PORT$FRONTEND_DEV_BACKEND_PATH
		OWN=http://localhost:$PORT_FORWARD_BACKEND_TO_HUB$FRONTEND_DEV_BACKEND_PATH
		LITERAL=cost is $9.99 and $NOT_A_FACT stays
	EOF
	OUT="$(BOX_ENV_FILE="$FIX/box-env" python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
facts = {"MUSTER_HUB_HOST": "hub", "SERVER_PORT": "8091",
         "FRONTEND_DEV_BACKEND_PATH": "/myappWeb/app", "PORT_FORWARD_BACKEND_TO_HUB": "8913"}
out = b.expand_box_env(b.parse_box_env(), facts)
assert "FRONTEND_DEV_BACKEND_URL=http://hub:8091/myappWeb/app" in out, out
assert "OWN=http://localhost:8913/myappWeb/app" in out, out
# safe_substitute: an unknown $name and a bare $ survive untouched. A token or a regex with a $ in it
# must never be able to fail a spawn.
assert "LITERAL=cost is $9.99 and $NOT_A_FACT stays" in out, out
# No file at all is the normal case for a project that needs none.
b.BOX_ENV_FILE = "/nonexistent"
assert b.parse_box_env() == [], b.parse_box_env()
# THE OVERRIDE. box-env is appended after service-env and the LAST line for a key wins — collapsed
# here rather than left to `docker run -e A=1 -e A=2`, so a docker upgrade cannot quietly point every
# agent at the wrong backend.
merged = b.last_wins(["FRONTEND_DEV_BACKEND_URL=http://localhost:8091/x", "SERVER_PORT=8091",
                      "FRONTEND_DEV_BACKEND_URL=http://hub:8091/x"])
assert merged == ["FRONTEND_DEV_BACKEND_URL=http://hub:8091/x", "SERVER_PORT=8091"], merged
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# The memo goes in the ONE ~/.claude every box mounts, so it must be identical for every box: it names
# the environment VARIABLES, never their values. It is also the only channel an agent reads without
# being told to — which is why the ports and the "localhost is this box" rule live there and not in a
# variable nobody prints.
test_broker_box_memo() {
	fixture
	mkdir -p "$FIX/claude"
	printf 'MY OWN NOTES\nkeep me\n' > "$FIX/claude/CLAUDE.md"
	printf 'FRONTEND 4211 4300\nBACKEND  8091 8900\n' > "$FIX/port-forwards"
	printf 'FRONTEND_DEV_BACKEND_URL=http://$MUSTER_HUB_HOST:1/x\n' > "$FIX/box-env"
	OUT="$(CLAUDE_HOME="$FIX/claude" PORT_FORWARDS_FILE="$FIX/port-forwards" BOX_ENV_FILE="$FIX/box-env" \
		PINCHTAB_SERVER=http://hub:9867 python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
b.ensure_box_memo()
b.ensure_box_memo()                      # idempotent: the broker runs it on every spawn
txt = open(os.path.join(os.environ["CLAUDE_HOME"], "CLAUDE.md")).read()
assert txt.count(b.MEMO_START) == 1, txt
assert "MY OWN NOTES" in txt and "keep me" in txt, txt      # never clobber someone else's memory
assert "$PORT_FORWARD_FRONTEND_TO_HUB" in txt, txt          # variable NAMES, shared-safe
assert "4300" not in txt and "4211" not in txt, txt         # never per-box values
assert "FRONTEND_DEV_BACKEND_URL" in txt, txt               # box-env's keys are advertised
# pinchtab is WHY the hub-side port exists: the browser runs on the hub, so that column is the one
# URL that is right for it and wrong for curl from the box. An agent told only half of that learns
# one port is unreachable and never finds out what the other was for.
assert "pinchtab" in txt and "on the hub, not in this box" in txt, txt
assert "$PORT_FORWARD_<NAME>_TO_HUB" in txt, txt
# …and a stack that runs no pinchtab is not told about one.
b.PT_SERVER = ""
assert "pinchtab" not in b.box_memo(), b.box_memo()
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# pinchtab's token has to be the SAME on both sides — the server reads it from its config, every box
# gets it from the broker. Making a fresh stack work without inventing a secret means the hub writes
# one into the config, and the broker reads it back out of the same file. The failure this prevents is
# quiet: a box with the wrong token gets auth errors that read like a broken browser service.
test_pinchtab_token() {
	fixture
	cp "$ROOT/pinchtab-config.json.example" "$FIX/pt.json"
	OUT="$(python3 "$ROOT/hub/pinchtab-token.py" "$FIX/pt.json" 2>&1)"; RC=$?
	ok; has "freshly generated"
	local first second
	first="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"]["token"])' "$FIX/pt.json")"
	[ ${#first} -ge 32 ] || fail "generated token looks too short: $first"
	case "$first" in *change-me*) fail "the placeholder survived: $first" ;; esac
	# Idempotent: the entrypoint runs this on every boot, and a token that changed each time would
	# lock out every box spawned before the restart.
	python3 "$ROOT/hub/pinchtab-token.py" "$FIX/pt.json" >/dev/null 2>&1
	second="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"]["token"])' "$FIX/pt.json")"
	eq "$second" "$first" "a second run must not change the token"
	# A CONFIGURED token wins, so a stack that keeps PT_TOKEN in a vault keeps both sides on it.
	cp "$ROOT/pinchtab-config.json.example" "$FIX/pt2.json"
	OUT="$(PT_TOKEN=from-the-vault python3 "$ROOT/hub/pinchtab-token.py" "$FIX/pt2.json" 2>&1)"; RC=$?
	ok
	eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"]["token"])' "$FIX/pt2.json")" \
		"from-the-vault" "PT_TOKEN must win over generating one"
	# Everything else in the file survives — it is the user's config, not ours.
	eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["browser"]["binary"])' "$FIX/pt2.json")" \
		"/usr/bin/google-chrome-stable" "the rest of the config must be untouched"
	# Unparseable or missing: say so and exit 0. The hub must boot; pinchtab will explain itself far
	# better than this can, and a hub that refuses to start over a browser config is the worse failure.
	printf 'not json {\n' > "$FIX/pt3.json"
	OUT="$(python3 "$ROOT/hub/pinchtab-token.py" "$FIX/pt3.json" 2>&1)"; RC=$?
	ok; has "leaving"
	OUT="$(python3 "$ROOT/hub/pinchtab-token.py" /nonexistent/pt.json 2>&1)"; RC=$?
	ok
}

# The other half: the broker hands a box the token the SERVER is using. PINCHTAB_TOKEN (from PT_TOKEN)
# wins; otherwise it comes out of the config the hub just wrote.
test_broker_pinchtab_token() {
	fixture
	cp "$ROOT/pinchtab-config.json.example" "$FIX/pt.json"
	OUT="$(PINCHTAB_CONFIG="$FIX/pt.json" python3 - "$BROKER_PY" "$FIX/pt.json" <<'PYEOF' 2>&1
import importlib.util, json, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
cfg = sys.argv[2]
# The shipped placeholder is not a token. Handing it to a box produces an auth failure that reads
# like a broken server, so it counts as "none".
assert b.pinchtab_token() == "", b.pinchtab_token()
d = json.load(open(cfg)); d["server"]["token"] = "generated-by-the-hub"; json.dump(d, open(cfg, "w"))
assert b.pinchtab_token() == "generated-by-the-hub", b.pinchtab_token()
b.PT_TOKEN = "from-env"
assert b.pinchtab_token() == "from-env", b.pinchtab_token()
b.PT_TOKEN = ""; b.PT_CONFIG = "/nonexistent"
assert b.pinchtab_token() == "", b.pinchtab_token()
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# EVERY message to an agent has to land in CLAUDE's pane. `-t main` names the SESSION, and tmux sends
# that to whichever window is current — so after you attach to a box and open a second window, or an
# agent splits one to watch a build, the next fix/rebase/post-merge instruction is typed into that
# shell. It goes somewhere, it never arrives, and nothing fails: the send succeeded.
test_broker_box_target() {
	fixture
	mkdir -p "$FIX/bin"
	cat > "$FIX/bin/docker" <<-'EOF'
		#!/bin/bash
		printf '%s\n' "$*" >> "$DOCKER_LOG"
		case "$*" in
		  *"list-panes -t main:claude"*) [ -n "$NO_NAMED_WINDOW" ] && exit 1; echo "%7"; exit 0 ;;
		  *"list-panes -t main"*)        echo "%3"; exit 0 ;;
		esac
		exit 0
	EOF
	chmod +x "$FIX/bin/docker"
	OUT="$(PATH="$FIX/bin:$PATH" DOCKER_LOG="$FIX/docker.log" python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
b.box_say("work1", "a line")
b.box_paste("work1", "line one\nline two")
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
	local log; log="$(cat "$FIX/docker.log")"
	# The pane is looked up by the window NAME muster-box.sh gives claude's window…
	case "$log" in *"list-panes -t main:claude"*) ;; *) fail "should resolve claude's window by name" "$log" ;; esac
	# …and every send goes to that PANE ID. A pane id is also immune to base-index, which main:claude.0
	# would not be.
	case "$log" in *"send-keys -t %7 -l a line"*) ;; *) fail "send-keys must target the resolved pane" "$log" ;; esac
	case "$log" in *"paste-buffer -d -p -b cbx -t %7"*) ;; *) fail "paste must target the resolved pane" "$log" ;; esac
	# NOTHING may be aimed at the bare session any more — that is the bug.
	case "$log" in *"-t main -l"*|*"-t main Enter"*|*"-t main"$'\n'*) fail "a send still targets the session" "$log" ;; esac
	# An OLD box, from before that window was named, still gets its message.
	: > "$FIX/docker.log"
	OUT="$(PATH="$FIX/bin:$PATH" DOCKER_LOG="$FIX/docker.log" NO_NAMED_WINDOW=1 python3 - "$BROKER_PY" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
b.box_say("work1", "a line")
print("ok")
PYEOF
)"; RC=$?
	ok
	log="$(cat "$FIX/docker.log")"
	case "$log" in *"send-keys -t %3 -l a line"*) ;; *) fail "an unnamed window must fall back to the session's pane" "$log" ;; esac
}

# A KILLED BOX MUST GIVE ITS PORT SLOT BACK. Killing keeps the box directory on purpose — the upper
# layer holds work that was never pushed, plus warm caches, and `box <same name>` reattaches to it —
# and the slot file lives in that directory. Counting slot FILES therefore counted every box that had
# ever existed: after the sixteenth, every spawn failed with "out of port-forward slots — kill a box
# first" while `muster ls` showed two boxes running. Killing another one could never help.
test_broker_slot_reuse() {
	fixture
	mkdir -p "$FIX/bin"
	cat > "$FIX/bin/docker" <<-'EOF'
		#!/bin/bash
		case "$*" in *"ps -a"*) printf '%s\n' $LIVE_BOXES ;; esac
		exit 0
	EOF
	chmod +x "$FIX/bin/docker"
	local i
	for i in $(seq 0 15); do mkdir -p "$FIX/boxes/old$i"; echo "$i" > "$FIX/boxes/old$i/slot"; done
	mkdir -p "$FIX/boxes/alive"; echo 3 > "$FIX/boxes/alive/slot"
	OUT="$(PATH="$FIX/bin:$PATH" BOXROOT="$FIX/boxes" PROJECT_NAME=proj \
		LIVE_BOXES="box-proj-alive" python3 - "$BROKER_PY" "$FIX/boxes" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
root = sys.argv[2]
# Sixteen boxes have existed; exactly one still has a container.
assert sorted(b.live_slots()) == [3], sorted(b.live_slots())
# So a new box spawns rather than being told the stack is full.
assert b.alloc_slot(os.path.join(root, "fresh")) == 0, b.alloc_slot(os.path.join(root, "fresh"))
# A live box keeps the ports you already have open on the hub.
assert b.alloc_slot(os.path.join(root, "alive")) == 3
# And a killed box reclaims its own slot when nothing live took it — a recreate keeps its ports too.
assert b.alloc_slot(os.path.join(root, "old11")) == 11
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
	# When that many boxes really do exist, it still refuses — and says how many, so the message can be
	# checked against `muster ls` instead of believed.
	OUT="$(PATH="$FIX/bin:$PATH" BOXROOT="$FIX/boxes" PROJECT_NAME=proj \
		LIVE_BOXES="$(for i in $(seq 0 15); do printf 'box-proj-old%s ' "$i"; done)" \
		python3 - "$BROKER_PY" "$FIX/boxes" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
try:
    b.alloc_slot(os.path.join(sys.argv[2], "seventeenth"))
    raise SystemExit("a seventeenth live box should have been refused")
except RuntimeError as e:
    assert "16 of 16" in str(e), e
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

# THE MOUNTS TABLE GRAMMAR. One file feeds two very different consumers (this parser for the boxes,
# gen-hub-mounts.sh for the hub), so a mode one side accepts and the other does not is the failure to
# guard. A bad mode must NAME the line, because the table is edited on the server by hand.
test_broker_parse_mounts() {
	fixture
	mkdir -p "$FIX/golden/g-1/docs"
	cat > "$FIX/mounts" <<-'EOF'
		# comments and blanks ignored

		CHECKOUT                          repo             rw
		./data/npm-cache                  .npm             rw     rw
		./data/gradle-cache               .gradle          rw     cow-keep
		./data/scratch                    scratch          rw     cow
		./data/sealed                     sealed           rw     overlay
		/var/jenkins_home/.m2/repository  .m2/repository   ro     ro
		docs                              reference        -      ro
		./data/hub-only                   hubonly          rw     -
	EOF
	OUT="$(STACK_DIR="$FIX/stack" MOUNTS_FILE="$FIX/mounts" python3 - "$BROKER_PY" "$FIX" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
fix = sys.argv[2]
golden = os.path.join(fix, "golden", "g-1")
rows, dst, ro = b.parse_mounts(golden)
assert (dst, ro) == ("/home/dev/repo", False), (dst, ro)
modes = {d: m for _s, d, m in rows}
assert modes == {"/home/dev/.npm": "rw", "/home/dev/.gradle": "cow-keep",
                 "/home/dev/scratch": "cow", "/home/dev/sealed": "overlay",
                 "/home/dev/.m2/repository": "ro", "/home/dev/reference": "ro"}, modes
srcs = {d: s for s, d, _m in rows}
assert srcs["/home/dev/.gradle"] == os.path.join(fix, "stack", "data/gradle-cache"), srcs
assert srcs["/home/dev/reference"] == os.path.join(golden, "docs"), srcs   # golden-relative, confined
# A cow row's per-box directory is named by the SAME rule as the overlay uppers, so what a box owns
# is predictable from the table alone.
assert b.overlay_key("/home/dev/.gradle") == "gradle", b.overlay_key("/home/dev/.gradle")
assert b.overlay_key("/home/dev/.m2/repository") == "m2-repository"
# A bad mode names the file and the LINE, and lists what is allowed.
open(os.path.join(fix, "bad"), "w").write("./x  y  rw  sideways\n")
b.MOUNTS_FILE = os.path.join(fix, "bad")
try:
    b.parse_mounts(golden)
    raise SystemExit("a bad box mode should have been refused")
except ValueError as e:
    assert ":1:" in str(e) and "sideways" in str(e), e
    assert "cow" in str(e) and "cow-keep" in str(e), e
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
	# The HUB half of the same table: cow is box-side only, and must never be quietly rendered into
	# compose.override.yml as a plain bind mount of the ORIGINAL — that would put the hub and the boxes
	# back on one directory, which is the deadlock the mode exists to avoid.
	printf './data/gradle-cache  .gradle  cow-keep  cow-keep\n' > "$FIX/mounts-badhub"
	OUT="$("$ROOT/gen-hub-mounts.sh" "$FIX/mounts-badhub" "$FIX/override.yml" 2>&1)"; RC=$?
	notok; has "box-side only"
}

# THE COW COPY. `cp` is shimmed rather than run for real: the suite has to pass on any filesystem (a CI
# runner's overlayfs has no reflink at all), and the shim can assert that --reflink=always is what the
# broker asks for, which the real cp could not. Everything around the copy — staging, the keep/fresh
# lifecycle, what a failure leaves behind — is the logic under test.
test_broker_cow_copy() {
	fixture
	mkdir -p "$FIX/bin" "$FIX/src/sub" "$FIX/boxes/work1"
	echo hub > "$FIX/src/sub/from-hub"
	cat > "$FIX/bin/cp" <<-'EOF'
		#!/bin/bash
		# Stand-in for cp(1): insists on the flags the broker must pass, then does a plain copy.
		case " $* " in *" --reflink=always "*) ;; *) echo "cp shim: no --reflink=always in: $*" >&2; exit 64 ;; esac
		[ -n "${COW_CP_FAIL:-}" ] && { echo "cp: failed to clone: Operation not supported" >&2; exit 1; }
		args=(); for a in "$@"; do [ "$a" = --reflink=always ] || args+=("$a"); done
		exec /bin/cp "${args[@]}"
	EOF
	chmod +x "$FIX/bin/cp"
	OUT="$(PATH="$FIX/bin:$PATH" BOXROOT="$FIX/boxes" python3 - "$BROKER_PY" "$FIX" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
fix, src = sys.argv[2], os.path.join(sys.argv[2], "src")
dst = "/home/dev/.gradle"
box = os.path.join(fix, "boxes", "work1")

# The name is derived from the destination, like the overlay uppers.
path = b.make_cow_copy("work1", src, dst, keep=True)
assert path == os.path.join(box, "cow-gradle"), path
assert open(os.path.join(path, "sub", "from-hub")).read() == "hub\n"
assert not os.path.exists(path + ".new"), "the staging dir must not survive a successful copy"

# cow-keep is the box's WARM CACHE: a plain recreate must not throw its work away…
open(os.path.join(path, "mine"), "w").write("box\n")
b.make_cow_copy("work1", src, dst, keep=True)
assert os.path.exists(os.path.join(path, "mine")), "cow-keep must survive a recreate"
# …and nothing flows back to the hub.
assert not os.path.exists(os.path.join(src, "mine")), "a box's copy must never touch the source"
# --fresh is the ONE thing that re-seeds it (the same flag that discards the overlay uppers).
b.make_cow_copy("work1", src, dst, keep=True, fresh=True)
assert not os.path.exists(os.path.join(path, "mine")), "--fresh must re-copy a cow-keep"

# Plain cow is scratch: re-copied from the hub on every spawn.
open(os.path.join(path, "mine"), "w").write("box\n")
b.make_cow_copy("work1", src, dst, keep=False)
assert not os.path.exists(os.path.join(path, "mine")), "cow must be re-copied on every spawn"

# A FAILING COPY IS LOUD, and leaves the previous copy alone rather than a half-written one. Silence
# here would mean --reflink=always had quietly become a multi-GB byte copy per box.
open(os.path.join(path, "mine"), "w").write("box\n")
os.environ["COW_CP_FAIL"] = "1"
try:
    b.make_cow_copy("work1", src, dst, keep=False)
    raise SystemExit("a failed reflink copy must not be swallowed")
except RuntimeError as e:
    assert src in str(e) and path in str(e), e            # both paths, so it can be checked
    assert "reflink" in str(e) and "filesystem" in str(e), e
assert os.path.exists(os.path.join(path, "mine")), "a failed copy must not destroy the old one"
assert not os.path.exists(path + ".new"), "a failed copy must not leave staging behind"
del os.environ["COW_CP_FAIL"]

# The reap list: a copy is a DIRECTORY, not a docker volume, so it has its own record — kill_box would
# otherwise run `docker volume rm /some/path`. Only mode `cow` goes on it.
b.record_cow_dirs("work1", [os.path.join(box, "cow-scratch")])
assert b.created_cow_dirs("work1") == [os.path.join(box, "cow-scratch")], b.created_cow_dirs("work1")
# Rewritten on every spawn, so flipping a row cow -> cow-keep stops the reaping.
b.record_cow_dirs("work1", [])
assert b.created_cow_dirs("work1") == [], b.created_cow_dirs("work1")
# It drives an rm -rf, so anything outside the box's own directory is dropped rather than executed.
open(os.path.join(box, "cow-temp"), "w").write("/etc\n%s\n" % os.path.join(box, "cow-scratch"))
assert b.created_cow_dirs("work1") == [os.path.join(box, "cow-scratch")], b.created_cow_dirs("work1")
# A box that has none (no file at all) is not an error.
assert b.created_cow_dirs("neverspawned") == []
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
}

# --fresh REACHES EVERY UPPER LAYER THE BOX OWNS, not just the checkout's. `fresh_upper` was threaded
# to the checkout overlay and nowhere else, so a box recreated for a clean start silently came back
# with every `overlay` row's private writes intact — which is not what "discard upper" says, and not
# what `golden retire`/`golden snapshot` mean when they use the flag. `docker` is shimmed because
# _overlay_volume creates a real volume and the suite must run without docker (Jenkins has none).
test_broker_fresh_clears_shared_uppers() {
	fixture
	mkdir -p "$FIX/boxes/work1" "$FIX/bin"
	cat > "$FIX/bin/docker" <<-'EOF'
		#!/bin/bash
		# Stand-in for docker(1): volume create/rm always succeed, nothing else is used here.
		[ "$1" = volume ] || { echo "docker shim: unexpected: $*" >&2; exit 64; }
		exit 0
	EOF
	chmod +x "$FIX/bin/docker"
	# BOX_UID/BOX_GID are the RUNNING user's here. _overlay_volume hands the upper layer to the box uid
	# and does NOT swallow the failure — in production the broker is root and an upper the box cannot
	# write is a broken box, so that is right. But the suite is not root: with the default 1000:1000
	# this passes only on a machine whose uid happens to be 1000, and fails everywhere else (EPERM on a
	# CI runner at uid 1001, EINVAL in a user namespace). Same trap as the activity-hooks test below.
	OUT="$(PATH="$FIX/bin:$PATH" BOXROOT="$FIX/boxes" PROJECT_NAME=myapp \
		BOX_UID="$(id -u)" BOX_GID="$(id -g)" \
		python3 - "$BROKER_PY" "$FIX" <<'PYEOF' 2>&1
import importlib.util, os, sys
os.environ.setdefault("BROKER_TOKEN", "t")
spec = importlib.util.spec_from_file_location("b", sys.argv[1])
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
fix = sys.argv[2]
lower = os.path.join(fix, "lower"); os.makedirs(lower, exist_ok=True)
upper = os.path.join(fix, "boxes", "work1", "ovl-gradle", "upper")
dst = "/home/dev/.gradle"

# An ordinary recreate keeps the row's upper layer — it is the box's warm cache.
b.make_shared_overlay_volume("work1", lower, dst)
open(os.path.join(upper, "warm"), "w").write("cached\n")
b.make_shared_overlay_volume("work1", lower, dst)
assert os.path.exists(os.path.join(upper, "warm")), "a plain recreate must keep the warm cache"

# --fresh discards it, exactly as it does the checkout's upper layer.
b.make_shared_overlay_volume("work1", lower, dst, fresh_upper=True)
assert not os.path.exists(os.path.join(upper, "warm")), "--fresh must clear an overlay row's upper"
assert os.path.isdir(upper), "…and leave a usable (empty) upper behind"
print("ok")
PYEOF
)"; RC=$?
	ok; has ok
	# The flag is worth nothing if create_box does not hand it on — that was the actual bug.
	grep -q 'make_shared_overlay_volume(name, src, dst, fresh_upper)' "$BROKER_PY" \
		|| fail "create_box must pass fresh_upper to make_shared_overlay_volume"
}

# =====================================================================  the run

# =====================================================================  job boxes
#
# The unattended path: spawn, brief, and collect an answer through the box's own home. Every test
# here pre-writes .cbx-state, because a fresh box makes `job` wait for its claude to announce itself
# — which in a real stack is minutes and here has to be a fact the fixture states.
job_env() { export MUSTER_JOB_BRIEF_SETTLE=0 MUSTER_JOB_START_TIMEOUT=2; }

test_job_briefs_and_collects() {
	job_env
	box_state j1 idle 60                       # its claude "started" after we did
	cbx job j1 -m "price this chair" --detach
	ok
	stub_saw POST "/box/j1" || fail "the box was never spawned"
	stub_saw POST "/box/j1/paste" || fail "the brief did not go through /paste"
	# A brief is multi-line the moment the protocol footer is on it, and send-keys would submit it
	# one line at a time — so /say must never be how a job is delivered.
	if stub_saw POST "/box/j1/say"; then fail "a job brief must be pasted, not typed line by line"; fi
	OUT="$(stub_body /box/j1/paste)"
	has "price this chair"
	has "muster-job-result.json"               # the footer names the file the hub actually watches

	# Now the agent answers, and a second call collects it. Stdout is the file and nothing else.
	box_result j1 muster-job-result.json '{"price_eur": 240}'
	cbx job j1 --collect --timeout 5 --poll 1
	ok
	eq "$OUT" '{"price_eur": 240}' "the result file is what lands on stdout"
}

test_job_collect_times_out() {
	job_env
	box_state j2 idle 60
	cbx job j2 --collect --timeout 1 --poll 1
	eq "$RC" "3" "no answer must be its own exit status, not a generic failure"
	has "wrote no ~/muster-job-result.json"
	has "left up"                              # you can still go and look at it
}

test_job_collect_timeout_zero_is_one_look() {
	job_env
	box_state j2b idle 60
	# A caller polling many boxes from one loop needs --timeout 0 to LOOK and return, never
	# to block: kavintage's research daemon depends on exactly this.
	local before after
	before="$(date +%s)"
	cbx job j2b --collect --timeout 0 --poll 5
	after="$(date +%s)"
	eq "$RC" "3" "nothing there yet is still exit 3"
	[ "$((after - before))" -le 2 ] || fail "--timeout 0 waited $((after - before))s; it must not block"
}

test_job_result_path_cannot_escape_the_box() {
	job_env
	# $BOXES is every box's home, so '..' in a result path is a read of somebody else's box.
	cbx job j3 --collect --result ../../other/home/.ssh/id_rsa
	notok
	has "must not contain '..'"
	cbx job j3 --collect --result /etc/passwd
	notok
	has "not an absolute path"
	# And it is checked BEFORE anything is spawned: a typo costs nothing.
	if stub_saw POST "/box/j3"; then fail "a bad --result must be caught before the box is spawned"; fi
}

test_job_result_symlink_cannot_escape_the_box() {
	job_env
	box_state j3b idle 60
	# The --result check only vets the NAME we were handed; the file is written by the agent, and a
	# symlink parked at that name is resolved HERE, on the hub, where $BOXES holds every box's home
	# and the hub's own files sit right next to it. Same read the '..' check refuses, spelled with a
	# symlink — so it has to be refused the same way, and above all never printed as "the answer".
	printf 'the hub secret\n' > "$FIX/outside-any-box"
	ln -sfn "$FIX/outside-any-box" "$FIX/boxes/j3b/home/muster-job-result.json"
	cbx job j3b --collect --timeout 5 --poll 1
	notok
	hasnt "the hub secret"
	has "refusing to read it"

	# A symlinked DIRECTORY along the way is the same hole, so the whole path is resolved, not just
	# its last component.
	box_state j3c idle 60
	ln -sfn "$FIX" "$FIX/boxes/j3c/home/out"
	cbx job j3c --collect --result out/outside-any-box --timeout 5 --poll 1
	notok
	hasnt "the hub secret"

	# And a DANGLING symlink is caught at brief time: it reads as "nothing here yet", and the agent's
	# answer would then be written straight through it, out of its own home.
	box_state j3d idle 60
	ln -sfn "$FIX/not-there-yet" "$FIX/boxes/j3d/home/muster-job-result.json"
	cbx job j3d -m "go"
	notok
	has "still holds a result"
	if stub_saw POST "/box/j3d/paste"; then fail "nothing may be briefed onto a symlink out of the box"; fi
}

test_job_refuses_a_stale_result() {
	job_env
	box_state j4 idle 60
	box_result j4 muster-job-result.json '{"from": "a job that ran yesterday"}'
	cbx job j4 -m "do it again"
	notok
	has "still holds a result"
	if stub_saw POST "/box/j4/paste"; then fail "nothing may be briefed while yesterday's answer is still there"; fi
}

test_job_purges_only_after_an_answer() {
	job_env
	box_state j5 idle 60
	box_result j5 muster-job-result.json 'done'
	cbx job j5 --collect --purge --timeout 5 --poll 1
	ok
	has "done"
	stub_saw DELETE "/box/j5/purge" || fail "--purge should bin the box once the answer is in"

	# A box that never answered is NOT purged: whatever went wrong is only visible in the box.
	box_state j6 idle 60
	cbx job j6 --collect --purge --timeout 1 --poll 1
	eq "$RC" "3" "a timeout is exit 3"
	if stub_saw DELETE "/box/j6/purge"; then fail "a timed-out job box must survive so you can look at it"; fi
}

test_job_keeps_unreviewed_work() {
	job_env
	handoff j7 1 >/dev/null                    # the box pushed a branch nobody has read
	box_state j7 idle 60
	box_result j7 muster-job-result.json 'ok'
	cbx job j7 --collect --purge --timeout 5 --poll 1
	ok
	has "NOT purging"
	if stub_saw DELETE "/box/j7/purge"; then fail "a script may not bin a box holding unreviewed work"; fi
}

test_job_waits_for_the_session_then_briefs_anyway() {
	job_env
	# No .cbx-state at all: an image without the activity hooks. That must degrade to "brief it
	# anyway" — the old behaviour — never to a failure.
	cbx job j8 -m "hello" --detach
	ok
	has "never reported a session start"
	stub_saw POST "/box/j8/paste" || fail "the brief must still be delivered"

	# A state file left over from an EARLIER session is not proof that this one is up.
	box_state j9 idle -600
	cbx job j9 -m "hello" --detach
	ok
	has "never reported a session start"
}

test_job_flags() {
	job_env
	box_state j10 idle 60
	cbx job j10 -m "x" --no-protocol --detach
	ok
	OUT="$(stub_body /box/j10/paste)"
	hasnt "how this job reports back"

	cbx job j11 -m "x" --detach --collect
	notok
	has "two halves of one run"

	cbx job j12
	notok
	has "needs a brief"

	box_state j13 idle 60
	cbx job j13 -m "x" --timeout abc
	notok
	has "wants a number of seconds"
}

run "syntax: every script parses"                  test_syntax
run "skills: muster ships its own, and the image carries them" test_skills_ship
run "config: no project defaults in the source tree" test_no_project_defaults
run "help: every command is documented"            test_help_covers_every_command
run "help: an unknown command prints usage"        test_unknown_command_prints_usage

run "compose: the box build service is profiled"    test_build_only_service_is_profiled
run "compose: .dockerignore protects the stack dir" test_dockerignore_protects_the_stack_dir
run "ask: refuses paths, tools and empty prompts" test_ask_refuses_what_it_should
run "ask: refuses to run without a token"       test_ask_refuses_to_run_without_a_token
run "hub: tab-completion for both names"           test_hub_completion
run "ci: images are named by git describe"         test_images_workflow_names_images_by_describe
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
run "cli: flags work before the positional"        test_flags_before_the_positional
run "peek: runs pinchtab as the box"               test_peek_uses_the_box_session
run "peek: a box with no session says so"          test_peek_without_a_session_explains
run "hold: pauses the box's tab, with a timeout"   test_hold_pauses_with_a_timeout
run "merge: --undo restores dev and the queue"     test_merge_undo
run "merge: --undo refuses when it would take more" test_merge_undo_refuses
run "merge: --undo after a squash says why not"    test_merge_undo_after_squash
run "merge: refuses a stale dev"                   test_merge_refuses_stale_dev
run "merge: already-contained closes out"          test_merge_already_contained_closes_out
run "merge: a conflict leaves a way out"           test_merge_conflict_leaves_a_way_out
run "merge: refuses over dirty files it would overwrite" test_merge_refuses_over_dirty_files
run "merge: a failed merge is not always a conflict" test_merge_failure_is_not_always_a_conflict
run "merge: a conflict asks before touching dev"   test_merge_conflict_asks_first
run "merge: --reword rewrites messages only"       test_merge_reword_rewrites_messages_only
run "merge: --reword keeps edits when you quit"    test_merge_reword_keeps_edits_when_you_quit
run "merge: --reword and --squash are opposites"   test_merge_reword_refuses_squash_and_merges

run "drop: retires the branch and tells the box"   test_drop
run "rebase: asks the box to rebase"               test_rebase_asks_the_box
run "rebase: the prompt covers a dirty tree"       test_rebase_prompt_covers_a_dirty_tree
run "merge: its rebase prompt covers that too"     test_merge_rebase_prompt_covers_a_dirty_tree

run "push: nothing to push"                        test_push_nothing_to_do
run "push: dev to origin"                          test_push_dev
run "push: without -y the preview shows"           test_push_shows_the_preview_when_asking
run "push: a named branch"                         test_push_named_branch
run "push: rejects an unknown branch"              test_push_rejects_unknown_branch
run "pull: fast-forwards from origin"              test_pull_fast_forward

run "export: produces an mbox"                     test_export_produces_an_mbox
run "import: replaces the agent's branch"          test_import_replaces_the_branch

run "box: a refused name says which rule"          test_box_name_rejection_is_readable
run "box: spawn / ls / recreate / kill"            test_box_lifecycle
run "box: retired boxes are listed and purgeable" test_box_retired_and_purge
run "job: briefs a box and collects its answer"   test_job_briefs_and_collects
run "job: no answer is exit 3, not a hang"       test_job_collect_times_out
run "job: --timeout 0 looks once and returns"     test_job_collect_timeout_zero_is_one_look
run "job: a result path cannot leave the box"    test_job_result_path_cannot_escape_the_box
run "job: a symlinked result cannot escape either" test_job_result_symlink_cannot_escape_the_box
run "job: yesterday's answer is not this one"    test_job_refuses_a_stale_result
run "job: --purge only after an answer"          test_job_purges_only_after_an_answer
run "job: never bins unreviewed work"            test_job_keeps_unreviewed_work
run "job: no hooks still gets briefed"           test_job_waits_for_the_session_then_briefs_anyway
run "job: flag handling"                         test_job_flags
run "ls: only ls pays for the retired sizes"       test_retired_sizes_only_ls_pays_for_them
run "ls: an unknown size prints '?', never 0B"     test_retired_size_unknown_prints_a_question_mark
run "q: one box listing per frame"                 test_box_list_is_fetched_once_per_frame
run "q: a live frame makes one /box request"       test_q_frame_makes_one_box_request
run "q: the first frame does not fetch"            test_q_first_frame_does_not_fetch
run "q: the rebase verdict is cached"              test_rebase_verdict_is_cached
run "forwards: re-establishes them"                test_forwards
run "broker: unreachable is reported, not fatal"   test_broker_unreachable_is_reported_not_fatal
run "version: drift between hub and broker warns"  test_version_drift

run "golden: snapshot, ls, reap"                   test_golden_snapshot_and_reap
run "golden: strips worktrees from the snapshot"   test_golden_snapshot_strips_worktrees
run "golden: retire one that boxes are still on"   test_golden_retire
run "golden: leaves unsafe boxes behind"           test_golden_snapshot_leaves_unsafe_boxes_behind
run "golden: migrate carries uncommitted work"     test_golden_migrate
run "q: shows how far the golden has drifted"      test_q_shows_golden_drift

run "svcs: lists the manifests"                    test_svcs_lists_manifests
run "svcs: built-in manifests + override"          test_svcs_builtin_and_override
run "svcs: up and down a service"                  test_service_up_down
run "svcs: a failed start leaves readable output"  test_service_output_is_captured
run "svcs: a dead service is not 'up'"            test_service_dead_window_is_not_up
run "svcs: ready= says running vs usable"          test_service_ready_probe
run "svcs: the ready probe is memoised"            test_service_ready_is_cached

run "aliases: forward to the hub"                   test_aliases_forward_to_the_hub
run "aliases: ssh vs mosh transport split"         test_aliases_transport_split
run "aliases: hostile arguments are quoted"        test_aliases_quote_hostile_arguments
run "aliases: attach to a box / the hub"           test_aliases_box_and_hub_attach
run "aliases: box spawns then attaches"            test_aliases_box_spawn_attaches
run "aliases: pipes never allocate a PTY"          test_aliases_pipes_never_allocate_a_pty
run "aliases: exec into the hub"                   test_aliases_exec_runs_in_the_hub_too
run "aliases: tunnel specs"                        test_aliases_tunnel_specs
run "aliases: the tab title names the box"         test_aliases_set_the_tab_title
run "aliases: a session restores the terminal"     test_aliases_restore_the_terminal_after_a_session
run "aliases: the alternate screen is asked, not assumed" test_aliases_leave_the_alternate_screen_only_when_it_is_set
run "aliases: the restore never hits stdout"       test_aliases_terminal_restore_never_touches_stdout
run "paste: an image, then attach"                 test_aliases_paste_an_image
run "paste: says so when you are attached"         test_aliases_paste_when_already_attached
run "paste: no clipboard reader says which"        test_aliases_paste_without_a_clipboard_reader
run "aliases: refuse an unconfigured stack"        test_aliases_refuse_without_a_server
run "aliases: cbxcp argument checking"             test_aliases_cbxcp_argument_checking
run "aliases: completion (cmds, flags, branches)"   test_aliases_completion
run "aliases: the cache follows box changes"       test_aliases_cache_follows_boxes
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
run "broker: box-name limit follows the hostname"  test_broker_box_name_limit_follows_the_hostname
run "broker: retired sizes are opt-in"             test_broker_retired_sizes_are_opt_in
run "broker: home mount parents are pre-created"   test_broker_creates_home_mount_parents
run "box: ~/keep survives a recreate"              test_broker_box_keeps_a_durable_dir
run "broker: the branch job survives a recreate"   test_broker_persists_the_branch_job
run "broker: query parameters"                     test_broker_query_params
run "broker: a killed box resumes its session"      test_broker_session_resume
run "broker: the spawn route asks for a resume"     test_broker_spawn_route_resumes
run "broker: a box that is already up reattaches"   test_broker_box_already_up
run "broker: the spawn route checks for it first"   test_broker_spawn_route_reattaches
run "broker: permission mode passes through"       test_broker_box_mode
run "broker: activity hooks, stale ones pruned"    test_broker_activity_hooks
run "broker: the stack's claude settings merge in" test_broker_claude_settings
run "broker: messages target claude's pane"        test_broker_box_target
run "broker: a killed box frees its port slot"     test_broker_slot_reuse
run "broker: the mounts table grammar"             test_broker_parse_mounts
run "broker: cow — a private reflinked copy"       test_broker_cow_copy
run "broker: --fresh clears every upper layer"     test_broker_fresh_clears_shared_uppers
run "broker: box-env, expanded per box"            test_broker_box_env
run "broker: the box memo in shared ~/.claude"     test_broker_box_memo
# THE BROWSER PROFILE IS REAPED ON EVERY HUB BOOT, and only the profile. It lives in the bind-mounted
# ~/.pinchtab, so it is the one browser state that survives a recreate and nothing else prunes it: on
# one stack it reached 3.4GB, which took pinchtab's /health from 303ms to 3.0s — longer than the
# deadline every pinchtab CLI command gives its preflight, so agents in boxes were told the server was
# "not running" and stopped verifying in a browser at all. Reaping also means a review can never be
# done against a cached copy of a bundle that has since changed.
#
# The test runs the entrypoint's own block, extracted from the file, so it cannot drift from what
# boots. Two invariants: profiles/ goes, and config.json (the shared token) + sessions.json stay.
test_hub_reaps_the_pinchtab_profile() {
	fixture
	# The block, verbatim from the entrypoint: PT_PROFILES= up to the fi that closes it.
	local blk="$FIX/reap.sh"
	awk '/^PT_PROFILES=/,/^fi$/' "$ROOT/hub/entrypoint.sh" > "$blk"
	[ -s "$blk" ] || fail "could not find the reap block in hub/entrypoint.sh"
	mkdir -p "$FIX/pt/profiles/default/Default/Cache"
	printf '{"server":{"token":"t"}}\n' > "$FIX/pt/config.json"
	printf '{}\n'                       > "$FIX/pt/sessions.json"
	head -c 4096 /dev/zero               > "$FIX/pt/profiles/default/Default/Cache/data_1"
	PT_CONFIG="$FIX/pt/config.json" bash "$blk" >/dev/null 2>&1
	[ ! -d "$FIX/pt/profiles" ] || fail "the profile survived the boot"
	[ -f "$FIX/pt/config.json" ]   || fail "config.json was taken with it — that is the shared token"
	[ -f "$FIX/pt/sessions.json" ] || fail "sessions.json was taken with it — those are the boxes' tabs"
	# Opt out, for a browser someone wants to keep logged in.
	mkdir -p "$FIX/pt/profiles/default"
	MUSTER_PINCHTAB_KEEP_PROFILE=1 PT_CONFIG="$FIX/pt/config.json" bash "$blk" >/dev/null 2>&1
	[ -d "$FIX/pt/profiles" ] || fail "MUSTER_PINCHTAB_KEEP_PROFILE=1 must keep the profile"
	ok
	# ORDERING, which is what makes the delete safe: before autostart, the server cannot be running.
	local reap auto
	reap="$(grep -n '^PT_PROFILES=' "$ROOT/hub/entrypoint.sh" | head -1 | cut -d: -f1)"
	auto="$(grep -n '^muster autostart' "$ROOT/hub/entrypoint.sh" | head -1 | cut -d: -f1)"
	[ -n "$reap" ] && [ -n "$auto" ] || fail "could not locate the reap and autostart lines"
	[ "$reap" -lt "$auto" ] || fail "the profile is reaped AFTER autostart — pinchtab would be using it"
}

# A NESTED MOUNT DESTINATION LEAVES ROOT-OWNED PARENTS. Docker creates a missing destination, and
# every missing parent, as root; the destination is then covered by the mount, but the parents stay —
# real, root-owned, in a home that is uid 1000 throughout. The tool that fails afterwards is not the
# one in the mounts row: `.local/share/chezmoi` is what made ~/.local/share unwritable, and what broke
# was tuicr, unable to create ~/.local/share/tuicr, so `cbx review` died with "Permission denied".
# The hub cannot repair it (it runs as dev), so it must at least SAY so at boot.
test_hub_warns_about_unwritable_mount_parents() {
	fixture
	[ "$(id -u)" != 0 ] || { skip "running as root: every -w test passes regardless"; return 0; }
	local blk="$FIX/parents.sh"
	# The function, verbatim from the entrypoint, so the test cannot drift from what boots.
	awk '/^check_home_parents\(\) \{/,/^\}$/' "$ROOT/hub/entrypoint.sh" > "$blk"
	[ -s "$blk" ] || fail "could not find check_home_parents in hub/entrypoint.sh"
	echo 'check_home_parents' >> "$blk"
	printf './data/chezmoi\t.local/share/chezmoi\tro\tro\n' > "$FIX/mounts-t"
	mkdir -p "$FIX/fakehome/.local/share"
	# Writable: the good case must stay silent, or the warning is noise nobody reads.
	OUT="$(HOMEROOT="$FIX/fakehome" MOUNTS_FILE="$FIX/mounts-t" bash "$blk" 2>&1)"; RC=$?
	ok; eq "$OUT" "" "a writable home must produce no warning"
	# What docker leaves behind: the parent exists and we cannot write to it.
	chmod 555 "$FIX/fakehome/.local/share"
	OUT="$(HOMEROOT="$FIX/fakehome" MOUNTS_FILE="$FIX/mounts-t" bash "$blk" 2>&1)"; RC=$?
	chmod 755 "$FIX/fakehome/.local/share"          # so the fixture can be cleaned up
	has ".local/share is not writable"
	has "Permission denied"                          # names the symptom you will actually see
	has ".local/share/chezmoi"                       # …and the row that caused it
	# THE CHAIN, not just the nearest parent. `.local/share/chezmoi` made BOTH ~/.local and
	# ~/.local/share root-owned; a check that looked only at the immediate parent would clear a home
	# whose ~/.local is still unwritable, which is the half that breaks ~/.local/bin next.
	chmod 555 "$FIX/fakehome/.local"
	OUT="$(HOMEROOT="$FIX/fakehome" MOUNTS_FILE="$FIX/mounts-t" bash "$blk" 2>&1)"
	chmod 755 "$FIX/fakehome/.local"
	has "/.local is not writable"
	# A top-level destination is NOT a warning: docker covers that mountpoint immediately.
	printf './data/npm-cache\t.npm\trw\trw\n' > "$FIX/mounts-t"
	OUT="$(HOMEROOT="$FIX/fakehome" MOUNTS_FILE="$FIX/mounts-t" bash "$blk" 2>&1)"
	eq "$OUT" "" "a top-level mount destination has no parents to warn about"
}

run "hub: warns about unwritable mount parents"    test_hub_warns_about_unwritable_mount_parents
run "pinchtab: the hub seeds a token"              test_pinchtab_token
run "pinchtab: the hub reaps the profile"           test_hub_reaps_the_pinchtab_profile
run "pinchtab: the broker hands boxes that token"  test_broker_pinchtab_token
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
