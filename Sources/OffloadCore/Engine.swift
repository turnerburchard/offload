import Foundation
import CryptoKit

public enum DriveRole: String, Codable, CaseIterable, Sendable { case none, primary, backup }

public enum Naming {
    public static func slug(_ s: String) -> String {
        let chars = s.lowercased().unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(chars).split(separator: "-").joined(separator: "-")
    }
    public static func month(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
    public static func isValidMonth(_ m: String) -> Bool { m.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
    /// Single source for the import's name: SSD/backup folder and Lightroom catalog both use it.
    public static func baseName(_ month: String, _ desc: String) -> String { "import-\(month)-\(slug(desc))" }
    public static func photoFolder(_ month: String, _ desc: String) -> String { baseName(month, desc) }
    public static func videoFolder(_ month: String, _ desc: String) -> String { "video/\(month)-\(slug(desc))" }
}

public struct Target: Identifiable, Sendable {
    public var id: String { drive }
    public let drive: String
    public let role: DriveRole
    public let volume: URL
    public let photoDir: URL
    public let videoDir: URL?          // backups only, and only when the card has video
    public func dest(_ f: CardFile) -> URL? { (f.kind == .photo ? photoDir : videoDir)?.appendingPathComponent(f.rel) }
    public func files(_ card: CardScan) -> [CardFile] { card.files.filter { dest($0) != nil } }
}

public struct Plan: Sendable {
    public var targets: [Target] = []
    public var missing: [String] = []            // configured but not mounted
    public var backupsConfigured: [String] = []
    public var problems: [String] = []           // block the copy
    public var warnings: [String] = []
}

public enum Engine {
    public static let logPrefix = "offload-verify-"

    /// `requireMountPoint`: a configured drive counts as present only if its path is a real mount point,
    /// so an unplugged drive's leftover /Volumes/<name> folder on the boot disk is never written to.
    public static func plan(card: CardScan, month: String, desc: String, roles: [String: DriveRole],
                            volumesRoot: URL, requireMountPoint: Bool = true) -> Plan {
        var p = Plan()
        if Naming.slug(desc).isEmpty { p.problems.append("Enter a name for this import.") }
        if !Naming.isValidMonth(month) { p.problems.append("Month must look like 2026-11.") }
        if card.files.isEmpty { p.problems.append("No files found on the card.") }
        let checkFolders = p.problems.isEmpty
        let ordered = roles.filter { $0.value != .none }.sorted { ($0.value == .primary ? 0 : 1, $0.key) < ($1.value == .primary ? 0 : 1, $1.key) }
        for (drive, role) in ordered {
            if role == .backup { p.backupsConfigured.append(drive) }
            let vol = volumesRoot.appendingPathComponent(drive, isDirectory: true)
            let isMount = (try? vol.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            guard FileManager.default.fileExists(atPath: vol.path), isMount || !requireMountPoint,
                  vol.standardizedFileURL != card.root.standardizedFileURL else { p.missing.append(drive); continue }
            let t = Target(drive: drive, role: role, volume: vol,
                           photoDir: vol.appendingPathComponent(Naming.photoFolder(month, desc)),
                           videoDir: role == .backup && !card.videos.isEmpty ? vol.appendingPathComponent(Naming.videoFolder(month, desc)) : nil)
            if checkFolders {
                for (dir, kind) in [(t.photoDir, CardFile.Kind.photo), (t.videoDir, .video)] {
                    if let dir, let c = conflict(dir, card.files.filter { $0.kind == kind }) { p.problems.append("\(drive): \(c)") }
                }
                let need = t.files(card).reduce(Int64(0)) { $0 + $1.size }
                if let free = try? vol.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity, Int64(free) < need {
                    p.problems.append("\(drive): not enough free space (\(bytes(Int64(free))) free, \(bytes(need)) needed).")
                }
            }
            p.targets.append(t)
        }
        if p.backupsConfigured.isEmpty { p.warnings.append("No backup drives configured — the card can never be marked safe to wipe.") }
        for m in p.missing {
            p.warnings.append(p.backupsConfigured.contains(m)
                ? "Backup “\(m)” is not connected. Copying to the others is fine, but the card will NOT be safe to wipe."
                : "Editing drive “\(m)” is not connected; it won't get a copy.")
        }
        if p.targets.isEmpty { p.problems.append("No destination drives are connected.") }
        return p
    }

    /// Refuse to write into an existing non-empty folder unless it's a resume of the same import:
    /// every file already there must match a card file by relative path and size (MD5 runs afterwards anyway).
    static func conflict(_ dir: URL, _ files: [CardFile]) -> String? {
        var errs: [String] = []
        let existing = Card.walk(dir, &errs).filter { !$0.rel.split(separator: "/").contains { $0.hasPrefix(".") } && !$0.rel.hasPrefix(logPrefix) }
        let expected = Dictionary(files.map { ($0.rel, $0.size) }, uniquingKeysWith: { a, _ in a })
        if let foreign = existing.first(where: { expected[$0.rel] != $0.size }) {
            return "\(dir.lastPathComponent) already exists and contains \(foreign.rel), which is not from this card. Pick a different name."
        }
        return errs.first.map { "can't read existing folder: \($0)" }
    }

    public static func md5(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var md5 = Insecure.MD5()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { md5.update(data: d) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct Missing: Error {}

    /// Plain-language reason for a failed read (Foundation's own text for EACCES says "permission to save").
    public static func readReason(_ e: Error) -> String {
        let ns = e as NSError
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(u.code))) }
        if ns.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(ns.code))) }
        return ns.localizedFailureReason ?? ns.localizedDescription
    }

    /// Hash each card file once and every destination copy in parallel (different devices).
    /// `knownCard` holds card MD5s from an earlier pass (card files don't change), so the card isn't re-read.
    public static func verify(_ card: CardScan, _ targets: [Target], files: [CardFile]? = nil, knownCard: [String: String] = [:],
                              cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> [FileResult] {
        let files = files ?? card.files
        let total = Double(max(1, files.reduce(0) { $0 + $1.size }))
        var done: Int64 = 0, results: [FileResult] = []
        for f in files {
            if cancelled() { break }
            let ts = targets.filter { $0.dest(f) != nil }
            var hashes = [Result<String, Error>](repeating: .failure(Missing()), count: ts.count + 1)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: ts.count + 1) { i in
                let r: Result<String, Error>
                if i == 0 { r = knownCard[f.label].map { .success($0) } ?? Result { try md5(f.url) } }
                else {
                    let url = ts[i - 1].dest(f)!
                    r = FileManager.default.fileExists(atPath: url.path) ? Result { try md5(url) } : .failure(Missing())
                }
                lock.withLock { hashes[i] = r }
            }
            let card = try? hashes[0].get()
            var dest: [String: DestStatus] = [:]
            for (i, t) in ts.enumerated() {
                switch hashes[i + 1] {
                case _ where card == nil: dest[t.drive] = .unverified
                case .failure(let e) where e is Missing: dest[t.drive] = .missing
                case .failure(let e): dest[t.drive] = .readError("couldn't read the copy on \(t.drive): \(readReason(e))")
                case .success(let h): dest[t.drive] = h == card ? .ok : .mismatch(h)
                }
            }
            var cardError: String?
            if case .failure(let e) = hashes[0] { cardError = "Couldn't be read from the card (\(readReason(e)))." }
            results.append(FileResult(file: f, cardMD5: card, cardError: cardError, dest: dest))
            done += f.size
            progress(Double(done) / total)
        }
        return results
    }

    /// Combine passes over the same files (SSD pass, backup pass, retry): later card reads win, destinations merge.
    public static func merge(_ a: [FileResult], _ b: [FileResult]) -> [FileResult] {
        var byLabel = Dictionary(a.map { ($0.file.label, $0) }, uniquingKeysWith: { x, _ in x })
        for r in b {
            if let old = byLabel[r.file.label] {
                let md5 = r.cardMD5 ?? old.cardMD5
                byLabel[r.file.label] = FileResult(file: r.file, cardMD5: md5, cardError: md5 == nil ? r.cardError : nil,
                                                   dest: old.dest.merging(r.dest) { _, new in new })
            } else { byLabel[r.file.label] = r }
        }
        let order = (a + b).map(\.file.label)
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }.compactMap { byLabel[$0] }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

public enum DestStatus: Sendable, Equatable {
    case ok, missing, mismatch(String), readError(String)
    case unverified                       // card copy unreadable, nothing to compare against
}

public struct FileResult: Sendable {
    public let file: CardFile
    public let cardMD5: String?
    public let cardError: String?
    public let dest: [String: DestStatus]
}

// MARK: - A run: card -> SSD, verify SSD ("ready for Lightroom"), then card -> backups, verify, logs

public final class OffloadRun: @unchecked Sendable {
    public enum Phase: Sendable { case copyingSSD, verifyingSSD, copyingBackups, verifyingBackups, retrying, done, cancelled }
    public struct SSDStatus: Sendable {
        public let drive: String
        public let folder: URL
        public let ok: Int
        public let problems: [String]      // missing / mismatched / unreadable copies on the SSD
        public let unreadableOnCard: Int
        public var ready: Bool { problems.isEmpty }
    }
    public let card: CardScan
    public let plan: Plan
    public var onCopyProgress: (String, Double) -> Void = { _, _ in }
    public var onVerifyProgress: (Double) -> Void = { _ in }
    public var onPhase: (Phase) -> Void = { _ in }
    public var onSSDVerified: (SSDStatus) -> Void = { _ in }

    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false
    public var isCancelled: Bool { lock.withLock { cancelled } }

    public init(card: CardScan, plan: Plan) { self.card = card; self.plan = plan }

    public func cancel() { lock.withLock { cancelled = true; processes.forEach { $0.terminate() } } }

    /// Prevent idle system sleep (the "caffeinate" part). Closing the lid still sleeps.
    private func awake<T>(_ body: () -> T) -> T {
        let a = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Offloading SD card")
        defer { ProcessInfo.processInfo.endActivity(a) }
        return body()
    }

    /// Blocking; call off the main thread.
    public func run() -> Report {
        awake {
            let ssd = plan.targets.filter { $0.role == .primary }, backups = plan.targets.filter { $0.role != .primary }
            var errors: [String: String] = [:], results: [FileResult] = []
            if !ssd.isEmpty {
                onPhase(.copyingSSD)
                errors.merge(copyAll(ssd)) { a, _ in a }
                onPhase(.verifyingSSD)
                if !isCancelled { results = Engine.verify(card, ssd, cancelled: { self.isCancelled }, progress: onVerifyProgress) }
                for t in ssd where !isCancelled {
                    let s = Report(card: card, plan: plan, results: results, copyErrors: [:], cancelled: false).drives.first { $0.drive == t.drive }
                    onSSDVerified(SSDStatus(drive: t.drive, folder: t.photoDir, ok: s?.ok ?? 0,
                                            problems: (s?.mismatched.map { "MISMATCH \($0)" } ?? []) + (s?.missing.map { "MISSING \($0)" } ?? []) + (s?.readErrors ?? []),
                                            unreadableOnCard: results.filter { $0.cardError != nil }.count))
                }
            }
            if !backups.isEmpty && !isCancelled {
                onPhase(.copyingBackups)
                errors.merge(copyAll(backups)) { a, _ in a }
                onPhase(.verifyingBackups)
                let known = Dictionary(results.compactMap { r in r.cardMD5.map { (r.file.label, $0) } }, uniquingKeysWith: { a, _ in a })
                if !isCancelled { results = Engine.merge(results, Engine.verify(card, backups, knownCard: known, cancelled: { self.isCancelled }, progress: onVerifyProgress)) }
            }
            var report = Report(card: card, plan: plan, results: results, copyErrors: errors, cancelled: isCancelled)
            report.writeLogs()
            onPhase(isCancelled ? .cancelled : .done)
            return report
        }
    }

    /// Re-attempt only the files that couldn't be read from the card: copy each one to every drive, verify, merge.
    public func retryUnreadable(_ previous: Report) -> Report {
        awake {
            onPhase(.retrying)
            let files = previous.results.filter { $0.cardError != nil }.map(\.file)
            var errors: [String: String] = [:]
            for f in files where !isCancelled {
                for t in plan.targets {
                    guard let dst = t.dest(f) else { continue }
                    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let (status, stderr) = rsync(["-t", "--modify-window=2", f.url.path, dst.path]) { _ in }
                    if status != 0 { errors[t.drive, default: ""] += "rsync exited \(status): \(stderr.suffix(400))" }
                }
            }
            let fresh = Engine.verify(card, plan.targets, files: files, cancelled: { self.isCancelled }, progress: onVerifyProgress)
            var report = Report(card: card, plan: plan, results: Engine.merge(previous.results, fresh), copyErrors: errors, cancelled: isCancelled)
            report.writeLogs()
            onPhase(isCancelled ? .cancelled : .done)
            return report
        }
    }

    /// One rsync per destination, destinations in parallel.
    func copyAll(_ targets: [Target]) -> [String: String] {
        var errors: [String: String] = [:]
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let t = targets[i]
            let files = t.files(card)
            let sizes = Dictionary(files.map { ("\($0.kind.rawValue):\($0.rel)", $0.size) }, uniquingKeysWith: { a, _ in a })
            let total = Double(max(1, files.reduce(0) { $0 + $1.size }))
            // Files already present with the right size count as done (resume).
            var done = files.filter { f in (try? t.dest(f)!.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) == f.size } ?? false }
                .reduce(Int64(0)) { $0 + $1.size }
            onCopyProgress(t.drive, Double(done) / total)
            var jobs: [(URL, URL, CardFile.Kind)] = [(Card.photoDir(card.root), t.photoDir, .photo)]
            if let v = t.videoDir { jobs.append((Card.videoDir(card.root), v, .video)) }
            for (src, dst, kind) in jobs where !isCancelled {
                var err: String?
                do {
                    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
                    // rsync -rt --modify-window=2 --exclude='._*'  (not -a: exFAT has no POSIX permissions)
                    let (status, stderr) = rsync(["-rt", "--modify-window=2", "--exclude=._*", "-v", src.path + "/", dst.path + "/"]) { line in
                        if let s = sizes["\(kind.rawValue):\(line)"] { done += s; self.onCopyProgress(t.drive, min(1, Double(done) / total)) }
                    }
                    if status != 0 { err = "rsync exited \(status): " + stderr.suffix(800) }
                } catch { err = error.localizedDescription }
                if let err { lock.withLock { errors[t.drive] = [errors[t.drive], err].compactMap { $0 }.joined(separator: "\n") } }
            }
            onCopyProgress(t.drive, 1)
        }
        return errors
    }

    func rsync(_ args: [String], onLine: @escaping (String) -> Void) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let shouldStart: Bool = lock.withLock { if cancelled { return false }; processes.append(p); return true }
        guard shouldStart else { return (-1, "cancelled") }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let g = DispatchGroup()
        var errData = Data()
        g.enter(); DispatchQueue.global().async {
            var buf = Data()
            while case let d = out.fileHandleForReading.availableData, !d.isEmpty {
                buf.append(d)
                while let nl = buf.firstIndex(of: 10) {
                    onLine(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
            g.leave()
        }
        g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        p.waitUntilExit(); g.wait()
        return (p.terminationStatus, String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - Report, verdict, logs

public struct DriveSummary: Sendable {
    public let drive: String
    public let role: DriveRole
    public var ok = 0, unverified = 0
    public var missing: [String] = [], mismatched: [String] = [], readErrors: [String] = []
    public var copyError: String?
    public var logs: [URL] = []
    public var logError: String?
    public var clean: Bool { missing.isEmpty && mismatched.isEmpty && readErrors.isEmpty }
}

public enum Verdict: Sendable {
    case safe
    case notSafe([String])
    public var isSafe: Bool { if case .safe = self { return true }; return false }
}

public struct Report: Sendable {
    public let date = Date()
    public let card: CardScan
    public let plan: Plan
    public let results: [FileResult]
    public let cancelled: Bool
    public var drives: [DriveSummary]
    public let cardUnreadable: [(file: String, error: String)]
    public let verdict: Verdict

    public init(card: CardScan, plan: Plan, results: [FileResult], copyErrors: [String: String], cancelled: Bool) {
        self.card = card; self.plan = plan; self.results = results; self.cancelled = cancelled
        var drives = plan.targets.map { DriveSummary(drive: $0.drive, role: $0.role, copyError: copyErrors[$0.drive]) }
        for r in results {
            for i in drives.indices {
                switch r.dest[drives[i].drive] {
                case .ok: drives[i].ok += 1
                case .unverified: drives[i].unverified += 1
                case .missing: drives[i].missing.append(r.file.label)
                case .mismatch: drives[i].mismatched.append(r.file.label)
                case .readError(let e): drives[i].readErrors.append("\(r.file.label): \(e)")
                case nil: break
                }
            }
        }
        self.drives = drives
        cardUnreadable = results.compactMap { r in r.cardError.map { (r.file.label, $0) } }

        var reasons: [String] = []
        if !cardUnreadable.isEmpty { reasons.append("\(cardUnreadable.count) file(s) could not be read from the card, so they have no verified backup.") }
        if cancelled { reasons.append("The run was cancelled.") }
        if card.files.isEmpty { reasons.append("No files were found on the card.") }
        if !card.scanErrors.isEmpty { reasons.append("Part of the card couldn't be listed (\(card.scanErrors.count) errors).") }
        if results.count < card.files.count { reasons.append("Only \(results.count) of \(card.files.count) files were verified.") }
        if plan.backupsConfigured.isEmpty { reasons.append("No backup drives are configured.") }
        for m in plan.missing where plan.backupsConfigured.contains(m) { reasons.append("Backup drive “\(m)” was not connected.") }
        for d in drives where d.role == .backup && !d.clean {
            reasons.append("\(d.drive): \(d.missing.count) missing, \(d.mismatched.count) mismatched, \(d.readErrors.count) unreadable.")
        }
        verdict = reasons.isEmpty ? .safe : .notSafe(reasons)
    }

    public var headline: String {
        if !cardUnreadable.isEmpty { return "NOT safe to wipe — \(cardUnreadable.count) file\(cardUnreadable.count == 1 ? "" : "s") could not be read from the card" }
        return verdict.isSafe ? "Safe to wipe" : "NOT safe to wipe"
    }

    public func logText(for t: Target) -> String {
        let d = drives.first { $0.drive == t.drive }
        var s = "Offload verification log — \(ISO8601DateFormatter().string(from: date))\n"
        if !cardUnreadable.isEmpty {
            s += "\n!!! \(cardUnreadable.count) FILE(S) COULD NOT BE READ FROM THE CARD — NOT SAFE TO WIPE !!!\n"
            s += cardUnreadable.map { "!!!   \($0.file): \($0.error)\n" }.joined() + "\n"
        }
        s += """
        Card: \(card.root.path)  uuid=\(card.uuid ?? "?")  files=\(card.files.count)  bytes=\(card.totalBytes)
        Drive: \(t.drive) (\(t.role.rawValue))
        Photos -> \(t.photoDir.path)
        Video  -> \(t.videoDir?.path ?? "(none)")
        This drive: \(d?.ok ?? 0) ok, \(d?.missing.count ?? 0) missing, \(d?.mismatched.count ?? 0) mismatched, \(d?.readErrors.count ?? 0) read errors\n
        """
        if let e = d?.copyError { s += "Copy errors:\n\(e)\n" }
        switch verdict {
        case .safe: s += "VERDICT: SAFE TO WIPE\n"
        case .notSafe(let r): s += "VERDICT: NOT SAFE TO WIPE\n" + r.map { "  - \($0)\n" }.joined()
        }
        s += "\nstatus     card-md5                          dest-md5                          file\n"
        for r in results {
            guard let st = r.dest[t.drive] else { continue }
            let c = r.cardMD5 ?? "UNREADABLE-ON-CARD".padding(toLength: 32, withPad: " ", startingAt: 0)
            let (tag, dm): (String, String) = switch st {
                case .ok: ("OK", c)
                case .missing: ("MISSING", "-")
                case .mismatch(let h): ("MISMATCH", h)
                case .readError(let e): ("READERR", e)
                case .unverified: ("UNREADABLE", "-")
            }
            s += "\(tag.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c)  \(dm.padding(toLength: 32, withPad: " ", startingAt: 0))  \(r.file.label)\n"
        }
        return s
    }

    /// Writes the log into each destination's import folder (and its video folder).
    public mutating func writeLogs() {
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate, .withTime])
        for t in plan.targets {
            guard let i = drives.firstIndex(where: { $0.drive == t.drive }) else { continue }
            let text = logText(for: t)
            for dir in [t.photoDir, t.videoDir].compactMap({ $0 }) where FileManager.default.fileExists(atPath: dir.path) {
                let url = dir.appendingPathComponent("\(Engine.logPrefix)\(stamp).log")
                do { try text.write(to: url, atomically: true, encoding: .utf8); drives[i].logs.append(url) }
                catch { drives[i].logError = error.localizedDescription }
            }
        }
    }
}
