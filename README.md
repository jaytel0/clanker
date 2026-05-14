# Agent Notch

Local-first macOS dynamic-notch app concept for monitoring coding-agent sessions across Codex, Claude Code, Pi, terminals, and related harnesses.

The build contract lives in [spec.md](./spec.md). It defines the product scope, reuse strategy, data model, bridge protocol, harness adapters, notch UI behavior, installation model, and acceptance criteria.

Current state:

- Specification complete enough to build against.
- SwiftPM macOS scaffold exists.
- `script/build_and_run.sh` builds and stages `dist/AgentNotch.app`.
- The app currently launches a dynamic-notch shell with mock sessions; real harness adapters are specified but not implemented yet.

Run locally:

```bash
./script/build_and_run.sh
```

Install locally:

```bash
./script/build_and_run.sh --install
```
