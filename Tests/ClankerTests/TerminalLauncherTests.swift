import XCTest
@testable import Clanker

final class TerminalLauncherTests: XCTestCase {
    func testGhosttyUsesMacOSNewWindowService() {
        XCTAssertEqual(TerminalLauncher.ghosttyNewWindowServiceName, "New Ghostty Window Here")
    }

    func testGhosttyUsesMacOSOpenWithWorkingDirectory() {
        let appURL = URL(fileURLWithPath: "/Applications/Ghostty.app")
        let path = "/Users/example/My Project"

        XCTAssertEqual(
            TerminalLauncher.ghosttyOpenArguments(appURL: appURL, path: path),
            [
                "-n",
                "/Applications/Ghostty.app",
                "--args",
                "--working-directory=/Users/example/My Project",
                "--window-inherit-working-directory=false"
            ]
        )
    }
}
