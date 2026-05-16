import Foundation
import XCTest
@testable import Clanker

final class OnboardingScannerTests: XCTestCase {
    func testSuggestsOnlyDeveloperRootWhenItExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let developer = home.appendingPathComponent("Developer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: developer.appendingPathComponent("personal", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("code", isDirectory: true),
            withIntermediateDirectories: true
        )

        let suggestions = OnboardingScanner.suggestedRoots(home: home.path)

        XCTAssertEqual(suggestions.map(\.path), [developer.path])
        XCTAssertEqual(suggestions.map(\.isSelected), [true])
    }

    func testReturnsNoSuggestionsWhenDeveloperRootIsMissing() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClankerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("code", isDirectory: true),
            withIntermediateDirectories: true
        )

        let suggestions = OnboardingScanner.suggestedRoots(home: home.path)

        XCTAssertTrue(suggestions.isEmpty)
    }
}
