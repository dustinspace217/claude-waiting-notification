#!/usr/bin/env bash
#
# notify-with-focus-check.sh — Claude Code Notification hook
#
# Shows a desktop notification and plays a chime when Claude is waiting
# for input, but skips both if the Konsole tab that triggered this hook
# is currently the visible tab in the focused Konsole window.
#
# Detection strategy:
#   1. Walk the process tree upward from this hook's PID to find the ancestor
#      'konsole' process, recording every PID along the way.
#      Uses bash built-ins and /proc reads only — no awk or cat forks.
#      The Konsole tab's root shell is somewhere in that chain.
#   2. Construct the Konsole D-Bus service name directly from the konsole PID
#      (org.kde.konsole-<PID>) and fetch all its objects in a single call,
#      caching the result for reuse across sessions and windows.
#   3. Find the Konsole session (tab) whose shell processId() is in our chain.
#      All D-Bus return values are validated as plain integers before use.
#   4. Suppress only if that session is the currentSession() of a window in
#      this Konsole instance AND the active KWin window belongs to this
#      konsole process (checked via kdotool, which is Wayland-native).
#
# Known limitation: Konsole's D-Bus API does not expose which KWin window ID
# maps to which /Windows/N object, so if the same konsole process has multiple
# windows open the window match may be imprecise. This situation is uncommon.
#
# Requirements:
#   sudo dnf install kdotool    (official Fedora repos)
#   qdbus                       (installed as part of Qt)

# ── Notify helper ─────────────────────────────────────────────────────────────
# Called at every early-exit point so failures always produce a notification
# rather than silently doing nothing.  disown detaches the audio process so
# the hook exits immediately without waiting for playback to finish.
_notify() {
    notify-send \
        --app-name="Claude Code" \
        --icon=dialog-information \
        --urgency=normal \
        "Claude Code" \
        "Waiting for your input"
    paplay /usr/share/sounds/freedesktop/stereo/message-new-instant.oga &
    disown
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
# kdotool provides Wayland-native active-window queries via KWin's D-Bus
# scripting API.  Without it the focus check is not possible.
if ! command -v kdotool &>/dev/null; then
    _notify; exit 0
fi

# ── Walk process tree from $$ up to konsole ───────────────────────────────────
# A single pass builds CHAIN_PIDS and locates KONSOLE_PID simultaneously,
# avoiding the double-walk the naive find+loop approach would require.

declare -A CHAIN_PIDS
KONSOLE_PID=""
pid=$$

while [[ "$pid" -gt 1 ]]; do
    # Read process name via bash built-in — no cat fork.
    comm=""
    [[ -f "/proc/$pid/comm" ]] && read -r comm < "/proc/$pid/comm"

    if [[ "$comm" == "konsole" ]]; then
        KONSOLE_PID="$pid"
        break
    fi

    # Record this PID in the chain before stepping up.
    CHAIN_PIDS["$pid"]=1

    # Read the parent PID from /proc/status via bash built-in — no awk fork.
    next_pid=""
    if [[ -f "/proc/$pid/status" ]]; then
        while IFS=$' \t' read -r key val _; do
            if [[ "$key" == "PPid:" ]]; then
                next_pid="${val//[^0-9]/}"   # strip anything non-numeric
                break
            fi
        done < "/proc/$pid/status"
    fi

    [[ -z "$next_pid" || "$next_pid" -le 1 ]] && break
    pid="$next_pid"
done

[[ -z "$KONSOLE_PID" || "${#CHAIN_PIDS[@]}" -eq 0 ]] && { _notify; exit 0; }

# ── Locate Konsole's D-Bus service and cache its object list ───────────────────
# KDE names the service org.kde.konsole-<PID> when multiple instances are open.
# Constructing the name directly from KONSOLE_PID avoids listing all bus
# services.  Fetching the full object list once and caching it here means
# both the /Sessions/ and /Windows/ queries below use the same data without
# a second D-Bus round-trip.

KONSOLE_SVC="org.kde.konsole-${KONSOLE_PID}"
KONSOLE_OBJECTS=$(qdbus "$KONSOLE_SVC" 2>/dev/null)
if [[ -z "$KONSOLE_OBJECTS" ]]; then
    # Fallback: a single Konsole instance may omit the PID suffix.
    KONSOLE_SVC="org.kde.konsole"
    KONSOLE_OBJECTS=$(qdbus "$KONSOLE_SVC" 2>/dev/null)
fi
[[ -z "$KONSOLE_OBJECTS" ]] && { _notify; exit 0; }

# ── Find the Konsole session (tab) whose shell is in our process chain ─────────
# processId() returns the PID of the root shell in the tab's pty — somewhere
# in CHAIN_PIDS regardless of how many intermediate processes exist between
# the tab shell and this hook script.
#
# Both the path and the returned PID are validated as integers before use,
# so a malformed or hostile D-Bus response cannot inject arbitrary strings
# into the array key lookup or into subsequent D-Bus path arguments.

OUR_SESSION_ID=""
while IFS= read -r sess_path; do
    [[ "$sess_path" =~ ^/Sessions/[0-9]+$ ]] || continue

    sess_shell_pid=$(qdbus "$KONSOLE_SVC" "$sess_path" \
        org.kde.konsole.Session.processId 2>/dev/null)
    [[ "$sess_shell_pid" =~ ^[0-9]+$ ]] || continue

    if [[ -n "${CHAIN_PIDS["$sess_shell_pid"]}" ]]; then
        OUR_SESSION_ID="${sess_path##*/}"   # strip /Sessions/ prefix, keep numeric ID
        break
    fi
done < <(printf '%s\n' "$KONSOLE_OBJECTS" | grep '^/Sessions/')

[[ -z "$OUR_SESSION_ID" ]] && { _notify; exit 0; }

# ── Check: our tab is visible AND our Konsole window is focused ────────────────
# kdotool uses KWin's D-Bus scripting API — fully Wayland-native.
# getwindowpid is only called after confirming the window class is
# org.kde.konsole, saving one kdotool invocation when another app is focused.
# currentSession and window paths are validated as integers before comparison.

ACTIVE_UUID=$(kdotool getactivewindow 2>/dev/null)
if [[ -n "$ACTIVE_UUID" ]]; then
    ACTIVE_CLASS=$(kdotool getwindowclassname "$ACTIVE_UUID" 2>/dev/null)

    if [[ "$ACTIVE_CLASS" == "org.kde.konsole" ]]; then
        ACTIVE_WIN_PID=$(kdotool getwindowpid "$ACTIVE_UUID" 2>/dev/null)

        if [[ "$ACTIVE_WIN_PID" == "$KONSOLE_PID" ]]; then
            while IFS= read -r win_path; do
                [[ "$win_path" =~ ^/Windows/[0-9]+$ ]] || continue

                current_sess=$(qdbus "$KONSOLE_SVC" "$win_path" \
                    org.kde.konsole.Window.currentSession 2>/dev/null)
                [[ "$current_sess" =~ ^[0-9]+$ ]] || continue

                if [[ "$current_sess" == "$OUR_SESSION_ID" ]]; then
                    exit 0   # Our Claude tab is the active tab in the focused window — suppress
                fi
            done < <(printf '%s\n' "$KONSOLE_OBJECTS" | grep '^/Windows/')
        fi
    fi
fi

# ── Notify ────────────────────────────────────────────────────────────────────
_notify
