#!/usr/bin/env python3
"""box-broker — the only container with the docker socket.

It is "claude-box.sh as a service": the hub asks it (over the internal compose network, gated by
a shared token) to create/kill/list agent boxes, and the broker runs the modified claude-box.sh
with a VETTED environment. The hub can influence only the box name and the curated mount list;
image, uid, network, privileges and the socket are the broker's. Every curated mount source is
resolved and confined under the project root, so a compromised hub can expose project files to a
box but can never mount host paths or gain privilege.

THE CHECKOUT IS AN OVERLAY. One prepared "golden" tree (cloned, deps installed, caches warm) is
shared read-only by every box as an overlayfs lowerdir; each box writes into its own upperdir, so
N agents cost N x (their own diff) instead of N full checkouts. The mount is performed by DOCKER
(a local-driver volume with type=overlay), so neither this broker nor the box needs CAP_SYS_ADMIN.
Each box therefore gets a REAL .git and works on its own branch (agent/<box>), pushing to the hub;
the hub reviews and merges. See hub/cbx and README-remote.md.

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
  BOX_IMAGE           the claude-box image (default: claude-box)
  BOX_NETWORK         docker network the box joins (e.g. cbx-<project>)
  GOLDEN_DIR          HOST path holding the sealed goldens + the `current` symlink
  GOLDEN_STAGING      HOST path the hub prepares new goldens in (sealed via /golden/seal)
  PROJECT_ROOT        confinement root for box-mounts extras (default: the current golden)
  CHECKOUT_DST        where the overlay is mounted in the box (default /home/dev/repo — must match the hub)
  NPM_CACHE/GRADLE_CACHE  HOST paths shared rw with the hub at ~/.npm and ~/.gradle
  M2_REPO             HOST path of the Maven repository, mounted READ-ONLY at ~/.m2/repository
  CLAUDE_HOME         HOST path of the shared ~/.claude (mounted into every box)
  BOXROOT             HOST path whose <name>/{home,upper,work} subdirs back each box
  BOX_MOUNTS          HOST path of the box-mounts manifest (EXTRA mounts only; see box-mounts.example)
  DEV_BRANCH          branch agents base their work on (default: dev)
  HUB_GIT_URL         the hub repo as the boxes reach it (default: git://hub/repo)
  PINCHTAB_SERVER     e.g. http://hub:9867     PINCHTAB_TOKEN  the pinchtab token
  PORT_FORWARDS_FILE  HOST path of the port-forwards manifest (NAME BOX_PORT HUB_BASE_PORT per line)
  PORT_FORWARD_SLOTS  max concurrent boxes with forwards; each box's slot N -> hub port BASE+N (dflt 16)
  BOX_UID/BOX_GID     synthetic non-root identity inside the box (default 1000/1000)
  CLAUDEBOX_SCRIPT    path to claude-box.sh (default /usr/local/bin/claude-box.sh)
"""
import json
import os
import re
import shutil
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BROKER_TOKEN", "")
PORT = int(os.environ.get("BROKER_PORT", "8099"))
PROJECT = os.environ.get("PROJECT_NAME", "project")
BOX_IMAGE = os.environ.get("BOX_IMAGE", "claude-box")
BOX_NETWORK = os.environ.get("BOX_NETWORK", "")
GOLDEN_DIR = os.environ.get("GOLDEN_DIR", "")
GOLDEN_STAGING = os.environ.get("GOLDEN_STAGING", "")
# Where the overlay lands in the box. MUST equal the hub's own repo path: goldens are snapshots of
# that tree, and installed dependencies bake absolute paths in, so they only stay valid if the tree
# is mounted back where it was prepared.
CHECKOUT_DST = os.environ.get("CHECKOUT_DST", "/home/dev/repo")
CLAUDE_HOME = os.environ.get("CLAUDE_HOME", "")
# Shared package caches mounted (rw) into every box AND the hub at ~/.npm and ~/.gradle, so node/gradle
# artifacts are downloaded once, not duplicated per box. uid 1000 (dev) owns them; npm + gradle both
# handle concurrent access to a shared cache via their own file locks.
NPM_CACHE = os.environ.get("NPM_CACHE", "")
GRADLE_CACHE = os.environ.get("GRADLE_CACHE", "")
# Jenkins' pre-populated Maven repository, mounted READ-ONLY at ~/.m2/repository in every box — the
# same mount the hub gets, so a box resolves dependencies from the shared cache instead of
# re-downloading them. Unlike the caches above this lives OUTSIDE the stack dir and is therefore not
# visible from this container, so it is never created or chowned here: docker resolves the host path
# itself. A wrong path is silently bound as an empty directory (docker's behaviour), so if a box
# suddenly can't resolve deps, check this value first.
M2_REPO = os.environ.get("M2_REPO", "")
BOXROOT = os.environ.get("BOXROOT", "")
BOX_MOUNTS = os.environ.get("BOX_MOUNTS", "")
DEV_BRANCH = os.environ.get("DEV_BRANCH", "dev")
HUB_GIT_URL = os.environ.get("HUB_GIT_URL", "git://hub/repo")
PT_SERVER = os.environ.get("PINCHTAB_SERVER", "")
PT_TOKEN = os.environ.get("PINCHTAB_TOKEN", "")
# Per-project port forwards (like box-mounts). File grammar: 'NAME BOX_PORT HUB_BASE_PORT' per line;
# each box gets a slot N and every forward is published on the hub at 127.0.0.1:(HUB_BASE_PORT + N).
PORT_FORWARDS_FILE = os.environ.get("PORT_FORWARDS_FILE", "")
PORT_FORWARD_SLOTS = int(os.environ.get("PORT_FORWARD_SLOTS", "16"))
# Project/service env (KEY=VALUE lines) handed to every box — backend/frontend settings an agent needs
# when it runs those services itself. The SAME file is given to the hub via `env_file:` in compose, so
# a service behaves identically whether the hub or a box runs it.
SERVICE_ENV_FILE = os.environ.get("SERVICE_ENV_FILE", "")
BOX_UID = os.environ.get("BOX_UID", "1000")
BOX_GID = os.environ.get("BOX_GID", "1000")
CLAUDEBOX_SCRIPT = os.environ.get("CLAUDEBOX_SCRIPT", "/usr/local/bin/claude-box.sh")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
GOLDEN_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
HOME_IN = "/home/dev"

# Serializes the background `docker pull` of BOX_IMAGE so concurrent spawns don't each start one.
_pull_lock = threading.Lock()
# Serializes golden seal/reap against spawns, so a box can never be created against a golden that is
# being moved or deleted underneath it.
_golden_lock = threading.RLock()


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
	"""Per-project forwards from PORT_FORWARDS_FILE (like box-mounts). One line each:
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
	when handed to claude-box.sh)."""
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


def alloc_slot(box_dir):
	"""Stable per-box slot index (0..PORT_FORWARD_SLOTS-1), persisted so a recreate keeps the same hub
	ports. Raises when every slot is taken (refuse to spawn — we're out of forward ports)."""
	sf = os.path.join(box_dir, "slot")
	if os.path.exists(sf):
		try:
			return int(open(sf).read().strip())
		except ValueError:
			pass
	used = set()
	if BOXROOT and os.path.isdir(BOXROOT):
		for d in os.listdir(BOXROOT):
			f = os.path.join(BOXROOT, d, "slot")
			if os.path.exists(f):
				try:
					used.add(int(open(f).read().strip()))
				except ValueError:
					pass
	for slot in range(PORT_FORWARD_SLOTS):
		if slot not in used:
			with open(sf, "w") as fh:
				fh.write(str(slot))
			return slot
	raise RuntimeError(f"out of port-forward slots (max {PORT_FORWARD_SLOTS} concurrent boxes) — kill a box first")


def start_forwarders(name, slot, forwards):
	"""One socat per forward, in the HUB's netns, mapping hub 127.0.0.1:(base+slot) -> box:box_port. So
	the hub browser (and anything on the hub) reaches each box service as http://localhost:<hub_port> —
	allowlisted by default, Host stays localhost. socat runs FROM the box image (--entrypoint socat) in
	the hub's netns (--network container:<hub>), so bind=127.0.0.1 is the hub loopback and the box name
	resolves via the hub's cbx-network DNS."""
	if not forwards:
		return
	hub = hub_container()
	if not hub:
		print(f"box-broker: no hub container found — skipping port-forwards for {name}", flush=True)
		return
	for fwd_name, box_port, hub_base in forwards:
		hub_port = hub_base + slot
		c = pf_container(name, fwd_name)
		subprocess.run(["docker", "rm", "-f", c], capture_output=True, text=True)
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


def parse_manifest(golden):
	"""EXTRA mounts from box-mounts, on top of the overlay checkout. Grammar per line:
	    TREE <dst> <ro|rw>     where the overlay checkout lands (default: repo rw). `ro` mounts the
	                           golden directly read-only instead of an overlay (no upper, no writes).
	    <src> <dst> <ro|rw>    golden/<src> bind-mounted at HOME_IN/<dst>
	Returns (mounts, checkout_dst, checkout_ro). '#'/blank lines ignored; a missing file means just the
	overlay checkout at CHECKOUT_DST."""
	mounts, checkout_dst, checkout_ro = [], CHECKOUT_DST, False
	if not BOX_MOUNTS or not os.path.exists(BOX_MOUNTS):
		return mounts, checkout_dst, checkout_ro
	with open(BOX_MOUNTS) as fh:
		for raw in fh:
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			parts = line.split()
			if parts[0] == "TREE":
				checkout_dst = safe_dst(parts[1]) if len(parts) > 1 else CHECKOUT_DST
				checkout_ro = len(parts) > 2 and parts[2] == "ro"
			else:
				src, dst = parts[0], (parts[1] if len(parts) > 1 else parts[0])
				mode = parts[2] if len(parts) > 2 else "rw"
				suffix = ":ro" if mode == "ro" else ""
				mounts.append(f"{confined_src(src, golden)}:{safe_dst(dst)}{suffix}")
	return mounts, checkout_dst, checkout_ro


def make_overlay_volume(name, golden, fresh_upper=False):
	"""(Re)create the box's checkout volume: golden as lowerdir, the box's own upperdir on top.

	Docker's local driver performs the mount itself, so no capability is needed here or in the box.
	Mount options are fixed at create time, so the volume is always recreated (removing a volume does
	NOT touch upper/ — that's what lets a recreate keep the agent's uncommitted work)."""
	vol = box_volume(name)
	box_dir = os.path.join(BOXROOT, name)
	upper, work = os.path.join(box_dir, "upper"), os.path.join(box_dir, "work")
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
		 "--opt", f"o=lowerdir={golden},upperdir={upper},workdir={work}", vol],
		capture_output=True, text=True,
	)
	if r.returncode != 0:
		raise RuntimeError(f"creating the overlay volume failed: {r.stderr.strip()}")
	return vol


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
	for event, state in ACTIVITY_HOOKS:
		cmd = f"cbx-activity {state}"
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
	os.chown(path, int(BOX_UID), int(BOX_GID))
	print(f"box-broker: registered activity hooks in {path}", flush=True)


def session_args(box_dir, resume):
	"""The --session-id / --resume flag for this box's claude.

	All boxes share CLAUDE_HOME, so `claude --continue` would be ambiguous across them; instead each
	box pins a stable session id (stored in its box dir). A fresh spawn passes --session-id (recording
	it); a recreate passes --resume, so the box picks up exactly where it left off.

	Note claude stores transcripts per project directory, so moving a box's workdir orphans its
	session and --resume then fails at startup. Recovering means moving the .jsonl under
	CLAUDE_HOME/projects/ to the new directory name (or clearing this box's session-id file)."""
	session_file = os.path.join(box_dir, "session-id")
	if resume and os.path.exists(session_file):
		with open(session_file) as fh:
			sid = fh.read().strip()
		if sid:
			return f"--resume {sid}"
	sid = str(uuid.uuid4())
	with open(session_file, "w") as fh:
		fh.write(sid)
	return f"--session-id {sid}"


def create_box(name, resume=False, fresh_upper=False):
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
	# Per-project port forwards: each box gets a slot, and every forward is published on the hub at
	# 127.0.0.1:(HUB_BASE_PORT + slot). The box gets PORT_FORWARDS + PORT_FORWARD_<NAME>_FROM/_TO_HUB so
	# the project's own scripts can wire e.g. CLAUDEBOX_DEV_URL and the frontend's backend URL. Running
	# out of slots refuses the spawn (alloc_slot raises).
	forwards = parse_port_forwards()
	slot = alloc_slot(box_dir) if forwards else None
	mounts, checkout_dst, checkout_ro = parse_manifest(golden)
	claude_args = session_args(box_dir, resume)
	# The checkout itself: an overlay volume (rw, the normal case) or the golden bind-mounted read-only.
	if checkout_ro:
		mounts.insert(0, f"{golden}:{checkout_dst}:ro")
	else:
		mounts.insert(0, f"{make_overlay_volume(name, golden, fresh_upper)}:{checkout_dst}")
	with open(os.path.join(box_dir, "golden"), "w") as fh:
		fh.write(os.path.basename(golden))
	# Shared package caches (rw) at ~/.npm and ~/.gradle — one copy across the hub + all boxes, so
	# node/gradle don't re-download per box. The dirs are created + chowned to the box uid here.
	for cache_host, cache_dst in ((NPM_CACHE, f"{HOME_IN}/.npm"), (GRADLE_CACHE, f"{HOME_IN}/.gradle")):
		if cache_host:
			os.makedirs(cache_host, exist_ok=True)
			os.chown(cache_host, int(BOX_UID), int(BOX_GID))
			mounts.append(f"{cache_host}:{cache_dst}")
	# Maven repo: read-only, and NOT created/chowned — see M2_REPO above.
	if M2_REPO:
		mounts.append(f"{M2_REPO}:{HOME_IN}/.m2/repository:ro")
	env = dict(os.environ)
	env.update(
		CLAUDEBOX_HEADLESS="1",
		CLAUDEBOX_DETACH="1",
		CLAUDEBOX_IMAGE=BOX_IMAGE,
		CLAUDEBOX_USER="dev",
		CLAUDEBOX_UID=BOX_UID,
		CLAUDEBOX_GID=BOX_GID,
		CLAUDEBOX_NAME=container,
		CLAUDEBOX_NETWORK=BOX_NETWORK,
		CLAUDEBOX_SHARED=anchor,
		CLAUDEBOX_CLAUDE_DIR=CLAUDE_HOME,
		CLAUDEBOX_WORKDIR=checkout_dst,
		CLAUDEBOX_CLAUDE_ARGS=claude_args,
		CLAUDEBOX_PINCHTAB_SERVER=PT_SERVER,
		CLAUDEBOX_PINCHTAB_TOKEN=PT_TOKEN,
		CLAUDEBOX_EXTRA_MOUNTS="\n".join(mounts),
		CLAUDEBOX_EXTRA_TMPFS="",
		# Project/service env (service-env), so a backend/frontend an AGENT starts is configured
		# exactly like the one the hub starts.
		CLAUDEBOX_EXTRA_ENV="\n".join(parse_service_env()),
		# Runs in the box's tmux window before claude: puts the box on its own agent/<name> branch,
		# based on the hub's DEV_BRANCH, with the hub as its only remote (see box-bin/cbx-box-init).
		CLAUDEBOX_INIT_CMD="cbx-box-init" if not checkout_ro else "",
		CBX_BOX="" if checkout_ro else name,
		CBX_HUB_GIT_URL=HUB_GIT_URL,
		CBX_DEV_BRANCH=DEV_BRANCH,
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
	proc = subprocess.run([CLAUDEBOX_SCRIPT], env=env, capture_output=True, text=True)
	if proc.returncode != 0:
		raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "claude-box.sh failed")
	start_forwarders(name, slot, forwards)  # after the box exists
	return {"box": name, "container": container, "workdir": checkout_dst, "session": claude_args,
	        "golden": os.path.basename(golden), "branch": f"agent/{name}",
	        "slot": slot, "forwards": forward_ports, "mounts": mounts}


def kill_box(name):
	"""Remove the box + its forwarders + its overlay volume. upper/ is deliberately LEFT on disk: it
	holds any work the agent had not pushed, and `cbx box <same name>` reattaches to it."""
	stop_forwarders(name)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True, check=True)
	subprocess.run(["docker", "volume", "rm", box_volume(name)], capture_output=True, text=True)
	return {"killed": name}


def list_boxes():
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
	return {"boxes": rows}


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


def box_say(name, text):
	"""Type a line into the box's claude session (tmux send-keys). This is how `cbx fix` delivers
	review feedback without you attaching. -l sends the text LITERALLY, so tmux never interprets a
	word like 'Enter' or 'C-c' inside your message as a key."""
	c = box_container(name)
	r = subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", "main", "-l", text],
	                   capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "send-keys failed")
	subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", "main", "Enter"],
	               capture_output=True, text=True)
	return {"box": name, "sent": text}


def pull_box_image(wait=False):
	"""Pull BOX_IMAGE so spawns use a recent image. Best-effort + coalesced: a bare local tag is
	skipped and failures are logged (not raised). wait=False (spawns) skips if a pull is already in
	flight; wait=True (recreate) blocks for it then pulls, so the new box gets the newest image."""
	if "/" not in BOX_IMAGE:
		return  # bare local tag (e.g. build.sh's 'claude-box') — nothing to pull
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

	def _path(self):
		return self.path.split("?", 1)[0].rstrip("/")

	def do_GET(self):
		if not self._authed():
			return
		path = self._path()
		try:
			if path == "/box":
				return self._reply(200, list_boxes())
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
			# Default: spawn a fresh box.
			if not path.startswith("/box/"):
				return self._reply(404, {"error": "not found"})
			name = path[len("/box/"):]
			if not NAME_RE.match(name):
				return self._reply(400, {"error": "bad box name"})
			result = create_box(name)
		except Exception as e:  # noqa: BLE001
			return self._reply(500, {"error": str(e)})
		self._reply(201, result)
		# Refresh the image in the background for the NEXT spawn — AFTER replying, so this spawn's
		# response isn't delayed by the pull (this spawn already used the current cached image).
		pull_box_image_async()

	def do_DELETE(self):
		if not self._authed():
			return
		name = self._path()[len("/box/"):]
		if not NAME_RE.match(name):
			return self._reply(400, {"error": "bad box name"})
		try:
			self._reply(200, kill_box(name))
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
