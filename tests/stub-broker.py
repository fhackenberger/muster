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
GOLDEN = os.environ.get("GOLDEN_DIR", "")
STAGING = os.environ.get("GOLDEN_STAGING", "")

BOXES = {}       # name -> {"golden": …, "base": …, "merge": …, "dirty": [ … ]}


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
        if path == "/box":
            return self._reply(200, {"boxes": [
                {"box": n, "container": f"box-test-{n}", "status": "Up 3 minutes",
                 "golden": b["golden"]} for n, b in sorted(BOXES.items())]})
        if path.startswith("/box/") and path.endswith("/dirty"):
            n = path[len("/box/"):-len("/dirty")]
            return self._reply(200, {"dirty": BOXES.get(n, {}).get("dirty", [])})
        if path == "/golden":
            cur = current_golden()
            in_use = {}
            for n, b in BOXES.items():
                in_use.setdefault(b["golden"], []).append(n)
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
            keep = {b["golden"] for b in BOXES.values()} | {current_golden()}
            gone = []
            for e in sorted(os.listdir(GOLDEN or ".")):
                if e == "current" or e in keep or not e.startswith("g-"):
                    continue
                shutil.rmtree(os.path.join(GOLDEN, e))
                gone.append(e)
            return self._reply(200, {"reaped": gone})
        if path == "/forwards" or path.startswith("/forwards/"):
            return self._reply(200, {"forwards": sorted(BOXES)})
        if path == "/recreate":
            return self._reply(200, {"recreated": sorted(BOXES)})
        if path.startswith("/recreate/"):
            n = path[len("/recreate/"):]
            if n not in BOXES:
                return self._reply(500, {"error": f"no such box {n}"})
            return self._reply(200, {"box": n, "container": f"box-test-{n}"})
        for verb in ("say", "paste"):
            if path.startswith("/box/") and path.endswith("/" + verb):
                n = path[len("/box/"):-len(verb) - 1]
                if n not in BOXES:
                    return self._reply(500, {"error": f"no such box {n}"})
                if not body.strip():
                    return self._reply(400, {"error": "empty message"})
                return self._reply(200, {verb: n})
        if path.startswith("/box/"):
            n = path[len("/box/"):]
            BOXES[n] = {"golden": current_golden(),
                        "base": self._param("base") or "", "merge": self._param("merge") or "",
                        "dirty": []}
            return self._reply(201, {"box": n, "container": f"box-test-{n}",
                                     "golden": BOXES[n]["golden"], "branch": f"agent/{n}",
                                     "base": BOXES[n]["base"], "merge": BOXES[n]["merge"]})
        return self._reply(404, {"error": "not found"})

    def do_DELETE(self):
        path = self._path()
        record("DELETE", self.path)
        n = path[len("/box/"):]
        if n not in BOXES:
            return self._reply(500, {"error": f"no such box {n}"})
        del BOXES[n]
        return self._reply(200, {"killed": n})

    def log_message(self, *a):
        return


if __name__ == "__main__":
    port = int(os.environ.get("STUB_PORT", sys.argv[1] if len(sys.argv) > 1 else "8799"))
    HTTPServer(("127.0.0.1", port), H).serve_forever()
