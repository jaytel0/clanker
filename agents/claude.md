# Clanker — Agent Notes

## Always build to the installed app

Clanker is installed at `/Applications/Clanker.app` and set as a login item.
**After any code change, rebuild and install using the build script:**

```bash
pkill -x Clanker 2>/dev/null; sleep 0.3
cd /Users/jaytel/Developer/personal/clanker && bash script/build_and_run.sh install
```

This kills the running instance, rebuilds, copies the `.app` bundle to
`/Applications/Clanker.app`, and relaunches it. Never just run `swift build`
and open the raw binary — the installed app is what the user actually uses.

## Quick reference

| Task | Command |
|---|---|
| Rebuild & install | `bash script/build_and_run.sh install` |
| Run from dist/ (dev) | `bash script/build_and_run.sh run` |
| Stream logs | `bash script/build_and_run.sh logs` |
| Debug with lldb | `bash script/build_and_run.sh debug` |

## App details

- **Bundle ID:** `dev.clanker.app`
- **Installed:** `/Applications/Clanker.app`
- **Login item:** yes (auto-starts on login)
- **Icon:** `Sources/Clanker/Resources/AppIcon.icns` (generated from `clanker.png`)

## Build notes

- SPM executable target — no Xcode project
- Resource bundles land in `APP_CONTENTS/Resources/` (see script)
- `AppIcon.icns` is copied from `Sources/Clanker/Resources/` into the bundle by
  the build script; `CFBundleIconFile` in Info.plist points to it

## Discovery architecture (v0.5)

Session discovery lives in `Sources/Clanker/Services/Discovery/`:

- `AgentDiscovery.swift` — `LocalSessionScanner.scan()` orchestrator + 8s transcript cache gate
- `ProcessSnapshot.swift` — one `ps` call per tick (pid/ppid/pgid/tpgid/stat/%cpu/etime/tty/command); cwd via libproc (`CProcInfo` target), lsof fallback; terminal identity walk (`TerminalIdentityResolver`)
- `HarnessDetection.swift` — strong (install-path) vs weak (executable-name) signals; weak signals are ignored for `.app/Contents/` internals so GUI apps (Claude.app helpers, Codex computer-use) never read as harnesses
- `TerminalProcessSource.swift` — per-tty rows anchored on the foreground process group; CPU-subtree threshold decides working vs idle
- `ClaudeSources.swift` / `CodexSources.swift` / `PiSource.swift` — transcript parsing, all cached per file by (mtime, size) via `FileParseCache`
- `DiscoveredSession.swift` — normalized model + `SessionMerger`

Cmux integration is in `Services/Terminal/CmuxSupport.swift`: panels parsed from
`~/Library/Application Support/cmux/session-com.cmuxterm.app.json` (tty → title/cwd/panel-id,
guarded by mtime + cwd agreement), focus via the bundled CLI (`focus-panel`).
Debug any of this with `.build/debug/Clanker --print-sessions`.

## Attention notifications + inline reply (v0.5)

- `Services/Notifications/AttentionNotifier.swift` — `AttentionTracker` (pure, tested) debounces
  transitions into needs-approval/input/error (2.5s stability, 60s re-notify cooldown, auto-clear
  when resolved) and posts UNUserNotifications with a text-input Reply action.
- `Services/Reply/SessionReplyService.swift` — routes reply text into the owning session:
  tmux `send-keys` → Cmux CLI `send-panel` → iTerm `write text` → focus + pid-targeted CGEvents.
  `route(for:)` is pure and unit-tested.
- Notch rows show a reply affordance (persistent on attention rows, hover elsewhere); the notch
  pins open while `NotchViewModel.replyTargetID` is set; pane shortcuts are suppressed while a
  text field is first responder (GlobalNotchEventMonitor).
- Settings → General → Attention Alerts holds the toggles.
