import XCTest
@testable import Clanker

final class TerminalLauncherTests: XCTestCase {
    func testGhosttyUsesMacOSNewWindowService() {
        XCTAssertEqual(TerminalLauncher.ghosttyNewWindowServiceName, "New Ghostty Window Here")
    }
}
