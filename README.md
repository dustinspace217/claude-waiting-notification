# notify-with-focus-check.sh

A Claude Code notification hook for KDE Plasma 6 on Wayland. When Claude finishes working and is waiting for your input, it fires a desktop notification and plays a chime — but only if you are not already looking at the Konsole tab where that Claude instance is running.

---

## The problem it solves

When you run Claude Code in Konsole and switch away to do something else while it works, you need to know when it is done. A simple notification hook solves that, but it creates the opposite annoyance: if you are already sitting on the Claude tab watching it finish, the notification fires anyway, interrupting whatever you are doing with an alert you did not need.

This hook eliminates that noise. It fires only when you are actually away.

---

## How it works

The hook uses a four-step detection strategy to determine whether your Claude tab is the currently visible, focused tab before deciding whether to notify.

**Step 1 — Process tree walk**

Starting from the hook's own PID, the script walks up the process tree through `/proc` using only bash built-ins (no forked subprocesses). It records every PID it passes through and stops when it finds an ancestor process named `konsole`. This gives it two things: the PID of the Konsole process that owns this tab, and a set of PIDs representing the process chain down to this hook.

**Step 2 — D-Bus service lookup**

Konsole registers itself on the session D-Bus bus under a predictable service name: `org.kde.konsole-<PID>`. The script constructs that name directly from the PID found in step 1 and fetches the full list of D-Bus objects Konsole is exposing in a single call. This list is cached and reused for all subsequent queries, avoiding redundant round-trips. If the PID-suffixed name is not found, it falls back to `org.kde.konsole` (used when only one Konsole instance is running).

**Step 3 — Tab identity matching via Konsole's session API**

Konsole exposes each open tab as a D-Bus object under `/Sessions/<N>`. Each session has a `processId()` method that returns the PID of the shell running in that tab's terminal. The script iterates over every `/Sessions/` object and calls `processId()` on each one, checking whether the returned PID appears anywhere in the process chain recorded in step 1. When it finds a match, it has identified which session ID belongs to this Claude instance.

**Step 4 — Focused window check via kdotool**

With the session ID known, the script uses `kdotool getactivewindow` to get the currently focused window, then verifies that the window belongs to the same Konsole process (not just any Konsole window on the system). If those match, it iterates over Konsole's `/Windows/` D-Bus objects and calls `currentSession()` on each one to find which tab is currently visible. If the visible tab's session ID matches the one identified in step 3, the user is already looking at the Claude tab and the notification is suppressed. In every other case — different app focused, different Konsole window, different tab — the notification fires.

---

## Requirements

| Tool | How to install | How to verify |
|---|---|---|
| `kdotool` | `sudo dnf install kdotool` | `kdotool --version` should print a version string |
| `qdbus` | Ships with Qt; usually already present on KDE | `qdbus --version` should exit cleanly |
| `notify-send` | `sudo dnf install libnotify` | `notify-send "test"` should show a desktop notification |
| `paplay` | `sudo dnf install pipewire-utils` (or `pulseaudio-utils`) | `paplay /usr/share/sounds/freedesktop/stereo/message-new-instant.oga` should play a sound |
| KDE Plasma 6 | — | Check with `plasmashell --version` |
| Wayland session | — | `echo $WAYLAND_DISPLAY` should print a non-empty value such as `wayland-0` |

---

## Installation

**1. Copy the script into place.**

```bash
cp notify-with-focus-check.sh ~/.claude/hooks/notify-with-focus-check.sh
```

Verify: `ls -l ~/.claude/hooks/notify-with-focus-check.sh` should show the file exists.

**2. Make it executable.**

```bash
chmod +x ~/.claude/hooks/notify-with-focus-check.sh
```

Verify: `ls -l ~/.claude/hooks/notify-with-focus-check.sh` should show `-rwxr-xr-x` (or similar with execute bits set).

**3. Register the hook in Claude Code's settings.**

Open `~/.claude/settings.json` and add the hook block shown in the next section. If the file does not exist yet, create it as valid JSON.

Verify: Start a Claude Code session, let it finish a task, then switch to a different application. You should receive a desktop notification and hear the chime. Switch back to the Claude tab and let it finish another task — no notification should appear.

---

## settings.json hook entry

Add the following inside the top-level object in `~/.claude/settings.json`. If a `"hooks"` key already exists, merge this entry into it rather than replacing the whole block.

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-with-focus-check.sh"
          }
        ]
      }
    ]
  }
}
```

The `Notification` hook fires when Claude Code transitions to a state where it is waiting for user input — the same event that would trigger Claude Code's built-in notification behavior.

---

## Portability notes

- **Konsole-specific.** The tab identity detection in steps 2 and 3 relies entirely on Konsole's D-Bus API (`org.kde.konsole.Session.processId`, `org.kde.konsole.Window.currentSession`). Other terminal emulators do not expose this API. The hook will fall back to always notifying if the D-Bus lookup fails.

- **kdotool is required for focus detection.** `kdotool` is a Wayland-native tool that queries KWin's D-Bus scripting interface. If it is not installed, the script detects its absence at startup and falls back to always notifying rather than failing silently.

- **Graceful fallback behavior.** Every failure path in the script — missing `kdotool`, D-Bus service not found, session not matched — calls `_notify` and exits cleanly. The worst-case outcome is the same as a simple notification hook: you always get the alert.

- **Not tested on GNOME or other compositors.** The `kdotool getactivewindow` call and the Konsole D-Bus paths are KDE/KWin-specific. The script will fall back to unconditional notification on GNOME or other desktop environments.

- **Not tested on X11.** `kdotool` targets Wayland via KWin's D-Bus API. Behavior under an X11 session is untested.

---

## Known limitations

**Multiple Konsole windows from the same process.** Konsole's D-Bus API does not expose which KWin window ID corresponds to which `/Windows/N` object. When a single Konsole process has multiple windows open, the script checks whether the active window belongs to that process but cannot pinpoint which specific window object in D-Bus it represents. It then checks `currentSession()` across all windows in that process. In practice this means: if you have two Konsole windows from the same process, and the active one is not the one containing the Claude tab but the other one happens to have the Claude session ID as its current tab, the notification may be incorrectly suppressed. This scenario requires having two separate Konsole windows — not just two tabs — showing the same session simultaneously, which is uncommon in normal use.
