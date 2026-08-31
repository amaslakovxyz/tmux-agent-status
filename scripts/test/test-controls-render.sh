#!/usr/bin/env bash
# Task 3.3 — controls-render test.
#
# Runs sidebar.sh headlessly (--render-once) against an ISOLATED tmux
# server (never the live default socket) and asserts the new clickable
# control-region labels ("Switcher" / "Sidebar" / "Close") are present in
# the rendered frame.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDEBAR="$SCRIPT_DIR/../sidebar.sh"

LBL="sidebar-ctl-test-$$"

cleanup() {
    env -u TMUX tmux -L "$LBL" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Isolated server + a couple of sessions, so collect()/render() have real
# content to walk (not required for the control labels themselves, but
# exercises the same code path a live sidebar runs). Never bare `tmux` —
# always -L against a unique label, and env -u TMUX to guard against
# running nested inside a real tmux client.
if ! env -u TMUX tmux -L "$LBL" new-session -d -s alpha -c /tmp >/dev/null 2>&1; then
    echo "FAIL: could not start isolated tmux server"
    exit 1
fi
env -u TMUX tmux -L "$LBL" new-session -d -s beta -c /tmp >/dev/null 2>&1 || true

SOCK="$(env -u TMUX tmux -L "$LBL" display-message -p '#{socket_path}' 2>/dev/null)"
SESSID="$(env -u TMUX tmux -L "$LBL" display-message -p -t alpha '#{session_id}' 2>/dev/null)"
SESSID="${SESSID#\$}"
[ -n "$SESSID" ] || SESSID=0

if [ -z "$SOCK" ]; then
    echo "FAIL: could not resolve isolated tmux socket_path"
    exit 1
fi

# Point sidebar.sh's bare `tmux` calls at the isolated server: exporting
# TMUX=<socket_path>,<pid>,<session_id> makes unqualified `tmux ...` calls
# inside sidebar.sh resolve against that socket/session — the same
# mechanism tmux run-shell/hooks rely on — without ever touching the live
# default socket.
out="$(TMUX="${SOCK},0,${SESSID}" bash "$SIDEBAR" --render-once 2>/dev/null)"

for want in "Switcher" "Sidebar" "Close"; do
    case "$out" in
        *"$want"*) ;;
        *) echo "FAIL: control '$want' not rendered"; exit 1 ;;
    esac
done

echo "PASS controls-render"
