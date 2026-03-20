#!/usr/bin/env bash
set -u
#
# notify-with-focus-check.sh — Claude Code Notification hook
#
# Shows a desktop notification and plays a chime when Claude is waiting
# for user input, but skips both if the Konsole tab that triggered this
# hook is currently the visible tab in the focused Konsole window.
#
# Notification type filter: only fires for 'waiting_for_user_input'.
# Other types (e.g. 'permission_prompt') surface inline in the terminal
# and do not need an additional desktop notification.
#
# Detection strategy:
#   1. Walk the process tree upward from this hook's PID to find the ancestor
#      'konsole' process, recording every PID along the way.
#      Uses bash built-ins and /proc reads only — no awk or cat forks.
#      The Konsole tab's root shell is somewhere in that chain.
#   2. Run an early kdotool check: if the active window is not our Konsole
#      instance, fire the notification and exit — no D-Bus calls needed.
#   3. Construct the Konsole D-Bus service name from the konsole PID
#      (org.kde.konsole-<PID>) and fetch all its objects in a single call,
#      caching the result for reuse across sessions and windows.
#   4. Find the Konsole session (tab) whose shell processId() is in our chain.
#      All D-Bus return values are validated as plain integers before use.
#   5. Suppress only if that session is the currentSession() of any window
#      in this Konsole instance (window is already confirmed focused in step 2).
#
# Known limitation: Konsole's D-Bus API does not expose which KWin window ID
# maps to which /Windows/N object, so if the same konsole process has multiple
# windows open the window match may be imprecise. This situation is uncommon.
#
# Requirements:
#   sudo dnf install kdotool           (official Fedora repos)
#   sudo dnf install qt6-qttools       (provides /usr/bin/qdbus-qt6)

# ── Filter by notification type ───────────────────────────────────────────────
# The Notification hook receives a JSON payload on stdin containing a
# notification_type field.  We only want a desktop pop-up for the
# 'waiting_for_user_input' state.  Other known types:
#   permission_prompt  — Claude needs tool approval; the terminal shows this
#                        inline and a desktop notification is redundant noise.
# Unknown/future types fall through (safe default: notify rather than drop).
_HOOK_STDIN=$(cat)
_NOTIF_TYPE=$(python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('notification_type',''))" \
    <<< "$_HOOK_STDIN" 2>/dev/null || true)

if [[ "$_NOTIF_TYPE" == "permission_prompt" ]]; then
    exit 0
fi

# ── Notify helper ─────────────────────────────────────────────────────────────
# Called at every early-exit point so failures always produce a notification
# rather than silently doing nothing.  'disown $!' detaches the specific audio
# background job by PID so the hook exits without waiting for playback.
_notify() {
    notify-send \
        --app-name="Claude Code" \
        --icon=dialog-information \
        --urgency=normal \
        "Claude Code" \
        "Waiting for your input"
    paplay /usr/share/sounds/freedesktop/stereo/message-new-instant.oga &
    disown $!
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
# kdotool provides Wayland-native active-window queries via KWin's D-Bus API.
# Without it the focus check is not possible.
if ! command -v kdotool &>/dev/null; then
    >&2 echo "notify-with-focus-check: kdotool not found — install with: sudo dnf install kdotool"
    _notify; exit 0
fi

# Probe for qdbus-qt6 first (qt6-qttools package), then fall back to plain
# 'qdbus'.  The D-Bus wire protocol is language-agnostic so either binary
# works with Qt6 services; qdbus-qt6 is preferred to avoid a Qt4 dependency.
QDBUS=""
if command -v qdbus-qt6 &>/dev/null; then
    QDBUS="qdbus-qt6"
elif command -v qdbus &>/dev/null; then
    QDBUS="qdbus"
else
    >&2 echo "notify-with-focus-check: no qdbus binary found — install with: sudo dnf install qt6-qttools"
    _notify; exit 0
fi

# The D-Bus session bus address must be set.  Hooks launched by Claude Code
# may not inherit DBUS_SESSION_BUS_ADDRESS; without it all qdbus calls fail.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    >&2 echo "notify-with-focus-check: DBUS_SESSION_BUS_ADDRESS is unset — cannot reach session bus"
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

if [[ -z "$KONSOLE_PID" || "${#CHAIN_PIDS[@]}" -eq 0 ]]; then
    >&2 echo "notify-with-focus-check: ancestor konsole process not found"
    _notify; exit 0
fi

# ── Early kdotool check: is our Konsole the focused window? ───────────────────
# Running this check now — before any D-Bus calls — short-circuits the common
# case where the user is in another app.  If the active window is not our
# specific konsole instance, we fire immediately without querying Konsole's
# session/window objects at all.

ACTIVE_UUID=$(timeout 2 kdotool getactivewindow 2>/dev/null || true)

# Validate: non-empty and only alphanumeric/hyphen characters.
# kdotool returns a KWin window UUID string on Wayland.  Consistent with the
# integer validation applied to all qdbus return values below.
if [[ -z "$ACTIVE_UUID" || ! "$ACTIVE_UUID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    >&2 echo "notify-with-focus-check: kdotool returned no valid window identifier"
    _notify; exit 0
fi

ACTIVE_CLASS=$(timeout 2 kdotool getwindowclassname "$ACTIVE_UUID" 2>/dev/null || true)

if [[ "$ACTIVE_CLASS" != "org.kde.konsole" ]]; then
    # Focused window is not Konsole — user is in another application.
    _notify; exit 0
fi

ACTIVE_WIN_PID=$(timeout 2 kdotool getwindowpid "$ACTIVE_UUID" 2>/dev/null || true)

if [[ "$ACTIVE_WIN_PID" != "$KONSOLE_PID" ]]; then
    # Focused Konsole window belongs to a different konsole instance.
    _notify; exit 0
fi

# Our Konsole instance is the focused window.  Now check which tab is active.

# ── Locate Konsole's D-Bus service and cache its object list ───────────────────
# KDE names the service org.kde.konsole-<PID> when multiple instances exist.
# Constructing the name from KONSOLE_PID avoids listing all bus services.
# Fetching the full object list once means both the /Sessions/ and /Windows/
# queries below reuse the same data without extra D-Bus round-trips.

KONSOLE_SVC="org.kde.konsole-${KONSOLE_PID}"
KONSOLE_OBJECTS=$(timeout 2 "$QDBUS" "$KONSOLE_SVC" 2>/dev/null || true)

if [[ -z "$KONSOLE_OBJECTS" ]]; then
    # Fallback: a single Konsole instance may register without the PID suffix.
    # Before trusting the fallback, verify via the bus daemon that the service
    # belongs to our KONSOLE_PID — prevents a different konsole process from
    # suppressing this notification.
    KONSOLE_SVC="org.kde.konsole"
    KONSOLE_OBJECTS=$(timeout 2 "$QDBUS" "$KONSOLE_SVC" 2>/dev/null || true)

    if [[ -n "$KONSOLE_OBJECTS" ]]; then
        fallback_pid=$(timeout 2 "$QDBUS" org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus.GetConnectionUnixProcessID "$KONSOLE_SVC" 2>/dev/null || true)
        if [[ "$fallback_pid" != "$KONSOLE_PID" ]]; then
            >&2 echo "notify-with-focus-check: fallback D-Bus service PID ($fallback_pid) does not match konsole PID ($KONSOLE_PID)"
            _notify; exit 0
        fi
    fi
fi

if [[ -z "$KONSOLE_OBJECTS" ]]; then
    >&2 echo "notify-with-focus-check: could not reach Konsole D-Bus service for PID $KONSOLE_PID"
    _notify; exit 0
fi

# ── Find the Konsole session (tab) whose shell is in our process chain ─────────
# processId() returns the PID of the root shell in the tab's pty — somewhere
# in CHAIN_PIDS regardless of intermediate processes between the tab shell
# and this hook script.
#
# Both the session path and the returned PID are validated as integers before
# use, so a malformed D-Bus response cannot inject strings into the array key
# or into subsequent D-Bus path arguments.

OUR_SESSION_ID=""
while IFS= read -r sess_path; do
    [[ "$sess_path" =~ ^/Sessions/[0-9]+$ ]] || continue

    sess_shell_pid=$(timeout 2 "$QDBUS" "$KONSOLE_SVC" "$sess_path" \
        org.kde.konsole.Session.processId 2>/dev/null || true)
    [[ "$sess_shell_pid" =~ ^[0-9]+$ ]] || continue

    # ${arr[$key]+x} returns "x" if the key exists in the array, empty if not.
    if [[ -n "${CHAIN_PIDS[$sess_shell_pid]+x}" ]]; then
        OUR_SESSION_ID="${sess_path##*/}"   # strip /Sessions/ prefix, keep numeric ID
        break
    fi
done <<< "$KONSOLE_OBJECTS"

if [[ -z "$OUR_SESSION_ID" ]]; then
    >&2 echo "notify-with-focus-check: could not identify our Konsole session tab"
    _notify; exit 0
fi

# ── Check: is our tab the active tab in the focused Konsole window? ────────────
# We already confirmed the focused window is our Konsole instance (early check
# above).  Now verify our session is currentSession() of at least one window —
# i.e. our specific tab is the one visible in the foreground.

while IFS= read -r win_path; do
    [[ "$win_path" =~ ^/Windows/[0-9]+$ ]] || continue

    current_sess=$(timeout 2 "$QDBUS" "$KONSOLE_SVC" "$win_path" \
        org.kde.konsole.Window.currentSession 2>/dev/null || true)
    [[ "$current_sess" =~ ^[0-9]+$ ]] || continue

    if [[ "$current_sess" == "$OUR_SESSION_ID" ]]; then
        exit 0   # Our tab is the active tab in the focused Konsole — suppress
    fi
done <<< "$KONSOLE_OBJECTS"

# ── Notify ────────────────────────────────────────────────────────────────────
_notify
