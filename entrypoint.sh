#!/bin/sh
set -e

# Runs as root. Recreates the host user inside the container so /etc/passwd, $HOME, and the
# bind mounts under /home/<user> all line up with whoever launched the box, then drops to that
# user. The identity is passed by muster-box.sh:
: "${HOST_USER:?entrypoint: HOST_USER not set (run via muster-box.sh)}"
: "${HOST_UID:?entrypoint: HOST_UID not set (run via muster-box.sh)}"
: "${HOST_GID:?entrypoint: HOST_GID not set (run via muster-box.sh)}"

# Primary group (match by GID; reuse whatever name already owns it).
if ! getent group "$HOST_GID" >/dev/null 2>&1; then
	groupadd -g "$HOST_GID" "$HOST_USER"
fi

# User (match by UID; home is the bind-mounted /home/<user>, so don't create it).
if ! getent passwd "$HOST_UID" >/dev/null 2>&1; then
	useradd -o -u "$HOST_UID" -g "$HOST_GID" -d "/home/$HOST_USER" -s /bin/bash -M "$HOST_USER"
fi
USER_NAME="$(getent passwd "$HOST_UID" | cut -d: -f1)"

# Set the clipboard proxy's UID to the runtime value (passed from the settings file) so it
# matches the host 'muster-clip' account the X server authorizes — no rebuild to change it.
CLIP_USER="muster-clip"
CLIP_UID="${CLIP_UID:-60001}"
if [ "$CLIP_UID" = "$HOST_UID" ]; then
	echo "entrypoint: CLIP_UID ($CLIP_UID) must differ from your UID ($HOST_UID)" >&2
	exit 1
fi
if [ "$(getent passwd "$CLIP_USER" | cut -d: -f3)" != "$CLIP_UID" ]; then
	usermod -o -u "$CLIP_UID" "$CLIP_USER"
fi

# Membership in 'clipusers' is what the static sudoers rule grants (xclip/xsel via the proxy).
usermod -aG clipusers "$USER_NAME"

export HOME="/home/$USER_NAME" USER="$USER_NAME" LOGNAME="$USER_NAME"

# We install claude SYSTEM-WIDE at /usr/local/bin/claude (it survives the home bind-mount), but
# the bind-mounted ~/.claude config records the host's install path ~/.local/bin/claude, so
# claude's self-check ('claude doctor') flags it as missing in the container. Expose the system
# binary at that expected per-user path via a symlink (self-heals a stale/broken link, persists
# in the shared home). Done as root so it can write the bind-mounted home; then chown to the user.
if [ -x /usr/local/bin/claude ] && [ ! -e "$HOME/.local/bin/claude" ]; then
	mkdir -p "$HOME/.local/bin"
	ln -sf /usr/local/bin/claude "$HOME/.local/bin/claude"
	chown "$HOST_UID:$HOST_GID" "$HOME/.local" "$HOME/.local/bin" 2>/dev/null || true
	chown -h "$HOST_UID:$HOST_GID" "$HOME/.local/bin/claude" 2>/dev/null || true
fi

# Put ~/.local/bin on PATH so claude's self-check sees its native-install dir on PATH (and any
# other user-local tools resolve). setpriv preserves this env into both the default 'claude'
# command and an interactive '--shell' bash, and the home path is only known here at runtime
# (so it can't be a build-time ENV). A /etc/profile.d drop-in covers login shells too.
export PATH="$HOME/.local/bin:$PATH"

# THIS BOX'S OWN BROWSER TAB. pinchtab isolates by session and gives each session its own tab, so a
# session per box is what stops two agents from driving the same tab and silently yanking the page out
# from under each other. Created here, before claude starts, and exported — passing a session per call
# would mean a wrapper around every `pinchtab` invocation, i.e. a different command line every time,
# i.e. a permission prompt every time for the agent.
#
# As the box user (setpriv), because the token file lives in the user's home at 0600 and a root-owned
# one would be unreadable to the agent that needs it. Best-effort throughout: the server may not be up
# yet, or there may be no pinchtab at all, and neither is a reason to fail to start a box — the agent
# can re-run `muster-pinchtab-session` once it is.
if [ -x /usr/local/bin/muster-pinchtab-session ]; then
	_pt="$(setpriv --reuid "$HOST_UID" --regid "$HOST_GID" --init-groups \
		env HOME="$HOME" PATH="$PATH" muster-pinchtab-session 2>/dev/null || true)"
	[ -n "$_pt" ] && export PINCHTAB_SESSION="$_pt"
	unset _pt
fi

# Ctrl-Z on the container tty sends SIGTSTP to the foreground app. For the claude TUI that strands
# the box: claude stops mid-run while the host-side docker client keeps the terminal in raw mode, so
# it looks hung with no shell to `fg` from (the stop is INSIDE the container — the docker client is
# never suspended, so there's no host job to resume). Undefine the tty's suspend char for the claude
# command so an accidental Ctrl-Z is a no-op; claude saves this termios at startup and restores it on
# every cooked-mode moment, so the guard holds throughout. Interactive --shell/--root keep normal job
# control (their stty is untouched).
case "${1:-}" in
	claude) [ -t 0 ] && stty susp undef 2>/dev/null || true ;;
esac

# --root (muster-box.sh): stay root and exec the command directly, skipping the privilege drop.
# The identity + bind mounts above are still set up so paths line up; this is just for in-box
# administration (apt install, etc).
if [ "${MUSTER_ROOT:-}" = "1" ]; then
	exec "$@"
fi

# Drop root, keeping the workdir docker set (-w), and exec the command (default: claude).
exec setpriv --reuid "$HOST_UID" --regid "$HOST_GID" --init-groups "$@"
