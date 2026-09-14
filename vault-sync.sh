#!/bin/bash
set -euo pipefail

# vault-sync.sh — push this stack's `vault-credentials` and `vault-services` into the running
# agent-vault, and write back the one thing the boxes need: the agent token.
#
# The counterpart of gen-hub-mounts.sh. That script renders a file compose cannot read; this one
# pushes two files agent-vault cannot read — it keeps its state in a database, so the only way to
# make a file the source of truth is to apply it. Run it whenever either file changes:
#
#     ./vault-sync.sh && cbx recreate all
#
# The recreate is not optional when the token changed: a box's environment is fixed at creation.
#
# WHAT IT DOES, in the order it has to happen:
#   1. owner account   register on a fresh instance, then log in (the session lives in the volume)
#   2. vault           create it if this is the first run
#   3. credentials     vault-credentials -> `vault credential set`  (before services, see below)
#   4. services        vault-services    -> `vault service set -f`  (REPLACES the whole list)
#   5. agent + token   one agent per stack; its token is written to data/agent-vault/vault-env, which
#                      the broker reads as VAULT_ENV_FILE and hands to every box
#
# Credentials go before services because agent-vault rejects a service that references a credential
# key it cannot resolve — push them the other way round on a fresh vault and every rule is refused.
#
# IDEMPOTENT, and deliberately asymmetric about deletion. Services are replaced wholesale, so this
# file is the whole egress policy. Credentials are only ever SET: a key dropped from
# vault-credentials keeps its old value in the vault until someone deletes it by hand. A rendering
# slip that empties the file must not strip a live stack of everything it brokers.
#
# THE TOKEN IS NOT ROTATED unless you ask. `--rotate-token` mints a new one and invalidates the old
# immediately — every running box is then talking to the proxy with a dead token until it is
# recreated, so it is a thing you choose, not a side effect of editing a credential.
#
# `--shred-credentials` DELETES vault-credentials once everything above has succeeded. agent-vault
# never reads that file — only this script does, once — so after a sync the copy on disk is a
# duplicate that LOOKS like the source of the values and is not: edit it without re-running this and
# the vault serves the old value forever. For a stack whose vault-credentials is generated (Ansible
# templates it from a secret store), the generator is the source of truth and the server's copy is
# a transient artifact worth removing. For a stack where the file IS hand-maintained, deleting it
# would destroy the only copy — hence a flag and not a default.
#
# Config comes from .env (see .env.example):
#   AGENT_VAULT_VAULT            the vault name (default: $PROJECT_NAME)
#   AGENT_VAULT_OWNER_EMAIL      the instance owner, created on first run
#   AGENT_VAULT_OWNER_PASSWORD   its password — this script's only way back in
#   AGENT_VAULT_ADDR             how a BOX reaches the vault (default: http://agent-vault:14321)

cd "$(dirname "$0")"

ROTATE=0
SHRED=0
for arg in "$@"; do
	case "$arg" in
		--rotate-token)      ROTATE=1 ;;
		--shred-credentials) SHRED=1 ;;
		*) echo "vault-sync: unknown option '$arg' (--rotate-token, --shred-credentials)" >&2; exit 1 ;;
	esac
done

# .env is not sourced — it may hold quoted values and this script must not execute it. Same reader as
# gen-hub-mounts.sh uses for MUSTER_CONF_DIR, for the same reason.
env_get() {
	[ -f .env ] || return 0
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -1 | tr -d "\"'"
}

CONF_DIR="${MUSTER_CONF_DIR:-$(env_get MUSTER_CONF_DIR)}"
CONF_DIR="${CONF_DIR:-.}"
PROJECT="$(env_get PROJECT_NAME)"
VAULT="${AGENT_VAULT_VAULT:-$(env_get AGENT_VAULT_VAULT)}"
VAULT="${VAULT:-$PROJECT}"
OWNER_EMAIL="${AGENT_VAULT_OWNER_EMAIL:-$(env_get AGENT_VAULT_OWNER_EMAIL)}"
OWNER_PASS="${AGENT_VAULT_OWNER_PASSWORD:-$(env_get AGENT_VAULT_OWNER_PASSWORD)}"
BOX_ADDR="${AGENT_VAULT_ADDR:-$(env_get AGENT_VAULT_ADDR)}"
BOX_ADDR="${BOX_ADDR:-http://agent-vault:14321}"

CREDS="$CONF_DIR/vault-credentials"
SERVICES="$CONF_DIR/vault-services"
OUT_DIR="data/agent-vault"
# NOT named box-env. The real box-env is a config file that MUSTER_CONF_DIR moves with the rest; this
# one is generated state and stays under ./data. Two files with one basename is how a stack ends up
# with the conf-dir rule applied to the wrong one.
OUT="$OUT_DIR/vault-env"

[ -n "$VAULT" ] || { echo "vault-sync: no vault name (set AGENT_VAULT_VAULT or PROJECT_NAME in .env)" >&2; exit 1; }
[ -n "$OWNER_EMAIL" ] && [ -n "$OWNER_PASS" ] || {
	echo "vault-sync: AGENT_VAULT_OWNER_EMAIL and AGENT_VAULT_OWNER_PASSWORD must be set in .env" >&2; exit 1; }
# A missing one is also what --shred-credentials leaves behind, and "copy the example" would be the
# wrong advice for the stack that just shredded a generated file — say both.
[ -f "$CREDS" ] || { echo "vault-sync: no $CREDS here." >&2
	echo "            Hand-managed stack: cp vault-credentials.example $CREDS" >&2
	echo "            Generated stack: re-run whatever templates it (--shred-credentials removes it after each sync)" >&2
	exit 1; }
[ -f "$SERVICES" ] || { echo "vault-sync: no $SERVICES here (cp vault-services.example $SERVICES)" >&2; exit 1; }

# Everything runs as the CLI half of the same binary, inside the server's own container: it is the
# only place that already has the master password, the data volume and a loopback route to the API.
# Nothing here needs agent-vault installed on the host.
av() { docker compose exec -T agent-vault agent-vault "$@"; }

docker compose ps --status running --services 2>/dev/null | grep -qx agent-vault || {
	echo "vault-sync: the agent-vault service is not running." >&2
	echo "            COMPOSE_PROFILES=agent-vault must be set in .env; then: docker compose up -d agent-vault" >&2
	exit 1
}

# ---- 1. owner account ---------------------------------------------------------------------------
# The first account on an instance becomes the owner. On every later run registration fails because
# the account is already there, which is the expected path and not an error — the login that follows
# is the real check, and it is the one whose failure must stop the script.
if ! printf '%s' "$OWNER_PASS" | av register --email "$OWNER_EMAIL" --password-stdin >/dev/null 2>&1; then
	: # already registered, or registration closed — login decides
fi
printf '%s' "$OWNER_PASS" | av login --email "$OWNER_EMAIL" --password-stdin --device-label vault-sync >/dev/null

# ---- 2. vault -----------------------------------------------------------------------------------
if av vault list 2>/dev/null | grep -qw -- "$VAULT"; then
	echo "vault-sync: vault '$VAULT' exists"
else
	av vault create "$VAULT" >/dev/null
	echo "vault-sync: created vault '$VAULT'"
fi

# ---- 3. credentials ---------------------------------------------------------------------------
# Same grammar as service-env (compose's env_file format), parsed the same way the broker parses that
# file: KEY=VALUE, value literal to end of line, '#' comments, no expansion. A malformed key is a hard
# error rather than a silently skipped credential — a service referencing it would then be rejected
# with a message about the service, three steps from the line that is actually wrong.
creds=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
	lineno=$((lineno + 1))
	line="${raw#"${raw%%[![:space:]]*}"}"
	case "$line" in ''|'#'*) continue ;; esac
	case "$line" in *=*) ;; *) echo "vault-sync: $CREDS:$lineno: expected KEY=VALUE" >&2; exit 1 ;; esac
	key="${line%%=*}"
	case "$key" in
		[A-Za-z_]*) [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "vault-sync: $CREDS:$lineno: bad key '$key'" >&2; exit 1; } ;;
		*) echo "vault-sync: $CREDS:$lineno: bad key '$key'" >&2; exit 1 ;;
	esac
	creds+=("$line")
done < "$CREDS"

if [ "${#creds[@]}" -gt 0 ]; then
	# One call, not one per key: `credential set` takes them all, and each invocation would otherwise
	# put another secret in the container's process list for the length of a round trip.
	av vault credential set --vault "$VAULT" "${creds[@]}" >/dev/null
	echo "vault-sync: set ${#creds[@]} credential(s) in '$VAULT'"
else
	echo "vault-sync: $CREDS holds no credentials — nothing to set" >&2
fi

# ---- 4. services --------------------------------------------------------------------------------
# Piped in on stdin rather than mounted: the file lives in the stack dir, which the agent-vault
# container has no reason to see, and /dev/stdin keeps it that way.
av vault service set --vault "$VAULT" -f /dev/stdin < "$SERVICES" >/dev/null
echo "vault-sync: applied $SERVICES to '$VAULT'"

# ---- 5. agent + token ---------------------------------------------------------------------------
# One agent per stack, named after the project. `--role no-access` is the default and the right one:
# it is an instance-level role, and this identity has no business anywhere but its own vault, where
# `--vault <name>:proxy` grants it exactly the right to proxy.
AGENT_NAME="${PROJECT:-muster}"
mkdir -p "$OUT_DIR"
token=""
if [ -f "$OUT" ] && [ "$ROTATE" = 0 ]; then
	token="$(sed -n 's/^AGENT_VAULT_TOKEN=//p' "$OUT" | tail -1)"
fi

if [ -z "$token" ]; then
	if av agent list 2>/dev/null | grep -qw -- "$AGENT_NAME"; then
		[ "$ROTATE" = 1 ] || echo "vault-sync: agent '$AGENT_NAME' exists but no token is stored here — rotating to recover it" >&2
		token="$(av agent rotate "$AGENT_NAME" --token-only)"
		echo "vault-sync: rotated the token for agent '$AGENT_NAME' — the old one is now invalid"
	else
		token="$(av agent create "$AGENT_NAME" --vault "$VAULT:proxy" --token-only)"
		echo "vault-sync: created agent '$AGENT_NAME'"
	fi
fi
[ -n "$token" ] || { echo "vault-sync: no agent token" >&2; exit 1; }

# The broker reads this as VAULT_ENV_FILE and applies it to every box between service-env and
# box-env — so a project can still override any of it, and nothing here needs a second home.
#
# MUSTER_CLAUDE_LAUNCHER is what actually puts a box behind the proxy: muster-box.sh prefixes the
# claude command with it, so claude and every tool it runs inherit HTTPS_PROXY and the CA trust that
# `agent-vault run` sets up. Drop that line and the boxes still hold the token but route nothing.
tmp="$OUT.tmp.$$"
trap 'rm -f "$tmp"' EXIT
{
	echo "# GENERATED by vault-sync.sh — DO NOT EDIT. Holds this stack's agent token."
	echo "# Regenerate with ./vault-sync.sh; rotate with ./vault-sync.sh --rotate-token."
	echo "AGENT_VAULT_ADDR=$BOX_ADDR"
	echo "AGENT_VAULT_VAULT=$VAULT"
	echo "AGENT_VAULT_TOKEN=$token"
	echo "MUSTER_CLAUDE_LAUNCHER=agent-vault run --"
} > "$tmp"
chmod 0600 "$tmp"
mv "$tmp" "$OUT"

echo "vault-sync: wrote $OUT — run 'cbx recreate all' to put the boxes on it"

# ---- 6. the plaintext copy, once it is no longer needed ------------------------------------------
# LAST, and only on success. Everything above can fail and be retried; a file deleted before the
# retry would take the values with it. By here the vault holds them and this copy answers no
# question — agent-vault reads its own store, not this.
#
# `shred` is best-effort on a journalling filesystem (it cannot reach a block the fs has already
# copied elsewhere), so this is about closing the obvious window, not about defeating forensics.
# The real protection was always the 0600 and the absence of a mount into any container.
if [ "$SHRED" = 1 ]; then
	if command -v shred >/dev/null 2>&1; then
		shred -u "$CREDS"
	else
		rm -f "$CREDS"
	fi
	echo "vault-sync: removed $CREDS — the vault is the source of these values now"
fi
