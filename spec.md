# Clanker Specification

Working title: **Clanker**.

This document is the build contract for a local-first macOS dynamic-notch app that monitors ongoing terminal, Codex, Pi, Claude Code, and related coding-agent sessions. The product should feel closer to Ping Island / AgentPeek than to a menu bar popover. A menu bar item may exist only as a recovery/settings affordance; the primary interaction is the notch surface.

## 1. Product Goal

Clanker gives a single, always-available overview of local and remote coding-agent work:

- Which sessions are running.
- Which project or repo each session belongs to.
- Which harness/client produced each session.
- Which sessions need attention now.
- What changed most recently.
- How to jump back to the exact terminal, tmux pane, IDE window, or desktop agent.
- How to answer approvals or questions without hunting through tabs.

The app is personal infrastructure. It should favor correctness, local privacy, and fast session routing over broad distribution polish.

## 2. Reference Implementations

We will not reinvent the core architecture where working implementations exist.

Primary implementation reference:

- Ping Island: `https://github.com/erha19/ping-island`
  - Apache 2.0.
  - Strongest baseline for notch UI, `NSPanel` overlay, hook socket bridge, hook installer, Codex app-server monitoring, terminal focusing, managed client profiles, IDE focus extensions, attention routing, and tests.
  - Local code inspected under `/tmp/clanker-refs/ping-island`.

Secondary references:

- AgentPeek: `https://agentpeek.app/docs`
  - Product/UX reference for a polished notch monitor, permission prompts, session overview, local server awareness, token/cost windows, and local-first positioning.
  - Not treated as a source-code dependency.
- Claudette: `https://github.com/emilevauge/claudette`
  - MIT.
  - Reference for Claude Code session polling, JSONL tail reads, Ghostty window/tab/split matching, busy/waiting heuristics, context status-line sidecar, and notifications.
  - Local code inspected under `/tmp/clanker-refs/claudette`.
- PiScope: `https://github.com/vbehar/PiScope`
  - MIT.
  - Reference for Pi session file parsing, incremental mtime cache, cost/token/model extraction, and project aggregation from `~/.pi/agent/sessions`.
  - Local code inspected under `/tmp/clanker-refs/PiScope`.
- Official OpenAI Codex docs:
  - `https://developers.openai.com/codex/hooks`
  - `https://developers.openai.com/codex/app-server`
  - Source of truth for Codex hook/app-server behavior when repo code and docs disagree.

## 3. Reuse Policy

This project should reuse design and code aggressively where license-compatible.

Allowed reuse:

- Vendor or port Ping Island implementation slices:
  - `NotchPanel`, `NotchWindowController`, `NotchViewController`, `NotchShape`, `NotchGeometry`, screen/notch metrics.
  - Hook bridge shape: `BridgeEnvelope`, `BridgeResponse`, `HookPayloadMapper`, `HookSocketServer`.
  - Hook installation patterns: JSON/JSONC/TOML/plugin/hook-directory installers, managed-profile table, managed-entry removal.
  - Codex app-server monitor and Codex usage loader.
  - Terminal focus stack: process tree, terminal registry, AppleScript focus, IDE URI focus extension model, tmux matching.
  - Session state machine patterns and tests.
- Port PiScope parser behavior for Pi sessions.
- Port Claudette's Claude fallback heuristics when hooks are missing or stale.

Required attribution:

- If any Ping Island source code is copied or adapted, retain Apache 2.0 notices and add/keep a `NOTICE` file.
- If any Claudette or PiScope source code is copied or adapted, retain MIT copyright notices in source or third-party notices.
- Track copied files in `THIRD_PARTY.md` with original path, license, and local destination.

Preferred implementation route:

1. Fork or vendor the minimal Ping Island subsystems listed above.
2. Rename product symbols and remove unrelated mascot/marketing features.
3. Add Pi and terminal-first support.
4. Keep tests from copied subsystems and adapt them before adding new behavior.

## 4. Non-Goals

- No cloud sync.
- No telemetry.
- No hosted account.
- No App Store distribution in v1.
- No LLM proxying or prompt interception beyond local hook payloads.
- No rewriting agent transcripts.
- No permanently deleting session files.
- No attempting to control every unsupported terminal with brittle UI scripting.

## 5. Platform Contract

Target:

- macOS 14+.
- Swift 6.x.
- SwiftUI for view composition.
- AppKit for overlay windows, panels, AppleScript, global event monitors, and activation/focus behavior.

App shape:

- Accessory app (`LSUIElement=true`) by default.
- Primary UI is a dynamic notch overlay, not `MenuBarExtra`.
- Optional small menu bar/status item may be enabled for:
  - Settings.
  - Restart bridge.
  - Diagnostics.
  - Quit.
  - Emergency hide/show notch.
- Settings lives in a real native window.
- Diagnostics lives in a real native window or exported bundle.

Required permissions:

- Notifications: alert when a session changes into attention-needed or completion-ready.
- Automation / Apple Events: focus iTerm2, Ghostty, Terminal.app, supported IDEs.
- Accessibility: only if global input/event handling requires it; avoid if event monitors and AppleScript are sufficient.
- Filesystem: user-level access to harness config/session directories.
- Launch at Login: optional.

## 6. User Experience Contract

### 6.1 Closed Notch

Closed state is always small and centered at the top of the selected display.

It must show:

- Representative active harness icon or stack of icons.
- Count of active/attention sessions.
- Attention indicator:
  - Normal: active/running.
  - Warning: approval needed.
  - Intervention: question/input needed.
  - Done: recently completed and ready to review.
  - Error: failed session/tool.
- Optional compact preview text for the most recent attention session, disabled by default if it makes the notch too noisy.

Closed notch must not intercept clicks outside its visible region.

### 6.2 Expanded Notch

Expanded state opens on:

- Click.
- Hover after a short delay.
- Global shortcut.
- Attention event, if notifications/auto-open are enabled.

Expanded state must include:

- Header:
  - Active count.
  - Attention count.
  - Current grouping mode.
  - Search/filter entry when keyboard focus is active.
- Grouped session list:
  - `By Project`.
  - `By Harness`.
  - `By Terminal`.
  - `Needs Attention`.
- Session rows:
  - Harness/client icon.
  - Project name.
  - Session title.
  - Status.
  - Last activity age.
  - Terminal/IDE badge.
  - Model when known.
  - Token/cost summary when known.
  - Attention action when applicable.

Default sort order:

1. Needs human response.
2. Has approval pending.
3. Has error.
4. Recently completed.
5. Active/running.
6. Last activity descending.

### 6.3 Session Detail

Opening a row shows detail inside the expanded notch when space allows; otherwise it opens a detachable panel.

Required detail fields:

- Full title and cwd.
- Project root.
- Harness/client.
- Session id.
- Terminal/IDE target.
- Status timeline.
- Last prompt preview.
- Latest assistant preview.
- Tool currently pending/running, if any.
- Diff summary when available.
- Tokens/cost/context when available.
- Links/actions:
  - Focus terminal or IDE.
  - Open project in Finder.
  - Copy session id.
  - Copy cwd.
  - Open transcript file.
  - Archive/hide session.

### 6.4 Attention Actions

For supported harnesses, the notch can respond to:

- Allow once.
- Allow for session.
- Deny.
- Cancel.
- Answer question with structured fields/options.
- Continue or reply to completed waiting session when supported.

Actions must be idempotent:

- If a request was already resolved in the terminal, the notch must cancel or clear its local pending state.
- If the response socket is gone, the UI must show the action as failed and point the user back to the terminal.

### 6.5 Detachable Mode

The app should support Ping Island-style detach:

- Long-press/drag from the notch to create a floating compact session companion.
- Detached surface follows the same selected/representative session.
- Detached surface can be returned to the notch.
- This is not required for MVP, but the architecture must not block it.

## 7. Architecture

### 7.1 Targets

Recommended repo structure:

```text
Clanker.xcodeproj
Clanker/
  App/
  Core/
  Models/
  Stores/
  Services/
    Bridge/
    Hooks/
    Harnesses/
    Notch/
    Terminal/
    Usage/
  UI/
    Notch/
    Sessions/
    Settings/
  Resources/
ClankerBridge/
  Package.swift
  Sources/ClankerBridge/
Tests/
  ClankerTests/
  ClankerBridgeTests/
THIRD_PARTY.md
NOTICE
```

Targets:

- `Clanker.app`: macOS accessory app.
- `ClankerBridge`: small CLI binary invoked by hooks and plugins.
- `ClankerTests`: app/service tests.
- `ClankerBridgeTests`: payload mapping, stdout response, and integration tests.

### 7.2 Process Model

```text
Agent CLI / IDE / Hook
        |
        | stdin JSON + env
        v
ClankerBridge
        |
        | Unix domain socket request
        v
Clanker.app HookSocketServer
        |
        v
SessionStore
        |
        +--> NotchViewModel / UI
        +--> Response back through socket when hook expects output
        +--> Transcript watcher / usage loader / terminal matcher
```

Fallback scanners run in the app:

```text
Claude sessions     ~/.claude/sessions + ~/.claude/projects
Pi sessions         ~/.pi/agent/sessions
Codex usage/logs    ~/.codex plus app-server when available
Terminals           process tree + cwd + tty + AppleScript/IDE metadata
```

### 7.3 Source of Truth Priority

For a live session, use sources in this order:

1. Blocking hook or app-server pending request.
2. Live hook event.
3. Codex app-server thread state.
4. Harness session sidecar/status file.
5. Transcript tail parser.
6. Terminal/process cwd and pid.
7. Historical session file.

The store must preserve provenance per field, so debugging can explain why a session is marked waiting.

## 8. Core Data Model

### 8.1 Harness

```swift
enum HarnessID: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case pi
    case terminal
    case gemini
    case qwen
    case kimi
    case opencode
    case openclaw
    case hermes
    case qoder
    case codebuddy
    case workbuddy
    case cursor
    case copilot
    case custom
}
```

### 8.2 Session Status

```swift
enum SessionStatusKind: String, Codable, Sendable {
    case starting
    case active
    case thinking
    case runningTool
    case compacting
    case waitingForApproval
    case waitingForInput
    case completed
    case idle
    case interrupted
    case stale
    case error
}

struct SessionStatus: Codable, Equatable, Sendable {
    var kind: SessionStatusKind
    var detail: String?
    var enteredAt: Date
}
```

Attention rule:

```swift
var needsAttention: Bool {
    status.kind == .waitingForApproval ||
    status.kind == .waitingForInput ||
    status.kind == .error ||
    intervention != nil
}
```

### 8.3 Session

```swift
struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var stableID: String
    var harness: HarnessID
    var clientProfileID: String
    var title: String
    var preview: String?

    var cwd: String?
    var projectRoot: String?
    var projectName: String

    var status: SessionStatus
    var intervention: InterventionRequest?

    var pid: Int?
    var tty: String?
    var terminal: TerminalContext?

    var model: String?
    var usage: UsageSnapshot?
    var diff: DiffSummary?

    var transcriptPath: String?
    var sessionFilePath: String?
    var metadata: [String: String]

    var createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date
    var archivedAt: Date?

    var provenance: [String: FieldProvenance]
}
```

### 8.4 Terminal Context

```swift
struct TerminalContext: Codable, Hashable, Sendable {
    var terminalProgram: String?
    var terminalBundleID: String?
    var terminalPID: Int?
    var terminalSessionID: String?
    var iTermSessionID: String?
    var ghosttyTerminalID: String?
    var tty: String?
    var tmuxSession: String?
    var tmuxPane: String?
    var cwd: String?
    var remoteTransport: String?
    var remoteHost: String?
    var ideName: String?
    var ideBundleID: String?
    var launchURL: String?
}
```

### 8.5 Intervention

```swift
enum InterventionKind: String, Codable, Sendable {
    case approval
    case question
}

struct InterventionRequest: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var sessionID: String
    var kind: InterventionKind
    var title: String
    var message: String
    var options: [InterventionOption]
    var questions: [InterventionQuestion]
    var supportsSessionScope: Bool
    var rawContext: [String: String]
    var requestedAt: Date
}
```

### 8.6 Usage

```swift
struct UsageSnapshot: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var costUSD: Decimal?
    var contextUsedFraction: Double?
    var modelBreakdown: [String: Decimal]
    var source: String
    var updatedAt: Date
}
```

### 8.7 Store Persistence

Use SQLite via `SQLite.swift`, GRDB, or a small direct `sqlite3` wrapper. Do not store in only `UserDefaults`.

Tables:

- `sessions`
- `session_events`
- `interventions`
- `usage_snapshots`
- `terminal_targets`
- `project_roots`
- `adapter_state`
- `hidden_sessions`
- `diagnostic_logs`

Retention:

- Live sessions: indefinite until archived/hidden.
- Event logs: 14 days default.
- Diagnostic logs: 7 days default.
- Usage summaries: 90 days default.

All retention must be user configurable.

## 9. Bridge Protocol

The bridge protocol is the normalized local contract between hook clients and the app. It should follow Ping Island's `BridgeEnvelope` pattern, with our additional `pi` and `terminal` support.

### 9.1 Request

```json
{
  "protocol": "clanker.bridge.v1",
  "id": "9FDD85DD-7D15-4583-8BB7-15EE7566F7F6",
  "provider": "codex",
  "clientProfileID": "codex-cli",
  "eventType": "PermissionRequest",
  "sessionKey": "codex:thread-id",
  "sessionID": "thread-id",
  "title": "Bash",
  "preview": "npm test",
  "cwd": "/Users/me/dev/project",
  "status": {
    "kind": "waitingForApproval",
    "detail": "Bash wants to run npm test"
  },
  "terminal": {
    "terminalProgram": "iTerm.app",
    "terminalBundleID": "com.googlecode.iterm2",
    "iTermSessionID": "w0t1p0",
    "tty": "/dev/ttys004",
    "currentDirectory": "/Users/me/dev/project",
    "tmuxSession": "main",
    "tmuxPane": "%12"
  },
  "intervention": {
    "id": "tool-use-id",
    "kind": "approval",
    "title": "Approval Needed",
    "message": "Allow Bash to run npm test?",
    "options": [
      { "id": "approve", "title": "Allow Once" },
      { "id": "approveForSession", "title": "Allow Session" },
      { "id": "deny", "title": "Deny" }
    ],
    "supportsSessionScope": true
  },
  "expectsResponse": true,
  "metadata": {
    "tool_name": "Bash",
    "tool_use_id": "tool-use-id",
    "transcript_path": "/Users/me/.codex/sessions/..."
  },
  "sentAt": "2026-05-14T12:00:00Z"
}
```

### 9.2 Response

```json
{
  "requestID": "9FDD85DD-7D15-4583-8BB7-15EE7566F7F6",
  "decision": "approveForSession",
  "reason": null,
  "answers": null,
  "updatedInput": null,
  "errorMessage": null
}
```

Allowed decisions:

- `approve`
- `approveForSession`
- `deny`
- `cancel`
- `answer`

Each adapter maps the normalized response back to the harness-specific stdout format.

## 10. Harness Adapter Contract

Every harness adapter must implement:

```swift
protocol HarnessAdapter: Sendable {
    var id: HarnessID { get }
    var displayName: String { get }
    var capabilities: HarnessCapabilities { get }

    func install() async throws
    func uninstall() async throws
    func status() async -> AdapterInstallStatus

    func start() async
    func stop() async

    func handleBridgeEnvelope(_ envelope: BridgeEnvelope) async throws -> AgentSessionEvent
    func refreshSnapshots() async throws -> [AgentSession]
    func respond(to intervention: InterventionRequest, with decision: InterventionDecision) async throws
}
```

Capabilities:

```swift
struct HarnessCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let liveHooks
    static let transcriptRead
    static let usageRead
    static let approvals
    static let questions
    static let appServer
    static let launchSession
    static let resumeSession
    static let terminalFocus
}
```

Adapter rules:

- Adapters never mutate transcripts/session logs.
- Installers must preserve unrelated config and unrelated hooks.
- Installers must mark managed entries with app-specific command paths.
- Installers must back up config before first write.
- Adapters emit normalized `AgentSessionEvent` into `SessionStore`; they do not mutate UI state directly.

## 11. Required Harness Support

### 11.1 Tier 1: Must Work in v1

| Harness | Sources | Actions | Reuse |
|---|---|---|---|
| Codex CLI | `~/.codex/hooks.json`, Codex transcript/session metadata, optional app-server | approvals, questions when available, focus, usage | Ping Island Codex hooks/app-server/usage |
| Codex App | Codex app-server on local websocket | approvals, questions, start/resume/read/archive | Ping Island `CodexAppServerMonitor` |
| Claude Code | `~/.claude/settings.json` hooks, `~/.claude/sessions`, `~/.claude/projects` JSONL fallback | approvals, questions, auto-approve session, focus | Ping Island hooks + Claudette fallback |
| Pi | `~/.pi/agent/sessions/<project>/*.jsonl` | read-only live/history, focus when terminal can be matched | PiScope parser plus terminal matcher |
| Plain terminals | process tree, cwd, tty, tmux, shell title | focus only | Ping Island process/terminal focus |

### 11.2 Tier 2: Should Support Through Ping Island Adapter Matrix

These should be in settings from the start if we port Ping Island profiles:

- Gemini CLI: `~/.gemini/settings.json`.
- Hermes: `~/.hermes/plugins/ping_island`.
- Qwen Code: `~/.qwen/settings.json`.
- Kimi CLI: `~/.kimi/config.toml`.
- OpenClaw: `~/.openclaw/hooks/...` plus transcript refresh.
- OpenCode: `~/.config/opencode/plugins/...`.
- Cursor: `~/.cursor/hooks.json`.
- Qoder, Qoder CLI, QoderWork: `~/.qoder/settings.json`, `~/.qoderwork/settings.json`.
- CodeBuddy, CodeBuddy CLI, WorkBuddy: their settings files.
- GitHub Copilot: `.github/hooks/island.json`-style profile.

Tier 2 can be hidden behind an "Integrations" setting if not installed locally.

### 11.3 Custom Harnesses

Allow users to add a custom hook command that emits `clanker.bridge.v1` envelopes.

Settings fields:

- Name.
- Provider id.
- Config path.
- Install command template.
- Event names.
- Response mode: none, stdout JSON, socket callback.

## 12. Project and Grouping Contract

Project root resolver:

1. If `cwd` exists and is inside a Git worktree, use `git rev-parse --show-toplevel` with a 300 ms timeout.
2. Else use nearest ancestor containing one of:
   - `package.json`
   - `pnpm-workspace.yaml`
   - `Cargo.toml`
   - `Package.swift`
   - `pyproject.toml`
   - `go.mod`
   - `.project`
3. Else use `cwd`.
4. Else use harness-provided project/workspace.
5. Else use `Unknown Project`.

Grouping modes:

- `attention`: one flat list of sessions needing attention.
- `project`: group by `projectRoot`.
- `harness`: group by `HarnessID`/client profile.
- `terminal`: group by terminal/IDE app.
- `remote`: group by remote host.

Group sorting:

1. Highest-priority contained session.
2. Most recent contained session.
3. Name.

Session sorting inside groups:

```swift
sortKey = (
    needsHumanInput ? 0 : 1,
    needsApproval ? 0 : 1,
    hasError ? 0 : 1,
    isRecentlyCompleted ? 0 : 1,
    isActive ? 0 : 1,
    -lastActivityAt.timeIntervalSinceReferenceDate
)
```

## 13. Notch Implementation Contract

Use AppKit for the window boundary and SwiftUI for content.

Required implementation pattern:

- Borderless non-activating `NSPanel`.
- Clear background.
- Floating above menu bar.
- Joins all spaces.
- Fullscreen auxiliary.
- Stationary.
- Ignores cycle.
- Closed state ignores mouse events so normal menu bar clicks pass through.
- Opened state handles mouse events.
- Global event monitor detects hover/click around notch hit regions.
- Screen observer repositions on display changes, resolution changes, fullscreen transitions, and selected-screen changes.

Geometry:

- Detect physical notch when available.
- Fall back to centered synthetic notch dimensions on non-notched displays.
- Keep the overlay window full-width top band, but render only the notch/panel.
- Panel width/height must be computed from content with maximums:
  - Width: min(screen width - 64, 600) for hover dashboard.
  - Width: min(screen width * 0.44, 520) for clicked list.
  - Height: min(screen height - 120, user setting max panel height).

Animations:

- Closed to open: spring/ease 200-300 ms.
- Attention pulse: subtle, bounded, no layout shift.
- Row insertion/removal: stable identity by `stableID`.

## 14. Terminal Focus Contract

Focus must prefer stable identifiers over fuzzy names.

Order:

1. IDE extension URI focus, when installed and matched.
2. Terminal app stable session id:
   - iTerm session id.
   - Ghostty terminal id.
   - Terminal.app tty.
3. tmux session/pane target.
4. cwd match.
5. title/title suffix match.
6. activate app fallback.

Supported focus targets:

- Ghostty.
- iTerm2.
- Terminal.app.
- tmux.
- VS Code.
- Cursor.
- Qoder.
- CodeBuddy.
- WorkBuddy.
- Generic app activation by bundle id.

The UI must clearly show when precise focus is unavailable.

## 15. Usage and Cost Contract

Usage display is best effort.

Required:

- Pi:
  - Parse `usage.totalTokens`.
  - Parse `usage.cost.total`.
  - Parse cache read/write tokens and costs.
  - Derive primary model by session cost weight.
- Claude:
  - Parse usage snapshots when available.
  - Read status-line sidecar/context percentage if configured.
  - Display "unknown" rather than inventing cost.
- Codex:
  - Use Ping Island's Codex usage loader/app-server state when available.
  - Display model and context when available.
- Other harnesses:
  - Use hook metadata if present.
  - Use transcript parser only when format is known.

The UI must label unknown values as unknown. It must not estimate cost unless the estimator is explicitly marked approximate.

## 16. Hook Installation Contract

Installer must support:

- JSON hooks.
- JSONC-ish config parsing where existing files have comments/trailing commas.
- TOML hooks.
- Plugin file.
- Plugin directory.
- Hook directory with activation config.

Install procedure:

1. Resolve profile config paths under real user home.
2. Read existing config.
3. Create backup on first write:
   - `path.clanker.bak.<timestamp>`
4. Remove prior Clanker managed entries.
5. Preserve unrelated hooks/settings.
6. Add managed entries invoking `ClankerBridge`.
7. Write atomically.
8. Validate by reading file back.
9. Record installed version and profile in settings.

Uninstall procedure:

1. Remove only Clanker managed entries.
2. Preserve unrelated hooks/settings.
3. Disable activation entry only if it points to Clanker.
4. Leave backups alone.

## 17. Privacy and Safety Contract

Default behavior:

- Local-only.
- No network calls except:
  - User-initiated update check, if enabled.
  - Optional release download, if enabled.
- No telemetry.
- No prompt/session upload.
- No transcript mutation.
- No shell command execution except:
  - Local bridge binary invoked by configured hooks.
  - Explicit focus commands/AppleScript.
  - Bounded project-root detection.
  - Optional CLI version checks for integrations.

Redaction:

- Diagnostics export must redact:
  - Home path unless user disables redaction.
  - API keys.
  - Bearer tokens.
  - SSH keys.
  - Long prompt bodies by default.
  - Tool inputs longer than a configured limit.

## 18. Settings Contract

Settings sections:

- General:
  - Launch at login.
  - Hide Dock icon.
  - Show menu bar fallback.
  - Global shortcut.
- Display:
  - Selected screen.
  - Notch display mode: compact, detailed.
  - Hover open delay.
  - Auto-collapse.
  - Auto-hide when idle.
  - Max panel height.
- Grouping:
  - Default grouping mode.
  - Sort mode.
  - Hidden/archived sessions.
- Integrations:
  - Install/uninstall per harness.
  - Show adapter status.
  - Show config path.
  - Restore from backup.
- Terminal Focus:
  - Enable AppleScript focus.
  - Enable IDE extensions.
  - tmux path.
  - Diagnostic test focus.
- Notifications:
  - Attention.
  - Completion.
  - Error.
  - Temporary mute.
- Privacy:
  - Diagnostics redaction.
  - Retention periods.
  - Disable transcript previews.

## 19. MVP Scope

MVP must ship:

- Dynamic notch window, no menu-bar-first UX.
- Session store with grouping and attention sorting.
- Codex hooks.
- Codex app-server read/approval path when available.
- Claude Code hooks.
- Claude JSONL/session fallback.
- Pi read-only parser.
- Plain terminal/process scanner.
- Ghostty, iTerm2, Terminal.app focus.
- Settings for enabling integrations.
- Local diagnostics export.
- Unit tests for bridge mapping, hook install round trips, project resolver, Pi parser, Claude blocked-on-user fallback, and sort order.

MVP can defer:

- Detachable companion.
- Mascots/custom sounds.
- Remote SSH bridge.
- IDE extension installation.
- Full Tier 2 response actions, as long as the adapter profiles are modeled and safe to enable later.

## 20. Build Phases

### Phase 0: Legal and Scaffold

Deliverables:

- `NOTICE`.
- `THIRD_PARTY.md`.
- Xcode app target.
- SwiftPM bridge target.
- CI/test script.

Acceptance:

- App launches as accessory app.
- Bridge builds as executable.
- Licenses are recorded for copied code.

### Phase 1: Notch Shell

Deliverables:

- `NotchPanel`.
- `NotchWindowController`.
- `NotchViewModel`.
- Closed/opened SwiftUI notch.
- Mock session store.
- Grouping and sorting UI.

Acceptance:

- Notch appears on selected display.
- Closed state passes clicks through.
- Expanded state handles clicks.
- Keyboard shortcut opens/closes.
- Mock sessions demonstrate project/harness grouping and attention sort.

### Phase 2: Bridge and Store

Deliverables:

- Unix socket server.
- Bridge envelope/response schema.
- Bridge executable.
- SQLite store.
- Event log.

Acceptance:

- Bridge can send sample envelope to app.
- App creates/updates session.
- App can respond to a blocking request.
- Socket failure is surfaced in diagnostics.

### Phase 3: Codex

Deliverables:

- Codex hook installer for `~/.codex/hooks.json`.
- Codex hook payload mapping.
- Codex app-server monitor.
- Codex session UI and attention actions.

Acceptance:

- Starting Codex creates a live session.
- Permission request appears in notch.
- Approve/deny works through hook response or app-server path.
- Focus returns to terminal when context exists.

### Phase 4: Claude

Deliverables:

- Claude hook installer for `~/.claude/settings.json`.
- Claude hook payload mapping.
- `~/.claude/sessions` scanner fallback.
- JSONL tail parser for title/latest text/blocked-on-user.
- Ghostty fallback matching.

Acceptance:

- Claude Code sessions appear within 2 seconds from hook or scanner.
- Busy/waiting/idle status is correct when transcript indicates pending tool/question.
- Focus Ghostty/iTerm2/Terminal.app returns to right session when identifiers are available.

### Phase 5: Pi

Deliverables:

- Pi session scanner for `~/.pi/agent/sessions`.
- Incremental mtime cache.
- Usage/cost/model parser.
- Pi session rows and detail.

Acceptance:

- Pi sessions appear grouped by project.
- Recent Pi sessions sort correctly.
- Cost/tokens/model values match PiScope parser output for the same files.
- Parser never writes to Pi files.

### Phase 6: Terminal Scanner

Deliverables:

- Process tree scanner.
- cwd resolver.
- tty resolver.
- terminal app registry.
- tmux matcher.

Acceptance:

- Plain shells appear when enabled.
- Shells are grouped by project.
- Focus works where supported and degrades visibly otherwise.

### Phase 7: Tier 2 Integrations

Deliverables:

- Port Ping Island managed profiles for Gemini, Qwen, Kimi, OpenCode, OpenClaw, Hermes, Qoder, CodeBuddy, WorkBuddy, Cursor, Copilot.
- Tests for config round trips.

Acceptance:

- Each profile can install/uninstall without deleting unrelated settings.
- Notify-only clients never block waiting for a response.
- Response-capable clients map decisions to correct stdout payloads.

## 21. Test Contract

Unit tests:

- `BridgeCodecTests`
- `HookPayloadMapperTests`
- `HookSocketServerTests`
- `HookInstallerJSONTests`
- `HookInstallerTOMLTests`
- `ProjectRootResolverTests`
- `SessionSortTests`
- `PiSessionParserTests`
- `ClaudeTranscriptParserTests`
- `CodexAppServerParserTests`
- `TerminalFocusTargetTests`
- `DiagnosticsRedactorTests`

Integration tests:

- Bridge executable to socket server.
- Hook installer writes temp config and preserves unknown fields.
- Sample Codex/Claude/Pi transcript fixtures.
- SQLite persistence/reload.

Manual QA:

- Notched MacBook built-in display.
- External monitor without notch.
- Fullscreen app.
- Multiple Spaces.
- Display sleep/wake.
- Ghostty, iTerm2, Terminal.app.
- tmux inside iTerm2/Ghostty.

## 22. Definition of Done

The project is ready for daily use when:

- The notch is the primary UI and remains stable across spaces/displays.
- Codex, Claude Code, Pi, and plain terminal sessions are visible.
- Grouping by project and harness works.
- Attention sort is correct.
- Codex and Claude approval/question paths work where the harness supports response hooks/app-server.
- Focus returns to the correct terminal or shows why it cannot.
- Pi sessions show usage/cost/model read-only.
- Hook install/uninstall preserves existing config.
- Diagnostics can explain every active session's source and status.
- No transcript/session files are modified.
- Tests pass locally.

## 23. Open Questions

- Product name: keep `Clanker`, rename to something repo-specific, or use a private codename.
- Whether to fork Ping Island directly or vendor specific files into a cleaner app skeleton.
- Whether the menu bar fallback should be enabled by default or only behind a setting.
- Whether remote SSH bridge support should be pulled in before or after Tier 2 integrations.
- Whether to include local dev-server scanning in MVP or treat it as a post-MVP AgentPeek-parity feature.
