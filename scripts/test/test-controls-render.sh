#!/usr/bin/env bash
# Task 3.3 — controls-render test.
#
# Runs sidebar.sh headlessly (--render-once) against an ISOLATED tmux
# server (never the live default socket) and asserts:
#   1. the clickable control-region labels ("Switcher"/"Sidebar"/"Close")
#      render in the persistent sidebar pane;
#   2. "Switcher" is drawn in green (1;32) — design fidelity with the
#      original status-bar buttons;
#   3. the control region is ABSENT in PREVIEW_MODE (switcher popup), where
#      mouse is disabled and the buttons would be dead clutter.
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

# 1. Labels present in sidebar mode.
for want in "Switcher" "Sidebar" "Close"; do
    case "$out" in
        *"$want"*) ;;
        *) echo "FAIL: control '$want' not rendered"; exit 1 ;;
    esac
done

# 2. Switcher is green. Isolate the escape sequence *immediately* before the
# "Switcher" label (control writes "...H\033[1;32m<icon> Switcher"): take the
# text up to "Switcher", then the tail after the last ESC[ — it must be the
# bold-green SGR (1;32m). Matching the nearest preceding color avoids a false
# pass on green ✓ glyphs elsewhere in the list.
before_switcher="${out%%Switcher*}"
nearest_color="${before_switcher##*$'\033['}"
case "$nearest_color" in
    "1;32m"*) ;;
    *) echo "FAIL: 'Switcher' not drawn in green (1;32); nearest SGR was: ${nearest_color%%m*}m"; exit 1 ;;
esac

# 3. Controls ABSENT in PREVIEW_MODE (switcher popup) — dead buttons there.
prev="$(TMUX="${SOCK},0,${SESSID}" bash "$SIDEBAR" --render-once --preview 2>/dev/null)"
for unwanted in "Switcher" "Sidebar" "Close pane"; do
    case "$prev" in
        *"$unwanted"*) echo "FAIL: control '$unwanted' leaked into PREVIEW_MODE"; exit 1 ;;
    esac
done

echo "PASS controls-render"
