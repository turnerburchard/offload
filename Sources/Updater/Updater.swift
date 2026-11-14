import Foundation
import CryptoKit

/// Minimal self-updater for an ad-hoc-signed app distributed via GitHub Releases.
/// UI-free so it can be tested offline; the app decides when to ask and when it's safe to install.

public struct SemVer: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int
    public let pre: [String]          // "1.2.0-beta.1" -> ["beta", "1"]; empty = release

    public init?(_ s: String) {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let main = s.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""   // drop build metadata
        let parts = main.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(nums.count), nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let n = nums.map { $0! } + Array(repeating: 0, count: 3 - nums.count)
        (major, minor, patch) = (n[0], n[1], n[2])
        pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    public var description: String { "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }   // prerelease < release
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true                  // numeric identifiers sort before alphanumeric
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.pre.count < b.pre.count
    }
    public static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: URL
        public let size: Int?
    }
    public let tag_name: String
    public let name: String?
    public let body: String?
    public let html_url: URL?
    public let draft: Bool?
    public let prerelease: Bool?
    public let assets: [Asset]

    public var version: SemVer? { SemVer(tag_name) }
    public var zipAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
}

public enum UpdateError: LocalizedError {
    case badResponse(String), noZip, noChecksum, checksumMismatch(expected: String, actual: String)
    case unzipFailed(String), noApp, wrongBundleID(String?), signatureInvalid(String), signerMismatch(String), notWritable(String), translocated, swapFailed(String)
    public var errorDescription: String? {
        switch self {
        case .badResponse(let s): "GitHub request failed: \(s)"
        case .noZip: "The release has no .zip asset."
        case .noChecksum: "The release doesn't publish a SHA-256 checksum for its .zip, so it won't be installed."
        case .checksumMismatch(let e, let a): "Downloaded file's SHA-256 doesn't match the release (expected \(e), got \(a))."
        case .unzipFailed(let s): "Couldn't unzip the update: \(s)"
        case .noApp: "The update zip doesn't contain an .app."
        case .wrongBundleID(let id): "The update is a different app (bundle id \(id ?? "missing"))."
        case .signatureInvalid(let s): "The update's code signature is invalid: \(s)"
        case .signerMismatch(let s): "The update isn't signed by the same certificate as this app, so it won't be installed. \(s)"
        case .notWritable(let p): "Can't replace the app at \(p) (no write permission). Download the update manually."
        case .translocated: "macOS is running this copy from a temporary location. Move the app to /Applications, open it from there, then update."
        case .swapFailed(let s): "Couldn't swap in the new version (the current version was left in place): \(s)"
        }
    }
}

public enum Updater {
    // MARK: Check

    public static func latestRelease(repo: String, session: URLSession = .shared) async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Offload-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.badResponse(code == 404 ? "no published release for \(repo)" : "HTTP \(code)") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// The release if it's a newer, non-draft, non-prerelease version that ships a zip.
    public static func newer(_ r: Release, than current: String) -> Release? {
        guard r.draft != true, r.prerelease != true, r.zipAsset != nil,
              let v = r.version, let c = SemVer(current), c < v else { return nil }
        return r
    }

    // MARK: Checksum

    /// Finds the SHA-256 for `fileName` in checksum text ("<hex>  <name>" lines, `shasum` output, or a bare hash).
    public static func parseChecksum(_ text: String, for fileName: String) -> String? {
        var bare: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: #"\b[0-9a-fA-F]{64}\b"#, options: .regularExpression) else { continue }
            let h = line[r].lowercased()
            if line.contains(fileName) { return h }
            bare.append(h)
        }
        return bare.count == 1 ? bare[0] : nil     // a single unlabeled hash is unambiguous
    }

    /// Checksum from a `<zip>.sha256` / `SHA256SUMS` / `checksums.txt` asset, else from the release body.
    public static func expectedSHA256(_ r: Release, fetch: (URL) async throws -> Data) async throws -> String {
        guard let zip = r.zipAsset else { throw UpdateError.noZip }
        let candidates = r.assets.filter {
            let n = $0.name.lowercased()
            return n == zip.name.lowercased() + ".sha256" || n.hasPrefix("sha256sum") || n == "checksums.txt"
        }
        for a in candidates {
            if let h = parseChecksum(String(decoding: try await fetch(a.browser_download_url), as: UTF8.self), for: zip.name) { return h }
        }
        if let body = r.body, let h = parseChecksum(body, for: zip.name) { return h }
        throw UpdateError.noChecksum
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { sha.update(data: d) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Prepare + install

    /// How an app is signed: ad-hoc (no certificate) or with a certificate, plus its designated requirement.
    public struct Signing: Sendable { public let adhoc: Bool; public let requirement: String? }

    public static func signing(of app: URL) -> Signing {
        let (_, info) = run("/usr/bin/codesign", ["-dv", app.path])                 // details go to stderr
        let (_, out) = run("/usr/bin/codesign", ["-d", "-r-", app.path], captureStdout: true)
        let req = out.split(whereSeparator: \.isNewline).first { $0.contains("designated =>") }
            .map { String($0[$0.range(of: "designated =>")!.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return Signing(adhoc: info.contains("Signature=adhoc") || info.contains("flags=0x2(adhoc)"), requirement: req)
    }

    /// The update must satisfy the running app's designated requirement (same identifier + same certificate leaf).
    /// If the running app is ad-hoc signed there's nothing to pin to, so any valid signature is accepted —
    /// that's the one-time migration to a certificate-signed build.
    public static func checkSigner(_ newApp: URL, matches running: URL) throws {
        let cur = signing(of: running)
        guard !cur.adhoc else { return }
        guard let req = cur.requirement else { throw UpdateError.signerMismatch("Couldn't read this app's signing requirement.") }
        let (status, err) = run("/usr/bin/codesign", ["--verify", "-R", "=" + req, newApp.path])
        guard status == 0 else { throw UpdateError.signerMismatch(err.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Verifies the zip's SHA-256, unzips it into `workDir`, and checks bundle id, code signature and
    /// (if `matchSignerOf` is given) that it's signed by the same certificate as the running app.
    /// Returns the ready-to-install .app (quarantine stripped). Throws without touching the installed app.
    public static func prepare(zip: URL, expectedSHA256: String, bundleID: String, workDir: URL, matchSignerOf running: URL? = nil) throws -> URL {
        let actual = try sha256(of: zip)
        guard actual == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch(expected: expectedSHA256, actual: actual) }
        let out = workDir.appendingPathComponent("unzipped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (unzipStatus, unzipErr) = run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard unzipStatus == 0 else { throw UpdateError.unzipFailed(unzipErr) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw UpdateError.noApp }
        let id = Bundle(url: app)?.bundleIdentifier ?? (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String)
        guard id == bundleID else { throw UpdateError.wrongBundleID(id) }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        let (sigStatus, sigErr) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard sigStatus == 0 else { throw UpdateError.signatureInvalid(sigErr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let running { try checkSigner(app, matches: running) }
        return app
    }

    /// Swaps `newApp` into `current`'s place. Old bundle is renamed aside first and restored if anything fails.
    /// `newApp` should be on the same volume (use `workDir(near:)`) so both steps are plain renames.
    public static func install(_ newApp: URL, replacing current: URL) throws {
        let fm = FileManager.default
        let parent = current.deletingLastPathComponent()
        if current.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
        let backup = parent.appendingPathComponent(".\(current.lastPathComponent).old-\(UUID().uuidString.prefix(8))")
        do { try fm.moveItem(at: current, to: backup) } catch { throw UpdateError.swapFailed(error.localizedDescription) }
        do { try fm.moveItem(at: newApp, to: current) } catch {
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: backup, to: current)
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: backup)
    }

    /// Install-on-quit: swap in a staged update unless a copy/verify run is in progress.
    /// Returns true if the new version is now in place. Failures leave the old app intact.
    @discardableResult
    public static func installOnQuit(staged: URL?, appURL: URL, runInProgress: Bool) -> Bool {
        guard !runInProgress, let staged, FileManager.default.fileExists(atPath: staged.path) else { return false }
        return (try? install(staged, replacing: appURL)) != nil
    }

    /// Temp dir on the same volume as `url`, so the final move is a rename.
    public static func workDir(near url: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    }

    /// Download + verify into a staging dir next to the app, without touching the installed app.
    /// Returns the staged .app; install it later with `install(_:replacing:)` (e.g. when the app quits).
    public static func stage(_ r: Release, bundleID: String, appURL: URL) async throws -> URL {
        guard let zip = r.zipAsset else { throw UpdateError.noZip }
        let fetch: (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
        let sha = try await expectedSHA256(r, fetch: fetch)
        let work = try workDir(near: appURL)
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: zip.browser_download_url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse("download failed") }
            let local = work.appendingPathComponent(zip.name)
            try FileManager.default.moveItem(at: tmp, to: local)
            let app = try prepare(zip: local, expectedSHA256: sha, bundleID: bundleID, workDir: work, matchSignerOf: appURL)
            try? FileManager.default.removeItem(at: local)
            return app
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Download → verify → install now. Leaves the installed app untouched on any failure.
    public static func downloadAndInstall(_ r: Release, bundleID: String, appURL: URL) async throws {
        let staged = try await stage(r, bundleID: bundleID, appURL: appURL)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        try install(staged, replacing: appURL)
    }

    /// Waits for this process to exit, then reopens the app.
    public static func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
        try? p.run()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], captureStdout: Bool = false) -> (Int32, String) {
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardError = err; p.standardOutput = captureStdout ? err : FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
