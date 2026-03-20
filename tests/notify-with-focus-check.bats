#!/usr/bin/env bats
# Tests for notify-with-focus-check.sh
#
# Run with:  bats tests/notify-with-focus-check.bats
# Requires:  sudo dnf install bats
#
# All external binaries (kdotool, qdbus-qt6, notify-send, paplay) are mocked
# via PATH prepend.  Process-tree walks use _NOTIFY_PROC_ROOT + _START_PID so tests
# never depend on running inside a real Konsole session.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/notify-with-focus-check.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Write content to a file, creating parent dirs as needed.
write_file() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

# Create fake /proc entries for one PID: comm file and status with PPid.
# Usage: fake_proc <proc_root> <pid> <comm> <ppid>
fake_proc() {
    local root="$1" pid="$2" comm="$3" ppid="$4"
    write_file "${root}/${pid}/comm" "${comm}"
    printf 'Name:\t%s\nPPid:\t%s\n' "$comm" "$ppid" > "${root}/${pid}/status"
}

# True if the notify-send sentinel was written (meaning _notify ran).
notify_fired()     { [[ -f "$BATS_TMPDIR/notify-fired" ]]; }
notify_suppressed() { ! notify_fired; }

# ── Setup / teardown ──────────────────────────────────────────────────────────

setup() {
    # Temp bin dir prepended to PATH — mocks shadow system binaries.
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # Temp fake /proc root.
    FAKE_PROC="$(mktemp -d)"
    export _NOTIFY_PROC_ROOT="$FAKE_PROC"

    rm -f "$BATS_TMPDIR/notify-fired"

    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"

    # --- sleep shim -----------------------------------------------------------
    # Required so the watchdog inside the script works even when tests run with
    # a restricted PATH that doesn't include /usr/bin.  Plain passthrough.
    write_file "$MOCK_BIN/sleep" '#!/bin/bash
exec /usr/bin/sleep "$@"'
    chmod +x "$MOCK_BIN/sleep"

    # --- notify-send mock -----------------------------------------------------
    write_file "$MOCK_BIN/notify-send" "#!/bin/bash
# Use a bash builtin redirect instead of touch to avoid PATH dependency.
: > '$BATS_TMPDIR/notify-fired'"
    chmod +x "$MOCK_BIN/notify-send"

    # --- paplay mock ----------------------------------------------------------
    write_file "$MOCK_BIN/paplay" '#!/bin/bash
exit 0'
    chmod +x "$MOCK_BIN/paplay"

    # --- kdotool mock ---------------------------------------------------------
    # Reads MOCK_KDOTOOL_UUID / _CLASS / _PID from the environment; values are
    # set in setup() below (not using :- inside the mock to avoid issues when
    # tests intentionally export an empty string).
    write_file "$MOCK_BIN/kdotool" '#!/bin/bash
case "${1:-}" in
    getactivewindow)    echo "$MOCK_KDOTOOL_UUID" ;;
    getwindowclassname) echo "$MOCK_KDOTOOL_CLASS" ;;
    getwindowpid)       echo "$MOCK_KDOTOOL_PID" ;;
esac'
    chmod +x "$MOCK_BIN/kdotool"

    # kdotool defaults — tests override as needed.
    export MOCK_KDOTOOL_UUID="{4bb44a33-a5d6-4cca-9bb9-10bc9a3ec0f5}"
    export MOCK_KDOTOOL_CLASS="org.kde.konsole"
    export MOCK_KDOTOOL_PID="3000"

    # --- qdbus-qt6 mock -------------------------------------------------------
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "%s\n" $MOCK_OBJECTS
        elif [[ "$OBJ" == /Sessions/* ]]; then
            echo "$MOCK_SESSION_PID"
        elif [[ "$OBJ" == /Windows/* ]]; then
            echo "$MOCK_CURRENT_SESSION"
        fi
        ;;
    org.freedesktop.DBus)
        echo "$MOCK_FALLBACK_PID"
        ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"

    # qdbus-qt6 defaults.
    export MOCK_OBJECTS="/Sessions/1 /Windows/1"
    export MOCK_SESSION_PID="4000"
    export MOCK_CURRENT_SESSION="1"
    export MOCK_FALLBACK_PID="3000"

    # --- Default fake process tree -------------------------------------------
    # 5000 (bash) → 4000 (node) → 3000 (konsole)
    # KONSOLE_PID = 3000;  CHAIN_PIDS = {5000, 4000}
    # MOCK_SESSION_PID=4000 → in CHAIN_PIDS → session found
    # MOCK_KDOTOOL_PID=3000 → matches KONSOLE_PID → same window
    # MOCK_CURRENT_SESSION=1 → matches OUR_SESSION_ID → suppressed
    fake_proc "$FAKE_PROC" 5000 "bash"    4000
    fake_proc "$FAKE_PROC" 4000 "node"    3000
    fake_proc "$FAKE_PROC" 3000 "konsole" 1
    export _START_PID=5000
}

teardown() {
    rm -rf "$MOCK_BIN" "$FAKE_PROC"
    rm -f "$BATS_TMPDIR/notify-fired"
}

# ── Prerequisite / early-exit tests ──────────────────────────────────────────
# Tests 01–03 exit before the watchdog is set up, so the restricted PATH used
# by 01 and 02 does not cause issues with the watchdog's sleep call.
# Test 04 runs past the watchdog setup (it fails during the proc-tree walk);
# the sleep shim in MOCK_BIN handles the watchdog's sleep call correctly.

@test "01: kdotool not in PATH → _notify fires" {
    # Remove kdotool from MOCK_BIN, then run with PATH limited to MOCK_BIN so
    # the system kdotool (in /usr/bin) is also hidden.  notify-send, paplay,
    # and sleep shims are still present so _notify() and the env can function.
    rm -f "$MOCK_BIN/kdotool"
    run env -i \
        "PATH=$MOCK_BIN" \
        "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        "_NOTIFY_PROC_ROOT=$_NOTIFY_PROC_ROOT" \
        "_START_PID=$_START_PID" \
        /usr/bin/bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"kdotool not found"* ]]
}

@test "02: no qdbus binary found → _notify fires" {
    rm -f "$MOCK_BIN/qdbus-qt6"
    # kdotool IS present in MOCK_BIN; qdbus-qt6 and qdbus are not.
    run env -i \
        "PATH=$MOCK_BIN" \
        "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        "_NOTIFY_PROC_ROOT=$_NOTIFY_PROC_ROOT" \
        "_START_PID=$_START_PID" \
        /usr/bin/bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"no qdbus binary found"* ]]
}

@test "03: DBUS_SESSION_BUS_ADDRESS unset → _notify fires" {
    run env -u DBUS_SESSION_BUS_ADDRESS bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"DBUS_SESSION_BUS_ADDRESS is unset"* ]]
}

@test "04: no ancestor konsole process in tree → _notify fires" {
    # Rewrite tree: 5000 → 4000 → 1 (init); loop terminates without finding konsole.
    fake_proc "$FAKE_PROC" 5000 "bash" 4000
    fake_proc "$FAKE_PROC" 4000 "node" 1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"ancestor konsole process not found"* ]]
}

@test "05: kdotool getactivewindow returns empty → _notify fires" {
    export MOCK_KDOTOOL_UUID=""
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"kdotool returned no valid window identifier"* ]]
}

@test "06: kdotool getactivewindow returns malformed output → _notify fires" {
    export MOCK_KDOTOOL_UUID="not-a-valid-uuid"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"kdotool returned no valid window identifier"* ]]
}

# ── UUID regex tests (direct, no script invocation) ───────────────────────────
# These validate the regex independently of the rest of the script, which is
# cleaner and avoids mock complexity for what is a pure string-matching test.

@test "11: UUID regex matches KWin braced format" {
    local uuid="{4bb44a33-a5d6-4cca-9bb9-10bc9a3ec0f5}"
    local regex='^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$'
    [[ "$uuid" =~ $regex ]]
}

@test "12: UUID regex rejects bare UUID without braces" {
    local uuid="4bb44a33-a5d6-4cca-9bb9-10bc9a3ec0f5"
    local regex='^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$'
    ! [[ "$uuid" =~ $regex ]]
}

@test "12b: UUID regex rejects empty string" {
    local uuid=""
    local regex='^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$'
    ! [[ "$uuid" =~ $regex ]]
}

@test "12c: UUID regex rejects shell injection attempt" {
    local uuid="{4bb44a33-a5d6-4cca-9bb9-10bc9a3ec0f5}; rm -rf /"
    local regex='^\{[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}$'
    ! [[ "$uuid" =~ $regex ]]
}

# ── Focus / window detection tests ───────────────────────────────────────────

@test "07: active window class is not org.kde.konsole → _notify fires" {
    export MOCK_KDOTOOL_CLASS="com.example.otherapp"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

@test "08: active window PID does not match KONSOLE_PID → _notify fires" {
    export MOCK_KDOTOOL_PID="9999"   # KONSOLE_PID is 3000
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

@test "09: Konsole D-Bus service unreachable → _notify fires" {
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
exit 1'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"could not reach Konsole D-Bus service"* ]]
}

@test "10: fallback D-Bus PID mismatch → _notify fires" {
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole-*)  exit 1 ;;                          # primary: not found
    org.kde.konsole)
        [[ -z "$OBJ" ]] && printf "/Sessions/1\n/Windows/1\n"  # fallback: exists
        ;;
    org.freedesktop.DBus)
        echo "9999"   # wrong PID — does not match KONSOLE_PID (3000)
        ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"fallback D-Bus service PID"*"does not match"* ]]
}

# ── Session / tab detection tests ─────────────────────────────────────────────

@test "13: no /Sessions/N objects in D-Bus output → _notify fires" {
    export MOCK_OBJECTS="/Windows/1 /MainWindow/1"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"could not identify our Konsole session tab"* ]]
}

@test "14: session processId not in CHAIN_PIDS → _notify fires" {
    export MOCK_SESSION_PID="99999"   # not in {5000, 4000}
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"could not identify our Konsole session tab"* ]]
}

@test "15: session processId returns non-integer → session skipped, _notify fires" {
    export MOCK_SESSION_PID="not-a-number"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"could not identify our Konsole session tab"* ]]
}

@test "16: processId in CHAIN_PIDS → OUR_SESSION_ID set, proceeds to window check" {
    # MOCK_SESSION_PID=4000 is in CHAIN_PIDS by default; should not error here.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"could not identify our Konsole session tab"* ]]
}

# ── Current-tab / suppress decision tests ─────────────────────────────────────

@test "17: our session IS currentSession of focused window → suppressed" {
    # MOCK_CURRENT_SESSION=1, OUR_SESSION_ID will be "1" — they match.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

@test "18: our session is NOT currentSession of any window → _notify fires" {
    export MOCK_CURRENT_SESSION="2"   # OUR_SESSION_ID is "1"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

@test "19: currentSession returns non-integer → window skipped, _notify fires" {
    export MOCK_CURRENT_SESSION="bad-value"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

@test "20: active in window 2 but not window 1 → suppressed" {
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Windows/1\n/Windows/2\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "4000"   # in CHAIN_PIDS
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "2"      # wrong session
        elif [[ "$OBJ" == /Windows/2 ]]; then
            echo "1"      # our session
        fi
        ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

# ── Process tree walk tests ───────────────────────────────────────────────────

@test "21: konsole is direct parent → KONSOLE_PID found, no tree-walk error" {
    fake_proc "$FAKE_PROC" 7000 "bash"    6000
    fake_proc "$FAKE_PROC" 6000 "konsole" 1
    export _START_PID=7000
    export MOCK_KDOTOOL_PID="6000"   # matches new KONSOLE_PID
    export MOCK_SESSION_PID="7000"   # 7000 is in CHAIN_PIDS
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ancestor konsole process not found"* ]]
}

@test "22: konsole is 5 levels up in tree → KONSOLE_PID still found" {
    fake_proc "$FAKE_PROC" 9005 "bash"    9004
    fake_proc "$FAKE_PROC" 9004 "node"    9003
    fake_proc "$FAKE_PROC" 9003 "python"  9002
    fake_proc "$FAKE_PROC" 9002 "perl"    9001
    fake_proc "$FAKE_PROC" 9001 "ruby"    9000
    fake_proc "$FAKE_PROC" 9000 "konsole" 1
    export _START_PID=9005
    export MOCK_KDOTOOL_PID="9000"
    export MOCK_SESSION_PID="9004"   # 9004 is in CHAIN_PIDS
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ancestor konsole process not found"* ]]
}
