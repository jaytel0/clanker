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
