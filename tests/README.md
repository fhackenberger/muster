# cbx test suite

```sh
./tests/run-tests.sh              # everything (~40s)
./tests/run-tests.sh minto        # only tests whose name matches
KEEP=1 ./tests/run-tests.sh       # keep the scratch fixtures to poke at
MUSTER_BIN=/tmp/cbx ./tests/run-tests.sh   # test a modified copy
```

**No docker, no network, no running stack.** What's under test is the part that holds the logic:
`hub/muster` (all of it), `box-bin/muster-box-init`, and `box-broker/broker.py`'s pure helpers. The broker
is replaced by `tests/stub-broker.py` — same HTTP contract, records every request as JSON so a test
can assert on *what cbx asked it to do* — and every git operation runs against a scratch repo with a
bare "origin" beside it. Runs in the Jenkins pipeline before any image is built.

Requires `git`, `jq`, `curl`, `python3` and `python3-yaml`. `tmux` and `script` are optional; the
tests that need them skip with a notice rather than failing.

The **hub base image ships all of them**, so the simplest way to run the suite anywhere — a CI agent
with nothing installed, a colleague's laptop — is in the image muster itself ships:

```sh
docker run --rm -v "$PWD:/w" -w /w -e TMPDIR=/tmp --entrypoint= \
  ghcr.io/fhackenberger/muster-hub-base:<version> ./tests/run-tests.sh
```

`--entrypoint=` because the image's own entrypoint would otherwise clone a repo and start tmux;
`TMPDIR=/tmp` keeps the scratch fixtures inside the container instead of the mounted workspace.

## How a test is written

```sh
test_merge_squash() {
    handoff work1 3 >/dev/null; box_up work1     # 3 commits pushed to refs/agents/work1, box "running"
    cbx merge work1 --squash                     # runs cbx, captures output in $OUT and status in $RC
    ok                                           # exited 0
    eq "$(git_ rev-list --count dev)" "2" "squash should land exactly one commit"
    OUT="$(git_ log -1 --format=%B dev)"
    has "Cbx-Box: work1"                         # $OUT contains this
}
run "merge: --squash lands one commit"  test_merge_squash
```

Each `run` gets a **fresh fixture**: a bare `origin.git`, a hub clone on `dev` with one commit, and
empty state dirs, with every path cbx reads exported. Helpers live in `lib.sh`:

| | |
|---|---|
| `cbx …` | run cbx → `$OUT`, `$RC` |
| `muster_tty "a\|m" merge x --reword` | drive an interactive prompt over a PTY (see below) |
| `handoff <box> [n]` | n commits on top of dev, pushed to `refs/agents/<box>`, with a note |
| `commit_on <start> <newref\|-> <msg> <file> <content>` | a commit, without moving the hub's checkout |
| `box_up <box>` | register a box with the stub broker so `ls`/`kill`/`say` behave |
| `stub_saw POST /box/x/say`, `stub_body <path>` | assert on what the broker was asked |
| `ok` `notok` `has` `hasnt` `eq` `ne` `exists` `absent` `at <ref>` | assertions |

Two conventions worth knowing, because both encode a real property of the system:

- **The hub's checkout never leaves `dev`.** Several tests assert it, so agent commits are made in
  throwaway linked worktrees (`commit_on`) rather than by checking anything out. The one exception is
  a commit *on* `dev` itself, which `commit_on` makes in place — moving the checked-out branch with
  `update-ref` would leave a stale index and every later command would see phantom staged changes.
- **Interactive prompts need `muster_tty`, not a pipe.** cbx drops pending terminal input before drawing
  a prompt (`tty_flush`, so a review TUI's leftover keystrokes can't answer the next question), which
  eats piped input before the prompt exists. `muster_tty` runs cbx under `script` and feeds keys with a
  delay, which is also a more faithful test of what a person does.

## Checking the suite has teeth

Mutate a copy and confirm the *right* test goes red:

```sh
cp hub/muster /tmp/cbx
sed -i 's/die "refusing to merge a minto box into $DEV"/true/' /tmp/cbx
MUSTER_BIN=/tmp/cbx ./tests/run-tests.sh      # -> FAIL minto: --box queue, review and land
```

Three such mutations are checked by hand whenever the suite changes: reverting the review
added-commits fix, dropping the minto guard in `cbx merge`, and putting the help printer back to its
old hard-coded `sed -n '4,52p'` line range (which is how `cbx push` silently fell out of `--help`).
