#!/usr/bin/env python3
"""box-broker — the only container with the docker socket.

It is "claude-box.sh as a service": the hub asks it (over the internal compose network, gated by
a shared token) to create/kill/list agent boxes, and the broker runs the modified claude-box.sh
with a VETTED environment. The hub can influence only the box name and the curated mount list;
image, uid, network, privileges and the socket are the broker's. Every curated mount source is
resolved and confined under the project root, so a compromised hub can expose project files to a
box but can never mount host paths or gain privilege.

To keep spawns fast AND current, the broker pulls BOX_IMAGE in the background at startup and after
each spawn — so a new box uses a recent image without ever waiting on a `docker pull`.

Config (env, from compose):
  BROKER_TOKEN        shared secret; required in the X-Broker-Token header
  BROKER_PORT         listen port (default 8099; not published to the LAN)
  PROJECT_NAME        used for the box name prefix  box-<project>-<name>
  BOX_IMAGE           the claude-box image (default: claude-box)
  BOX_NETWORK         docker network the box joins (e.g. cbx-<project>)
  PROJECT_ROOT        HOST path of the repo checkout — the mount-source confinement root
  CLAUDE_HOME         HOST path of the shared ~/.claude (mounted into every box)
  BOXROOT             HOST path whose <name>/home subdir is each box's empty home anchor
  BOX_MOUNTS          HOST path of the box-mounts manifest
  PINCHTAB_SERVER     e.g. http://hub:9867     PINCHTAB_TOKEN  the pinchtab token
  PORT_FORWARDS_FILE  HOST path of the port-forwards manifest (NAME BOX_PORT HUB_BASE_PORT per line)
  PORT_FORWARD_SLOTS  max concurrent boxes with forwards; each box's slot N -> hub port BASE+N (dflt 16)
  BOX_UID/BOX_GID     synthetic non-root identity inside the box (default 1000/1000)
  CLAUDEBOX_SCRIPT    path to claude-box.sh (default /usr/local/bin/claude-box.sh)
"""
import json
import os
import re
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BROKER_TOKEN", "")
PORT = int(os.environ.get("BROKER_PORT", "8099"))
PROJECT = os.environ.get("PROJECT_NAME", "project")
BOX_IMAGE = os.environ.get("BOX_IMAGE", "claude-box")
BOX_NETWORK = os.environ.get("BOX_NETWORK", "")
PROJECT_ROOT = os.path.realpath(os.environ.get("PROJECT_ROOT", "/work/checkout"))
CLAUDE_HOME = os.environ.get("CLAUDE_HOME", "")
# Shared package caches mounted (rw) into every box AND the hub at ~/.npm and ~/.gradle, so node/gradle
# artifacts are downloaded once, not duplicated per box. uid 1000 (dev/gradle) owns them; npm + gradle
# both handle concurrent access to a shared cache via their own file locks.
NPM_CACHE = os.environ.get("NPM_CACHE", "")
GRADLE_CACHE = os.environ.get("GRADLE_CACHE", "")
BOXROOT = os.environ.get("BOXROOT", "")
BOX_MOUNTS = os.environ.get("BOX_MOUNTS", "")
PT_SERVER = os.environ.get("PINCHTAB_SERVER", "")
PT_TOKEN = os.environ.get("PINCHTAB_TOKEN", "")
# Per-project port forwards (like box-mounts). File grammar: 'NAME BOX_PORT HUB_BASE_PORT' per line;
# each box gets a slot N and every forward is published on the hub at 127.0.0.1:(HUB_BASE_PORT + N).
PORT_FORWARDS_FILE = os.environ.get("PORT_FORWARDS_FILE", "")
PORT_FORWARD_SLOTS = int(os.environ.get("PORT_FORWARD_SLOTS", "16"))
BOX_UID = os.environ.get("BOX_UID", "1000")
BOX_GID = os.environ.get("BOX_GID", "1000")
CLAUDEBOX_SCRIPT = os.environ.get("CLAUDEBOX_SCRIPT", "/usr/local/bin/claude-box.sh")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
HOME_IN = "/home/dev"

# Serializes the background `docker pull` of BOX_IMAGE so concurrent spawns don't each start one.
_pull_lock = threading.Lock()


def box_container(name):
	return f"box-{PROJECT}-{name}"


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


def safe_dst(dst):
	"""Container-side destination under HOME_IN; reject absolute / traversal."""
	dst = dst.strip().lstrip("/")
	norm = os.path.normpath(dst)
	if norm.startswith("..") or norm.startswith("/") or norm == ".":
		raise ValueError(f"bad destination {dst!r}")
	return f"{HOME_IN}/{norm}"


def confined_src(src):
	"""HOST source, forced to resolve under PROJECT_ROOT (blocks /, the socket, other projects)."""
	src = src.strip()
	cand = os.path.realpath(os.path.join(PROJECT_ROOT, src))
	if cand != PROJECT_ROOT and not cand.startswith(PROJECT_ROOT + os.sep):
		raise ValueError(f"mount source {src!r} escapes the project root")
	return cand


def parse_manifest():
	"""Return (mounts, tmpfs, workdir). Grammar per line:
	    TREE <dst> <ro|rw>      whole checkout at HOME_IN/<dst>, with <dst>/.git shadowed; sets workdir
	    <src> <dst> <ro|rw>     checkout/<src> at HOME_IN/<dst>
	'#'/blank lines ignored. The workdir defaults to the whole-repo mount (the line whose
	src resolves to the project root, e.g. '.'), else the first mount, else HOME_IN."""
	mounts, tmpfs, workdir = [], [], None
	if not BOX_MOUNTS or not os.path.exists(BOX_MOUNTS):
		# default: whole tree, .git hidden
		mounts.append(f"{PROJECT_ROOT}:{HOME_IN}/checkout")
		tmpfs.append(f"{HOME_IN}/checkout/.git")
		return mounts, tmpfs, f"{HOME_IN}/checkout"
	with open(BOX_MOUNTS) as fh:
		for raw in fh:
			line = raw.strip()
			if not line or line.startswith("#"):
				continue
			parts = line.split()
			if parts[0] == "TREE":
				dst = safe_dst(parts[1]) if len(parts) > 1 else f"{HOME_IN}/checkout"
				mode = parts[2] if len(parts) > 2 else "rw"
				suffix = ":ro" if mode == "ro" else ""
				mounts.append(f"{PROJECT_ROOT}:{dst}{suffix}")
				tmpfs.append(f"{dst}/.git")
				workdir = dst
			else:
				src, dst = parts[0], (parts[1] if len(parts) > 1 else parts[0])
				mode = parts[2] if len(parts) > 2 else "rw"
				suffix = ":ro" if mode == "ro" else ""
				csrc, mdst = confined_src(src), safe_dst(dst)
				mounts.append(f"{csrc}:{mdst}{suffix}")
				# Land the box in the repo: the whole-checkout mount (src resolves to the project
				# root, e.g. the '.' line) sets the workdir; else the first mount seeds it.
				if csrc == PROJECT_ROOT:
					workdir = mdst
				elif workdir is None:
					workdir = mdst
	return mounts, tmpfs, workdir or HOME_IN


def create_box(name, resume=False):
	container = box_container(name)
	box_dir = os.path.join(BOXROOT, name)
	anchor = os.path.join(box_dir, "home")
	os.makedirs(anchor, exist_ok=True)
	os.chown(anchor, int(BOX_UID), int(BOX_GID))
	if CLAUDE_HOME:
		os.makedirs(CLAUDE_HOME, exist_ok=True)
		os.chown(CLAUDE_HOME, int(BOX_UID), int(BOX_GID))
	# Per-box claude session. All boxes share CLAUDE_HOME + the same cwd, so `claude --continue` would
	# be ambiguous across boxes; instead we pin a stable session id per box (stored in the box dir) and
	# resume THAT. A fresh spawn gets a new --session-id (recorded); a recreate reuses it via --resume,
	# so the box picks up exactly where it left off.
	session_file = os.path.join(box_dir, "session-id")
	claude_args = ""
	if resume and os.path.exists(session_file):
		with open(session_file) as fh:
			sid = fh.read().strip()
		if sid:
			claude_args = f"--resume {sid}"
	if not claude_args:
		sid = str(uuid.uuid4())
		with open(session_file, "w") as fh:
			fh.write(sid)
		claude_args = f"--session-id {sid}"
	# Per-project port forwards: each box gets a slot, and every forward is published on the hub at
	# 127.0.0.1:(HUB_BASE_PORT + slot). The box gets PORT_FORWARDS + PORT_FORWARD_<NAME>_FROM/_TO_HUB so
	# the project's own scripts can wire e.g. CLAUDEBOX_DEV_URL and the frontend's backend URL. Running
	# out of slots refuses the spawn (alloc_slot raises).
	forwards = parse_port_forwards()
	slot = alloc_slot(box_dir) if forwards else None
	mounts, tmpfs, workdir = parse_manifest()
	# Shared package caches (rw) at ~/.npm and ~/.gradle — one copy across the hub + all boxes, so
	# node/gradle don't re-download per box. The dirs are created + chowned to the box uid here.
	for cache_host, cache_dst in ((NPM_CACHE, f"{HOME_IN}/.npm"), (GRADLE_CACHE, f"{HOME_IN}/.gradle")):
		if cache_host:
			os.makedirs(cache_host, exist_ok=True)
			os.chown(cache_host, int(BOX_UID), int(BOX_GID))
			mounts.append(f"{cache_host}:{cache_dst}")
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
		CLAUDEBOX_WORKDIR=workdir,
		CLAUDEBOX_CLAUDE_ARGS=claude_args,
		CLAUDEBOX_PINCHTAB_SERVER=PT_SERVER,
		CLAUDEBOX_PINCHTAB_TOKEN=PT_TOKEN,
		CLAUDEBOX_EXTRA_MOUNTS="\n".join(mounts),
		CLAUDEBOX_EXTRA_TMPFS="\n".join(tmpfs),
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
	return {"box": name, "container": container, "workdir": workdir, "session": claude_args,
	        "slot": slot, "forwards": forward_ports, "mounts": mounts, "tmpfs": tmpfs}


def kill_box(name):
	stop_forwarders(name)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True, check=True)
	return {"killed": name}


def list_boxes():
	out = subprocess.run(
		["docker", "ps", "-a", "--filter", f"name=^box-{PROJECT}-", "--format", "{{.Names}}\t{{.Status}}"],
		capture_output=True, text=True, check=True,
	).stdout.strip()
	rows = [dict(zip(("container", "status"), ln.split("\t", 1))) for ln in out.splitlines() if ln]
	return {"boxes": rows}


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


def recreate_box(name):
	"""Pull the newest image, drop the old container, and respawn the box resuming ITS session."""
	pull_box_image(wait=True)
	subprocess.run(["docker", "rm", "-f", box_container(name)], capture_output=True, text=True)
	return create_box(name, resume=True)


def recreate_all():
	"""Recreate every box (newest image, each resuming its own session). Pulls once for all."""
	pull_box_image(wait=True)
	done = []
	for r in list_boxes()["boxes"]:
		name = _box_name_of(r["container"])
		subprocess.run(["docker", "rm", "-f", r["container"]], capture_output=True, text=True)
		done.append(create_box(name, resume=True)["box"])
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

	def _box_name(self):
		return self.path[len("/box/"):].strip("/")

	def do_GET(self):
		if not self._authed():
			return
		if self.path == "/box":
			try:
				self._reply(200, list_boxes())
			except Exception as e:  # noqa: BLE001
				self._reply(500, {"error": str(e)})
		else:
			self._reply(404, {"error": "not found"})

	def do_POST(self):
		if not self._authed():
			return
		# Recreate (newest image + respawn resuming each box's session). /recreate = every box.
		if self.path.rstrip("/") == "/recreate":
			try:
				return self._reply(200, recreate_all())
			except Exception as e:  # noqa: BLE001
				return self._reply(500, {"error": str(e)})
		if self.path.startswith("/recreate/"):
			rname = self.path[len("/recreate/"):].strip("/")
			if not NAME_RE.match(rname):
				return self._reply(400, {"error": "bad box name"})
			try:
				return self._reply(200, recreate_box(rname))
			except Exception as e:  # noqa: BLE001
				return self._reply(500, {"error": str(e)})
		# Default: spawn a fresh box.
		name = self._box_name()
		if not self.path.startswith("/box/") or not NAME_RE.match(name):
			return self._reply(400, {"error": "bad box name"})
		try:
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
		name = self._box_name()
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
