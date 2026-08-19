#!/bin/bash
set -euo pipefail

# gen-hub-mounts.sh — render the HUB column of the `mounts` table into compose.override.yml.
#
# `mounts` is the one mount table for this stack (see mounts.example). The broker reads its box
# column directly; compose cannot read it, so the hub's side is generated here into an override file
# that `docker compose` picks up automatically alongside compose.yml.
#
# Run it whenever `mounts` changes, then recreate — env and mounts are fixed at container creation:
#   ./gen-hub-mounts.sh && docker compose up -d hub && cbx recreate all
# Ansible runs it on the server right after templating `mounts`. Forgetting it is not silent: the
# hub's entrypoint compares its actual mounts against the table and complains at boot.
#
# Only PROJECT/TOOLCHAIN paths belong in the table. The stack's own plumbing (data/repo, the goldens,
# data/boxes, hub-services, data/claude, git-identity, …) stays in compose.yml where it is part of the
# stack's definition rather than of this project's environment.

cd "$(dirname "$0")"
MOUNTS="${1:-mounts}"
OUT="${2:-compose.override.yml}"

[ -f "$MOUNTS" ] || { echo "gen-hub-mounts: no $MOUNTS here" >&2; exit 1; }

tmp="$OUT.tmp.$$"
trap 'rm -f "$tmp"' EXIT

{
	echo "# GENERATED from '$MOUNTS' by gen-hub-mounts.sh — DO NOT EDIT."
	echo "# The hub's project mounts, so they cannot drift from what the boxes get. Regenerate with:"
	echo "#   ./gen-hub-mounts.sh && docker compose up -d hub"
	echo "services:"
	echo "  hub:"
	echo "    volumes:"
} > "$tmp"

lineno=0
while read -r src dst hub _box _rest || [ -n "${src:-}" ]; do
	lineno=$((lineno + 1))
	case "${src:-}" in ''|'#'*) continue ;; esac
	# The checkout is a box-side concept (an overlay of a golden); the hub has the real repo.
	[ "$src" = CHECKOUT ] && continue
	[ -n "${dst:-}" ] && [ -n "${hub:-}" ] || { echo "gen-hub-mounts: $MOUNTS:$lineno: expected '<src> <dst> <hub-mode> <box-mode>'" >&2; exit 1; }
	case "$hub" in
		-) continue ;;
		rw) suffix="" ;;
		ro) suffix=":ro" ;;
		overlay) echo "gen-hub-mounts: $MOUNTS:$lineno: 'overlay' is box-side only (the hub owns the lower layer)" >&2; exit 1 ;;
		cow|cow-keep) echo "gen-hub-mounts: $MOUNTS:$lineno: '$hub' is box-side only (the hub owns the original the boxes copy)" >&2; exit 1 ;;
		*) echo "gen-hub-mounts: $MOUNTS:$lineno: bad hub mode '$hub' (rw|ro|-)" >&2; exit 1 ;;
	esac
	case "$src" in
		./*|/*) ;;
		*) echo "gen-hub-mounts: $MOUNTS:$lineno: golden-relative source '$src' cannot be mounted on the hub (use '-')" >&2; exit 1 ;;
	esac
	case "$dst" in
		/*|*..*) echo "gen-hub-mounts: $MOUNTS:$lineno: destination '$dst' must be relative to /home/dev" >&2; exit 1 ;;
	esac
	echo "      - $src:/home/dev/$dst$suffix" >> "$tmp"
done < "$MOUNTS"

mv "$tmp" "$OUT"
echo "gen-hub-mounts: wrote $OUT from $MOUNTS" >&2
