import XCTest
@testable import Clanker

final class CmuxSupportTests: XCTestCase {
    func testParsesPanelsFromStateFile() throws {
        let json = """
        {
          "version": 1,
          "windows": [
            {
              "windowId": "WIN-1",
              "tabManager": {
                "workspaces": [
                  {
                    "workspaceId": "WS-1",
                    "processTitle": "…/Developer/personal/apdraw",
                    "panels": [
                      {
                        "id": "PANEL-1",
                        "directory": "/Users/me/Developer/personal/apdraw",
                        "title": "…/Developer/personal/apdraw",
                        "ttyName": "ttys007",
                        "type": "terminal",
                        "terminal": {
                          "workingDirectory": "/Users/me/Developer/personal/apdraw"
                        }
                      },
                      {
                        "id": "PANEL-2",
                        "directory": "/Users/me/proj",
                        "title": "run tests",
                        "ttyName": "ttys009",
                        "type": "terminal"
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-state-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let panels = try XCTUnwrap(CmuxSupport.parseStateFile(url))
        XCTAssertEqual(panels.count, 2)

        let first = try XCTUnwrap(panels.first { $0.panelID == "PANEL-1" })
        XCTAssertEqual(first.tty, "/dev/ttys007")
        XCTAssertEqual(first.cwd, "/Users/me/Developer/personal/apdraw")
        XCTAssertEqual(first.workspaceID, "WS-1")
        XCTAssertEqual(first.windowID, "WIN-1")
        // Path-shaped titles carry no information beyond cwd — dropped.
        XCTAssertNil(first.title)

        let second = try XCTUnwrap(panels.first { $0.panelID == "PANEL-2" })
        XCTAssertEqual(second.tty, "/dev/ttys009")
        XCTAssertEqual(second.title, "run tests")
    }

    func testPanelsByTTYIndexesNormalizedTTY() throws {
        let json = """
        {
          "windows": [
            {
              "windowId": "W",
              "tabManager": {
                "workspaces": [
                  {
                    "workspaceId": "S",
                    "panels": [
                      { "id": "P", "ttyName": "ttys003", "directory": "/tmp" }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-state-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let byTTY = CmuxSupport.panelsByTTY(stateFile: url)
        XCTAssertEqual(byTTY["/dev/ttys003"]?.panelID, "P")
    }

    func testMalformedStateFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-state-\(UUID().uuidString).json")
        try "not json".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(CmuxSupport.parseStateFile(url))
    }
}
