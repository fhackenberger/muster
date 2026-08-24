#!/usr/bin/env python3
"""box-broker — the only container with the docker socket.

It is "muster-box.sh as a service": the hub asks it (over the internal compose network, gated by
a shared token) to create/kill/list agent boxes, and the broker runs the modified muster-box.sh
with a VETTED environment. The hub can influence only the box NAME; image, uid, network,
privileges, the socket and the mount list are the broker's. What a box sees comes from the
`mounts` table (MOUNTS_FILE), which is root-owned project config synced by Ansible — the hub
cannot write it, so a compromised hub cannot add a mount.

MOUNTS IS THE ONE MOUNT TABLE — hub AND box. Same file, one row per path, a mode column per side,
so the two environments cannot drift apart (they did once: a `~/.gradle` shared rw with the hub
let its `bootRun` hold gradle's cache locks against every box forever). This broker reads the box
column; the hub's side of the same table is rendered into compose.override.yml by
gen-hub-mounts.sh, and the hub's entrypoint warns if what it actually has doesn't match.

THE CHECKOUT IS AN OVERLAY. One prepared "golden" tree (cloned, deps installed, caches warm) is
shared read-only by every box as an overlayfs lowerdir; each box writes into its own upperdir, so
N agents cost N x (their own diff) instead of N full checkouts. The mount is performed by DOCKER
(a local-driver volume with type=overlay), so neither this broker nor the box needs CAP_SYS_ADMIN.
Each box therefore gets a REAL .git and works on its own branch (agent/<box>), pushing to the hub;
the hub reviews and merges. See hub/muster and README-remote.md. A spawn may name a different base
branch and a branch to merge into it (POST /box/<name>?base=…&merge=…), which is how `cbx minto`
hands an agent a conflicted merge that is already set up when claude starts.

Goldens are immutable while any box is overlaid on one (changing a lowerdir under a live overlay
is undefined behaviour), so they are versioned: data/golden/g-<id>, with `current` pointing at the
newest. The hub prepares a new one in data/golden-staging (the only golden path it can write) and
calls /golden/seal to move it into place; boxes pick it up on the next recreate.

To keep spawns fast AND current, the broker pulls BOX_IMAGE in the background at startup and after
each spawn — so a new box uses a recent image without ever waiting on a `docker pull`.

Config (env, from compose):
  BROKER_TOKEN        shared secret; required in the X-Broker-Token header
  BROKER_PORT         listen port (default 8099; not published to the LAN)
  PROJECT_NAME        used for the box name prefix  box-<project>-<name>
  BOX_IMAGE           the muster image (default: muster)
  BOX_NETWORK         docker network the box joins (e.g. cbx-<project>)
  GOLDEN_DIR          HOST path holding the sealed goldens + the `current` symlink
  GOLDEN_STAGING      HOST path the hub prepares new goldens in (sealed via /golden/seal)
  PROJECT_ROOT        confinement root for golden-relative mount sources (default: the current golden)
  CHECKOUT_DST        where the overlay is mounted in the box (default /home/dev/repo — must match the hub)
  STACK_DIR           HOST path of the stack dir, what a './…' mount source resolves against
  MOUNTS_FILE         HOST path of the `mounts` table — hub + box mounts, one row per path (see
                      mounts.example for the grammar)
  CLAUDE_HOME         HOST path of the shared ~/.claude (mounted into every box; boxes also get
                      CLAUDE_CONFIG_DIR pointing at it, so .claude.json — the login and the user
                      preferences — is shared too and one login covers the whole stack)
  BOXROOT             HOST path whose <name>/{home,upper,work,ovl-*} subdirs back each box
  DEV_BRANCH          branch agents base their work on (default: dev)
  HUB_GIT_URL         the hub repo as the boxes reach it (default: git://hub/repo)
  PINCHTAB_SERVER     e.g. http://hub:9867     PINCHTAB_TOKEN  the pinchtab token
  PORT_FORWARDS_FILE  HOST path of the port-forwards manifest (NAME BOX_PORT HUB_BASE_PORT per line)
  PORT_FORWARD_SLOTS  max concurrent boxes with forwards; each box's slot N -> hub port BASE+N (dflt 16)
  SERVICE_ENV_FILE    KEY=VALUE lines given to the hub (compose env_file) AND every box, verbatim
  BOX_ENV_FILE        KEY=VALUE lines for BOXES ONLY, values expanded per box, applied last
  BOX_UID/BOX_GID     synthetic non-root identity inside the box (default 1000/1000)
  MUSTER_SCRIPT    path to muster-box.sh (default /usr/local/bin/muster-box.sh)
"""
import base64
import json
import os
import string
import re
import shutil
import subprocess
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BROKER_TOKEN", "")
PORT = int(os.environ.get("BROKER_PORT", "8099"))
PROJECT = os.environ.get("PROJECT_NAME", "project")
BOX_IMAGE = os.environ.get("BOX_IMAGE", "muster")
BOX_NETWORK = os.environ.get("BOX_NETWORK", "")
GOLDEN_DIR = os.environ.get("GOLDEN_DIR", "")
GOLDEN_STAGING = os.environ.get("GOLDEN_STAGING", "")
# Where the overlay lands in the box. MUST equal the hub's own repo path: goldens are snapshots of
# that tree, and installed dependencies bake absolute paths in, so they only stay valid if the tree
# is mounted back where it was prepared.
CHECKOUT_DST = os.environ.get("CHECKOUT_DST", "/home/dev/repo")
CLAUDE_HOME = os.environ.get("CLAUDE_HOME", "")
# The stack dir on the HOST. A './…' source in the mounts table resolves against it, which is what
# lets the same row be a literal './data/…' in the hub's compose override and an absolute host path
# in a box's -v — no $VAR that compose and this broker could expand differently.
STACK_DIR = os.environ.get("STACK_DIR", "")
BOXROOT = os.environ.get("BOXROOT", "")
MOUNTS_FILE = os.environ.get("MOUNTS_FILE", "")
DEV_BRANCH = os.environ.get("DEV_BRANCH", "dev")
HUB_GIT_URL = os.environ.get("HUB_GIT_URL", "git://hub/repo")
PT_SERVER = os.environ.get("PINCHTAB_SERVER", "")
PT_TOKEN = os.environ.get("PINCHTAB_TOKEN", "")
# Where the pinchtab SERVER's config lives on the host. Only read when PT_TOKEN is empty — see
# pinchtab_token().
PT_CONFIG = os.environ.get("PINCHTAB_CONFIG", "")
# Per-project port forwards (like `mounts`). File grammar: 'NAME BOX_PORT HUB_BASE_PORT' per line;
# each box gets a slot N and every forward is published on the hub at 127.0.0.1:(HUB_BASE_PORT + N).
PORT_FORWARDS_FILE = os.environ.get("PORT_FORWARDS_FILE", "")
PORT_FORWARD_SLOTS = int(os.environ.get("PORT_FORWARD_SLOTS", "16"))
# Project/service env (KEY=VALUE lines) handed to every box — backend/frontend settings an agent needs
# when it runs those services itself. The SAME file is given to the hub via `env_file:` in compose, so
# a service behaves identically whether the hub or a box runs it.
SERVICE_ENV_FILE = os.environ.get("SERVICE_ENV_FILE", "")
# The BOX half of that: KEY=VALUE lines whose values may use $VARIABLES, expanded per box and applied
# after service-env — so a project can override, for boxes only, a value that is correct on the hub.
# Optional; a stack without one behaves exactly as before.
BOX_ENV_FILE = os.environ.get("BOX_ENV_FILE", "")
BOX_UID = os.environ.get("BOX_UID", "1000")
BOX_GID = os.environ.get("BOX_GID", "1000")
MUSTER_SCRIPT = os.environ.get("MUSTER_SCRIPT", "/usr/local/bin/muster-box.sh")

# Which muster this is, baked into the image (see the Dockerfiles). Reported over /version so the hub
# can tell you when the two have drifted apart — three images, three build paths, and otherwise
# nothing at all stops a 0.2 broker from driving a 0.1 hub.
MUSTER_VERSION = os.environ.get("MUSTER_VERSION", "unknown")

# HOW A BOX'S CLAUDE STARTS, as project policy rather than something you type every time.
#
#   MUSTER_CLAUDE_PERMISSION_MODE  passed verbatim to claude's --permission-mode.
#   MUSTER_BOX_PROMPT              an opening prompt, given to claude as its first message.
#
# Both come from the stack's .env, so they are a property of the deployment: every box this broker
# spawns starts the same way, and a recreate reproduces it.
#
# THE NAME SAYS CLAUDE ON PURPOSE, and the value is passed THROUGH. Permission levels belong to the
# harness, not to muster: they are claude's vocabulary, they change when claude changes, and another
# agent CLI in a box would bring a different set with different meanings. The neutral-sounding
# MUSTER_BOX_MODE invited exactly the mistake it shipped with — it translated `auto` to acceptEdits,
# on the assumption that "auto" was a colloquialism for "accept the edits". It is not: `auto` is
# claude's own mode, in which a small model judges whether each command may run. Inventing a
# vocabulary on top of someone else's is how a deployment quietly ends up on a policy nobody chose.
MUSTER_CLAUDE_PERMISSION_MODE = os.environ.get("MUSTER_CLAUDE_PERMISSION_MODE", "").strip()
MUSTER_BOX_PROMPT = os.environ.get("MUSTER_BOX_PROMPT", "")

# Advisory only — the modes claude documents today. A value outside this list is still passed on,
# because claude gains modes on its own schedule and muster rejecting one it has not heard of is the
# more annoying failure. It is worth a line in the log either way: if boxes then die at startup on a
# flag claude rejects, this is the first place to look.
KNOWN_CLAUDE_MODES = ("default", "plan", "acceptEdits", "bypassPermissions", "auto")


def box_mode_arg():
	"""`--permission-mode <mode>` exactly as configured, or "" when unset."""
	if not MUSTER_CLAUDE_PERMISSION_MODE:
		return ""
	if MUSTER_CLAUDE_PERMISSION_MODE not in KNOWN_CLAUDE_MODES:
		print(f"box-broker: MUSTER_CLAUDE_PERMISSION_MODE={MUSTER_CLAUDE_PERMISSION_MODE!r} is not one of "
		      f"{list(KNOWN_CLAUDE_MODES)} — passing it to claude as-is. If boxes die at startup, this "
		      f"is why: claude exits on an unknown --permission-mode.", flush=True)
	return f"--permission-mode {MUSTER_CLAUDE_PERMISSION_MODE}"


def box_prompt(name, facts):
	"""The opening prompt for this box, with $VARIABLES filled in, base64-encoded for the launcher.

	SUBSTITUTION uses string.Template against the broker's own environment plus the per-box facts
	below, so a prompt can say what this box is without the deployment having to know: e.g.
	    MUSTER_BOX_PROMPT='You are agent $MUSTER_BOX on $MUSTER_BRANCH, based on $MUSTER_DEV_BRANCH.'
	`safe_substitute` leaves unknown names untouched — a stray $ in prose must not blow up a spawn.

	BASE64 because the result travels through two layers of shell parsing (muster-box.sh builds a
	`bash -lc` that builds a tmux command), and a prompt is exactly the sort of string that contains
	quotes, backticks and newlines. Same reason `cbxexec` does it."""
	if not MUSTER_BOX_PROMPT.strip():
		return ""
	mapping = dict(os.environ)
	mapping.update(facts)
	text = string.Template(MUSTER_BOX_PROMPT).safe_substitute(mapping)
	return base64.b64encode(text.encode()).decode()

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
GOLDEN_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
# A git branch name, for the ?base=/?merge= spawn parameters (`cbx minto`). These end up in the box's
# environment and are handed to `git checkout`/`git merge` there, so the set is deliberately narrow:
# the leading character rules out a name that would parse as an option, and valid_branch() rejects the
# revision syntax ('..', '@{') that the character class alone still admits.
BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$")


def valid_branch(name):
	return bool(name) and bool(BRANCH_RE.match(name)) and ".." not in name and not name.endswith(".lock")
HOME_IN = "/home/dev"
# Where a box's own durable directory appears inside it. Under the home rather than off in /work so
# that `cd ~/keep` needs no explanation and `ls ~` shows it; the host side is data/boxes/<box>/keep.
KEEP_DST = f"{HOME_IN}/keep"

# Serializes the background `docker pull` of BOX_IMAGE so concurrent spawns don't each start one.
_pull_lock = threading.Lock()
# Serializes golden seal/reap against spawns, so a box can never be created against a golden that is
# being moved or deleted underneath it.
_golden_lock = threading.RLock()


def box_image_version():
	"""The muster version baked into the image the broker spawns boxes from, or "unknown".

	Read from the IMAGE rather than assumed, because the box image is the one the broker does not
	build: it is the project's add-on, layered on some muster base, and which base that was is the
	thing that has to match. The broker names binaries inside it (muster-box-init, muster-activity)
	and sets the environment they read, so a mismatch here is boxes that fail to initialise — or, for
	an older image, silently ignore parameters a newer hub sent."""
	r = subprocess.run(
		["docker", "image", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", BOX_IMAGE],
		capture_output=True, text=True)
	if r.returncode != 0:
		return "unknown"                      # not pulled yet; not worth an error
	for line in r.stdout.splitlines():
		if line.startswith("MUSTER_VERSION="):
			return line.split("=", 1)[1].strip() or "unknown"
	return "unknown"


def box_container(name):
	return f"box-{PROJECT}-{name}"


def box_volume(name):
	return f"cbx-{PROJECT}-{name}"


def pf_container(name, fwd_name):
	# Distinct prefix (pf-, not box-) so these sidecars don't match the box listing filter.
	return f"pf-{PROJECT}-{name}-{fwd_name.lower()}"


def hub_container():
	"""The hub container id (via its compose labels), or None. It is the netns the forwarders join."""
	r = subprocess.run(
		["docker", "ps", "-q", "-f", f"label=com.docker.compose.project={PROJECT}",
		 "-f", "label=com.docker.compose.service=hub"],
		capture_output=True, text=True,
	)
	ids = r.stdout.split()
	return ids[0] if ids else None


# --------------------------------------------------------------------------- goldens

def current_golden():
	"""HOST path of the golden the next box should overlay. Follows data/golden/current."""
	if not GOLDEN_DIR:
		raise RuntimeError("GOLDEN_DIR is not configured")
	cur = os.path.join(GOLDEN_DIR, "current")
	if not os.path.exists(cur):
		raise RuntimeError(
			"no golden yet — prepare one from the hub with: cbx golden snapshot")
	return os.path.realpath(cur)


def list_goldens():
	"""Sealed goldens, which one is current, and which boxes reference each (reap safety)."""
	out, cur = [], ""
	try:
		cur = os.path.basename(current_golden())
	except RuntimeError:
		pass
	in_use = {}
	if BOXROOT and os.path.isdir(BOXROOT):
		for d in sorted(os.listdir(BOXROOT)):
			gf = os.path.join(BOXROOT, d, "golden")
			if os.path.exists(gf):
				in_use.setdefault(open(gf).read().strip(), []).append(d)
	if GOLDEN_DIR and os.path.isdir(GOLDEN_DIR):
		for d in sorted(os.listdir(GOLDEN_DIR)):
			p = os.path.join(GOLDEN_DIR, d)
			if d == "current" or not os.path.isdir(p) or os.path.islink(p):
				continue
			out.append({"golden": d, "current": d == cur, "boxes": in_use.get(d, [])})
	return {"goldens": out, "current": cur, "staging": GOLDEN_STAGING}


def seal_golden(gid):
	"""Move a hub-prepared staging tree into GOLDEN_DIR and point `current` at it.

	The hub cannot do this itself: it mounts GOLDEN_DIR read-only precisely so it can never write a
	sealed golden (mode bits can't be used for that — overlayfs checks write permission on the merged
	inode BEFORE copy-up, so a non-writable golden would make every file unwritable inside the box)."""
	if not GOLDEN_RE.match(gid):
		raise ValueError("bad golden id")
	with _golden_lock:
		src = os.path.join(GOLDEN_STAGING, gid)
		dst = os.path.join(GOLDEN_DIR, gid)
		if not os.path.isdir(src):
			raise RuntimeError(f"no staged golden at {src}")
		if os.path.exists(dst):
			raise RuntimeError(f"golden {gid} already exists")
		os.rename(src, dst)          # same filesystem (both under the stack dir) -> atomic
		link = os.path.join(GOLDEN_DIR, "current")
		tmp = link + ".tmp"
		os.symlink(gid, tmp)
		os.replace(tmp, link)        # atomic flip; boxes spawned from here on get the new golden
		return {"sealed": gid, "current": gid}


def reap_goldens():
	"""Delete sealed goldens that are neither current nor referenced by an existing box dir."""
	with _golden_lock:
		info = list_goldens()
		removed = []
		for g in info["goldens"]:
			if g["current"] or g["boxes"]:
				continue
			shutil.rmtree(os.path.join(GOLDEN_DIR, g["golden"]), ignore_errors=True)
			removed.append(g["golden"])
		return {"reaped": removed}


# --------------------------------------------------------------------------- port forwards

def parse_port_forwards():
	"""Per-project forwards from PORT_FORWARDS_FILE (like `mounts`). One line each:
	    NAME BOX_PORT HUB_BASE_PORT      e.g. 'FRONTEND 4200 4300'
	Returns [(name, box_port, hub_base)]. For a box in slot N, the hub publishes NAME on
	127.0.0.1:(HUB_BASE_PORT + N). '#'/blank lines ignored; empty/missing file -> no forwards."""
	fwds = []
	if not PORT_FORWARDS_FILE or not os.path.exists(PORT_FORWARDS_FILE):
		return fwds
	with open(PORT_FORWARDS_FILE) as fh:
		for raw in fh:
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			parts = line.split()
			if len(parts) != 3:
				raise ValueError(f"bad port-forwards line {raw.strip()!r} (want: NAME BOX_PORT HUB_BASE_PORT)")
			fwds.append((parts[0], int(parts[1]), int(parts[2])))
	return fwds


ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_service_env():
	"""KEY=VALUE lines from SERVICE_ENV_FILE, as a list of "KEY=VALUE" strings.

	Same file compose feeds the hub with `env_file:`, so the format is compose's: one KEY=VALUE per
	line, '#' comments, no quoting rules and no shell expansion — the value is taken literally to the
	end of the line. Keys are validated; a malformed line is rejected loudly rather than silently
	shipping something odd into every box. Values cannot contain newlines (the list is newline-joined
	when handed to muster-box.sh)."""
	out = []
	if not SERVICE_ENV_FILE or not os.path.exists(SERVICE_ENV_FILE):
		return out
	with open(SERVICE_ENV_FILE) as fh:
		for raw in fh:
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			if "=" not in line:
				raise ValueError(f"bad service-env line {line!r} (want: KEY=VALUE)")
			key, value = line.split("=", 1)
			key = key.strip()
			if not ENV_KEY_RE.match(key):
				raise ValueError(f"bad service-env key {key!r}")
			out.append(f"{key}={value}")
	return out


def pinchtab_token():
	"""The token a box's pinchtab CLI must present, which has to be the one the SERVER accepts.

	PINCHTAB_TOKEN (from the stack's PT_TOKEN) wins when it is set. When it is not, the hub generated
	one into the pinchtab config at first boot, and this reads it back out — that is what lets a fresh
	stack work with no secret for anyone to invent, and it keeps the two sides in step by having only
	one place where the token actually lives.

	Read at SPAWN, never cached: the hub may have generated it after this broker started, and a token
	cached at import would then be empty for the life of the container."""
	if PT_TOKEN:
		return PT_TOKEN
	if not PT_CONFIG:
		return ""
	try:
		with open(PT_CONFIG) as fh:
			token = (json.load(fh).get("server", {}) or {}).get("token") or ""
	except (OSError, ValueError, AttributeError):  # noqa: BLE001
		return ""
	token = token.strip()
	# The shipped example's placeholder is not a token; handing it to a box would produce an auth
	# failure that reads like a broken server.
	return "" if "change-me" in token else token


def parse_box_env():
	"""KEY=$TEMPLATE lines from BOX_ENV_FILE — the project's per-box environment.

	service-env is fed VERBATIM to the hub (by compose, as an env_file) and to every box, which is why
	it must never contain `$VAR`. This file is the opposite: it is read only here, expanded per box,
	and appended AFTER service-env, so a value defined there can be OVERRIDDEN for boxes only.

	That is the whole point. A URL like http://localhost:8091/app is correct on the hub and correct in
	your browser through the tunnels, and wrong inside a box, where localhost is the box. One key, two
	truths, and until now the second one was hard-coded in this file under the project's own variable
	names (FRONTEND_DEV_BACKEND_URL_OWN) — muster inventing meaning for a name it cannot know."""
	out = []
	if not BOX_ENV_FILE or not os.path.exists(BOX_ENV_FILE):
		return out
	with open(BOX_ENV_FILE) as fh:
		for raw in fh:
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			if "=" not in line:
				raise ValueError(f"bad box-env line {line!r} (want: KEY=VALUE)")
			key, value = line.split("=", 1)
			key = key.strip()
			if not ENV_KEY_RE.match(key):
				raise ValueError(f"bad box-env key {key!r}")
			out.append(f"{key}={value}")
	return out


def last_wins(lines):
	"""One line per key, keeping the LAST — which is how box-env overrides service-env.

	`docker run -e A=1 -e A=2` does keep the last, but resting a documented feature on an unwritten
	CLI detail is how a docker upgrade turns into a stack whose agents quietly talk to the wrong
	backend. Collapsing here makes the rule ours, and the environment easier to read in
	`docker inspect` besides."""
	seen = {}
	for line in lines:
		seen[line.split("=", 1)[0]] = line
	return list(seen.values())


def expand_box_env(lines, facts):
	"""Expand $VARIABLES in box-env values against this box's facts.

	safe_substitute, not substitute: an unknown $name is left exactly as written. A token, a password
	or a regex containing a stray $ must not be able to fail a spawn — and a typo'd variable that
	survives into the environment is visible in `docker inspect`, where a KeyError three layers down
	is not."""
	out = []
	for line in lines:
		key, value = line.split("=", 1)
		out.append(f"{key}={string.Template(value).safe_substitute(facts)}")
	return out


def _slot_of(name):
	try:
		with open(os.path.join(BOXROOT, name, "slot")) as fh:
			return int(fh.read().strip())
	except (OSError, ValueError):
		return None


def live_slots(exclude=None):
	"""Slots held by boxes that still have a CONTAINER — the only ones actually in use.

	This is the whole fix for "out of port-forward slots" with two boxes running. A killed box keeps
	its directory on purpose (the upper layer holds work that was never pushed, plus warm caches, and
	`box <same name>` reattaches to them), and the slot file lives in that directory. Counting files
	therefore counted every box that had EVER existed: after the sixteenth, spawning failed for good,
	and `muster ls` showed two boxes while the broker insisted it was full.

	`docker ps -a`: a stopped container still owns its ports as far as we are concerned, and kill_box
	removes the container — so "the container exists" is exactly the lifetime of a claim."""
	out = subprocess.run(["docker", "ps", "-a", "--filter", f"name=^box-{PROJECT}-",
	                      "--format", "{{.Names}}"], capture_output=True, text=True)
	slots = set()
	for ln in out.stdout.splitlines():
		name = _box_name_of(ln.strip())
		if not name or name == exclude:
			continue
		slot = _slot_of(name)
		if slot is not None:
			slots.add(slot)
	return slots


def alloc_slot(box_dir):
	"""A port-forward slot (0..PORT_FORWARD_SLOTS-1) for this box.

	Its own previous slot when nothing live holds it — so a recreate keeps the hub ports you had open
	— otherwise the lowest free one. Raises only when that many boxes really are alive."""
	name = os.path.basename(box_dir.rstrip("/"))
	sf = os.path.join(box_dir, "slot")
	taken = live_slots(exclude=name)
	mine = _slot_of(name)
	if mine is not None and mine not in taken and mine < PORT_FORWARD_SLOTS:
		return mine
	for slot in range(PORT_FORWARD_SLOTS):
		if slot not in taken:
			os.makedirs(box_dir, exist_ok=True)
			with open(sf, "w") as fh:
				fh.write(str(slot))
			return slot
	raise RuntimeError(f"out of port-forward slots: {len(taken)} of {PORT_FORWARD_SLOTS} are held by "
	                   f"boxes that still exist ('muster ls' shows them, 'muster kill <box>' frees one)")


def start_forwarders(name, slot, forwards):
	"""One socat per forward, in the HUB's netns, mapping hub 127.0.0.1:(base+slot) -> box:box_port. So
	the hub browser (and anything on the hub) reaches each box service as http://localhost:<hub_port> —
	allowlisted by default, Host stays localhost. socat runs FROM the box image (--entrypoint socat) in
	the hub's netns (--network container:<hub>), so bind=127.0.0.1 is the hub loopback and the box name
	resolves via the hub's cbx-network DNS."""
	# Rebuild this box's set from scratch. Recreating only the CURRENT manifest entries would leave a
	# forward whose NAME was deleted from port-forwards still running and still bound on the hub
	# loopback — pointing into a box where nothing listens, which looks exactly like a broken tunnel.
	stop_forwarders(name)
	if not forwards:
		return
	hub = hub_container()
	if not hub:
		print(f"box-broker: no hub container found — skipping port-forwards for {name}", flush=True)
		return
	for fwd_name, box_port, hub_base in forwards:
		hub_port = hub_base + slot
		c = pf_container(name, fwd_name)
		r = subprocess.run(
			["docker", "run", "-d", "--name", c, "--network", f"container:{hub}",
			 "--entrypoint", "socat", BOX_IMAGE,
			 f"TCP-LISTEN:{hub_port},bind=127.0.0.1,fork,reuseaddr", f"TCP:{box_container(name)}:{box_port}"],
			capture_output=True, text=True,
		)
		if r.returncode != 0:
			print(f"box-broker: forward {fwd_name} ({name}) failed: {r.stderr.strip()}", flush=True)


def stop_forwarders(name):
	ids = subprocess.run(
		["docker", "ps", "-aq", "-f", f"name=^pf-{PROJECT}-{name}-"],
		capture_output=True, text=True,
	).stdout.split()
	if ids:
		subprocess.run(["docker", "rm", "-f", *ids], capture_output=True, text=True)


# --------------------------------------------------------------------------- mounts

def refresh_forwarders(name=None):
	"""(Re)establish the socat forwarders for one box, or every running box.

	Needed because the forwarders run in the HUB's network namespace (--network container:<hub>): if
	the hub container is REPLACED — which `docker compose up -d hub` does on any config change — its
	netns goes with it and every forwarder dies. Nothing notices until an agent's frontend stops being
	reachable. The hub asks for this on boot, and `cbx forwards` triggers it by hand."""
	forwards = parse_port_forwards()
	done = []
	for r in list_boxes()["boxes"]:
		n = r["box"]
		if name and n != name:
			continue
		if not r["status"].startswith("Up"):
			continue          # forwarding into a stopped box is pointless
		slot = alloc_slot(os.path.join(BOXROOT, n)) if forwards else None
		start_forwarders(n, slot, forwards)
		done.append(n)
	return {"forwards": done}


def safe_dst(dst):
	"""Container-side destination under HOME_IN; reject absolute / traversal."""
	dst = dst.strip().lstrip("/")
	norm = os.path.normpath(dst)
	if norm.startswith("..") or norm.startswith("/") or norm == ".":
		raise ValueError(f"bad destination {dst!r}")
	return f"{HOME_IN}/{norm}"


def confined_src(src, root):
	"""HOST source, forced to resolve under `root` (blocks /, the socket, other projects)."""
	src = src.strip()
	cand = os.path.realpath(os.path.join(root, src))
	if cand != root and not cand.startswith(root + os.sep):
		raise ValueError(f"mount source {src!r} escapes the project root")
	return cand


def resolve_src(src, golden):
	"""A mounts-table source as a HOST path. Three forms, distinguished by the first character:
	    ./x   relative to the stack dir  (the same row is a literal './x' in the hub's compose override)
	    /x    an absolute host path outside the stack (e.g. Jenkins' maven repo)
	    x     relative to the golden — CONFINED to it, so a typo can't reach the socket or another
	          project. Box-side only: the hub has the real repo, not a golden."""
	src = src.strip()
	if src.startswith("./"):
		if not STACK_DIR:
			raise ValueError(f"mount source {src!r} needs STACK_DIR")
		return os.path.normpath(os.path.join(STACK_DIR, src[2:]))
	if src.startswith("/"):
		return os.path.normpath(src)
	return confined_src(src, golden)


def overlay_key(dst):
	"""Stable per-entry key for a per-box mount row, derived from its destination:
	'/home/dev/.gradle' -> 'gradle'. Names the box's upper dir (data/boxes/<box>/ovl-<key>) and its
	docker volume, and the box's private copy for a cow row (data/boxes/<box>/cow-<key>)."""
	key = dst[len(HOME_IN):].strip("/") if dst.startswith(HOME_IN) else dst.strip("/")
	key = re.sub(r"[^a-zA-Z0-9._-]", "-", key.replace("/", "-")).lstrip(".-")
	return key or "root"


def parse_mounts(golden):
	"""The `mounts` table — the ONE mount list, for the hub and for the boxes. Grammar per line:
	    CHECKOUT <dst> <rw|ro>            the box's working copy: an overlay of the CURRENT golden at
	                                      HOME_IN/<dst> (default 'repo rw'). `ro` binds the golden
	                                      itself instead — no upper layer, no writes, no git bootstrap.
	                                      Box-side by definition; the hub has the real repo.
	    <src> <dst> <hub> <box>           one path, a mode per side:
	                                        rw / ro   plain bind mount
	                                        overlay   <src> as a read-only LOWER layer with a per-box
	                                                  upper on top: shared content, private writes.
	                                                  Box side only. Only for a SEALED lower layer.
	                                        cow       a private reflinked copy of <src> for this box,
	                                                  writable, thrown away when the box is killed.
	                                                  Box side only.
	                                        cow-keep  the same copy, but kept across kill/recreate as
	                                                  the box's warm cache; re-copied only on --fresh.
	                                                  Box side only.
	                                        -         not mounted on that side
	This function reads the BOX column; gen-hub-mounts.sh renders the hub column into
	compose.override.yml. Returns (rows, checkout_dst, checkout_ro) where each row is
	(host_src, dst, mode). '#'/blank lines ignored; a missing file means just the overlay checkout."""
	rows, checkout_dst, checkout_ro = [], CHECKOUT_DST, False
	if not MOUNTS_FILE or not os.path.exists(MOUNTS_FILE):
		return rows, checkout_dst, checkout_ro
	with open(MOUNTS_FILE) as fh:
		for lineno, raw in enumerate(fh, 1):
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			parts = line.split()
			try:
				if parts[0] == "CHECKOUT":
					checkout_dst = safe_dst(parts[1]) if len(parts) > 1 else CHECKOUT_DST
					checkout_ro = len(parts) > 2 and parts[2] == "ro"
					continue
				if len(parts) < 4:
					raise ValueError("expected '<src> <dst> <hub-mode> <box-mode>'")
				src, dst, box_mode = parts[0], parts[1], parts[3]
				if box_mode == "-":
					continue
				if box_mode not in ("rw", "ro", "overlay", "cow", "cow-keep"):
					raise ValueError(f"bad box mode {box_mode!r} (rw|ro|overlay|cow|cow-keep|-)")
				rows.append((resolve_src(src, golden), safe_dst(dst), box_mode))
			except ValueError as exc:
				raise ValueError(f"{MOUNTS_FILE}:{lineno}: {exc}") from None
	return rows, checkout_dst, checkout_ro


def _overlay_volume(vol, lower, upper, work, fresh_upper=False):
	"""(Re)create an overlay volume: `lower` read-only underneath, `upper` on top.

	Docker's local driver performs the mount itself, so no capability is needed here or in the box.
	Mount options are fixed at create time, so the volume is always recreated (removing a volume does
	NOT touch upper/ — that's what lets a recreate keep whatever the box had written)."""
	if fresh_upper:
		shutil.rmtree(upper, ignore_errors=True)
		shutil.rmtree(work, ignore_errors=True)
	for d in (upper, work):
		os.makedirs(d, exist_ok=True)
		os.chown(d, int(BOX_UID), int(BOX_GID))
	subprocess.run(["docker", "volume", "rm", vol], capture_output=True, text=True)
	r = subprocess.run(
		["docker", "volume", "create", "--driver", "local",
		 "--opt", "type=overlay", "--opt", "device=overlay",
		 "--opt", f"o=lowerdir={lower},upperdir={upper},workdir={work}", vol],
		capture_output=True, text=True,
	)
	if r.returncode != 0:
		raise RuntimeError(f"creating the overlay volume {vol} failed: {r.stderr.strip()}")
	return vol


def make_overlay_volume(name, golden, fresh_upper=False):
	"""The box's checkout volume: golden as lowerdir, the box's own upperdir on top."""
	box_dir = os.path.join(BOXROOT, name)
	return _overlay_volume(box_volume(name), golden,
	                       os.path.join(box_dir, "upper"), os.path.join(box_dir, "work"), fresh_upper)


def make_shared_overlay_volume(name, lower, dst, fresh_upper=False):
	"""An `overlay` row from the mounts table: `lower` shared read-only underneath, this box's own
	upper layer on top — shared content, private writes. The upper layer SURVIVES kill/recreate (it is
	the box's warm cache) and dies with the box dir; `--fresh` discards it, the same flag with the same
	meaning as for the checkout's upper layer.

	IT USED TO SURVIVE --fresh TOO, because fresh_upper reached the checkout overlay and nothing else.
	Nothing said so — `cbx recreate --fresh` documents itself as "discard upper", and a box brought
	back for a clean start silently kept every mounts row's private writes. What --fresh promises is a
	box in the state a new spawn would give you, so it has to reach every upper layer the box owns.

	ONLY FOR A LOWER LAYER NOBODY WRITES TO. The kernel requires a lowerdir to be immutable while an
	overlay is mounted on it; if it is mutated the merged view is undefined. A golden qualifies —
	it is sealed at snapshot time and never touched again. A LIVE CACHE DOES NOT: see
	make_cow_copy() for what that cost us, and use `cow`/`cow-keep` for anything the hub keeps
	writing to."""
	box_dir = os.path.join(BOXROOT, name)
	key = overlay_key(dst)
	return _overlay_volume(f"{box_volume(name)}-{key}", lower,
	                       os.path.join(box_dir, f"ovl-{key}", "upper"),
	                       os.path.join(box_dir, f"ovl-{key}", "work"), fresh_upper)


def cow_dir(name, dst):
	"""Where a `cow`/`cow-keep` row's private copy lives: data/boxes/<box>/cow-<key>. Same naming rule
	as the overlay uppers (overlay_key), so what a box owns is predictable from the mounts table."""
	return os.path.join(BOXROOT, name, f"cow-{overlay_key(dst)}")


def make_cow_copy(name, src, dst, keep, fresh=False):
	"""A `cow` / `cow-keep` row: give this box a PRIVATE, WRITABLE, reflinked copy of `src` instead of
	an overlay on top of it. Returns the host path to bind-mount at `dst`.

	WHY, and why not an overlay. `overlay` was how toolchain caches were shared (see
	make_shared_overlay_volume — gradle takes cache locks for the whole build and hands them over only
	over localhost, so a cache shared `rw` between containers wedges forever). But the lower layer of
	such a row is the hub's LIVE cache, and the hub keeps building. overlayfs requires an immutable
	lowerdir while an overlay is mounted; the old rationale here — "a cache is content-addressed and
	written by rename, so mutating it is harmless" — is wrong for gradle's IMMUTABLE WORKSPACES.
	caches/<ver>/dependencies-accessors/<hash> (DefaultDependenciesAccessors) is rm -rf'd and renamed
	over on essentially every hub build, and once that happens under a live overlay the box can still
	list the directory but rm/mv/rmdir on it fail with EIO/ENOENT while the parent reports "Directory
	not empty". Gradle then spends ~5s per build in AssignImmutableWorkspaceStep ("Could not move
	inconsistent immutable workspace"). A private copy has no lower layer to be mutated underneath it.

	WHY REFLINK. /virtual_machines is btrfs, so `cp -a --reflink=always` shares extents: the copy is
	near-instant and costs almost no disk until one side writes. It needs no capability at all — an
	ordinary FICLONE ioctl any uid can issue — whereas the other obvious mechanism, a btrfs subvolume
	snapshot, needs root (or an unprivileged-snapshot mount option) and a subvolume to begin with.
	`--reflink=always` deliberately, never `auto`: a silent fallback to a byte copy would be a
	multi-GB copy per box across up to PORT_FORWARD_SLOTS boxes, and the point is to hear about it.

	LIFECYCLE, mirroring the overlay uppers:
	  keep=False (`cow`)       re-copied from the hub on every spawn/recreate, removed by kill_box.
	  keep=True  (`cow-keep`)  copied once, then kept across kill/recreate as the box's warm cache;
	                           only a --fresh spawn (fresh=True, same flag that discards the upper
	                           layers) throws it away and copies again.

	NOTHING FLOWS BACK. The box writes only into its own copy; the hub never sees it, and a long-lived
	`cow-keep` box drifts from the hub's cache until it is refreshed with --fresh. That was equally
	true of the overlay's upper layer. It is not a bug to be fixed by making the row `rw` — that is
	the cross-container lock deadlock, back again."""
	path = cow_dir(name, dst)
	if keep and not fresh and os.path.isdir(path):
		return path                       # the box's warm cache; only --fresh re-copies it
	staging = path + ".new"
	shutil.rmtree(staging, ignore_errors=True)
	os.makedirs(staging, exist_ok=True)
	# `src/.` so the CONTENTS land in staging (an existing dst would otherwise get src nested inside).
	r = subprocess.run(["cp", "-a", "--reflink=always", os.path.join(src, "."), staging],
	                   capture_output=True, text=True)
	if r.returncode != 0:
		shutil.rmtree(staging, ignore_errors=True)
		raise RuntimeError(
			f"reflink copy for box {name!r} failed: cp -a --reflink=always {src}/. -> {path}: "
			f"{r.stderr.strip() or r.stdout.strip()}. Most likely {src} and {os.path.dirname(path)} "
			f"are not on the same reflink-capable filesystem (btrfs/xfs with reflink), or {src} does "
			f"not exist. Not falling back to a full copy on purpose — that would copy the whole tree "
			f"once per box.")
	shutil.rmtree(path, ignore_errors=True)
	os.rename(staging, path)              # only now is the copy complete; a crash leaves .new, not path
	try:
		os.chown(path, int(BOX_UID), int(BOX_GID))
	except OSError:
		pass                              # best-effort, exactly like the golden/anchor chowns
	return path


def record_cow_dirs(name, dirs):
	"""Remember this box's DELETE-ON-KILL copies (mode `cow`). A copy is a plain directory, not a
	docker volume, so it cannot ride along in `volumes` — kill_box would try `docker volume rm` on a
	path. Rewritten on every spawn, so flipping a row cow -> cow-keep stops it being reaped."""
	with open(os.path.join(BOXROOT, name, "cow-temp"), "w") as fh:
		fh.write("".join(d + "\n" for d in dirs))


def created_cow_dirs(name):
	"""The delete-on-kill copies recorded for this box. Confined to the box's own directory: this list
	drives an rm -rf, and the file is written by us, but a path outside data/boxes/<name> is a bug we
	would rather skip than execute."""
	path = os.path.join(BOXROOT, name, "cow-temp")
	if not os.path.exists(path):
		return []
	root = os.path.join(BOXROOT, name) + os.sep
	with open(path) as fh:
		return [ln.strip() for ln in fh if ln.strip() and ln.strip().startswith(root)]


def record_volumes(name, vols):
	"""Remember which volumes were created for this box, so kill_box removes exactly those even if the
	mounts table changed in between. Box names may contain '-', so the volume prefix is ambiguous
	(box 'a' vs box 'a-b') — a listing filter would be wrong here, a record is not."""
	with open(os.path.join(BOXROOT, name, "volumes"), "w") as fh:
		fh.write("\n".join(vols) + "\n")


def created_volumes(name):
	path = os.path.join(BOXROOT, name, "volumes")
	if not os.path.exists(path):
		return [box_volume(name)]     # pre-mounts-table box: only the checkout volume existed
	with open(path) as fh:
		return [ln.strip() for ln in fh if ln.strip()]


# --------------------------------------------------------------------------- boxes

# Claude Code hooks that let the hub see whether a box is working. Each writes one line to
# $HOME/.cbx-state in the box, which is data/boxes/<name>/home on the host and /work/boxes/<name>/home
# (read-only) in the hub — so `cbx ls` / `cbx status` can read it with no daemon and no extra mount.
ACTIVITY_HOOKS = (
	("UserPromptSubmit", "busy"),     # a prompt was submitted
	("PostToolUse", "busy"),          # heartbeat: keeps 'busy' fresh through a long run
	("Notification", "waiting"),      # claude wants permission / an answer
	("Stop", "idle"),                 # turn finished
	("SessionStart", "idle"),
)


def ensure_activity_hooks():
	"""Add the activity hooks to the stack's shared ~/.claude/settings.json, idempotently.

	MERGES: existing hooks and every other setting are preserved, and an entry already present is not
	duplicated. A settings.json we can't parse is left completely alone — a broken activity readout is
	very much better than clobbering the file that also holds the login."""
	if not CLAUDE_HOME:
		return
	path = os.path.join(CLAUDE_HOME, "settings.json")
	data = {}
	if os.path.exists(path):
		try:
			with open(path) as fh:
				data = json.load(fh)
		except (ValueError, OSError) as e:  # noqa: BLE001
			print(f"box-broker: not touching {path} ({e}) — activity state will read as 'unknown'", flush=True)
			return
	if not isinstance(data, dict):
		return
	hooks = data.setdefault("hooks", {})
	if not isinstance(hooks, dict):
		return
	changed = False
	# FIRST, DROP OUR OWN STALE ENTRIES. settings.json lives in the stack's data dir and outlives every
	# image, so hooks written by a previous muster are still in it — including `cbx-activity`, the name
	# this helper had before the rename. Claude runs them, the binary is not there, and every box now
	# greets you with "SessionStart:startup hook error … cbx-activity: not found". Adding the new entry
	# does not fix that; the old one has to go.
	#
	# Narrow on purpose: only commands that are exactly a former spelling of OURS, in whichever event
	# they sit. Hooks someone else put in this file are none of our business.
	stale = {f"cbx-activity {state}" for _, state in ACTIVITY_HOOKS}
	for event, entries in list(hooks.items()):
		if not isinstance(entries, list):
			continue
		kept = []
		for grp in entries:
			if not isinstance(grp, dict):
				kept.append(grp)
				continue
			was = grp.get("hooks", [])
			inner = [h for h in was
			         if not (isinstance(h, dict) and h.get("command") in stale)]
			if len(inner) != len(was):
				changed = True
			if not inner:
				continue          # the group held nothing but the stale hook — drop the group too
			grp["hooks"] = inner
			kept.append(grp)
		hooks[event] = kept
	for event, state in ACTIVITY_HOOKS:
		cmd = f"muster-activity {state}"
		entries = hooks.setdefault(event, [])
		if not isinstance(entries, list):
			continue
		if any(h.get("command") == cmd
		       for grp in entries if isinstance(grp, dict)
		       for h in grp.get("hooks", []) if isinstance(h, dict)):
			continue
		entries.append({"hooks": [{"type": "command", "command": cmd}]})
		changed = True
	if not changed:
		return
	tmp = path + ".cbx-tmp"
	with open(tmp, "w") as fh:
		json.dump(data, fh, indent=2)
		fh.write("\n")
	os.replace(tmp, path)
	# The broker runs as root, so this hands the rewritten file back to the uid the boxes run as —
	# claude must be able to write its own settings. Best-effort on purpose: anywhere BUT the broker
	# (a test, someone running this by hand) the caller is not root and chown raises EPERM, which is
	# not a reason to fail after the file has already been written correctly.
	try:
		os.chown(path, int(BOX_UID), int(BOX_GID))
	except OSError as e:  # noqa: BLE001
		print(f"box-broker: could not chown {path} to {BOX_UID}:{BOX_GID} ({e}) — "
		      f"harmless unless boxes cannot write it", flush=True)
	print(f"box-broker: registered activity hooks in {path}", flush=True)


MEMO_START = "<!-- muster:box start -->"
MEMO_END = "<!-- muster:box end -->"


def box_memo():
	"""The text every agent should have read before deciding a service is unreachable.

	WHY IT IS SHARED AND NOT PER BOX. The port MAP is a property of the stack — which forwards exist,
	what each is for, which side of the tunnel is which. Only the numbers are per box, and those are
	already in the environment, so the memo names the VARIABLES rather than their values and is
	identical for every box. That is what makes it safe to put in the one ~/.claude every box mounts.

	Values would not be: that directory is a single host dir shared by the hub and all boxes, so a
	memo carrying real port numbers would be rewritten by whichever box spawned last and read by the
	others as if it were theirs."""
	lines = [MEMO_START,
	         "## muster box: how to reach services",
	         "",
	         "You are in an agent box: a container of your own, on the stack's docker network.",
	         "**`localhost` is this box** — not the hub, and not your reviewer's laptop. Every URL in",
	         "the shared service settings is written for a browser, so curling one from here returns",
	         "000 and means nothing about whether the service is up.",
	         "",
	         "- The hub answers to `$MUSTER_HUB_HOST` on the network. A service the HUB runs on port P",
	         "  is `http://$MUSTER_HUB_HOST:P`.",
	         "- Services YOU run bind inside this box and are published on the hub's loopback so the",
	         "  reviewer's browser can reach them; that hub-side port is not reachable from here.",
	         "",
	         "## Anything you want to keep goes in `~/keep` (`$MUSTER_KEEP`)",
	         "",
	         "It is the ONLY directory that outlives this container. Your checkout is an overlay that a",
	         "recreate replaces, and the rest of your home goes with the box — so notes to yourself,",
	         "scratch output, a fixture you downloaded, the write-up of an approach that did not work,",
	         "all belong there. **Do not commit them to your branch instead**: your branch is what your",
	         "reviewer reads, and junk in it is what review exists to catch. See the `muster-box` skill."]
	fwds = []
	try:
		fwds = parse_port_forwards()
	except (OSError, ValueError):
		pass
	if fwds:
		lines += ["", "| service | in this box | on the hub |", "|---|---|---|"]
		for fwd_name, _box_port, _hub_base in fwds:
			lines.append(f"| {fwd_name} | `$PORT_FORWARD_{fwd_name}_FROM` | "
			             f"`$PORT_FORWARD_{fwd_name}_TO_HUB` |")
		lines += ["", "Those are environment variables — read them, do not guess the numbers."]
	if PT_SERVER:
		# The hub-side column exists FOR THIS. Without it an agent reads two ports, finds one of them
		# unreachable from where it is standing, and never learns what the other one was for.
		lines += ["",
		          "### Looking at your own frontend (pinchtab)",
		          "",
		          "`pinchtab` drives a real Chrome — **on the hub, not in this box** — so you can load a",
		          "page you are serving and take screenshots. The CLI is installed here and already",
		          "pointed at that server (`$PINCHTAB_SERVER`, `$PINCHTAB_TOKEN`); `pinchtab --help`.",
		          "",
		          "Because the browser is on the hub, the URL you give it is resolved THERE. Your dev",
		          "server is published on the hub's loopback for exactly this reason, so use the hub",
		          "column above: `http://localhost:$PORT_FORWARD_<NAME>_TO_HUB`. That is the one URL",
		          "that is right for pinchtab and wrong for curl from this box — and the reverse is true",
		          "of the in-box port. Same two ports, two different consumers.",
		          "",
		          "The service has to be up on the hub (`up pinchtab` there); if it is not, ask your",
		          "reviewer rather than assuming the page is broken.",
		          "",
		          "**You have your own tab.** Every box gets its own pinchtab session at start-up and each",
		          "session owns a dedicated tab, so your navigation cannot disturb another agent's — and",
		          "theirs cannot disturb yours. `$PINCHTAB_SESSION` is already exported; if a call fails",
		          "with `401 invalid or expired agent session` (they last 24h), run",
		          "`export PINCHTAB_SESSION=\"$(muster-pinchtab-session --force-new)\"` and carry on.",
		          "",
		          "Two consequences worth knowing. Your reviewer can SEE that tab — screenshot or",
		          "accessibility tree — and can annotate it, so a message like \"e5 is the misaligned one\"",
		          "refers to YOUR refs and means exactly what it says. And your reviewer can PAUSE it while",
		          "setting a page up for you: browser calls then fail with `409 tab_paused_handoff`. That is",
		          "not a broken page and not something to work around — wait, or ask, and it will come back."]
	keys = []
	try:
		keys = [l.split("=", 1)[0] for l in parse_box_env()]
	except (OSError, ValueError):
		pass
	if keys:
		lines += ["",
		          "This project sets these for you, already correct for a box (they may differ from",
		          "the same names on the hub): " + ", ".join(f"`{k}`" for k in keys) + "."]
	lines.append(MEMO_END)
	return "\n".join(lines) + "\n"


def ensure_box_memo():
	"""Keep the memo in the shared ~/.claude/CLAUDE.md, between markers.

	Claude loads that file as memory in every session, which is the only channel an agent reads
	without being told to. Everything outside the markers is someone else's — the block is replaced
	whole, never merged, and the file is created if it does not exist."""
	if not CLAUDE_HOME:
		return
	path = os.path.join(CLAUDE_HOME, "CLAUDE.md")
	memo = box_memo()
	old = ""
	if os.path.exists(path):
		try:
			with open(path) as fh:
				old = fh.read()
		except OSError as e:  # noqa: BLE001
			print(f"box-broker: not touching {path} ({e})", flush=True)
			return
	if MEMO_START in old and MEMO_END in old:
		head, rest = old.split(MEMO_START, 1)
		_, tail = rest.split(MEMO_END, 1)
		new = head + memo.rstrip("\n") + tail
	else:
		new = (old.rstrip("\n") + "\n\n" if old.strip() else "") + memo
	if new == old:
		return
	tmp = path + ".muster-tmp"
	with open(tmp, "w") as fh:
		fh.write(new)
	os.replace(tmp, path)
	try:
		os.chown(path, int(BOX_UID), int(BOX_GID))
	except OSError:
		pass
	print(f"box-broker: refreshed the box memo in {path}", flush=True)


def transcript_path(workdir, sid):
	"""Where claude keeps this session's transcript, or "" if we cannot know.

	claude files transcripts per PROJECT DIRECTORY, named after the cwd with every '/' turned into
	'-' — /home/dev/repo becomes projects/-home-dev-repo. Every box has the same workdir, so they all
	share that directory and are told apart by the session id alone."""
	if not CLAUDE_HOME or not workdir:
		return ""
	return os.path.join(CLAUDE_HOME, "projects", workdir.replace("/", "-"), f"{sid}.jsonl")


def session_args(box_dir, resume, workdir=""):
	"""The --session-id / --resume flag for this box's claude.

	All boxes share CLAUDE_HOME, so `claude --continue` would be ambiguous across them; instead each
	box pins a stable session id, stored in its box dir. THE ID IS THE BOX'S, not the container's: a
	box that is killed and brought back up is the same box, with the same work in its upper layer and
	the same branch — an agent that has forgotten the conversation that produced them is not much use.

	Which flag depends only on whether a transcript for that id exists. --resume against an id claude
	has never seen fails at STARTUP, so the box comes up with no agent at all; that happens whenever a
	session-id file outlives its transcript — a workdir that moved (claude files transcripts per
	project directory), a cleaned CLAUDE_HOME, a box killed before claude ever wrote anything. Falling
	back to --session-id with the SAME id keeps the box's identity and simply starts a new
	conversation, which is the outcome you would want anyway."""
	session_file = os.path.join(box_dir, "session-id")
	sid = ""
	if os.path.exists(session_file):
		with open(session_file) as fh:
			sid = fh.read().strip()
	if not sid:
		sid = str(uuid.uuid4())
		with open(session_file, "w") as fh:
			fh.write(sid)
		return f"--session-id {sid}"
	if resume:
		t = transcript_path(workdir, sid)
		if t and os.path.exists(t):
			return f"--resume {sid}"
		print(f"box-broker: no transcript for session {sid} ({t or 'CLAUDE_HOME unset'}) — "
		      "starting a new conversation under the same id", flush=True)
	return f"--session-id {sid}"


def box_job(box_dir, base, merge):
	"""The box's branch job, persisted so a RECREATE reproduces it.

	`cbx minto` spawns a box whose branch is based on some other branch (base) with $DEV merged into it
	(merge) — see muster-box-init. Both are normally a no-op on recreate, because the box's upper layer
	still holds the branch and init resumes it; but a recreate --fresh discards the upper layer, and
	without these the box would silently come back based on DEV_BRANCH with no merge in progress —
	i.e. quietly the wrong thing, which is worse than failing."""
	out = {}
	for key, val in (("base", base), ("merge", merge)):
		path = os.path.join(box_dir, key + "-branch")
		if val:
			with open(path, "w") as fh:
				fh.write(val)
			out[key] = val
		elif os.path.exists(path):
			with open(path) as fh:
				out[key] = fh.read().strip()
	return out


def ensure_home_parents(anchor, dsts):
	"""Create the PARENT directories of every home-relative mount destination, owned by the box user.

	DOCKER CREATES A MISSING MOUNTPOINT — and its missing parents — AS ROOT. A one-level destination
	is harmless (docker makes /home/dev/repo and immediately covers it with the mount), but a nested
	one leaves real, root-owned, uncovered directories inside a home that must belong to uid 1000
	throughout. `.local/share/chezmoi` is the case that taught us: it left ~/.local and
	~/.local/share owned by root, and the next tool that wanted to create ~/.local/share/<its own
	dir> simply could not. Nothing warns; the tool reports a bare "Permission denied" about a path
	the mount table never mentions, days after the row that caused it was added.

	Existing directories are re-owned rather than skipped, so a box that already has the root-owned
	version is repaired by `cbx recreate` instead of needing to be purged."""
	for dst in dsts:
		# parse_mounts/safe_dst hand back ABSOLUTE container paths (/home/dev/…). Anything outside the
		# home is not the anchor's business — the checkout can be mounted elsewhere entirely.
		if not dst or not dst.startswith(HOME_IN + "/"):
			continue
		parent = os.path.dirname(dst[len(HOME_IN) + 1:])
		if not parent:
			continue                      # a top-level dst: docker's mountpoint, covered immediately
		cur = anchor
		for part in parent.split("/"):
			cur = os.path.join(cur, part)
			os.makedirs(cur, exist_ok=True)
			try:
				if os.stat(cur).st_uid != int(BOX_UID):
					os.chown(cur, int(BOX_UID), int(BOX_GID))
			except OSError:
				pass                      # best effort: a home we cannot fix is not a spawn we refuse


def create_box(name, resume=False, fresh_upper=False, base=None, merge=None):
	with _golden_lock:
		golden = current_golden()
	container = box_container(name)
	box_dir = os.path.join(BOXROOT, name)
	anchor = os.path.join(box_dir, "home")
	os.makedirs(anchor, exist_ok=True)
	os.chown(anchor, int(BOX_UID), int(BOX_GID))
	if CLAUDE_HOME:
		os.makedirs(CLAUDE_HOME, exist_ok=True)
		os.chown(CLAUDE_HOME, int(BOX_UID), int(BOX_GID))
		ensure_activity_hooks()
		ensure_box_memo()
	# Per-project port forwards: each box gets a slot, and every forward is published on the hub at
	# 127.0.0.1:(HUB_BASE_PORT + slot). The box gets PORT_FORWARDS + PORT_FORWARD_<NAME>_FROM/_TO_HUB so
	# the project's own scripts can wire e.g. MUSTER_DEV_URL and the frontend's backend URL. Running
	# out of slots refuses the spawn (alloc_slot raises).
	forwards = parse_port_forwards()
	slot = alloc_slot(box_dir) if forwards else None
	svc_env = parse_service_env()
	rows, checkout_dst, checkout_ro = parse_mounts(golden)
	# Before docker gets the chance to invent them as root — see ensure_home_parents.
	ensure_home_parents(anchor, [r[1] for r in rows] + [checkout_dst])
	claude_args = session_args(box_dir, resume, checkout_dst)
	job = box_job(box_dir, base, merge)
	# Project policy for how this box's claude comes up (MUSTER_CLAUDE_PERMISSION_MODE / MUSTER_BOX_PROMPT).
	# The mode is a flag, so it joins the claude args; the prompt travels separately, base64-encoded,
	# because it is free text going through two shells.
	mode_arg = box_mode_arg()
	if mode_arg:
		claude_args = f"{claude_args} {mode_arg}"
	prompt_b64 = box_prompt(name, {
		"MUSTER_BOX": name,
		"MUSTER_BRANCH": f"agent/{name}",
		"MUSTER_DEV_BRANCH": DEV_BRANCH,
		"MUSTER_BASE_BRANCH": job.get("base", DEV_BRANCH),
		"MUSTER_MERGE_BRANCH": job.get("merge", ""),
		"MUSTER_PROJECT": PROJECT,
		"MUSTER_WORKDIR": checkout_dst,
		"MUSTER_GOLDEN": os.path.basename(golden),
	})
	mounts, vols, cow_temp = [], [], []
	# THE ONE PLACE A BOX MAY KEEP SOMETHING. Everything else an agent writes is either in the repo
	# (reviewed, or thrown away when the branch is) or in a layer that a recreate or --fresh discards —
	# so notes, a scratch dump, a downloaded fixture, the reasoning behind an approach that did not
	# work, all had nowhere to live that would still be there tomorrow. Agents worked around it by
	# committing junk to the branch, which is exactly what review is for stopping.
	#
	# It lives in the box dir, beside the upper layers, so its lifetime is the BOX's, not the
	# container's: kill and recreate keep it, and --fresh deliberately does NOT clear it (that flag
	# means "a clean tree", not "forget what you learned"). `cbx purge` is the only thing that removes
	# it — which is already documented as the irreversible one, and already asks first.
	keep = os.path.join(box_dir, "keep")
	os.makedirs(keep, exist_ok=True)
	os.chown(keep, int(BOX_UID), int(BOX_GID))
	mounts.append(f"{keep}:{KEEP_DST}")
	# The checkout itself: an overlay volume (rw, the normal case) or the golden bind-mounted read-only.
	if checkout_ro:
		mounts.append(f"{golden}:{checkout_dst}:ro")
	else:
		vols.append(make_overlay_volume(name, golden, fresh_upper))
		mounts.append(f"{vols[-1]}:{checkout_dst}")
	with open(os.path.join(box_dir, "golden"), "w") as fh:
		fh.write(os.path.basename(golden))
	# Everything else the box sees, straight from the mounts table. Sources INSIDE the stack dir are
	# created + chowned to the box uid (they are this stack's own data dirs); sources outside it are
	# passed through untouched — this container cannot even see them, docker resolves them on the host.
	# A wrong path outside the stack is silently bound as an EMPTY DIR (docker's behaviour), so that is
	# the first thing to check when a box suddenly can't resolve dependencies.
	for src, dst, mode in rows:
		if STACK_DIR and (src == STACK_DIR or src.startswith(STACK_DIR + os.sep)):
			os.makedirs(src, exist_ok=True)
			os.chown(src, int(BOX_UID), int(BOX_GID))
		if mode == "overlay":
			vols.append(make_shared_overlay_volume(name, src, dst, fresh_upper))
			mounts.append(f"{vols[-1]}:{dst}")
		elif mode in ("cow", "cow-keep"):
			# A private reflinked copy, bind-mounted rw. `cow` is re-copied here on every spawn and
			# reaped by kill_box; `cow-keep` is the box's warm cache and only --fresh re-copies it.
			path = make_cow_copy(name, src, dst, keep=(mode == "cow-keep"), fresh=fresh_upper)
			if mode == "cow":
				cow_temp.append(path)
			mounts.append(f"{path}:{dst}")
		else:
			mounts.append(f"{src}:{dst}" + (":ro" if mode == "ro" else ""))
	record_volumes(name, vols)
	record_cow_dirs(name, cow_temp)
	env = dict(os.environ)
	env.update(
		MUSTER_HEADLESS="1",
		MUSTER_DETACH="1",
		MUSTER_IMAGE=BOX_IMAGE,
		MUSTER_USER="dev",
		MUSTER_UID=BOX_UID,
		MUSTER_GID=BOX_GID,
		MUSTER_NAME=container,
		MUSTER_NETWORK=BOX_NETWORK,
		MUSTER_SHARED=anchor,
		MUSTER_CLAUDE_DIR=CLAUDE_HOME,
		MUSTER_WORKDIR=checkout_dst,
		MUSTER_CLAUDE_ARGS=claude_args,
		MUSTER_CLAUDE_PROMPT_B64=prompt_b64,
		MUSTER_PINCHTAB_SERVER=PT_SERVER,
		MUSTER_PINCHTAB_TOKEN=pinchtab_token(),
		MUSTER_EXTRA_MOUNTS="\n".join(mounts),
		MUSTER_EXTRA_TMPFS="",
		# Project/service env (service-env), so a backend/frontend an AGENT starts is configured
		# exactly like the one the hub starts. Some entries are rewritten per box below.
		MUSTER_EXTRA_ENV="\n".join(svc_env),
		# Runs in the box's tmux window before claude: puts the box on its own agent/<name> branch,
		# based on the hub's DEV_BRANCH, with the hub as its only remote (see box-bin/muster-box-init).
		MUSTER_INIT_CMD="muster-box-init" if not checkout_ro else "",
		MUSTER_BOX="" if checkout_ro else name,
		MUSTER_HUB_GIT_URL=HUB_GIT_URL,
		MUSTER_DEV_BRANCH=DEV_BRANCH,
		# `cbx minto`: base the branch on something other than DEV_BRANCH, and (merge) leave that branch
		# merged-and-conflicted before claude starts. Doing it in the INIT command rather than as a
		# prompt is the point — a prompt is advisory and asynchronous, so "the agent never actually ran
		# the setup" would be a failure you could only find by attaching to the tmux session.
		MUSTER_BASE_BRANCH=job.get("base", ""),
		MUSTER_MERGE_BRANCH=job.get("merge", ""),
		HOME="/tmp",
	)
	forward_ports = {}
	if forwards:
		env["PORT_FORWARDS"] = ",".join(f[0] for f in forwards)
		for fwd_name, box_port, hub_base in forwards:
			hub_port = hub_base + slot
			forward_ports[fwd_name] = hub_port
			env[f"PORT_FORWARD_{fwd_name}_FROM"] = str(box_port)
			env[f"PORT_FORWARD_{fwd_name}_TO_HUB"] = str(hub_port)
	# THE PROJECT'S OWN PER-BOX ENVIRONMENT. Everything above is generic — forward names and port
	# numbers, which muster does know. What those mean to a project is box-env's business: which
	# variable its dev loop reads, what shape of URL it wants, which of the two backends is the
	# default. This file used to build FRONTEND_DEV_BACKEND_URL_OWN itself, from a variable name it had
	# no way to know the meaning of; that is now three lines in a project file.
	#
	# Appended LAST so a project can override a service-env value for boxes only — docker keeps the
	# last -e for a repeated key, and that override is the entire reason this exists.
	facts = dict(MUSTER_HUB_HOST=urllib.parse.urlsplit(HUB_GIT_URL).hostname or "hub",
	             MUSTER_BOX=name, MUSTER_BRANCH=f"agent/{name}", MUSTER_DEV_BRANCH=DEV_BRANCH,
	             MUSTER_PROJECT=PROJECT, MUSTER_WORKDIR=checkout_dst,
	             MUSTER_GOLDEN=os.path.basename(golden),
	             MUSTER_KEEP=KEEP_DST,
	             MUSTER_SLOT="" if slot is None else str(slot))
	facts["PORT_FORWARDS"] = env.get("PORT_FORWARDS", "")
	for fwd_name, hub_port in forward_ports.items():
		facts[f"PORT_FORWARD_{fwd_name}_TO_HUB"] = str(hub_port)
	for fwd_name, box_port, _ in forwards:
		facts[f"PORT_FORWARD_{fwd_name}_FROM"] = str(box_port)
	for e in svc_env:                                    # service-env values are substitutable too
		k, v = e.split("=", 1)
		facts.setdefault(k, v)
	svc_env.append(f"MUSTER_HUB_HOST={facts['MUSTER_HUB_HOST']}")
	# Named, not guessed: a script that writes here should say $MUSTER_KEEP, so the day the path moves
	# it keeps working — and so an agent reading the environment can find the durable directory at all.
	svc_env.append(f"MUSTER_KEEP={KEEP_DST}")
	svc_env.extend(expand_box_env(parse_box_env(), facts))
	env["MUSTER_EXTRA_ENV"] = "\n".join(last_wins(svc_env))
	proc = subprocess.run([MUSTER_SCRIPT], env=env, capture_output=True, text=True)
	if proc.returncode != 0:
		raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "muster-box.sh failed")
	start_forwarders(name, slot, forwards)  # after the box exists
	return {"box": name, "container": container, "workdir": checkout_dst, "session": claude_args,
	        "golden": os.path.basename(golden), "branch": f"agent/{name}",
	        "base": job.get("base", DEV_BRANCH), "merge": job.get("merge", ""),
	        "slot": slot, "forwards": forward_ports, "mounts": mounts}


def kill_box(name):
	"""Remove the box + its forwarders + every overlay volume it was given. The upper layers are
	deliberately LEFT on disk: they hold any work the agent had not pushed plus its warm caches, and
	`cbx box <same name>` reattaches to them. The one thing that does go is a `cow` row's private
	copy — that mode exists to say "this is scratch, throw it away"; `cow-keep` stays, like an upper
	layer, and is only rebuilt by a --fresh spawn."""
	stop_forwarders(name)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True, check=True)
	for vol in created_volumes(name):
		subprocess.run(["docker", "volume", "rm", vol], capture_output=True, text=True)
	for d in created_cow_dirs(name):
		shutil.rmtree(d, ignore_errors=True)
	return {"killed": name}


def list_boxes(sizes=False):
	"""The boxes, live and retired. `sizes` MEASURES the retired ones, and is off by default.

	WHY IT IS OPT-IN. dir_size walks a box directory file by file, and a retired box's upper layer is
	a checkout plus node_modules plus gradle caches plus build output — on the stack this was written
	for, 34 retired boxes came to 347,200 files, which is 2.4 SECONDS per request. This endpoint is
	what `cbx q`'s dashboard polls, twice per repaint, on a 5-second timer — and the dashboard does
	not display a size at all. `cbx ls` is the only caller that prints them, and it is typed by a
	person who can wait, so it asks for them with ?sizes=1 and everyone else stops paying."""
	out = subprocess.run(
		["docker", "ps", "-a", "--filter", f"name=^box-{PROJECT}-", "--format", "{{.Names}}\t{{.Status}}"],
		capture_output=True, text=True, check=True,
	).stdout.strip()
	rows = []
	for ln in out.splitlines():
		if not ln:
			continue
		container, status = ln.split("\t", 1)
		name = _box_name_of(container)
		gf = os.path.join(BOXROOT, name, "golden")
		rows.append({"container": container, "status": status, "box": name,
		             "golden": open(gf).read().strip() if os.path.exists(gf) else ""})
	# RETIRED BOXES: a directory with no container. `kill` leaves it on purpose — the upper layer holds
	# work that was never pushed plus warm caches, and `box <same name>` reattaches to it — but until
	# now nothing listed them, so they accumulated invisibly, holding disk and (once) port slots.
	live = {r["box"] for r in rows}
	retired = []
	if BOXROOT and os.path.isdir(BOXROOT):
		for d in sorted(os.listdir(BOXROOT)):
			if d in live or not os.path.isdir(os.path.join(BOXROOT, d)):
				continue
			gf = os.path.join(BOXROOT, d, "golden")
			# `size` is absent, not 0, when it was not asked for: a caller that prints it gets a visible
			# "null" it can fall back on, where a plausible-looking 0 would read as "this box is empty,
			# nothing to lose" about a directory holding unpushed work.
			row = {"box": d, "golden": open(gf).read().strip() if os.path.exists(gf) else ""}
			if sizes:
				row["size"] = dir_size(os.path.join(BOXROOT, d))
			retired.append(row)
	return {"boxes": rows, "retired": retired}


def dir_size(path):
	"""Bytes on disk under path, best-effort — a number you can act on when deciding what to purge."""
	total = 0
	for root, _dirs, files in os.walk(path, onerror=lambda e: None):
		for f in files:
			try:
				total += os.lstat(os.path.join(root, f)).st_size
			except OSError:
				pass
	return total


def purge_box(name):
	"""Remove a box FOR GOOD: container, overlay volumes, and the directory kill deliberately keeps.

	The one irreversible operation in this workflow, which is why the hub asks first and why nothing
	calls it implicitly. What goes with it: the upper layer (any work the agent never pushed), its
	warm caches, its session id — so `box <name>` afterwards is a genuinely new box, not a reattach."""
	stop_forwarders(name)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True)
	for vol in created_volumes(name):
		subprocess.run(["docker", "volume", "rm", vol], capture_output=True, text=True)
	box_dir = os.path.join(BOXROOT, name)
	freed = dir_size(box_dir) if os.path.isdir(box_dir) else 0
	shutil.rmtree(box_dir, ignore_errors=True)
	return {"purged": name, "freed": freed}


def box_dirty(name):
	"""`git status --porcelain` inside the box — a FIXED command, not arbitrary exec. The hub uses it
	to refuse a golden snapshot that would discard an agent's uncommitted work."""
	r = subprocess.run(
		["docker", "exec", "-u", "dev", box_container(name),
		 "git", "-C", CHECKOUT_DST, "status", "--porcelain"],
		capture_output=True, text=True,
	)
	if r.returncode != 0:
		return {"box": name, "reachable": False, "dirty": [], "error": r.stderr.strip()}
	files = [ln for ln in r.stdout.splitlines() if ln.strip()]
	return {"box": name, "reachable": True, "dirty": files}


BOX_TMUX_SESSION = "main"
# muster-box.sh creates the session as `new-session -d -s main -n claude`, so claude's window has a
# NAME — and a name is the only stable way to find it again.
BOX_TMUX_WINDOW = "claude"


def box_target(container):
	"""The tmux pane claude is in — resolved, never assumed.

	EVERY MESSAGE USED TO GO TO `-t main`, WHICH IS THE SESSION. tmux resolves a session-only target
	to whichever window is CURRENT and whichever pane is active in it. So the moment you attach to a
	box and open a second window — or an agent splits one to watch a build — the next `fix`, `rebase`
	or post-merge instruction is typed into that shell instead of into claude. It goes somewhere; it
	simply never arrives, and nothing reports a failure, because the send itself succeeded.

	So ask tmux for the pane id (%N) of claude's named window. A pane id is unambiguous and immune to
	base-index settings, which `main:claude.0` is not. Falling back through the window name to the
	bare session keeps boxes started before that window was named working — badly targeted, but no
	worse than they are now."""
	for target in (f"{BOX_TMUX_SESSION}:{BOX_TMUX_WINDOW}", BOX_TMUX_SESSION):
		r = subprocess.run(["docker", "exec", "-u", "dev", container,
		                    "tmux", "list-panes", "-t", target, "-F", "#{pane_id}"],
		                   capture_output=True, text=True)
		if r.returncode == 0 and r.stdout.strip():
			return r.stdout.split()[0]
	return BOX_TMUX_SESSION


def box_say(name, text):
	"""Type a line into the box's claude session (tmux send-keys). This is how `cbx fix` delivers
	review feedback without you attaching. -l sends the text LITERALLY, so tmux never interprets a
	word like 'Enter' or 'C-c' inside your message as a key."""
	c = box_container(name)
	t = box_target(c)
	r = subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", t, "-l", text],
	                   capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "send-keys failed")
	subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", t, "Enter"],
	               capture_output=True, text=True)
	return {"box": name, "sent": text}


def box_paste(name, text):
	"""Deliver a MULTI-LINE message into the box's claude session as a single prompt. Also a FIXED
	command pair, like /say — the payload is data, never a shell.

	send-keys (box_say) cannot do this: claude submits the prompt on every newline it receives, so an
	N-line review would arrive as N separate half-prompts, each acted on before the next lands. The
	fix is the same one your terminal uses for a real paste — bracketed paste: `load-buffer` puts the
	text in a tmux buffer, `paste-buffer -p` wraps it in the ESC[200~ / ESC[201~ markers that tell
	claude "this is pasted text, not typing", and the whole block goes into the composer intact. The
	Enter afterwards is then the only thing that submits it.

	-b cbx names the buffer (so a paste never disturbs your own tmux buffer stack) and -d drops it
	once pasted. Trailing newlines are stripped: they would land as blank lines before the submit.

	-p only emits the markers when the pane's application has ENABLED bracketed paste (DECSET 2004),
	which claude does. If some other program is in the window it degrades to a plain paste — i.e. to
	exactly what /say does today — so this is never worse than the alternative."""
	c = box_container(name)
	# Resolved ONCE: the paste and the Enter that submits it must land in the same pane, and a window
	# switch between the two calls would otherwise split a prompt from its submit.
	t = box_target(c)
	r = subprocess.run(["docker", "exec", "-i", "-u", "dev", c,
	                    "tmux", "load-buffer", "-b", "cbx", "-"],
	                   input=text.rstrip("\n"), capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "load-buffer failed")
	r = subprocess.run(["docker", "exec", "-u", "dev", c,
	                    "tmux", "paste-buffer", "-d", "-p", "-b", "cbx", "-t", t],
	                   capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "paste-buffer failed")
	subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", t, "Enter"],
	               capture_output=True, text=True)
	return {"box": name, "pasted": len(text)}


def pull_box_image(wait=False):
	"""Pull BOX_IMAGE so spawns use a recent image. Best-effort + coalesced: a bare local tag is
	skipped and failures are logged (not raised). wait=False (spawns) skips if a pull is already in
	flight; wait=True (recreate) blocks for it then pulls, so the new box gets the newest image."""
	if "/" not in BOX_IMAGE:
		return  # bare local tag (e.g. build.sh's 'muster') — nothing to pull
	if not _pull_lock.acquire(blocking=wait):
		return  # a pull is already running (and we're not waiting)
	try:
		r = subprocess.run(["docker", "pull", BOX_IMAGE], capture_output=True, text=True)
		if r.returncode == 0:
			print(f"box-broker: refreshed {BOX_IMAGE}", flush=True)
		else:
			print(f"box-broker: pull of {BOX_IMAGE} failed: {r.stderr.strip()}", flush=True)
	finally:
		_pull_lock.release()


def pull_box_image_async():
	"""Run pull_box_image() in a daemon thread so it never blocks a spawn response or startup."""
	threading.Thread(target=pull_box_image, daemon=True).start()


def _box_name_of(container):
	prefix = f"box-{PROJECT}-"
	return container[len(prefix):] if container.startswith(prefix) else container


def box_state(name):
	"""docker's state for this box's container ('running', 'exited', …), or '' when there is none."""
	r = subprocess.run(["docker", "inspect", "-f", "{{.State.Status}}", box_container(name)],
	                   capture_output=True, text=True)
	return r.stdout.strip() if r.returncode == 0 else ""


def existing_box(name):
	"""The spawn response for a box that is ALREADY UP — same shape as create_box's, so the hub can
	treat both the same and just attach.

	Spawning over a live box used to surface docker's name conflict verbatim ("the container name
	/box-<project>-<box> is already in use"), which reads like a broken stack and isn't: `muster box
	<name>` on a box you already have is the ordinary way of saying "put me back in it". The
	container's own labels are not consulted — everything here is state the broker persisted when it
	created the box, which is also what survives a broker restart."""
	box_dir = os.path.join(BOXROOT, name)
	gf = os.path.join(box_dir, "golden")
	slot = _slot_of(name)
	forwards = {f[0]: f[2] + slot for f in parse_port_forwards()} if slot is not None else {}
	job = box_job(box_dir, None, None)
	return {"box": name, "container": box_container(name), "existing": True,
	        "workdir": CHECKOUT_DST, "branch": f"agent/{name}",
	        "golden": open(gf).read().strip() if os.path.exists(gf) else "",
	        "base": job.get("base", DEV_BRANCH), "merge": job.get("merge", ""),
	        "slot": slot, "forwards": forwards}


def recreate_box(name, fresh_upper=False):
	"""Pull the newest image, drop the old container, and respawn the box resuming ITS session — now on
	whatever golden is current. fresh_upper=True also discards the box's upper layer, which is what
	moves it cleanly onto a new golden (only safe once its work is pushed; `cbx golden snapshot` checks)."""
	pull_box_image(wait=True)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True)
	return create_box(name, resume=True, fresh_upper=fresh_upper)


def recreate_all(fresh_upper=False):
	"""Recreate every box (newest image, each resuming its own session). Pulls once for all."""
	pull_box_image(wait=True)
	done = []
	for r in list_boxes()["boxes"]:
		name = r["box"]
		subprocess.run(["docker", "rm", "-f", r["container"]], capture_output=True, text=True)
		done.append(create_box(name, resume=True, fresh_upper=fresh_upper)["box"])
	return {"recreated": done}


class Handler(BaseHTTPRequestHandler):
	def _reply(self, code, obj):
		body = json.dumps(obj).encode()
		self.send_response(code)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def _authed(self):
		if not TOKEN or self.headers.get("X-Broker-Token") != TOKEN:
			self._reply(403, {"error": "forbidden"})
			return False
		return True

	def _body(self):
		n = int(self.headers.get("Content-Length") or 0)
		return self.rfile.read(n).decode() if n else ""

	def _flag(self, name):
		return name in (self.path.split("?", 1)[1] if "?" in self.path else "")

	def _param(self, name):
		"""A query parameter's value, or None. (_flag only answers "is this word present".)"""
		q = self.path.split("?", 1)[1] if "?" in self.path else ""
		vals = urllib.parse.parse_qs(q).get(name) or []
		return vals[0] if vals else None

	def _path(self):
		return self.path.split("?", 1)[0].rstrip("/")

	def do_GET(self):
		if not self._authed():
			return
		path = self._path()
		try:
			if path == "/version":
				return self._reply(200, {"broker": MUSTER_VERSION,
				                         "box_image": box_image_version(),
				                         "box_image_ref": BOX_IMAGE})
			if path == "/box":
				# ?sizes=1 measures the retired boxes' disk (seconds — see list_boxes). `cbx ls` asks;
				# the dashboard, which polls this, does not.
				return self._reply(200, list_boxes(sizes=self._flag("sizes")))
			if path == "/golden":
				return self._reply(200, list_goldens())
			if path.startswith("/box/") and path.endswith("/dirty"):
				name = path[len("/box/"):-len("/dirty")]
				if not NAME_RE.match(name):
					return self._reply(400, {"error": "bad box name"})
				return self._reply(200, box_dirty(name))
			return self._reply(404, {"error": "not found"})
		except Exception as e:  # noqa: BLE001
			return self._reply(500, {"error": str(e)})

	def do_POST(self):
		if not self._authed():
			return
		path = self._path()
		fresh = self._flag("fresh")
		try:
			# Golden lifecycle. The hub prepares in GOLDEN_STAGING (its only writable golden path) and
			# calls seal; reap drops goldens no box still references.
			if path.startswith("/golden/seal/"):
				return self._reply(200, seal_golden(path[len("/golden/seal/"):]))
			if path == "/golden/reap":
				return self._reply(200, reap_goldens())
			# Re-establish the hub-netns socat forwarders (they die with the hub container).
			if path == "/forwards":
				return self._reply(200, refresh_forwarders())
			if path.startswith("/forwards/"):
				fname = path[len("/forwards/"):]
				if not NAME_RE.match(fname):
					return self._reply(400, {"error": "bad box name"})
				return self._reply(200, refresh_forwarders(fname))
			# Recreate (newest image + respawn resuming each box's session). /recreate = every box.
			if path == "/recreate":
				return self._reply(200, recreate_all(fresh_upper=fresh))
			if path.startswith("/recreate/"):
				rname = path[len("/recreate/"):]
				if not NAME_RE.match(rname):
					return self._reply(400, {"error": "bad box name"})
				return self._reply(200, recreate_box(rname, fresh_upper=fresh))
			# Deliver review feedback into a box's claude session.
			if path.startswith("/box/") and path.endswith("/say"):
				name = path[len("/box/"):-len("/say")]
				if not NAME_RE.match(name):
					return self._reply(400, {"error": "bad box name"})
				text = self._body()
				if not text.strip():
					return self._reply(400, {"error": "empty message"})
				return self._reply(200, box_say(name, text))
			# Same, but as a bracketed paste — for MULTI-LINE feedback (a tuicr review), which
			# send-keys would split into one prompt per line.
			if path.startswith("/box/") and path.endswith("/paste"):
				name = path[len("/box/"):-len("/paste")]
				if not NAME_RE.match(name):
					return self._reply(400, {"error": "bad box name"})
				text = self._body()
				if not text.strip():
					return self._reply(400, {"error": "empty message"})
				return self._reply(200, box_paste(name, text))
			# Default: spawn a fresh box.
			if not path.startswith("/box/"):
				return self._reply(404, {"error": "not found"})
			name = path[len("/box/"):]
			if not NAME_RE.match(name):
				return self._reply(400, {"error": "bad box name"})
			# ?base=<branch>&merge=<branch> — `cbx minto`: start this box on <base> with <merge>
			# merged in and conflicted, instead of a fresh branch off DEV_BRANCH.
			base, merge = self._param("base"), self._param("merge")
			for b in (base, merge):
				if b is not None and not valid_branch(b):
					return self._reply(400, {"error": f"bad branch name: {b!r}"})
			# ALREADY THERE? Then this is a reattach, not a spawn (200, not 201) — see existing_box.
			# A container that exists but is NOT running is recreated rather than `docker start`ed: a start
			# re-runs the command frozen into it at creation, whose claude args may be `--session-id <id>`
			# for a session that by now exists — i.e. a box that comes back up with claude refusing to
			# start. recreate_box recomputes them with resume=True, keeps the upper layer, and rebuilds the
			# forwarders that died with the container.
			state = box_state(name)
			if state:
				# ...unless a branch job was asked for. `muster minto` means "start this box on <base> with
				# <merge> merged in and conflicted", and an existing box is on neither; attaching would hand
				# back a box that looks right and has had none of the setup.
				if base or merge:
					return self._reply(409, {"error": f"box '{name}' already exists — kill it first "
					                                  f"('muster kill {name}') or use another name"})
				if state == "running":
					return self._reply(200, existing_box(name))
				result = recreate_box(name)
				result["existing"] = True
				result["restarted"] = True
				return self._reply(200, result)
			# resume=True even though this is the "spawn" route: it is also the route that brings a
			# KILLED box back (`muster box <name>` on a name that still has its directory), and that
			# box's agent should pick up its own conversation. For a genuinely new box there is no
			# session-id file yet, so session_args creates one and this is a fresh session either way.
			result = create_box(name, resume=True, base=base, merge=merge)
		except Exception as e:  # noqa: BLE001
			return self._reply(500, {"error": str(e)})
		self._reply(201, result)
		# Refresh the image in the background for the NEXT spawn — AFTER replying, so this spawn's
		# response isn't delayed by the pull (this spawn already used the current cached image).
		pull_box_image_async()

	def do_DELETE(self):
		if not self._authed():
			return
		path = self._path()
		# /box/<name>        kill: container goes, the directory stays (reattachable)
		# /box/<name>/purge  purge: the directory goes too, permanently
		purge = path.endswith("/purge")
		name = path[len("/box/"):-len("/purge")] if purge else path[len("/box/"):]
		if not NAME_RE.match(name):
			return self._reply(400, {"error": "bad box name"})
		try:
			self._reply(200, purge_box(name) if purge else kill_box(name))
		except Exception as e:  # noqa: BLE001
			self._reply(500, {"error": str(e)})

	def log_message(self, fmt, *args):  # quieter logs
		return


def main():
	if not TOKEN:
		raise SystemExit("box-broker: BROKER_TOKEN is required")
	# Warm the image cache at startup so the first spawn doesn't pay the pull cost.
	pull_box_image_async()
	ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
	main()
