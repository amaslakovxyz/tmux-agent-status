#!/usr/bin/env bash
# Task 3.4 — controls-dispatch test.
#
# Unit-tests the pure dispatcher: sources sidebar.sh with --source-only
# (defines functions, returns before the main loop / any terminal or tmux
# side effects — see the SOURCE_ONLY guard in sidebar.sh) and calls
# dispatch_control() directly with TMUX_TEST_ECHO=1 so it echoes the
# resolved command instead of running it (never actually spawns a popup,
# toggles the sidebar, or kills a pane).
set -u

source "$(dirname "$0")/../sidebar.sh" --source-only 2>/dev/null

TMUX_TEST_ECHO=1

got="$(dispatch_control switcher)"
case "$got" in
    *switcher-popup-loop.sh*) ;;
    *) echo "FAIL: switcher not dispatched ($got)"; exit 1 ;;
esac

got="$(dispatch_control sidebar)"
case "$got" in
    *sidebar-toggle.sh*) ;;
    *) echo "FAIL: sidebar not dispatched ($got)"; exit 1 ;;
esac

got="$(dispatch_control close)"
case "$got" in
    *kill-pane*) ;;
    *) echo "FAIL: close not dispatched ($got)"; exit 1 ;;
esac

if dispatch_control bogus >/dev/null 2>&1; then
    echo "FAIL: unknown action should return non-zero"
    exit 1
fi

echo "PASS controls-dispatch"
