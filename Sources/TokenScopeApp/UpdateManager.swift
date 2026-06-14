import AppKit
import Foundation
import SwiftUI
import TokenScopeCore

/// Drives the in-app updater: check the GitHub Releases feed, and (only when a newer release
/// exists AND the app is installed somewhere it can safely replace itself) download the macOS zip,
/// swap the bundle in place via a backup-and-rollback helper, then relaunch.
@MainActor
final class UpdateManager: ObservableObject {
    enum Phase: Equatable {
        case idle                       // not checked yet — "Update Now" disabled
        case checking
        case upToDate                   // checked, already current — "Update Now" disabled
        case available(ReleaseInfo)     // newer release that can be installed in place — enabled
        case manualDownload(ReleaseInfo) // newer release, but can't auto-install here — go to page
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    let currentVersion: String
    /// True for `swift run` / unbundled builds (no Info.plist version). Such builds never offer an
    /// update — there is no real `.app` to replace, and every release would otherwise look newer.
    private let isDevBuild: Bool

    init(currentVersion: String? = nil) {
        let resolved = currentVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        self.currentVersion = (resolved?.isEmpty == false) ? resolved! : "0"
        self.isDevBuild = (resolved == nil || resolved!.isEmpty || resolved == "0")
    }

    /// The release to install, if any — non-nil ONLY in `.available`, i.e. after a check found a
    /// newer release that can be installed in place.
    var availableRelease: ReleaseInfo? {
        if case .available(let release) = phase { return release }
        return nil
    }

    /// "Update Now" is enabled ONLY here: a check must have run AND found a newer, in-place-
    /// installable release. Before any check (`.idle`), when up to date, when only a manual
    /// download is possible, while busy, or after a failure → disabled.
    var canInstall: Bool { availableRelease != nil && !isBusy }

    var isBusy: Bool { phase == .checking || phase == .installing }

    // MARK: - Check

    func check() async {
        guard !isBusy else { return }
        phase = .checking
        do {
            var request = URLRequest(url: UpdateService.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
            guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }
            guard let release = UpdateService.parseRelease(data) else { throw UpdateError.parse }
            lastChecked = Date()
            guard !isDevBuild, UpdateService.isUpdateAvailable(latest: release.version, current: currentVersion) else {
                phase = .upToDate
                return
            }
            // A newer release exists. Offer the one-click install only when we have an installable
            // zip AND the running bundle is in a writable, non-translocated location; otherwise the
            // in-place swap can't work, so route the user to a manual download instead of risking it.
            if release.zipURL != nil, Self.canSelfInstall(at: Bundle.main.bundlePath) {
                phase = .available(release)
            } else {
                phase = .manualDownload(release)
            }
        } catch {
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: - Install

    func install() async {
        guard case .available(let release) = phase, let zipURL = release.zipURL else { return }
        phase = .installing
        do {
            try await Self.downloadAndStageSwap(zipURL: zipURL, destinationBundlePath: Bundle.main.bundlePath)
            // The detached helper now waits for us to quit, swaps the bundle (with rollback) and
            // relaunches. Quitting is the last thing we do.
            NSApp.terminate(nil)
        } catch {
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    /// Opens the GitHub release page for the manual-download case.
    func openReleasePage() {
        let release: ReleaseInfo?
        switch phase {
        case .manualDownload(let r): release = r
        case .available(let r): release = r
        default: release = nil
        }
        if let url = release?.htmlURL { NSWorkspace.shared.open(url) }
    }

    // MARK: - Mechanism

    /// Whether the bundle at `bundlePath` can replace itself in place: it must be a real `.app`,
    /// not running from a read-only Gatekeeper App-Translocation mount, and its parent directory
    /// must be writable (so the same-directory renames in the helper can succeed).
    static func canSelfInstall(at bundlePath: String) -> Bool {
        guard bundlePath.hasSuffix(".app") else { return false }
        if bundlePath.contains("/AppTranslocation/") { return false }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: parent)
    }

    /// Downloads + unzips the new build, then stages a detached helper that — once this process
    /// exits — replaces the bundle with a backup-and-rollback sequence so there is never a moment
    /// with no app present, and always reopens whatever ended up at the destination.
    private static func downloadAndStageSwap(zipURL: URL, destinationBundlePath: String) async throws {
        let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("TokenScopeUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let zipPath = work.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: downloaded, to: zipPath)

        try runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path])

        let newApp = try locateApp(in: work, fileManager: fileManager)
        // The download is quarantined; clear it so the swapped-in copy launches without a prompt.
        _ = try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let pid = ProcessInfo.processInfo.processIdentifier
        let logPath = work.appendingPathComponent("update.log").path
        // Backup-and-rollback swap: stage the new app, move the old one aside, move the new one in,
        // and only then delete the backup. Any failure restores the original. At every step either
        // DEST or BACKUP holds a complete app, so `open "$DEST"` always has something to launch.
        let script = """
        #!/bin/sh
        exec >>\(shellQuote(logPath)) 2>&1
        echo "TokenScope updater started"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        NEW=\(shellQuote(newApp.path))
        DEST=\(shellQuote(destinationBundlePath))
        STAGE="$DEST.update-staged"
        BACKUP="$DEST.update-backup"
        /bin/rm -rf "$STAGE" "$BACKUP"
        if ! /usr/bin/ditto "$NEW" "$STAGE"; then
          echo "stage failed; leaving existing app untouched"
          /usr/bin/open "$DEST"
          exit 1
        fi
        if /bin/mv "$DEST" "$BACKUP"; then
          if /bin/mv "$STAGE" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            /bin/rm -rf "$BACKUP"
            echo "swap succeeded"
          else
            echo "install move failed; restoring backup"
            /bin/mv "$BACKUP" "$DEST"
            /bin/rm -rf "$STAGE"
          fi
        else
          echo "could not move existing app aside; leaving it in place"
          /bin/rm -rf "$STAGE"
        fi
        /usr/bin/open "$DEST"
        """
        let scriptPath = work.appendingPathComponent("relaunch.sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [scriptPath.path]
        try helper.run()
    }

    /// Finds the single `.app` produced by the unzip, instead of assuming its name.
    private static func locateApp(in directory: URL, fileManager: FileManager) throws -> URL {
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else { throw UpdateError.missingApp }
        return app
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.process("\(launchPath) failed (\(process.terminationStatus)): \(output)")
        }
        return output
    }

    /// Single-quote a path for safe interpolation into the /bin/sh helper.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum UpdateError: LocalizedError {
    case network
    case http(Int)
    case parse
    case missingApp
    case process(String)

    var message: String {
        switch self {
        case .network:
            return NSLocalizedString("Network error.", comment: "")
        case .http(let code):
            switch code {
            case 403: return NSLocalizedString("GitHub rate limit reached — please try again later.", comment: "")
            case 404: return NSLocalizedString("No published release found.", comment: "")
            default: return String(format: NSLocalizedString("Server returned %d.", comment: ""), code)
            }
        case .parse:
            return NSLocalizedString("Could not read the release information.", comment: "")
        case .missingApp:
            return NSLocalizedString("The downloaded build was incomplete.", comment: "")
        case .process(let detail):
            return detail
        }
    }

    var errorDescription: String? { message }
}
