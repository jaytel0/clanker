import AppKit
import Combine
import CoreGraphics
import Foundation

enum NotchDisplayMode: Equatable {
    case followActiveDisplay
    case locked(CGDirectDisplayID)
}

struct NotchDisplayDescriptor: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool

    var iconName: String {
        isBuiltIn ? "macbook" : "display"
    }
}

@MainActor
final class NotchDisplaySettings: ObservableObject {
    static let shared = NotchDisplaySettings()

    private enum Key {
        static let mode = "notch.display.mode"
        static let lockedDisplayID = "notch.display.lockedDisplayID"
    }

    private enum ModeValue {
        static let followActiveDisplay = "followActiveDisplay"
        static let lockedDisplay = "lockedDisplay"
    }

    @Published private(set) var mode: NotchDisplayMode {
        didSet { persistMode() }
    }

    @Published private(set) var availableDisplays: [NotchDisplayDescriptor] = []
    @Published private(set) var currentDisplayID: CGDirectDisplayID?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.string(forKey: Key.mode) == ModeValue.lockedDisplay,
           let lockedID = defaults.object(forKey: Key.lockedDisplayID) as? Int {
            self.mode = .locked(CGDirectDisplayID(lockedID))
        } else {
            self.mode = .followActiveDisplay
        }

        refreshDisplays()
    }

    var isFollowingActiveDisplay: Bool {
        if case .followActiveDisplay = mode { return true }
        return false
    }

    var lockedDisplayID: CGDirectDisplayID? {
        if case let .locked(displayID) = mode { return displayID }
        return nil
    }

    var currentDisplay: NotchDisplayDescriptor? {
        guard let currentDisplayID else { return nil }
        return availableDisplays.first { $0.id == currentDisplayID }
    }

    var lockedDisplayName: String? {
        guard let lockedDisplayID else { return nil }
        return availableDisplays.first { $0.id == lockedDisplayID }?.name
    }

    func followActiveDisplay() {
        mode = .followActiveDisplay
    }

    func lockToCurrentDisplay() {
        guard let currentDisplayID else { return }
        lock(to: currentDisplayID)
    }

    func lock(to displayID: CGDirectDisplayID) {
        mode = .locked(displayID)
    }

    func noteCurrentScreen(_ screen: NSScreen) {
        currentDisplayID = screen.clankerDisplayID
        refreshDisplays()
    }

    func refreshDisplays() {
        availableDisplays = Self.displayDescriptors()
    }

    func preferredScreen(active activeScreen: NSScreen?) -> NSScreen? {
        switch mode {
        case .followActiveDisplay:
            return activeScreen ?? NSScreen.main ?? NSScreen.screens.first
        case let .locked(displayID):
            return NSScreen.clankerScreen(matching: displayID)
                ?? activeScreen
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
    }

    private func persistMode() {
        switch mode {
        case .followActiveDisplay:
            defaults.set(ModeValue.followActiveDisplay, forKey: Key.mode)
            defaults.removeObject(forKey: Key.lockedDisplayID)
        case let .locked(displayID):
            defaults.set(ModeValue.lockedDisplay, forKey: Key.mode)
            defaults.set(Int(displayID), forKey: Key.lockedDisplayID)
        }
    }

    private static func displayDescriptors() -> [NotchDisplayDescriptor] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let displayID = screen.clankerDisplayID else { return nil }
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let rawName = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if isBuiltIn {
                name = "Mac Display"
            } else if rawName.isEmpty {
                name = "Display \(index + 1)"
            } else {
                name = rawName
            }
            return NotchDisplayDescriptor(id: displayID, name: name, isBuiltIn: isBuiltIn)
        }
    }
}

private extension NSScreen {
    var clankerDisplayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func clankerScreen(matching displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.clankerDisplayID == displayID }
    }
}
