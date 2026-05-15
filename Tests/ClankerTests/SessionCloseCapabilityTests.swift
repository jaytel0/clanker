import XCTest
@testable import Clanker

final class SessionCloseCapabilityTests: XCTestCase {
    func testOnlyProcessGroupCloseRequiresConfirmation() {
        XCTAssertFalse(SessionCloseCapability.none.canClose)
        XCTAssertTrue(SessionCloseCapability.terminalSession.canClose)
        XCTAssertTrue(SessionCloseCapability.processGroup.canClose)

        XCTAssertFalse(SessionCloseCapability.none.requiresConfirmation)
        XCTAssertFalse(SessionCloseCapability.terminalSession.requiresConfirmation)
        XCTAssertTrue(SessionCloseCapability.processGroup.requiresConfirmation)
    }
}
