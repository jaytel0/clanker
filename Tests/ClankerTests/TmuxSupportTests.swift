import XCTest
@testable import Clanker

final class TmuxSupportTests: XCTestCase {
    func testParsesTmuxPaneLine() throws {
        let pane = try XCTUnwrap(TmuxSupport.parsePaneLine(
            "work\t1\t2\t12345\tttys004\t/Users/example/project"
        ))

        XCTAssertEqual(pane.session, "work")
        XCTAssertEqual(pane.window, "1")
        XCTAssertEqual(pane.pane, "2")
        XCTAssertEqual(pane.pid, 12345)
        XCTAssertEqual(pane.tty, "/dev/ttys004")
        XCTAssertEqual(pane.cwd, "/Users/example/project")
        XCTAssertEqual(pane.paneAddress, "1.2")
        XCTAssertEqual(pane.target, "work:1.2")
    }

    func testParsesEmptyTmuxPaneTTYAndCWDAsNil() throws {
        let pane = try XCTUnwrap(TmuxSupport.parsePaneLine("work\t0\t1\t42\t-\t"))

        XCTAssertNil(pane.tty)
        XCTAssertNil(pane.cwd)
    }

    func testRejectsMalformedTmuxPaneLine() {
        XCTAssertNil(TmuxSupport.parsePaneLine("work\t0\t1\tnot-a-pid\t/dev/ttys004\t/tmp"))
        XCTAssertNil(TmuxSupport.parsePaneLine("work\t0\t1"))
    }
}
