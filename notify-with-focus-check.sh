#!/usr/bin/env bash
set -u
#
# notify-with-focus-check.sh — Claude Code Notification hook
#
# Shows a desktop notification and plays a chime when Claude is waiting
# for user input, but skips both if the Konsole tab that triggered this
# hook is currently the visible tab in the focused Konsole window.
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
#   timeout                            (GNU coreutils — present by default on all
#                                       standard Fedora installs; only absent in
#                                       stripped or minimal container environments)
#   notify-send                        (libnotify — present on standard KDE Plasma)
#   paplay                             (pulseaudio-utils — present on standard Fedora)

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

# ── Notify-with-click-to-focus helper ─────────────────────────────────────────
# Called at every exit point after KONSOLE_PID is identified — including early
# exits where the user is in a different app entirely.
#
# Sends a desktop notification with a "Focus Claude" action button and plays the
# chime immediately.  A background subshell waits (via notify-send --wait) for
# the user to click the action button; on click it:
#   1. Finds the Konsole window UUID — uses ACTIVE_UUID if it already belongs
#      to our Konsole instance (PID matches), otherwise searches via kdotool.
#   2. Lazily fetches KONSOLE_SVC / KONSOLE_OBJECTS if not already set —
#      needed when called from early exits before D-Bus queries ran.
#   3. Lazily finds OUR_SESSION_ID by walking the session list — needed at
#      the same early exits where the tab walk had not yet run.
#   4. Calls setCurrentSession on every Konsole window — only the window that
#      owns our session ID responds, switching to the Claude tab.
#   5. Calls kdotool windowactivate to raise the Konsole window to the
#      foreground (Wayland-native; routes through KWin's D-Bus API).
#
# The subshell is immediately disowned so the main script exits without waiting
# for notification dismissal or click — Claude Code continues unblocked.
#
# Requires: libnotify >= 0.7.8 for --action / --wait flags (standard on KDE
#   Plasma; verify with: notify-send --version).
# Globals read (all required at call site; inherited by subshell automatically):
#   KONSOLE_PID  – PID of the ancestor konsole process
#   QDBUS        – path to qdbus-qt6 or qdbus
#   CHAIN_PIDS   – associative array of PIDs in our process chain
# Globals read lazily (used if set, fetched fresh if not):
#   ACTIVE_UUID  – KWin UUID of the window active at hook invocation time
_notify_clickable() {
    (
        # --wait blocks until the notification is dismissed or an action is
        # clicked.  On click, notify-send prints the action key ("focus") to
        # stdout and exits 0.  On dismiss with no click, it prints nothing and
        # exits non-zero.  '|| true' prevents a non-zero exit from killing the
        # subshell so we continue to the early exit below.
        action=$(notify-send \
            --app-name="Claude Code" \
            --icon=dialog-information \
            --urgency=normal \
            --action="focus=Focus Claude" \
            --wait \
            "Claude Code" \
            "Waiting for your input" 2>/dev/null || true)

        [[ "$action" != "focus" ]] && exit 0

        # ── Step 1: Find the Konsole window UUID ──────────────────────────────
        # Use ACTIVE_UUID if it is already our Konsole instance; otherwise
        # search all windows for the one whose PID matches KONSOLE_PID.
        konsole_uuid=""
        active="${ACTIVE_UUID:-}"
        if [[ -n "$active" ]] && \
           [[ "$active" =~ ^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$ ]]; then
            active_class=$(kdotool getwindowclassname "$active" 2>/dev/null || true)
            if [[ "$active_class" == "org.kde.konsole" ]]; then
                active_pid=$(kdotool getwindowpid "$active" 2>/dev/null || true)
                [[ "$active_pid" == "$KONSOLE_PID" ]] && konsole_uuid="$active"
            fi
        fi
        if [[ -z "$konsole_uuid" ]]; then
            # Active window was not our Konsole — search for it by PID.
            # 'kdotool search konsole' lists all Konsole window UUIDs; we pick
            # the one whose PID matches KONSOLE_PID so multi-instance setups
            # always target the correct window.
            while IFS= read -r candidate; do
                [[ "$candidate" =~ ^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$ ]] \
                    || continue
                win_pid=$(kdotool getwindowpid "$candidate" 2>/dev/null || true)
                if [[ "$win_pid" == "$KONSOLE_PID" ]]; then
                    konsole_uuid="$candidate"
                    break
                fi
            done < <(kdotool search konsole 2>/dev/null || true)
        fi

        # ── Step 2: Fetch D-Bus service and object list ───────────────────────
        # Always construct from KONSOLE_PID so we target our specific instance,
        # not a stale or mismatched cached value from an early-exit code path.
        konsole_svc="org.kde.konsole-${KONSOLE_PID}"
        konsole_objects=$(timeout 2 "$QDBUS" "$konsole_svc" 2>/dev/null || true)
        if [[ -z "$konsole_objects" ]]; then
            konsole_svc="org.kde.konsole"
            konsole_objects=$(timeout 2 "$QDBUS" "$konsole_svc" 2>/dev/null || true)
        fi

        # ── Step 3: Find our session ID ───────────────────────────────────────
        # Walk /Sessions/* objects and match the one whose shell PID is in
        # CHAIN_PIDS — the same walk the main script does, repeated here for
        # exit paths that ran before the main walk completed.
        our_session=""
        if [[ -n "$konsole_objects" ]]; then
            while IFS= read -r sess_path; do
                [[ "$sess_path" =~ ^/Sessions/[0-9]+$ ]] || continue
                sess_pid=$(timeout 2 "$QDBUS" "$konsole_svc" "$sess_path" \
                    org.kde.konsole.Session.processId 2>/dev/null || true)
                [[ "$sess_pid" =~ ^[0-9]+$ ]] || continue
                if [[ -n "${CHAIN_PIDS[$sess_pid]+x}" ]]; then
                    our_session="${sess_path##*/}"
                    break
                fi
            done <<< "$konsole_objects"
        fi

        # ── Step 4: Switch to our tab ─────────────────────────────────────────
        # Calling setCurrentSession on every window is safe: windows that do
        # not own our session ID silently ignore it.
        if [[ -n "$our_session" && -n "$konsole_objects" ]]; then
            while IFS= read -r win_path; do
                [[ "$win_path" =~ ^/Windows/[0-9]+$ ]] || continue
                "$QDBUS" "$konsole_svc" "$win_path" \
                    org.kde.konsole.Window.setCurrentSession "$our_session" \
                    2>/dev/null || true
            done <<< "$konsole_objects"
        fi

        # ── Step 5: Raise and focus Konsole ───────────────────────────────────
        [[ -n "$konsole_uuid" ]] && kdotool windowactivate "$konsole_uuid" 2>/dev/null || true
    ) &
    disown $!

    # Play chime immediately — do not wait for the background click handler.
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

# timeout (GNU coreutils) wraps every qdbus call to cap per-call latency at
# 2 seconds.  Present on all standard Linux installations; guard here so a
# missing binary produces an actionable error rather than silently converting
# every D-Bus call into an empty string and failing with a misleading
# "could not reach Konsole D-Bus service" message.
if ! command -v timeout &>/dev/null; then
    >&2 echo "notify-with-focus-check: timeout not found — install with: sudo dnf install coreutils"
    _notify; exit 0
fi

# ── Global timeout watchdog ────────────────────────────────────────────────────
# Cap total runtime at 30 seconds.  Each qdbus call has a 2-second timeout;
# the worst-case D-Bus stack is (3 + N + M) × 2 seconds where N is the
# number of Konsole session tabs and M is the number of Konsole windows
# (3 = primary lookup + fallback lookup + PID verification).  kdotool calls
# have no per-call timeout — they are fast in practice; this watchdog is
# the backstop if KWin becomes unresponsive.  The EXIT trap cleans it up
# on normal exit so there is no orphan sleep process.
# Note: $$ inside ( ... ) & correctly refers to this script's PID in bash
# (POSIX-specified — $$ is not re-evaluated in subshells).
( sleep 30; kill $$ 2>/dev/null ) &   # 'kill' without -s sends SIGTERM by default
_WATCHDOG_PID=$!
trap 'kill "$_WATCHDOG_PID" 2>/dev/null' EXIT
# If the watchdog fires (KWin unresponsive for 30 s), its SIGTERM is caught here.
# Call _notify before dying so the user still gets a notification in that failure mode.
trap '_notify; exit 0' TERM

# ── Walk process tree from $$ up to konsole ───────────────────────────────────
# A single pass builds CHAIN_PIDS and locates KONSOLE_PID simultaneously,
# avoiding the double-walk the naive find+loop approach would require.
#
# _NOTIFY_PROC_ROOT defaults to /proc; override in tests to use a fake directory.
# _START_PID defaults to $$; override in tests to use a fake starting PID.
_NOTIFY_PROC_ROOT="${_NOTIFY_PROC_ROOT:-/proc}"

declare -A CHAIN_PIDS
KONSOLE_PID=""
pid="${_START_PID:-$$}"

while [[ "$pid" -gt 1 ]]; do
    # Read process name via bash built-in — no cat fork.
    comm=""
    [[ -f "${_NOTIFY_PROC_ROOT}/$pid/comm" ]] && read -r comm < "${_NOTIFY_PROC_ROOT}/$pid/comm"

    if [[ "$comm" == "konsole" ]]; then
        KONSOLE_PID="$pid"
        # Do NOT record KONSOLE_PID in CHAIN_PIDS.  We match against the shell
        # PIDs that konsole spawns (between konsole and this script), not
        # konsole itself.  This is intentional — see session loop below.
        break
    fi

    # Record this PID in the chain before stepping up.
    CHAIN_PIDS["$pid"]=1

    # Read the parent PID from /proc/status via bash built-in — no awk fork.
    next_pid=""
    if [[ -f "${_NOTIFY_PROC_ROOT}/$pid/status" ]]; then
        # IFS=$' \t' splits each line on spaces and tabs.  $'...' is ANSI-C
        # quoting — the only portable way to embed a literal tab in a string
        # without a subshell.  The trailing _ absorbs extra fields so key
        # and val are always single tokens.
        while IFS=$' \t' read -r key val _; do
            if [[ "$key" == "PPid:" ]]; then
                next_pid="${val//[^0-9]/}"   # ${var//pat/} removes all matches; [^0-9] = any non-digit
                break
            fi
        done < "${_NOTIFY_PROC_ROOT}/$pid/status"
    fi

    [[ -z "$next_pid" || "$next_pid" -le 1 ]] && break
    pid="$next_pid"
done

# ${CHAIN_PIDS[*]+x} returns "x" when the array has at least one entry, empty string
# when it has none.  The [*] subscript expands to all values space-joined; an empty
# expansion is treated as unset by the +word operator, so the result is "".  This
# avoids a bash 5.3 bug where ${#assoc[@]} raises "unbound variable" for a
# declared-but-empty associative array under set -u; the +word form is safe even
# for empty declared arrays.
if [[ -z "$KONSOLE_PID" || -z "${CHAIN_PIDS[*]+x}" ]]; then
    >&2 echo "notify-with-focus-check: ancestor konsole process not found"
    _notify; exit 0
fi

# ── Early kdotool check: is our Konsole the focused window? ───────────────────
# Running this check now — before any D-Bus calls — short-circuits the common
# case where the user is in another app.  If the active window is not our
# specific konsole instance, we fire immediately without querying Konsole's
# session/window objects at all.

ACTIVE_UUID=$(kdotool getactivewindow 2>/dev/null || true)

# Validate: non-empty and matching KWin's UUID format on Wayland.
# kdotool returns window IDs as {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx} with
# curly braces — NOT a bare UUID.  The regex requires the braces explicitly;
# a bare UUID (no braces) or any other format is rejected as invalid.
if [[ -z "$ACTIVE_UUID" || ! "$ACTIVE_UUID" =~ ^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$ ]]; then
    >&2 echo "notify-with-focus-check: kdotool returned no valid window identifier"
    _notify_clickable; exit 0
fi

ACTIVE_CLASS=$(kdotool getwindowclassname "$ACTIVE_UUID" 2>/dev/null || true)

if [[ "$ACTIVE_CLASS" != "org.kde.konsole" ]]; then
    >&2 echo "notify-with-focus-check: active window class is not Konsole ($ACTIVE_CLASS)"
    _notify_clickable; exit 0
fi

ACTIVE_WIN_PID=$(kdotool getwindowpid "$ACTIVE_UUID" 2>/dev/null || true)

if [[ ! "$ACTIVE_WIN_PID" =~ ^[0-9]+$ ]]; then
    >&2 echo "notify-with-focus-check: kdotool getwindowpid returned non-integer ($ACTIVE_WIN_PID)"
    _notify_clickable; exit 0
fi

if [[ "$ACTIVE_WIN_PID" != "$KONSOLE_PID" ]]; then
    >&2 echo "notify-with-focus-check: active window PID ($ACTIVE_WIN_PID) does not match konsole PID ($KONSOLE_PID)"
    _notify_clickable; exit 0
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
        if [[ ! "$fallback_pid" =~ ^[0-9]+$ ]]; then
            >&2 echo "notify-with-focus-check: fallback D-Bus service returned non-integer PID ($fallback_pid)"
            _notify_clickable; exit 0
        fi
        if [[ "$fallback_pid" != "$KONSOLE_PID" ]]; then
            >&2 echo "notify-with-focus-check: fallback D-Bus service PID ($fallback_pid) does not match konsole PID ($KONSOLE_PID)"
            _notify_clickable; exit 0
        fi
    fi
fi

if [[ -z "$KONSOLE_OBJECTS" ]]; then
    >&2 echo "notify-with-focus-check: could not reach Konsole D-Bus service for PID $KONSOLE_PID"
    _notify_clickable; exit 0
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
    _notify_clickable; exit 0
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

# ── Notify with click-to-focus ────────────────────────────────────────────────
# Reached when our tab exists but is not the current tab in any focused window.
# All prior checks confirmed Konsole is focused — our tab simply isn't the
# visible one.  The "Focus Claude" action button in the notification raises our
# tab and brings the Konsole window to the foreground when clicked.
_notify_clickable; exit 0
