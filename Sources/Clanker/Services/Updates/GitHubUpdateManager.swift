import AppKit
import Foundation
import UserNotifications

struct AppUpdate: Codable, Equatable, Identifiable {
    var id: String { version }

    let version: String
    let releaseName: String
    let releaseNotes: String
    let publishedAt: Date?
    let releasePageURL: URL
    let assetURL: URL?
    let assetName: String?

    var title: String {
        releaseName.isEmpty ? "Clanker \(version)" : releaseName
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Ready"
        case .checking:
            return "Checking…"
        case .upToDate:
            return "Clanker is up to date."
        case .updateAvailable:
            return "Update available."
        case .downloading:
            return "Downloading update…"
        case .installing:
            return "Installing update…"
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class GitHubUpdateManager: ObservableObject {
    static let shared = GitHubUpdateManager()

    @Published private(set) var state: UpdateCheckState = .idle
    @Published private(set) var availableUpdate: AppUpdate?
    @Published private(set) var lastCheckDate: Date?

    @Published var automaticChecksEnabled: Bool {
        didSet {
            defaults.set(automaticChecksEnabled, forKey: DefaultsKey.automaticChecksEnabled)
            rescheduleAutomaticChecks()
        }
    }

    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: DefaultsKey.notificationsEnabled)
        }
    }

    private enum DefaultsKey {
        static let automaticChecksEnabled = "Updates.automaticChecksEnabled"
        static let notificationsEnabled = "Updates.notificationsEnabled"
        static let lastCheckDate = "Updates.lastCheckDate"
        static let cachedRelease = "Updates.cachedRelease"
        static let notifiedVersion = "Updates.notifiedVersion"
        static let skippedVersion = "Updates.skippedVersion"
    }

    private let defaults: UserDefaults
    private var automaticTimer: Timer?
    private var started = false

    private let owner = "jaytel0"
    private let repository = "clanker"
    private let appName = "Clanker"
    private let automaticCheckInterval: TimeInterval = 6 * 60 * 60

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releaseListURL: URL {
        URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    }

    private var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automaticChecksEnabled = defaults.object(forKey: DefaultsKey.automaticChecksEnabled) as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: DefaultsKey.notificationsEnabled) as? Bool ?? true
        self.lastCheckDate = defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date
        restoreCachedReleaseIfNeeded()
    }

    func start() {
        guard !started else { return }
        started = true
        rescheduleAutomaticChecks()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.checkIfDue()
        }
    }

    func checkNow() {
        Task { [weak self] in
            await self?.checkForUpdates(userInitiated: true)
        }
    }

    func installAvailableUpdate() {
        Task { [weak self] in
            await self?.installLatestUpdate()
        }
    }

    func skipAvailableUpdate() {
        guard let availableUpdate else { return }
        defaults.set(availableUpdate.version, forKey: DefaultsKey.skippedVersion)
        self.availableUpdate = nil
        state = .idle
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releaseListURL)
    }

    func openAvailableReleasePage() {
        NSWorkspace.shared.open(availableUpdate?.releasePageURL ?? releaseListURL)
    }

    private func rescheduleAutomaticChecks() {
        automaticTimer?.invalidate()
        automaticTimer = nil

        guard started, automaticChecksEnabled else { return }
        automaticTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkIfDue()
            }
        }
    }

    private func checkIfDue() async {
        guard automaticChecksEnabled else { return }
        if let lastCheckDate, Date().timeIntervalSince(lastCheckDate) < automaticCheckInterval { return }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !state.isBusy else { return }

        state = .checking
        do {
            let update = try await fetchLatestRelease()
            let now = Date()
            lastCheckDate = now
            defaults.set(now, forKey: DefaultsKey.lastCheckDate)

            if let update, userInitiated || !isSkipped(update) {
                if userInitiated {
                    defaults.removeObject(forKey: DefaultsKey.skippedVersion)
                }
                availableUpdate = update
                cache(update)
                state = .updateAvailable
                notifyIfNeeded(about: update)
            } else {
                availableUpdate = nil
                clearCachedRelease()
                state = .upToDate
            }
        } catch {
            if userInitiated {
                state = .failed(error.localizedDescription)
            } else if availableUpdate != nil {
                state = .updateAvailable
            } else {
                state = .idle
            }
        }
    }

    private func fetchLatestRelease() async throws -> AppUpdate? {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Clanker/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.githubStatus(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let release = try decoder.decode(GitHubReleaseResponse.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }

        let releaseVersion = VersionComparator.normalizedVersion(from: release.tagName)
        guard VersionComparator.isNewer(releaseVersion, than: currentVersion) else { return nil }

        let asset = release.assets.bestInstallAsset(appName: appName)
        return AppUpdate(
            version: releaseVersion,
            releaseName: release.name ?? "",
            releaseNotes: release.body ?? "",
            publishedAt: release.publishedDate,
            releasePageURL: release.htmlURL,
            assetURL: asset?.browserDownloadURL,
            assetName: asset?.name
        )
    }

    private func installLatestUpdate() async {
        guard !state.isBusy else { return }
        guard let update = availableUpdate else {
            await checkForUpdates(userInitiated: true)
            guard availableUpdate != nil else { return }
            await installLatestUpdate()
            return
        }
        guard let assetURL = update.assetURL else {
            openAvailableReleasePage()
            state = .failed("No installable .zip asset was attached to this release.")
            return
        }

        let targetBundleURL = Bundle.main.bundleURL
        guard targetBundleURL.pathExtension == "app" else {
            openAvailableReleasePage()
            state = .failed("This build is not running from a Clanker.app bundle. Download the release manually.")
            return
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClankerUpdate-\(UUID().uuidString)", isDirectory: true)
        let extractionURL = tempRoot.appendingPathComponent("Extracted", isDirectory: true)
        let zipURL = tempRoot.appendingPathComponent(assetURL.lastPathComponent.isEmpty ? "Clanker.zip" : assetURL.lastPathComponent)

        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            state = .downloading
            let (downloadedURL, response) = try await URLSession.shared.download(from: assetURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw UpdateError.downloadStatus(httpResponse.statusCode)
            }
            try fileManager.moveItem(at: downloadedURL, to: zipURL)

            state = .installing
            try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
            try await ProcessRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, extractionURL.path])

            guard let candidateAppURL = findExtractedApp(in: extractionURL) else {
                throw UpdateError.extractedAppMissing
            }
            try validateCandidateApp(candidateAppURL, expectedVersion: update.version)
            try await verifyCandidateSignature(candidateAppURL)

            let installerURL = tempRoot.appendingPathComponent("install-clanker-update.zsh")
            try writeInstallerScript(to: installerURL)
            try await ProcessRunner.launchDetached(
                "/bin/zsh",
                arguments: [installerURL.path, candidateAppURL.path, targetBundleURL.path, tempRoot.path, String(ProcessInfo.processInfo.processIdentifier)]
            )
            NSApp.terminate(nil)
        } catch {
            try? fileManager.removeItem(at: tempRoot)
            state = .failed(error.localizedDescription)
        }
    }

    private func restoreCachedReleaseIfNeeded() {
        guard let data = defaults.data(forKey: DefaultsKey.cachedRelease),
              let cached = try? JSONDecoder().decode(AppUpdate.self, from: data),
              VersionComparator.isNewer(cached.version, than: currentVersion),
              !isSkipped(cached) else {
            return
        }
        availableUpdate = cached
        state = .updateAvailable
    }

    private func cache(_ update: AppUpdate) {
        if let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: DefaultsKey.cachedRelease)
        }
    }

    private func clearCachedRelease() {
        defaults.removeObject(forKey: DefaultsKey.cachedRelease)
    }

    private func isSkipped(_ update: AppUpdate) -> Bool {
        defaults.string(forKey: DefaultsKey.skippedVersion) == update.version
    }

    private func notifyIfNeeded(about update: AppUpdate) {
        guard notificationsEnabled,
              defaults.string(forKey: DefaultsKey.notifiedVersion) != update.version else { return }
        defaults.set(update.version, forKey: DefaultsKey.notifiedVersion)

        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .provisional])) ?? false
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Clanker \(update.version) is available"
            content.body = "Open Clanker’s notch menu to install the update."
            content.sound = nil

            let request = UNNotificationRequest(
                identifier: "clanker-update-\(update.version)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func findExtractedApp(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.pathExtension == "app", url.lastPathComponent == "\(appName).app" {
                return url
            }
        }
        return nil
    }

    private func validateCandidateApp(_ appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL) else {
            throw UpdateError.invalidAppBundle
        }

        let expectedBundleID = Bundle.main.bundleIdentifier ?? "dev.clanker.app"
        guard bundle.bundleIdentifier == expectedBundleID else {
            throw UpdateError.bundleIdentifierMismatch
        }

        let candidateVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard VersionComparator.normalizedVersion(from: candidateVersion) == expectedVersion else {
            throw UpdateError.versionMismatch(candidateVersion)
        }
    }

    private func verifyCandidateSignature(_ appURL: URL) async throws {
        do {
            try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])
        } catch {
            throw UpdateError.signatureInvalid
        }
    }

    private func writeInstallerScript(to url: URL) throws {
        let script = """
        #!/bin/zsh
        set -euo pipefail

        SOURCE_APP="$1"
        TARGET_APP="$2"
        TEMP_DIR="$3"
        APP_PID="$4"

        copy_app() {
          /bin/rm -rf "$TARGET_APP"
          /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
          /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
        }

        for _ in {1..80}; do
          if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.25
        done

        if ! copy_app; then
          /usr/bin/osascript - "$SOURCE_APP" "$TARGET_APP" <<'APPLESCRIPT'
        on run argv
          set sourceApp to item 1 of argv
          set targetApp to item 2 of argv
          do shell script "/bin/rm -rf " & quoted form of targetApp & " && /usr/bin/ditto " & quoted form of sourceApp & " " & quoted form of targetApp & " && /usr/bin/xattr -dr com.apple.quarantine " & quoted form of targetApp with administrator privileges
        end run
        APPLESCRIPT
        fi

        /usr/bin/open -n "$TARGET_APP"
        /bin/rm -rf "$TEMP_DIR"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let publishedAt: String?
    let assets: [GitHubReleaseAsset]

    var publishedDate: Date? {
        guard let publishedAt else { return nil }
        return GitHubDateParser.date(from: publishedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private extension Array where Element == GitHubReleaseAsset {
    func bestInstallAsset(appName: String) -> GitHubReleaseAsset? {
        let zipAssets = filter { $0.name.lowercased().hasSuffix(".zip") }
        return zipAssets.first { $0.name.localizedCaseInsensitiveContains(appName) }
            ?? zipAssets.first
    }
}

private enum VersionComparator {
    static func normalizedVersion(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"[0-9]+(\.[0-9]+)*"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = numericComponents(normalizedVersion(from: candidate))
        let rhs = numericComponents(normalizedVersion(from: current))
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case githubStatus(Int)
    case downloadStatus(Int)
    case extractedAppMissing
    case invalidAppBundle
    case bundleIdentifierMismatch
    case versionMismatch(String)
    case signatureInvalid
    case processFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .githubStatus(let status):
            return "GitHub update check failed (HTTP \(status))."
        case .downloadStatus(let status):
            return "Update download failed (HTTP \(status))."
        case .extractedAppMissing:
            return "The update archive did not contain Clanker.app."
        case .invalidAppBundle:
            return "The downloaded app bundle is invalid."
        case .bundleIdentifierMismatch:
            return "The downloaded app does not match this Clanker build."
        case .versionMismatch(let version):
            return "The downloaded app reported version \(version), which does not match the release."
        case .signatureInvalid:
            return "The downloaded app’s code signature could not be verified."
        case .processFailed(let executable, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(executable) failed with status \(status)."
                : "\(executable) failed: \(detail)"
        }
    }
}

private enum ProcessRunner {
    static func run(_ executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { process in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.processFailed(executable, process.terminationStatus, output))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func launchDetached(_ executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
    }
}

private enum GitHubDateParser {
    static func date(from value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
