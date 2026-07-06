import AppKit
import Foundation
import UserNotifications

// MARK: - Tracking (pure, testable)

/// Decides when a session's attention state deserves a notification.
///
/// Rules:
///   * a session must hold the same attention status for `debounce` seconds
///     before we notify — scan-to-scan flapping (working ⇄ approval) must
///     not reach the user;
///   * one notification per attention episode; a new episode starts when
///     the status changes or the session leaves and re-enters attention;
///   * re-notifying the same session is rate-limited by `renotifyCooldown`;
///   * leaving attention (or disappearing) emits `.clear` so stale banners
///     are withdrawn from Notification Center.
struct AttentionTracker {
    struct Episode: Equatable {
        var status: SessionStatusKind
        var firstSeen: Date
        var notified: Bool
    }

    enum Event: Equatable {
        case notify(session: AgentSession)
        case clear(sessionID: String)

        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.notify(let a), .notify(let b)): a.id == b.id && a.status == b.status
            case (.clear(let a), .clear(let b)): a == b
            default: false
            }
        }
    }

    var debounce: TimeInterval = 2.5
    var renotifyCooldown: TimeInterval = 60

    private(set) var episodes: [String: Episode] = [:]
    private(set) var lastNotifiedAt: [String: Date] = [:]

    mutating func update(sessions: [AgentSession], now: Date = Date()) -> [Event] {
        var events: [Event] = []
        var seen = Set<String>()

        for session in sessions where session.isLive {
            seen.insert(session.id)

            guard session.needsAttention else {
                if episodes.removeValue(forKey: session.id) != nil {
                    events.append(.clear(sessionID: session.id))
                }
                continue
            }

            if var episode = episodes[session.id], episode.status == session.status {
                let stableLongEnough = now.timeIntervalSince(episode.firstSeen) >= debounce
                let cooledDown = lastNotifiedAt[session.id]
                    .map { now.timeIntervalSince($0) >= renotifyCooldown } ?? true
                if !episode.notified, stableLongEnough, cooledDown {
                    episode.notified = true
                    lastNotifiedAt[session.id] = now
                    events.append(.notify(session: session))
                }
                episodes[session.id] = episode
            } else {
                episodes[session.id] = Episode(status: session.status, firstSeen: now, notified: false)
            }
        }

        for id in episodes.keys where !seen.contains(id) {
            episodes.removeValue(forKey: id)
            events.append(.clear(sessionID: id))
        }

        return events
    }
}

// MARK: - Notifier

/// Bridges attention transitions to macOS notifications with an inline
/// text-input reply — answer "Needs approval" straight from the banner.
@MainActor
final class AttentionNotifier: NSObject {
    static let enabledDefaultsKey = "attentionNotificationsEnabled"
    static let soundDefaultsKey = "attentionNotificationSound"

    private static let categoryID = "dev.clanker.agent-attention"
    private static let replyActionID = "dev.clanker.attention.reply"
    private static let focusActionID = "dev.clanker.attention.focus"
    private static let notificationPrefix = "clanker-attention-"

    private var tracker = AttentionTracker()
    private var latestSessions: [AgentSession] = []
    private var authorizationRequested = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    private static var soundEnabled: Bool {
        UserDefaults.standard.bool(forKey: soundDefaultsKey)
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply to the agent…"
        )
        let focus = UNNotificationAction(
            identifier: Self.focusActionID,
            title: "Open Terminal",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [reply, focus],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func update(sessions: [AgentSession]) {
        latestSessions = sessions
        let events = tracker.update(sessions: sessions)
        guard !events.isEmpty else { return }

        for event in events {
            switch event {
            case .notify(let session):
                guard Self.isEnabled else { continue }
                post(for: session)
            case .clear(let sessionID):
                withdraw(sessionID: sessionID)
            }
        }
    }

    // MARK: - Posting

    private func post(for session: AgentSession) {
        Task {
            let center = UNUserNotificationCenter.current()
            if !authorizationRequested {
                authorizationRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }

            let content = UNMutableNotificationContent()
            content.title = Self.title(for: session)
            content.subtitle = session.projectName
            content.body = Self.body(for: session)
            content.sound = Self.soundEnabled ? .default : nil
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["sessionID": session.id]
            content.threadIdentifier = session.projectName

            let request = UNNotificationRequest(
                identifier: Self.notificationPrefix + session.id,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func withdraw(sessionID: String) {
        let identifier = Self.notificationPrefix + sessionID
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func title(for session: AgentSession) -> String {
        let name = session.harness == .terminal ? "Terminal" : session.harness.displayName
        switch session.status {
        case .waitingForApproval: return "\(name) needs approval"
        case .waitingForInput: return "\(name) needs input"
        case .error: return "\(name) hit an error"
        default: return "\(name) needs attention"
        }
    }

    static func body(for session: AgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != session.harness.defaultSessionTitle {
            return title
        }
        return session.preview
    }

    // MARK: - Response handling

    private func handleResponse(actionID: String, sessionID: String?, text: String?) {
        guard let sessionID,
              let session = latestSessions.first(where: { $0.id == sessionID }) else {
            return
        }

        switch actionID {
        case Self.replyActionID:
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SessionReplyService.send(text, to: session)
            }
        default:
            // Banner click and "Open Terminal" both land the user in the
            // session that asked for them.
            TerminalFocusService.focus(session)
        }
    }
}

extension AttentionNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let actionID = response.actionIdentifier

        // Complete immediately — Clanker is a long-lived accessory app, so we
        // don't depend on the post-response background window, and the
        // non-Sendable completion handler must not cross into the Task.
        completionHandler()

        Task { @MainActor in
            self.handleResponse(actionID: actionID, sessionID: sessionID, text: text)
        }
    }
}
