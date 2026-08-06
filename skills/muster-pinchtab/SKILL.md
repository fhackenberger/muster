---
name: muster-pinchtab
description: "Use this skill together with the `pinchtab` skill whenever you drive a browser from inside a muster box or hub: it covers where Chrome actually runs (the hub, not your box), which URL reaches your dev server from there, your own session and tab (and what to do when it expires), what it means when your reviewer pauses or annotates that tab, and viewport/device emulation for responsive and mobile checks."
---

# pinchtab inside muster

The `pinchtab` skill (installed alongside this one) is upstream's and documents the CLI, the
accessibility-ref workflow and the HTTP API. **Read it first — this file only adds what is different
here, and what its docs do not cover.**

## Where the browser is

`pinchtab server` runs as a **hub service**, autostarted at boot (`muster ls` shows it; `muster
up/down pinchtab` controls it). Chrome lives in the hub container. Your box has the CLI, already
pointed at that server through `$PINCHTAB_SERVER` (e.g. `http://hub:9867`) and `$PINCHTAB_TOKEN`.

The consequence that catches everyone: **the URL you pass is resolved on the hub, not in your box.**
Your dev server is published on the hub's loopback for exactly this reason — use the hub column of
the port table in your box memo (`http://localhost:$PORT_FORWARD_<NAME>_TO_HUB`). The in-box port is
the right one for `curl` from here and the wrong one for pinchtab; the hub port is the reverse.

### The two ports, and the one wrong move

Your box and the hub are docker-network siblings: no shared loopback. `PORT_FORWARDS` names each
tunnel, and each name `ABC` has two numbers:

```
PORT_FORWARD_ABC_FROM      the port your server binds INSIDE your box
PORT_FORWARD_ABC_TO_HUB    where the hub sees it, on the HUB's loopback
```

So `curl` from here uses `_FROM`; pinchtab uses `http://localhost:$PORT_FORWARD_<NAME>_TO_HUB`,
because the browser resolves it on the hub. **`_TO_HUB` ports bind the hub's loopback only**, so
`hub:<TO_HUB>` is refused even when the tunnel is perfectly healthy — verify your own server with
`curl` locally and the tunnel by navigating the browser, never by probing `hub:<port>`.

Read the numbers from the environment; do not hardcode them. They differ per box, and a box that was
recreated may not get the same ones back.

If `$PINCHTAB_SERVER` is unset you are not in a server-mode box (a laptop box, or the hub itself) and
the CLI's own `127.0.0.1` default applies. Never "fix" a failure by falling back to `127.0.0.1` inside
a box: it answers `health ok` and drives no browser you can see.

## Your own session, and therefore your own tab

Every box points its CLI at that one server, so without sessions every box would drive the **same
tab** — two agents browsing at once yank the page out from under each other, and neither can tell.
pinchtab isolates by session and gives each session a dedicated tab, so muster creates one per box at
start-up and exports it:

```bash
echo "$PINCHTAB_SESSION"                                    # already set; nothing to pass per call
export PINCHTAB_SESSION="$(muster-pinchtab-session)"        # if it is empty (server was down at boot)
export PINCHTAB_SESSION="$(muster-pinchtab-session --force-new)"   # after 401 invalid or expired
```

Sessions expire 24h after creation — a fixed lifetime, **not** extended by activity — and the cue is
`401 invalid or expired agent session`. `--force-new` revokes the old one first.

Keep it as an exported variable rather than passing a session on each command line: a different
command line every time is a permission prompt every time.

**Subagents** inherit your environment, so they share your tab. One that needs its own sets
`MUSTER_PINCHTAB_SESSION_FILE` to a distinct path before calling `muster-pinchtab-session`.

### Your reviewer can see that tab — and pause it

Because the session is muster's, the hub can act on your tab:

- `peek` — a screenshot, or the accessibility tree. When you say "the page looks fine" and your
  reviewer disagrees, this is how they check what you actually got.
- `point` — pinchtab's labelled overlay drawn on your tab, then captured. So a message like **"e5 is
  the misaligned one" refers to YOUR refs** and means exactly what it says. Re-snapshot to resolve a
  ref you have not seen; do not guess.
- `hold` / `release` — your tab paused while a page is set up for you. Your browser calls then fail
  with **`409 tab_paused_handoff`**. That is not a broken page and not something to work around: wait,
  or ask. When it is released you are told, and you should re-snapshot — the page moved under you.

Everything below was verified against pinchtab 0.13.2 and 0.14.1. The images track pinchtab's newest
release rather than pinning it, so if something here does not match what you see, check which version
you actually have — `pinchtab --version`, or `cat /opt/muster/pinchtab-version` for the one the image
was built with — and trust the binary over this file.

## Viewport and device emulation

Not in upstream's skill, and the thing you want for any responsive or mobile check.

```bash
pinchtab set viewport 390 844 --dpr 3 --mobile      # add --tab <id>, --json
```

The CLI sends `deviceScaleFactor` only when `--dpr` is greater than 0, and `mobile` only when the
flag is present — so a bare `set viewport 390 844` leaves both at their defaults rather than
resetting them explicitly.

The HTTP form, when you want it per tab:

```bash
curl -X POST http://hub:9867/tabs/$TAB/emulation/viewport \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $PINCHTAB_TOKEN" \
  -d '{"width":390,"height":844,"deviceScaleFactor":3,"mobile":true}'
```

* Both `POST /emulation/viewport` (current tab) and `POST /tabs/{id}/emulation/viewport` exist.
* `width` and `height` must be positive, or 400. `deviceScaleFactor` ≤ 0 silently becomes 1.0.
  `mobile` defaults to false. On the tab-scoped form a `tabId` in the body that disagrees with the
  path is a 400.
* 200 echoes the four values plus `"status": "applied"`.
* No capability gating (`CapNone`), a 5s timeout, and the tab's domain policy still applies.
* Under the hood it is the real CDP override — `Emulation.setDeviceMetricsOverride` with
  `screen.width`/`screen.height` pinned to the viewport, so `window.screen` agrees with
  `window.innerWidth` instead of reporting the host display.

**Set it before you navigate, or reload after.** A page parses its `<meta name="viewport">` and
evaluates media queries against the metrics in force at parse time.

**It is per tab and per target.** Your session already owns its own tab (above), so a viewport you
set is yours alone — no coordination with the other boxes, and nothing of yours changes under them.

## What emulation does NOT give you here

Three limits that cost real time to discover:

1. **No touch emulation.** `Emulation.setTouchEmulationEnabled` / `setEmitTouchEventsForMouse` are
   not in the tree at all. `"mobile": true` buys viewport-meta handling, overlay scrollbars and text
   autosizing — **not touch events**. A `@media (pointer: coarse)` rule can be reached (see below);
   a `touchstart` listener cannot be exercised this way.
2. **One CSS media feature at a time.** `POST /emulation/media` takes
   `{"feature": "...", "value": "..."}` and calls `SetEmulatedMedia().WithFeatures([one feature])`.
   CDP treats that list as the complete override, so a second call **replaces** the first — you
   cannot have `pointer: coarse` and `hover: none` active simultaneously through this API.
3. **No user-agent override endpoint.** `SetUserAgentOverride` exists in the code but is not routed,
   so the UA stays instance-level, fixed at launch by config/stealth. Viewport is free per tab; a
   mobile **UA** still costs a separate pinchtab instance.

## Reporting a layout finding

Screenshot at the viewport you claim to have tested, and say which one it was — "broken at 390×844,
dpr 3, mobile" is actionable; "broken on mobile" sends the next person to reproduce it before they
can fix it. If the finding depends on touch, say so explicitly and how you established it, because
the emulation above did not.
