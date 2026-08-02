# Architecture Decision Records

One short document per significant decision: the context it was taken in, what was decided, what
follows from it, and which alternatives were rejected and why.

They exist because code answers *what* and never *why*. Six months on, "why is the box add-on behind a
compose profile" and "why not just give each agent a clone" are questions whose answers are otherwise
reconstructed from scratch — usually wrongly, and usually while changing the thing.

Format: [Michael Nygard's](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).
Numbered, dated, immutable once accepted — a decision that is later reversed gets a **new** record
that supersedes the old one, so the reasoning stays readable in order.

| | |
|---|---|
| [0001](0001-image-builds.md) | What we publish, what everyone builds, and where |
| [0002](0002-one-overlay-and-a-branch-per-agent.md) | One overlay and one branch per agent |
