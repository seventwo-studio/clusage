import AppKit
import Foundation

/// Handles the "download DMG → mount → verify → swap bundle → relaunch" flow.
///
/// macOS can't overwrite a running app bundle, so the actual swap is performed by a
/// short shell script that waits for our PID to exit, copies the new app over the old
/// one, unmounts the DMG, and relaunches. The app calls `NSApp.terminate` right after
/// spawning the script.
enum Installer {
    /// Team ID expected on the downloaded app. Releases are signed with Developer ID
    /// using this team — a mismatch means the download has been tampered with.
    static let expectedTeamID = "96452FLT2P"

    struct Error: Swift.Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Download a DMG to a cache location, reporting progress via `onProgress` (0...1).
    static func downloadDMG(
        from url: URL,
        version: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let cacheDir = try cacheDirectory()
        let destination = cacheDir.appendingPathComponent("Clusage-\(version).dmg")

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error(message: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }

        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let fraction = Double(received) / Double(total)
                    await MainActor.run { onProgress(min(1.0, fraction)) }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        await MainActor.run { onProgress(1.0) }

        Log.update.info("Downloaded DMG: \(received) bytes → \(destination.path)")
        return destination
    }

    /// Mount the DMG and return the mount point.
    static func mountDMG(at url: URL) throws -> URL {
        let plistOutput = try runCapturing(
            "/usr/bin/hdiutil",
            ["attach", url.path, "-nobrowse", "-readonly", "-noautoopen", "-plist"]
        )

        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw Error(message: "Could not parse hdiutil output")
        }

        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                Log.update.info("Mounted DMG at \(mount)")
                return URL(fileURLWithPath: mount)
            }
        }
        throw Error(message: "DMG had no mount point")
    }

    static func unmount(_ mountPoint: URL) {
        _ = try? runCapturing("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    /// Verify that the .app at `appURL` is signed and matches `expectedTeamID`.
    static func verify(appAt appURL: URL) throws {
        // codesign --verify --strict --deep
        let verifyResult = runExitStatus(
            "/usr/bin/codesign",
            ["--verify", "--strict", "--deep", appURL.path]
        )
        guard verifyResult.status == 0 else {
            throw Error(message: "Code signature invalid: \(verifyResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // codesign -dv for Team ID
        let info = runExitStatus("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path])
        // codesign -dv prints to stderr
        let combined = info.stdout + info.stderr
        guard let range = combined.range(of: "TeamIdentifier=") else {
            throw Error(message: "Could not read Team ID from signature")
        }
        let teamID = combined[range.upperBound...]
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard teamID == expectedTeamID else {
            throw Error(message: "Team ID mismatch: got '\(teamID)', expected '\(expectedTeamID)'")
        }
        Log.update.info("Signature verified, team ID \(teamID)")
    }

    /// Spawn the installer script and ask the app to terminate.
    ///
    /// After this returns, the caller should immediately call `NSApp.terminate(nil)`.
    static func scheduleSwapAndRelaunch(
        source: URL,
        destination: URL,
        mountPoint: URL,
        dmg: URL
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = FileManager.default.temporaryDirectory
        let scriptURL = tmp.appendingPathComponent("clusage-installer-\(pid).sh")
        let logURL = tmp.appendingPathComponent("clusage-installer-\(pid).log")

        let script = #"""
        #!/bin/bash
        APP_PID="$1"
        SRC="$2"
        DST="$3"
        MOUNT="$4"
        DMG="$5"
        LOG="$6"
        exec >"$LOG" 2>&1
        echo "[installer] pid=$$ waiting for app pid $APP_PID"
        for _ in $(seq 1 300); do
            kill -0 "$APP_PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$APP_PID" 2>/dev/null; then
            echo "[installer] app did not exit; aborting"
            /usr/bin/hdiutil detach "$MOUNT" -quiet || true
            exit 1
        fi
        echo "[installer] app exited; swapping bundle"
        rm -rf "$DST" || { echo "[installer] failed to remove $DST"; exit 1; }
        cp -R "$SRC" "$DST" || { echo "[installer] failed to copy"; exit 1; }
        /usr/bin/hdiutil detach "$MOUNT" -quiet || true
        rm -f "$DMG" || true
        echo "[installer] relaunching $DST"
        /usr/bin/open "$DST"
        echo "[installer] done"
        """#

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            String(pid),
            source.path,
            destination.path,
            mountPoint.path,
            dmg.path,
            logURL.path,
        ]
        // Detach stdio so the child survives our termination.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        Log.update.info("Installer script launched (pid=\(process.processIdentifier), log=\(logURL.path))")
    }

    /// Destination path where the swapped app should end up. Same as the running bundle.
    static var currentBundleURL: URL {
        Bundle.main.bundleURL
    }

    // MARK: - Helpers

    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("studio.seventwo.clusage/updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private static func runCapturing(_ path: String, _ arguments: [String]) throws -> String {
        let result = runExitStatus(path, arguments)
        guard result.status == 0 else {
            throw Error(message: "\(path) failed (\(result.status)): \(result.stderr)")
        }
        return result.stdout
    }

    private static func runExitStatus(_ path: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", String(describing: error))
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }
}
