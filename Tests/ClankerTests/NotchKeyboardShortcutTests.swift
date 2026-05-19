import XCTest
@testable import Clanker

@MainActor
final class NotchKeyboardShortcutTests: XCTestCase {
    func testNumberShortcutsMapAllPanes() {
        XCTAssertEqual(NotchPane(shortcutKey: "1"), .sessions)
        XCTAssertEqual(NotchPane(shortcutKey: "2"), .recents)
        XCTAssertEqual(NotchPane(shortcutKey: "3"), .spend)
        XCTAssertNil(NotchPane(shortcutKey: "4"))
        XCTAssertNil(NotchPane(shortcutKey: nil))
    }

    func testSelectPaneTracksDirectionalNavigation() {
        let viewModel = NotchViewModel(sessionStore: LocalSessionStore())

        viewModel.selectPane(.spend)
        XCTAssertEqual(viewModel.selectedPane, .spend)
        XCTAssertEqual(viewModel.tabDirection, .forward)

        viewModel.selectPane(.sessions)
        XCTAssertEqual(viewModel.selectedPane, .sessions)
        XCTAssertEqual(viewModel.tabDirection, .backward)
    }

    func testGithubMarkLookupUsesCandidateResourceBundlesWithoutBundleModule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        let resourceBundle = directory.appendingPathComponent("Clanker_Clanker.bundle", isDirectory: true)
        let resource = resourceBundle.appendingPathComponent("GithubMark.svg")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: resource)

        XCTAssertEqual(
            GithubMarkImage.githubMarkURL(
                inCandidateDirectories: [directory.appendingPathComponent("Missing.bundle"), resourceBundle]
            ),
            resource
        )
    }
}
