import Foundation
import XCTest
@testable import Clanker

@MainActor
final class NotchDemoModeTests: XCTestCase {
    func testViewModelDefaultsSpendToToday() {
        let viewModel = NotchViewModel(sessionStore: LocalSessionStore())

        XCTAssertEqual(viewModel.selectedSpendTimeframe, .today)
    }

    func testDemoModeFiltersToPersonalProjectsAndSessions() {
        XCTAssertTrue(NotchDemoMode.isPersonalProject(project(category: "personal", path: "/Users/jaytel/Developer/personal/clanker")))
        XCTAssertTrue(NotchDemoMode.isPersonalProject(project(category: "recent", path: "/Users/jaytel/Developer/personal/dotfiles")))
        XCTAssertFalse(NotchDemoMode.isPersonalProject(project(category: "shopify", path: "/Users/jaytel/Developer/shopify/world")))
        XCTAssertFalse(NotchDemoMode.isPersonalProject(project(category: "personal", path: "/Users/jaytel/Developer/shopify/personal-tools")))

        XCTAssertTrue(NotchDemoMode.isPersonalSession(session(cwd: "/Users/jaytel/Developer/personal/clanker")))
        XCTAssertFalse(NotchDemoMode.isPersonalSession(session(cwd: "/Users/jaytel/Developer/shopify/world")))
    }

    func testDemoSpendLooksLikeOneDayPersonalUsageAroundNineHundredDollars() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 18,
            hour: 15,
            minute: 30
        )))

        let snapshots = NotchDemoMode.demoUsageSnapshots(now: now, calendar: calendar)
        let summary = SpendSummary(snapshots: snapshots, timeframe: .today, now: now, calendar: calendar)
        let total = NSDecimalNumber(decimal: try XCTUnwrap(summary.totalCostUSD)).doubleValue

        XCTAssertEqual(snapshots.count, 5)
        XCTAssertEqual(total, 913.96, accuracy: 0.001)
        XCTAssertNotEqual(total, total.rounded())
        XCTAssertTrue(snapshots.allSatisfy { $0.cwd.contains("/personal/") })
        XCTAssertTrue(snapshots.allSatisfy { SpendTimeframe.today.contains($0.observedAt, now: now, calendar: calendar) })
    }

    private func project(category: String, path: String) -> RecentProject {
        RecentProject(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            category: category,
            score: Date(),
            githubURL: nil,
            hasActiveSession: false
        )
    }

    private func session(cwd: String) -> AgentSession {
        AgentSession(
            id: UUID().uuidString,
            title: "Codex",
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd,
            harness: .codex,
            status: .working,
            preview: "Preview",
            lastActivity: Date(),
            pid: 123,
            terminalName: "Ghostty",
            tty: "/dev/ttys001",
            isLive: true,
            appBundleID: "com.mitchellh.ghostty",
            launchURL: nil
        )
    }
}
