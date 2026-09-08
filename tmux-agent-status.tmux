#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default key bindings
default_switcher_key="S"
default_next_done_key="N"
default_wait_key="W"
default_park_key="p"

# Get user configuration or use defaults.
switcher_key=$(tmux show-option -gqv "@agent-status-key")
next_done_key=$(tmux show-option -gqv "@agent-next-done-key")
wait_key=$(tmux show-option -gqv "@agent-wait-key")
park_key=$(tmux show-option -gqv "@agent-park-key")

[ -z "$switcher_key" ] && switcher_key="$default_switcher_key"
[ -z "$next_done_key" ] && next_done_key="$default_next_done_key"
[ -z "$wait_key" ] && wait_key="$default_wait_key"
[ -z "$park_key" ] && park_key="$default_park_key"

# Default switcher view: "tree" (hierarchical session/window/pane, default)
# or "agents" (flat list of every agent pane). Toggle mid-session with ctrl-f.
switcher_default_mode=$(tmux show-option -gqv "@agent-switcher-default-mode")
case "$switcher_default_mode" in
    tree|agents) ;;
    *) switcher_default_mode="tree" ;;
esac

# Switcher style: "popup" (fzf only), "sidebar" (sidebar only), or "both" (default)
switcher_style=$(tmux show-option -gqv "@agent-switcher-style")
[ -z "$switcher_style" ] && switcher_style="both"

# Display method: "popup" (default, requires tmux 3.2+) or "window" (fallback)
display_method=$(tmux show-option -gqv "@agent-status-display-method")
[ -z "$display_method" ] && display_method="popup"

# Sidebar key (used in "both" mode; in "sidebar" mode the main switcher key is used)
sidebar_key=$(tmux show-option -gqv "@agent-sidebar-key")
[ -z "$sidebar_key" ] && sidebar_key="o"

# Helper to bind the fzf switcher using the configured display method.
# Passes the default mode through via TMUX_AGENT_SWITCHER_MODE so the
# script can pick the right initial view without an extra CLI flag.
bind_fzf_switcher() {
    local key="$1"
    local launch
    case "$display_method" in
        "window")
            printf -v launch 'env TMUX_AGENT_SWITCHER_MODE=%q %q' \
                "$switcher_default_mode" "$CURRENT_DIR/scripts/hook-based-switcher.sh"
            tmux bind-key "$key" new-window -n "agent-status" "$launch"
            ;;
        "popup"|*)
            # Popup geometry varies by mode + preview state, so the popup
            # loop wrapper owns the display-popup invocation and relaunches
            # with new dimensions when the inner script requests it.
            printf -v launch 'env TMUX_AGENT_SWITCHER_MODE=%q %q' \
                "$switcher_default_mode" "$CURRENT_DIR/scripts/switcher-popup-loop.sh"
            tmux bind-key "$key" run-shell -b "$launch"
            ;;
    esac
}

case "$switcher_style" in
    popup)
        bind_fzf_switcher "$switcher_key"
        ;;
    sidebar)
        tmux bind-key "$switcher_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh"
        ;;
    both|*)
        bind_fzf_switcher "$switcher_key"
        tmux bind-key "$sidebar_key" run-shell "$CURRENT_DIR/scripts/sidebar-toggle.sh"
        ;;
esac

# Set up keybinding to switch to next done project
tmux bind-key "$next_done_key" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Set up keybinding to put session in wait mode
tmux bind-key "$wait_key" run-shell "$CURRENT_DIR/scripts/wait-session.sh"

# Set up keybinding to park a session for later
tmux bind-key "$park_key" run-shell "$CURRENT_DIR/scripts/park-session.sh"

# Detect iTerm2 Control Mode (tmux -CC) and skip status polling / daemons
# to avoid interfering with the control protocol. Keybindings above are fine.
control_mode=$(tmux display-message -p '#{client_control_mode}' 2>/dev/null)
if [ "$control_mode" = "1" ]; then
    exit 0
fi

# Set up tmux status line integration
tmux set-option -g status-interval 1

# Check if our status is already in the status-right
current_status_right=$(tmux show-option -gqv status-right)
if ! echo "$current_status_right" | grep -q "status-line.sh"; then
    tmux set-option -ag status-right " #($CURRENT_DIR/scripts/status-line.sh)"
fi

# Purge any hooks this plugin registered on a previous load before re-adding
# them below. tpm re-runs this file on every `prefix+r` (source-file), and the
# `set-hook -ga` (append) calls below would otherwise stack a fresh copy of all
# 15 hooks each time. Left unchecked they accumulate linearly: after N reloads
# every after-select-pane / session-created fires N stale copies, spawning N
# subprocesses per event and congesting the server command queue (observed as
# laggy pane focus / "click several times to switch"). Match on $CURRENT_DIR so
# we only drop OUR hooks; other plugins' hooks on the same event survive.
purge_plugin_hooks() {
    local hook_type name
    for hook_type in session-created client-attached client-session-changed \
        after-select-pane after-select-window after-switch-client \
        session-window-changed window-pane-changed pane-exited \
        window-layout-changed after-new-window after-kill-window \
        after-rename-window; do
        while IFS= read -r name; do
            [ -n "$name" ] && tmux set-hook -gu "$name"
        done < <(tmux show-hooks -g "$hook_type" 2>/dev/null \
            | grep -F "$CURRENT_DIR" | sed 's/ .*//')
    done
}
purge_plugin_hooks

# Set up daemon monitor to ensure smart-monitor is always running
# Start daemon monitor on session created
tmux set-hook -ga session-created "run-shell '$CURRENT_DIR/scripts/daemon-monitor.sh'"

# Sidebars are event-driven: wake them when tmux client focus changes so they
# can refresh ACTIVE markers without polling in the pane process.
tmux set-hook -ga client-attached "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga client-session-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga after-select-pane "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga after-select-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga after-switch-client "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga session-window-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"
tmux set-hook -ga window-pane-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh refresh'"

# Nudge the collector when tmux structure or names change so cache rebuilds stay
# event-driven instead of waiting for a fallback poll.
tmux set-hook -ga session-created "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
tmux set-hook -ga pane-exited "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
tmux set-hook -ga window-layout-changed "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
tmux set-hook -ga after-new-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
tmux set-hook -ga after-kill-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"
tmux set-hook -ga after-rename-window "run-shell -b '$CURRENT_DIR/scripts/sidebar-signal.sh collect'"

# Auto-create sidebar in new sessions (small delay so the session is ready)
tmux set-hook -ga session-created "run-shell -b 'sleep 0.5 && $CURRENT_DIR/scripts/sidebar-toggle.sh'"

# Start sidebar data collector daemon (one per tmux server)
"$CURRENT_DIR/scripts/sidebar-collector.sh" &

# Also start it now if tmux is already running
if tmux list-sessions >/dev/null 2>&1; then
    "$CURRENT_DIR/scripts/daemon-monitor.sh" >/dev/null 2>&1

    # Create sidebar in all existing sessions that don't have one
    for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        has_sidebar=$(tmux list-panes -t "$sess" -F '#{pane_title}' 2>/dev/null | grep -c "agent-sidebar")
        if [ "$has_sidebar" -eq 0 ]; then
            tmux run-shell -t "$sess" -b "$CURRENT_DIR/scripts/sidebar-toggle.sh" 2>/dev/null
        fi
    done
fi
