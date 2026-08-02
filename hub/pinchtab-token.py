#!/usr/bin/env python3
"""muster-pinchtab-token <config.json> — make sure the pinchtab server has a usable token.

Run by the hub's entrypoint before anything can autostart the pinchtab service. The token has to
match on BOTH sides: the server reads it from this config, and every agent box gets it from the
broker as PINCHTAB_TOKEN (the broker reads it back out of this same file when the stack .env does not
set PT_TOKEN). Three cases, in order:

  - a config already holding a real token   left completely alone — it is yours, not ours
  - PT_TOKEN set in the stack .env          written in, so the two sides agree
  - neither                                 generated here, so a fresh stack works with no secret
                                            for anyone to invent

Its own file rather than a heredoc in the entrypoint: this edits JSON somebody may have hand-tuned,
which deserves to be readable and to have a test — and a heredoc'd script indented with tabs under
`<<-` silently loses its own indentation, which is an IndentationError at boot rather than at build.

Exit status is 0 whenever the config is left in a usable state, including when there was nothing to
do. A config that cannot be read or parsed is NOT an error either: pinchtab will complain about it far
better than this can, and a hub that refuses to boot over it would be worse than one whose browser
service does not start.
"""
import json
import os
import secrets
import sys

# The placeholder the shipped example carries. Anything containing it counts as "not set yet"; an
# empty token would mean a server that accepts nobody.
PLACEHOLDER = "change-me"


def main(path):
	try:
		with open(path) as fh:
			cfg = json.load(fh)
	except (OSError, ValueError) as e:  # noqa: BLE001
		print(f"pinchtab-token: leaving {path} alone ({e})", file=sys.stderr)
		return 0
	if not isinstance(cfg, dict):
		print(f"pinchtab-token: {path} is not a JSON object — leaving it alone", file=sys.stderr)
		return 0
	server = cfg.setdefault("server", {})
	if not isinstance(server, dict):
		print(f"pinchtab-token: {path} has no 'server' object — leaving it alone", file=sys.stderr)
		return 0
	token = (server.get("token") or "").strip()
	if token and PLACEHOLDER not in token:
		return 0
	configured = os.environ.get("PT_TOKEN", "").strip()
	server["token"] = configured or secrets.token_hex(24)
	tmp = path + ".muster-tmp"
	with open(tmp, "w") as fh:
		json.dump(cfg, fh, indent=2)
		fh.write("\n")
	os.replace(tmp, path)
	where = "PT_TOKEN from the stack .env" if configured else "freshly generated"
	print(f"pinchtab-token: set the token in {path} ({where})", file=sys.stderr)
	return 0


if __name__ == "__main__":
	if len(sys.argv) != 2:
		print(__doc__.splitlines()[0], file=sys.stderr)
		raise SystemExit(2)
	raise SystemExit(main(sys.argv[1]))
