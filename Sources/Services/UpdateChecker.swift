import AppKit
import Foundation

@MainActor @Observable
final class UpdateChecker {
    struct Release: Sendable {
        let version: String
        let htmlURL: URL
        /// URL of the Clusage.dmg asset, if present on the release.
        let dmgURL: URL?
    }

    enum InstallState: Equatable {
        case idle
        case downloading(progress: Double)
        case verifying
        case installing
        case failed(String)
    }

    private(set) var availableRelease: Release?
    private(set) var isChecking = false
    private(set) var lastError: String?
    private(set) var installState: InstallState = .idle

    /// Called the first time a given version shows up as available. Used to post a
    /// user notification. Set by ClusageApp.
    var onUpdateAvailable: (@MainActor (Release) -> Void)?

    private var timerTask: Task<Void, Never>?
    private static let checkInterval: TimeInterval = 6 * 60 * 60 // 6 hours

    var autoCheck: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.autoCheckUpdates) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKeys.autoCheckUpdates)
            if newValue { schedulePeriodicCheck() } else { timerTask?.cancel() }
        }
    }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.skipVersion) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.skipVersion) }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    init() {
        // Default to auto-check enabled on first launch
        if UserDefaults.standard.object(forKey: DefaultsKeys.autoCheckUpdates) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.autoCheckUpdates)
        }
    }

    func startIfEnabled() {
        guard autoCheck else { return }
        schedulePeriodicCheck()
        // Check on launch if last check was > 6 hours ago
        let lastCheck = UserDefaults.standard.double(forKey: DefaultsKeys.lastUpdateCheck)
        if Date().timeIntervalSince1970 - lastCheck > Self.checkInterval {
            Task { await checkForUpdate() }
        }
    }

    func checkForUpdate() async {
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastUpdateCheck)

            if isNewer(release.version, than: currentVersion) {
                if skippedVersion == release.version {
                    Log.update.info("Update \(release.version) available but skipped by user")
                    availableRelease = nil
                } else {
                    Log.update.info("Update available: \(release.version) (current: \(self.currentVersion))")
                    let isNew = availableRelease?.version != release.version
                    availableRelease = release
                    if isNew, UserDefaults.standard.string(forKey: DefaultsKeys.lastNotifiedVersion) != release.version {
                        UserDefaults.standard.set(release.version, forKey: DefaultsKeys.lastNotifiedVersion)
                        onUpdateAvailable?(release)
                    }
                }
            } else {
                Log.update.info("Already on latest version \(self.currentVersion)")
                availableRelease = nil
            }
        } catch {
            Log.update.error("Update check failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func skipCurrentUpdate() {
        guard let release = availableRelease else { return }
        skippedVersion = release.version
        availableRelease = nil
        Log.update.info("User skipped version \(release.version)")
    }

    // MARK: - Install

    /// Download the DMG for the current available release, verify it, and schedule an
    /// in-place swap + relaunch. The app will terminate at the end.
    func downloadAndInstall() async {
        guard let release = availableRelease else { return }
        guard let dmgURL = release.dmgURL else {
            installState = .failed("This release does not include a direct download.")
            return
        }

        installState = .downloading(progress: 0)
        Log.update.info("Starting in-place install of \(release.version) from \(dmgURL)")

        do {
            let localDMG = try await Installer.downloadDMG(
                from: dmgURL,
                version: release.version,
                onProgress: { [weak self] fraction in
                    guard let self else { return }
                    // Only bump UI if still in downloading state
                    if case .downloading = self.installState {
                        self.installState = .downloading(progress: fraction)
                    }
                }
            )

            installState = .verifying

            let mountPoint = try Installer.mountDMG(at: localDMG)
            let newApp = mountPoint.appendingPathComponent("Clusage.app")

            guard FileManager.default.fileExists(atPath: newApp.path) else {
                Installer.unmount(mountPoint)
                throw Installer.Error(message: "Clusage.app not found inside DMG")
            }

            do {
                try Installer.verify(appAt: newApp)
            } catch {
                Installer.unmount(mountPoint)
                throw error
            }

            let destination = Installer.currentBundleURL
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                Installer.unmount(mountPoint)
                throw Installer.Error(message: "Cannot write to \(destination.deletingLastPathComponent().path). Please download manually.")
            }

            installState = .installing

            try Installer.scheduleSwapAndRelaunch(
                source: newApp,
                destination: destination,
                mountPoint: mountPoint,
                dmg: localDMG
            )

            // Allow the spawned script a moment to reach its wait loop, then quit.
            try? await Task.sleep(for: .milliseconds(200))
            Log.update.info("Terminating app to complete install")
            NSApp.terminate(nil)
        } catch {
            Log.update.error("Install failed: \(error.localizedDescription)")
            installState = .failed(error.localizedDescription)
        }
    }

    func resetInstallState() {
        installState = .idle
    }

    // MARK: - Private

    private func schedulePeriodicCheck() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checkInterval))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdate()
            }
        }
    }

    private struct GitHubAsset: Decodable, Sendable {
        let name: String
        let browser_download_url: String
    }

    private struct GitHubRelease: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let assets: [GitHubAsset]
    }

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/seventwo-studio/clusage/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let ghRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = ghRelease.tag_name.hasPrefix("v")
            ? String(ghRelease.tag_name.dropFirst())
            : ghRelease.tag_name

        guard let htmlURL = URL(string: ghRelease.html_url) else {
            throw URLError(.badURL)
        }

        let dmgURL = ghRelease.assets
            .first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            .flatMap { URL(string: $0.browser_download_url) }

        return Release(version: version, htmlURL: htmlURL, dmgURL: dmgURL)
    }

    /// Semantic version comparison: returns true if `a` is newer than `b`.
    /// Strips pre-release suffixes (e.g. "-beta.1") before comparing numeric parts.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = numericVersionParts(a)
        let partsB = numericVersionParts(b)
        for i in 0..<max(partsA.count, partsB.count) {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    /// Extract numeric version parts, stripping any pre-release suffix (e.g. "1.2.3-beta.1" → [1, 2, 3]).
    private func numericVersionParts(_ version: String) -> [Int] {
        let base = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        return base.split(separator: ".").compactMap { Int($0) }
    }
}
