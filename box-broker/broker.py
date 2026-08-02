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
  BOX_UID/BOX_GID     synthetic non-root identity inside the box (default 1000/1000)
  MUSTER_SCRIPT    path to muster-box.sh (default /usr/local/bin/muster-box.sh)
"""
import json
import os
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
# Per-project port forwards (like `mounts`). File grammar: 'NAME BOX_PORT HUB_BASE_PORT' per line;
# each box gets a slot N and every forward is published on the hub at 127.0.0.1:(HUB_BASE_PORT + N).
PORT_FORWARDS_FILE = os.environ.get("PORT_FORWARDS_FILE", "")
PORT_FORWARD_SLOTS = int(os.environ.get("PORT_FORWARD_SLOTS", "16"))
# Project/service env (KEY=VALUE lines) handed to every box — backend/frontend settings an agent needs
# when it runs those services itself. The SAME file is given to the hub via `env_file:` in compose, so
# a service behaves identically whether the hub or a box runs it.
SERVICE_ENV_FILE = os.environ.get("SERVICE_ENV_FILE", "")
BOX_UID = os.environ.get("BOX_UID", "1000")
BOX_GID = os.environ.get("BOX_GID", "1000")
MUSTER_SCRIPT = os.environ.get("MUSTER_SCRIPT", "/usr/local/bin/muster-box.sh")

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
	"""Stable per-entry key for an overlay row, derived from its destination: '/home/dev/.gradle' ->
	'gradle'. Names the box's upper dir (data/boxes/<box>/ovl-<key>) and its docker volume."""
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
				if box_mode not in ("rw", "ro", "overlay"):
					raise ValueError(f"bad box mode {box_mode!r} (rw|ro|overlay|-)")
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


def make_shared_overlay_volume(name, lower, dst):
	"""An `overlay` row from the mounts table: `lower` shared read-only underneath, this box's own
	upper layer on top — shared content, private writes.

	This is how a per-toolchain cache is given to a box (`~/.gradle` is the case that forced it).
	Gradle guards its caches with cross-process locks that are held for the WHOLE build — and
	`bootRun` never finishes — and are only handed over when the waiting process pings the holder on
	LOCALHOST. Between containers that ping cannot arrive, so a `~/.gradle` shared rw with the hub let
	one long-running build block every box's gradle forever ("Owner PID: <a pid in another
	namespace>", waiting on caches/journal-1). With the overlay the artifacts are still shared (read
	straight out of the lower layer, never copied), while every lock file, journal entry and daemon
	registry write is copied up into the box's own upper layer.

	The upper layer SURVIVES kill/recreate (it is the box's warm cache) and dies with the box dir. The
	lower layer is the hub's live cache, which the hub keeps writing to; overlayfs wants a stable lower
	layer, but a cache is the one case where that is harmless — artifacts are content-addressed and
	written by rename, and anything a box finds inconsistent it re-fetches into its own upper."""
	box_dir = os.path.join(BOXROOT, name)
	key = overlay_key(dst)
	return _overlay_volume(f"{box_volume(name)}-{key}", lower,
	                       os.path.join(box_dir, f"ovl-{key}", "upper"),
	                       os.path.join(box_dir, f"ovl-{key}", "work"))


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
	# Per-project port forwards: each box gets a slot, and every forward is published on the hub at
	# 127.0.0.1:(HUB_BASE_PORT + slot). The box gets PORT_FORWARDS + PORT_FORWARD_<NAME>_FROM/_TO_HUB so
	# the project's own scripts can wire e.g. MUSTER_DEV_URL and the frontend's backend URL. Running
	# out of slots refuses the spawn (alloc_slot raises).
	forwards = parse_port_forwards()
	slot = alloc_slot(box_dir) if forwards else None
	svc_env = parse_service_env()
	rows, checkout_dst, checkout_ro = parse_mounts(golden)
	claude_args = session_args(box_dir, resume)
	job = box_job(box_dir, base, merge)
	mounts, vols = [], []
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
			vols.append(make_shared_overlay_volume(name, src, dst))
			mounts.append(f"{vols[-1]}:{dst}")
		else:
			mounts.append(f"{src}:{dst}" + (":ro" if mode == "ro" else ""))
	record_volumes(name, vols)
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
		MUSTER_PINCHTAB_SERVER=PT_SERVER,
		MUSTER_PINCHTAB_TOKEN=PT_TOKEN,
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
	# The BACKEND forward is provisioned for every box but NOT used by default: the frontend keeps
	# pointing at the HUB's backend (the service-env value), which is the one actually running. The
	# tunnel just sits there ready, so an agent that decides to run its own backend switches with a
	# single variable — we hand it the finished URL rather than making it work out its slot port:
	#     export FRONTEND_DEV_BACKEND_URL="$FRONTEND_DEV_BACKEND_URL_OWN"   # then restart the dev loop
	# It must be a FULL app URL, not host:port — the frontend derives its REST base by stripping
	# /app[-suffix]/* off it, so a missing path segment sends every REST call to the wrong place.
	if "BACKEND" in forward_ports:
		path = ""
		for e in svc_env:
			if e.startswith("FRONTEND_DEV_BACKEND_PATH="):
				path = e.split("=", 1)[1]
		svc_env.append(f"FRONTEND_DEV_BACKEND_URL_OWN=http://localhost:{forward_ports['BACKEND']}{path}")
		env["MUSTER_EXTRA_ENV"] = "\n".join(svc_env)
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
	`cbx box <same name>` reattaches to them."""
	stop_forwarders(name)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True, check=True)
	for vol in created_volumes(name):
		subprocess.run(["docker", "volume", "rm", vol], capture_output=True, text=True)
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
	r = subprocess.run(["docker", "exec", "-i", "-u", "dev", c,
	                    "tmux", "load-buffer", "-b", "cbx", "-"],
	                   input=text.rstrip("\n"), capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "load-buffer failed")
	r = subprocess.run(["docker", "exec", "-u", "dev", c,
	                    "tmux", "paste-buffer", "-d", "-p", "-b", "cbx", "-t", "main"],
	                   capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(r.stderr.strip() or "paste-buffer failed")
	subprocess.run(["docker", "exec", "-u", "dev", c, "tmux", "send-keys", "-t", "main", "Enter"],
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
			result = create_box(name, base=base, merge=merge)
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
