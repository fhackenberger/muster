# Contributing

## Run the tests

```sh
./tests/run-tests.sh              # everything, ~40s
./tests/run-tests.sh minto        # only tests whose name matches
```

No docker, no network, no running stack: the broker is replaced by a stub with the same HTTP contract,
and every git operation runs against a scratch repo. It gates CI, so a red suite is a red pull request.
`tests/README.md` explains the fixtures and how to add a case.

**Send a test with the change.** Then check it has teeth — mutate a copy and confirm the *right* test
goes red:

```sh
cp hub/muster /tmp/m && sed -i 's/<the guard you just added>/true/' /tmp/m
MUSTER_BIN=/tmp/m ./tests/run-tests.sh
```

## The shape of the code

Three pieces, and which one you are touching decides how it reaches a server:

| | |
|---|---|
| `hub/muster` | the CLI: the review queue, merges, goldens. Runs in the hub container |
| `box-broker/broker.py` | the only holder of the docker socket; spawns boxes |
| `box-bin/*` | what an agent has inside its box (`handoff`, `mydiff`, the init) |
| `muster.bash_aliases` | the laptop side: one command family per stack |

`hub/muster` runs under `set -euo pipefail`. Three traps that have each cost a real bug:

- end helpers that may legitimately fail with `|| true` — a bare `git notes show` inside `$( )` kills
  the whole command silently;
- never write `local a="$1" b="x-$a"` — bash expands every word of one `local` before assigning any,
  so `$a` is unset there;
- bash locals are **dynamically scoped**, so a `local DEV` silently shadows the global in everything
  you then call. (The alias factory uses that on purpose; read it before you fight it.)

The header comment block in `hub/muster` **is** `muster --help`, printed by pattern. A new subcommand
goes in three places — that block, the dispatch `case`, and `README-remote.md` — and a test asserts
all three stay in step.

## Style

Match what is around you. The comments here explain *why*, especially where something looks odd: most
of them mark a trap someone already fell into. If you remove one, make sure the trap went with it.

## Decisions

Anything structural gets an ADR in `docs/adr/` — short, dated, with the alternatives that were
rejected and why.
