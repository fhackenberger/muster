# Security

## Reporting

Please report vulnerabilities privately via GitHub's **Report a vulnerability** button on the Security
tab, not as a public issue. We aim to acknowledge within a week.

## What muster actually is, security-wise

muster runs an AI agent with **write access to a checkout of your code** and a shell, in a container,
unattended. That is the whole point of it, and it is the thing to think clearly about before pointing
it at anything you care about. The design assumes the agent is *not* trusted with anything beyond its
own branch.

### The trust boundaries, and what enforces them

| Boundary | Enforced by |
|---|---|
| A box cannot reach your real origin | it has no credentials for it. The hub holds the only clone with the deploy key; boxes get the repo over `git://` on a private docker network |
| A box cannot write anything but its own branch | a `pre-receive`-style `update` hook on the hub confines pushes to `refs/agents/<box>` and `refs/notes/cbx`. It cannot touch `dev`, cannot delete refs |
| A box cannot start containers | it has no docker socket. Only the **broker** does, and the broker's API is a fixed set of operations gated by a shared token on an internal network — the hub can influence a box's *name*, nothing else |
| A box cannot see another box's work | separate overlay upper layers; the shared golden below them is read-only |
| A box cannot silently change what future boxes get | goldens are immutable while any box is on one; the hub prepares a new one and the broker seals it |

### What is deliberately *not* a boundary

- **The agent is root inside its own box.** It can install packages, run anything, and rewrite its own
  checkout. Isolation is at the container edge, not inside it.
- **The mounts table is shared.** Anything listed in `mounts` is visible to every box, by design — that
  is how caches are shared. Do not put credentials there. Read `mounts.example` before adding a row.
- **Agents can reach the network** unless you stop them. If that matters, put the box network behind an
  egress policy; muster does not do it for you.
- **`service-env` reaches both the hub and every box.** API keys you put there are readable by any
  agent. That is intended (their dev services need them) and worth deciding consciously.
- **The hub is trusted.** It holds the deploy key and merges to `dev`. Anyone who can `docker exec`
  into it, or who controls the broker token, has that access too.

### Things worth doing on a real deployment

- Give the deploy key **write access only if the hub needs to push**, and protect the default branch
  with a ruleset that the key cannot bypass. `README-remote.md` walks through both.
- Keep the broker token out of your shell history — it lives in the stack `.env`, mode 0600.
- Review before you merge. The queue exists so that "an agent wrote it" and "it is in `dev`" are two
  different events, separated by you.
- Prefer a machine that is not also your production host. muster wants a docker socket and a few GB;
  it does not want to be next to anything an escaped container would enjoy.
