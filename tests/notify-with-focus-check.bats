#!/usr/bin/env bats
# Tests for notify-with-focus-check.sh
#
# Run with:  bats tests/notify-with-focus-check.bats
# Requires:  sudo dnf install bats
#
# All external binaries (kdotool, qdbus-qt6, timeout, notify-send, paplay) are
# mocked via PATH prepend.  Process-tree walks use _NOTIFY_PROC_ROOT + _START_PID
# so tests never depend on running inside a real Konsole session.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/notify-with-focus-check.sh"

# ── Helpers ─────────────────────────────────────────────────────────────────────────────

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
notify_fired()     { [[ -f "$MOCK_BIN/notify-fired" ]]; }
notify_suppressed() { ! notify_fired; }

# ── Setup / teardown ───────────────────────────────────────────────────────────

setup() {
    # Temp bin dir prepended to PATH — mocks shadow system binaries.
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"

    # Temp fake /proc root.
    FAKE_PROC="$(mktemp -d)"
    export _NOTIFY_PROC_ROOT="$FAKE_PROC"

    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"

    # --- sleep shim -----------------------------------------------------------
    # Required so the watchdog inside the script works even when tests run with
    # a restricted PATH that doesn't include /usr/bin.  Plain passthrough.
    write_file "$MOCK_BIN/sleep" '#!/bin/bash
exec /usr/bin/sleep "$@"'
    chmod +x "$MOCK_BIN/sleep"

    # --- notify-send mock -----------------------------------------------------
    # Sentinel path is baked in as a literal string (MOCK_BIN expanded at setup
    # time).  Using MOCK_BIN (unique per-test mktemp dir) rather than BATS_TMPDIR
    # (shared across all tests in a suite run) prevents cross-test contamination.
    write_file "$MOCK_BIN/notify-send" "#!/bin/bash
: > '$MOCK_BIN/notify-fired'"
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
    # Sentinel ($MOCK_BIN/notify-fired) is removed as part of rm -rf $MOCK_BIN.
}

# ── Prerequisite / early-exit tests ────────────────────────────────────────────
# Tests 01–03 exit before the watchdog is set up, so the restricted PATH used
# by 01, 02, and 02c does not cause issues with the watchdog's sleep call.
# Test 02b also uses restricted PATH but runs the full script — it installs
# a timeout shim so the watchdog and qdbus timeout calls work under env -i.
# Test 02c hides timeout but exits at the prerequisite check, before watchdog.
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

@test "02b: qdbus fallback (no qdbus-qt6) → proceeds and suppresses" {
    # When qdbus-qt6 is absent but plain qdbus is present, the script should
    # set QDBUS="qdbus" and proceed to the suppress outcome normally.
    # env -i is required so the system /usr/bin/qdbus-qt6 is also hidden.
    rm -f "$MOCK_BIN/qdbus-qt6"

    # timeout shim: qdbus calls use 'timeout 2 qdbus ...' and /usr/bin/timeout
    # is not on the restricted PATH, so provide a passthrough shim.
    write_file "$MOCK_BIN/timeout" '#!/bin/bash
exec /usr/bin/timeout "$@"'
    chmod +x "$MOCK_BIN/timeout"

    # qdbus mock: same contract as the qdbus-qt6 mock in setup().
    write_file "$MOCK_BIN/qdbus" '#!/bin/bash
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
    chmod +x "$MOCK_BIN/qdbus"

    run env -i \
        "PATH=$MOCK_BIN" \
        "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        "_NOTIFY_PROC_ROOT=$_NOTIFY_PROC_ROOT" \
        "_START_PID=$_START_PID" \
        "MOCK_OBJECTS=$MOCK_OBJECTS" \
        "MOCK_SESSION_PID=$MOCK_SESSION_PID" \
        "MOCK_CURRENT_SESSION=$MOCK_CURRENT_SESSION" \
        "MOCK_FALLBACK_PID=$MOCK_FALLBACK_PID" \
        "MOCK_KDOTOOL_UUID=$MOCK_KDOTOOL_UUID" \
        "MOCK_KDOTOOL_CLASS=$MOCK_KDOTOOL_CLASS" \
        "MOCK_KDOTOOL_PID=$MOCK_KDOTOOL_PID" \
        /usr/bin/bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

@test "02c: timeout not in PATH → _notify fires" {
    # The timeout prerequisite check fires before the watchdog is set up, so
    # a restricted PATH without timeout exits cleanly without needing a sleep shim.
    # kdotool and qdbus-qt6 are still in MOCK_BIN so the script passes those
    # checks before reaching the timeout guard.
    run env -i \
        "PATH=$MOCK_BIN" \
        "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
        "_NOTIFY_PROC_ROOT=$_NOTIFY_PROC_ROOT" \
        "_START_PID=$_START_PID" \
        /usr/bin/bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"timeout not found"* ]]
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

# ── UUID regex tests (direct, no script invocation) ─────────────────────────────
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

# ── Focus / window detection tests ─────────────────────────────────────────────

@test "07: active window class is not org.kde.konsole → _notify fires" {
    export MOCK_KDOTOOL_CLASS="com.example.otherapp"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"active window class is not Konsole"* ]]
}

@test "08: active window PID does not match KONSOLE_PID → _notify fires" {
    export MOCK_KDOTOOL_PID="9999"   # KONSOLE_PID is 3000
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"active window PID"*"does not match konsole PID"* ]]
}

@test "08b: kdotool getwindowpid returns non-integer → _notify fires" {
    # The integer validation checks ^[0-9]+$ before comparing to KONSOLE_PID.
    # Test 08 covers a numeric-but-mismatched PID.  This test covers the
    # non-integer branch: the regex fails and the script fires _notify with a
    # distinct "non-integer" message, before reaching any D-Bus session logic.
    export MOCK_KDOTOOL_PID="not-a-number"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"kdotool getwindowpid returned non-integer"* ]]
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

@test "10b: fallback D-Bus PID is non-integer → _notify fires" {
    # Exercises the non-integer branch of the fallback PID check.
    # Test 10 covers a numeric-but-wrong PID (9999).  This test has
    # org.freedesktop.DBus return an empty string so fallback_pid="" fails the
    # ^[0-9]+$ regex, producing the distinct "non-integer PID" message.
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole-*)  exit 1 ;;
    org.kde.konsole)
        [[ -z "$OBJ" ]] && printf "/Sessions/1\n/Windows/1\n"
        ;;
    org.freedesktop.DBus)
        echo ""
        ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"fallback D-Bus service returned non-integer PID"* ]]
}

# ── Session / tab detection tests ───────────────────────────────────────────────

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

# ── Current-tab / suppress decision tests ─────────────────────────────────────────

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

# ── Process tree walk tests ──────────────────────────────────────────────────────

@test "21: konsole is direct parent → KONSOLE_PID found, no tree-walk error" {
    fake_proc "$FAKE_PROC" 7000 "bash"    6000
    fake_proc "$FAKE_PROC" 6000 "konsole" 1
    export _START_PID=7000
    export MOCK_KDOTOOL_PID="6000"   # matches new KONSOLE_PID
    export MOCK_SESSION_PID="7000"   # 7000 is in CHAIN_PIDS
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ancestor konsole process not found"* ]]
    notify_suppressed
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
    notify_suppressed
}

# ── Additional coverage for identified branch gaps ─────────────────────────────

@test "23: _START_PID is konsole itself → CHAIN_PIDS empty → _notify fires" {
    # When _START_PID points directly at the konsole process, the walk finds
    # "konsole" on the very first iteration and breaks before recording anything
    # into CHAIN_PIDS.  KONSOLE_PID is set to 3000, but CHAIN_PIDS has zero
    # entries, so the guard -z "${CHAIN_PIDS[*]+x}" fires and calls _notify.
    export _START_PID=3000   # default fake proc tree has 3000 as "konsole"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    [[ "$output" == *"ancestor konsole process not found"* ]]
}

# ── Fallback D-Bus path: full end-to-end ───────────────────────────────────────────
# Tests 10 and 10b exercise the fallback PID mismatch branches (early exit).
# Test 09 makes both the primary and fallback services return empty.
# These two tests are the first where the fallback path succeeds all the way
# through PID verification and into the session/window loops.

@test "24: primary D-Bus service fails, fallback succeeds with matching PID → suppressed" {
    # 1. org.kde.konsole-3000 returns empty (primary not registered)
    # 2. org.kde.konsole returns objects (fallback registered)
    # 3. GetConnectionUnixProcessID returns 3000 (matches KONSOLE_PID)
    # 4. /Sessions/1 processId = 4000 (in CHAIN_PIDS)
    # 5. /Windows/1 currentSession = 1 (our session) → suppress
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole-*)  exit 0 ;;   # primary: empty, not registered
    org.kde.konsole)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Windows/1\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "4000"   # in CHAIN_PIDS {5000,4000}
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "1"      # matches OUR_SESSION_ID "1"
        fi ;;
    org.freedesktop.DBus)
        echo "3000" ;;    # matches KONSOLE_PID
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

@test "25: primary D-Bus fails, fallback succeeds, tab is background → _notify fires" {
    # Same fallback path as test 24 but currentSession differs — our tab is not active.
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole-*)  exit 0 ;;
    org.kde.konsole)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Windows/1\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "4000"
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "2"   # currentSession 2 ≠ OUR_SESSION_ID "1"
        fi ;;
    org.freedesktop.DBus)
        echo "3000" ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

# ── Session loop: skip-then-find ────────────────────────────────────────────────────
# Tests 14 and 15 exhaust the session loop with no match.  These two tests are
# the first where the loop skips one session and then correctly finds another.

@test "26: two sessions, first PID not in CHAIN_PIDS, second is → suppressed" {
    # /Sessions/1 processId=99999 (not in chain) → continue
    # /Sessions/2 processId=4000  (in chain)     → OUR_SESSION_ID="2"
    # /Windows/1  currentSession=2               → suppress
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Sessions/2\n/Windows/1\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "99999"   # not in CHAIN_PIDS
        elif [[ "$OBJ" == /Sessions/2 ]]; then
            echo "4000"    # in CHAIN_PIDS
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "2"       # matches OUR_SESSION_ID "2"
        fi ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

@test "27: two sessions, first skipped, second found, tab is background → _notify fires" {
    # Same session-skip-then-find as test 26 but our tab is not the active one.
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Sessions/2\n/Windows/1\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "99999"
        elif [[ "$OBJ" == /Sessions/2 ]]; then
            echo "4000"
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "1"   # currentSession 1 ≠ OUR_SESSION_ID "2"
        fi ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

# ── Window loop: malformed path is skipped ─────────────────────────────────────────
# The window loop guards each path with [[ "$win_path" =~ ^/Windows/[0-9]+$ ]].
# No previous test reaches the window loop with a malformed window path in the
# objects list.

@test "28: malformed window path is skipped, valid window still suppresses" {
    # /Windows/foo fails ^/Windows/[0-9]+$ and is skipped.
    # /Windows/1 is still checked and matches OUR_SESSION_ID → suppress.
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Windows/foo\n/Windows/1\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "4000"
        elif [[ "$OBJ" == /Windows/1 ]]; then
            echo "1"   # matches OUR_SESSION_ID "1"
        fi ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_suppressed
}

@test "29: all window paths malformed → loop body never runs, _notify fires" {
    # Every window path fails the regex; the loop exits without suppressing.
    write_file "$MOCK_BIN/qdbus-qt6" '#!/bin/bash
SVC="${1:-}"; OBJ="${2:-}"
case "$SVC" in
    org.kde.konsole*)
        if [[ -z "$OBJ" ]]; then
            printf "/Sessions/1\n/Windows/foo\n/Windows/bar\n"
        elif [[ "$OBJ" == /Sessions/1 ]]; then
            echo "4000"
        fi ;;
esac'
    chmod +x "$MOCK_BIN/qdbus-qt6"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
}

# ── Clickable notification (click-to-focus) ───────────────────────────────────────────
# Tests 30–32 exercise the _notify_clickable() code path — the final exit when
# our tab exists but is not the currently visible one.  All three tests use a
# qdbus-qt6 mock that returns "99" for currentSession() (so the window loop
# never suppresses) and records when setCurrentSession() is called.

@test "30: tab in background → notify-send called with --action flag" {
    # Override notify-send to record its arguments so we can verify --action.
    write_file "$MOCK_BIN/notify-send" "#!/bin/bash
: > '$MOCK_BIN/notify-fired'
printf '%s\n' \"\$@\" > '$MOCK_BIN/notify-args'"
    chmod +x "$MOCK_BIN/notify-send"

    # Return "99" for currentSession so the tab is in the background.
    export MOCK_CURRENT_SESSION="99"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    notify_fired
    # The first argument written that starts with "--action" confirms the flag.
    grep -q '^--action' "$MOCK_BIN/notify-args"
}

@test "31: user clicks 'Focus Claude' → setCurrentSession and windowactivate called" {
    # notify-send outputs "focus" — simulates the user clicking the action.
    write_file "$MOCK_BIN/notify-send" "#!/bin/bash
: > '$MOCK_BIN/notify-fired'
echo focus"
    chmod +x "$MOCK_BIN/notify-send"

    # qdbus-qt6: return "99" for currentSession (tab in background);
    # write sentinel when setCurrentSession is called.
    write_file "$MOCK_BIN/qdbus-qt6" "#!/bin/bash
SVC=\"\${1:-}\"; OBJ=\"\${2:-}\"; METHOD=\"\${3:-}\"
case \"\$SVC\" in
    org.kde.konsole*)
        if [[ -z \"\$OBJ\" ]]; then
            printf '/Sessions/1\n/Windows/1\n'
        elif [[ \"\$OBJ\" == '/Sessions/1' ]]; then
            echo '4000'
        elif [[ \"\$OBJ\" == '/Windows/1' && \"\$METHOD\" == 'org.kde.konsole.Window.setCurrentSession' ]]; then
            : > '$MOCK_BIN/set-session-fired'
        elif [[ \"\$OBJ\" == '/Windows/1' ]]; then
            echo '99'
        fi ;;
esac"
    chmod +x "$MOCK_BIN/qdbus-qt6"

    # kdotool: default query responses + write sentinel for windowactivate.
    write_file "$MOCK_BIN/kdotool" "#!/bin/bash
case \"\${1:-}\" in
    getactivewindow)    echo \"\$MOCK_KDOTOOL_UUID\" ;;
    getwindowclassname) echo \"\$MOCK_KDOTOOL_CLASS\" ;;
    getwindowpid)       echo \"\$MOCK_KDOTOOL_PID\" ;;
    windowactivate)     : > '$MOCK_BIN/windowactivate-fired' ;;
esac"
    chmod +x "$MOCK_BIN/kdotool"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Allow the disowned background subshell to complete.
    local i=0
    while [[ ! -f "$MOCK_BIN/set-session-fired" && $i -lt 20 ]]; do
        sleep 0.1
        i=$((i + 1))
    done

    notify_fired
    [[ -f "$MOCK_BIN/set-session-fired" ]]
    [[ -f "$MOCK_BIN/windowactivate-fired" ]]
}

@test "32: notification dismissed (no click) → setCurrentSession not called" {
    # Default notify-send fires but outputs nothing — simulates dismiss.
    # qdbus-qt6: same as test 31 (records setCurrentSession calls).
    write_file "$MOCK_BIN/qdbus-qt6" "#!/bin/bash
SVC=\"\${1:-}\"; OBJ=\"\${2:-}\"; METHOD=\"\${3:-}\"
case \"\$SVC\" in
    org.kde.konsole*)
        if [[ -z \"\$OBJ\" ]]; then
            printf '/Sessions/1\n/Windows/1\n'
        elif [[ \"\$OBJ\" == '/Sessions/1' ]]; then
            echo '4000'
        elif [[ \"\$OBJ\" == '/Windows/1' && \"\$METHOD\" == 'org.kde.konsole.Window.setCurrentSession' ]]; then
            : > '$MOCK_BIN/set-session-fired'
        elif [[ \"\$OBJ\" == '/Windows/1' ]]; then
            echo '99'
        fi ;;
esac"
    chmod +x "$MOCK_BIN/qdbus-qt6"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Allow the disowned background subshell to complete.
    sleep 0.3

    notify_fired
    [[ ! -f "$MOCK_BIN/set-session-fired" ]]
}
