#!/usr/bin/env python3
"""stub-broker — the box-broker's HTTP contract, without docker.

`cbx` never touches the docker socket; it asks the broker over HTTP. That makes the whole hub CLI
testable offline: this serves the same endpoints, records what it was asked to do, and keeps just
enough state (which boxes "exist") for the listing commands to be meaningful.

Two endpoints are implemented for REAL rather than faked, because their behaviour is what the
corresponding cbx command is actually being tested against:

  POST /golden/seal/<id>   moves golden-staging/<id> -> golden/<id> and flips the `current` symlink,
                           exactly as the real broker does (the hub cannot do it: it mounts the
                           golden dir read-only).
  POST /golden/reap        deletes goldens no box references.

Everything the stub is ASKED is appended to $STUB_LOG as one JSON object per line, so a test can
assert on it: {"method": …, "path": …, "body": …}.

Env: STUB_PORT, STUB_LOG, GOLDEN_DIR, GOLDEN_STAGING.
"""
import json
import os
import shutil
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.environ.get("STUB_LOG", "/tmp/stub-broker.log")
# name -> golden, for boxes that were killed: a directory with no container.
RETIRED = {}
GOLDEN = os.environ.get("GOLDEN_DIR", "")
STAGING = os.environ.get("GOLDEN_STAGING", "")

BOXES = {}       # name -> {"golden": …, "base": …, "merge": …, "dirty": [ … ]}

# What a TEST wants /box/<n>/dirty to say, as JSON: {"work1": {"dirty": [" M a.txt"], "head": "<sha>"}}
# The real broker reads both out of the container; here they are whatever the fixture is pretending.
BOX_STATE = json.loads(os.environ.get("STUB_BOX_STATE", "{}"))


def record(method, path, body=""):
    with open(LOG, "a") as fh:
        fh.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")


def current_golden():
    link = os.path.join(GOLDEN, "current")
    return os.path.basename(os.path.realpath(link)) if os.path.exists(link) else "none"


class H(BaseHTTPRequestHandler):
    def _reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def _path(self):
        return self.path.split("?", 1)[0].rstrip("/")

    def _param(self, name):
        import urllib.parse
        q = self.path.split("?", 1)[1] if "?" in self.path else ""
        v = urllib.parse.parse_qs(q).get(name) or []
        return v[0] if v else None

    def do_GET(self):
        path = self._path()
        record("GET", self.path)
        if path == "/version":
            v = os.environ.get("STUB_MUSTER_VERSION", "0.0.0-stub")
            return self._reply(200, {"broker": v, "box_image": v, "box_image_ref": "stub/box:test"})
        if path == "/box":
            # RETIRED: a box directory with no container. The real broker derives them from BOXROOT;
            # here they are whatever the test put in RETIRED, which is enough to exercise the listing
            # and `purge`.
            #
            # ?sizes=1 IS HONOURED HERE TOO, because the whole point of the flag is that measuring
            # costs seconds: the real broker walks every file under every retired box. A stub that
            # always sent a size would let a hub that had stopped asking still print one, and the
            # regression this guards against — the dashboard quietly going back to paying for sizes
            # it never displays — would sail through the suite.
            # A BROKER THAT DOES NOT ANSWER THE QUESTION — an older one from before the flag, or a
            # newer one that dropped it — is `touch $STUB_LOG.ignore-sizes`. A FILE, not an env var:
            # the stub is started once for the whole suite, so a variable set on the cbx call under
            # test could never reach it. The hub must then print what it knows ('?'), not a 0.
            deaf = os.path.exists(LOG + ".ignore-sizes")
            retired = []
            for n, g in sorted(RETIRED.items()):
                r = {"box": n, "golden": g}
                if self._param("sizes") and not deaf:
                    r["size"] = 12345678
                retired.append(r)
            return self._reply(200, {"boxes": [
                {"box": n, "container": f"box-test-{n}", "status": "Up 3 minutes",
                 "golden": b["golden"]} for n, b in sorted(BOXES.items())],
                "retired": retired})
        if path.startswith("/box/") and path.endswith("/dirty"):
            n = path[len("/box/"):-len("/dirty")]
            st = BOX_STATE.get(n, {})
            # A BOX WITH NO CONTAINER ANSWERS 200 AND SAYS NOTHING. The real broker's box_dirty
            # execs into the container; when that fails — which for a retired box it always does —
            # it returns reachable:false with an EMPTY dirty list and an EMPTY head. Modelled here
            # because the hub used to read those two blanks as "clean" and "the broker is old", and
            # waved a retired box through a move that deleted the layer its work was in.
            if n not in BOXES:
                return self._reply(200, {"box": n, "reachable": False, "dirty": [], "head": "",
                                         "error": f"No such container: box-test-{n}"})
            return self._reply(200, {"box": n, "reachable": True,
                                     "dirty": st.get("dirty", BOXES.get(n, {}).get("dirty", [])),
                                     "head": st.get("head", "")})
        if path == "/golden":
            cur = current_golden()
            in_use = {}
            # LIVE AND RETIRED BOTH HOLD A GOLDEN. The real list_goldens walks the box DIRECTORIES,
            # and `kill` keeps a box's directory on purpose — so a retired box still pins the golden
            # it was overlaid on, and `retire` still has to deal with it. Counting only live boxes
            # here made the whole retired-box path untestable, which is where its bugs were.
            for n, b in BOXES.items():
                in_use.setdefault(b["golden"], []).append(n)
            for n, g in RETIRED.items():
                in_use.setdefault(g, []).append(n)
            out = []
            for d in sorted(os.listdir(GOLDEN or ".")):
                p = os.path.join(GOLDEN, d)
                if d == "current" or not os.path.isdir(p) or os.path.islink(p):
                    continue
                out.append({"golden": d, "current": d == cur, "boxes": in_use.get(d, [])})
            return self._reply(200, {"goldens": out, "current": cur, "staging": STAGING})
        return self._reply(404, {"error": "not found"})

    def do_POST(self):
        path = self._path()
        body = self._body()
        record("POST", self.path, body)
        if path.startswith("/golden/seal/"):
            gid = path[len("/golden/seal/"):]
            src, dst = os.path.join(STAGING, gid), os.path.join(GOLDEN, gid)
            if not os.path.isdir(src):
                return self._reply(500, {"error": f"no staged golden {gid}"})
            shutil.move(src, dst)
            link = os.path.join(GOLDEN, "current")
            tmp = link + ".new"
            os.symlink(gid, tmp)
            os.replace(tmp, link)
            return self._reply(200, {"sealed": gid})
        if path == "/golden/reap":
            keep = {b["golden"] for b in BOXES.values()} | set(RETIRED.values()) | {current_golden()}
            gone = []
            for e in sorted(os.listdir(GOLDEN or ".")):
                if e == "current" or e in keep or not e.startswith("g-"):
                    continue
                shutil.rmtree(os.path.join(GOLDEN, e))
                gone.append(e)
            return self._reply(200, {"reaped": gone})
        # Re-point a RETIRED box at the current golden without docker: the real broker deletes its
        # upper layers and rewrites its `golden` file. Refuses while a container exists — the running
        # box would keep its old mount and the file would already be lying.
        if path.endswith("/rebase-golden"):
            n = path[len("/box/"):-len("/rebase-golden")]
            if n in BOXES:
                return self._reply(409, {"error": f"{n!r} still has a container — it is not retired."})
            if n not in RETIRED:
                return self._reply(409, {"error": f"no box directory for {n!r}"})
            RETIRED[n] = current_golden()
            return self._reply(200, {"box": n, "golden": current_golden(), "freed": 4321})
        if path == "/forwards" or path.startswith("/forwards/"):
            return self._reply(200, {"forwards": sorted(BOXES)})
        # Recreating respawns a box on whatever golden is CURRENT — which is the whole mechanism behind
        # `golden retire`'s "move them" answer, so the stub has to model it or that move is untestable.
        if path == "/recreate":
            for b in BOXES.values():
                b["golden"] = current_golden()
            return self._reply(200, {"recreated": sorted(BOXES)})
        if path.startswith("/recreate/"):
            n = path[len("/recreate/"):]
            if n not in BOXES:
                return self._reply(500, {"error": f"no such box {n}"})
            BOXES[n]["golden"] = current_golden()
            return self._reply(200, {"box": n, "container": f"box-test-{n}"})
        for verb in ("say", "paste"):
            if path.startswith("/box/") and path.endswith("/" + verb):
                n = path[len("/box/"):-len(verb) - 1]
                if n not in BOXES:
                    return self._reply(500, {"error": f"no such box {n}"})
                if not body.strip():
                    return self._reply(400, {"error": "empty message"})
                return self._reply(200, {verb: n})
        if path.startswith("/box/") and "/migrate/" in path:
            rest = path[len("/box/"):]
            n, _, action = rest.partition("/migrate/")
            # The real broker allowlists the action, because it becomes argv inside the box. Mirrored
            # here so a hub that asks for an action the broker does NOT have fails loudly in the
            # tests, instead of collecting a cheerful 200 from a stub that accepts anything.
            if action not in ("stash", "apply", "apply-keep-golden", "list"):
                return self._reply(400, {"ok": False, "error": f"bad migrate action {action!r}"})
            st = BOX_STATE.get(n, {})
            if st.get("migrate_fails"):
                return self._reply(500, {"ok": False, "error": "pretend the patch did not apply"})
            files = [ln.split(None, 1)[-1] for ln in st.get("dirty", [])]
            return self._reply(200, {"ok": True, "action": action, "files": files,
                                     "output": f"applied {len(files)} path(s)"})
        if path.startswith("/box/"):
            n = path[len("/box/"):]
            # The real broker refuses a name longer than the container hostname can carry, and its
            # refusal is a SENTENCE naming the rule. Mirrored here (with this stub's own project) so
            # the hub's side of it — unwrapping .error rather than printing raw JSON at you — is
            # covered end to end.
            limit = 63 - len("box-test-")
            if len(n) > limit:
                return self._reply(400, {"error": f"box name {n!r} is {len(n)} characters; the limit "
                                                  f"is {limit} for project 'test', because the "
                                                  f"container's hostname (box-test-<name>) must fit in 63"})
            # RESURRECTING A RETIRED BOX PUTS IT BACK ON ITS OWN GOLDEN, not on whatever is current:
            # its directory and upper layer were kept, and an upper layer is only coherent on the
            # lower layer it was computed against (create_box -> recorded_golden in the broker). So a
            # box you bring back is still behind, and `golden migrate` is still what moves it.
            BOXES[n] = {"golden": RETIRED.pop(n, "") or current_golden(),
                        "base": self._param("base") or "", "merge": self._param("merge") or "",
                        "dirty": []}
            return self._reply(201, {"box": n, "container": f"box-test-{n}",
                                     "golden": BOXES[n]["golden"], "branch": f"agent/{n}",
                                     "base": BOXES[n]["base"], "merge": BOXES[n]["merge"]})
        return self._reply(404, {"error": "not found"})

    def do_DELETE(self):
        path = self._path()
        record("DELETE", self.path)
        if path.endswith("/purge"):
            n = path[len("/box/"):-len("/purge")]
            BOXES.pop(n, None)
            RETIRED.pop(n, None)
            return self._reply(200, {"purged": n, "freed": 12345678})
        n = path[len("/box/"):]
        if n not in BOXES:
            return self._reply(500, {"error": f"no such box {n}"})
        # kill keeps the directory, so the box becomes RETIRED rather than vanishing.
        RETIRED[n] = BOXES[n]["golden"]
        del BOXES[n]
        return self._reply(200, {"killed": n})

    def log_message(self, *a):
        return


if __name__ == "__main__":
    port = int(os.environ.get("STUB_PORT", sys.argv[1] if len(sys.argv) > 1 else "8799"))
    HTTPServer(("127.0.0.1", port), H).serve_forever()
