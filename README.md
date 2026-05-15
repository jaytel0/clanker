# Clanker

Local-first macOS dynamic-notch app concept for monitoring coding-agent sessions across Codex, Claude Code, Pi, terminals, and related harnesses.

The build contract lives in [spec.md](./spec.md). It defines the product scope, reuse strategy, data model, bridge protocol, harness adapters, notch UI behavior, installation model, and acceptance criteria.

Current state:

- Specification complete enough to build against.
- SwiftPM macOS scaffold exists.
- `script/build_and_run.sh` builds and stages `dist/Clanker.app`.
- The app launches the dynamic-notch shell and discovers local terminal, Codex, Claude Code, and Pi sessions from live processes, Codex app-server, and local transcript/session files.

Run locally:

```bash
./script/build_and_run.sh
```

Install locally:

```bash
./script/build_and_run.sh --install
```
