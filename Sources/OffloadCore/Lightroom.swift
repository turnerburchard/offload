import Foundation

/// "Create Lightroom catalog": copy an empty template .lrcat to <catalogs>/<base>/<base>.lrcat and open it.
/// Deliberately minimal — never writes to any catalog database; the template is only ever read (via a temp copy).
public enum Lightroom {
    public static let bundleID = "com.adobe.LightroomClassicCC7"

    public enum TemplateStatus: Equatable, Sendable {
        case ok
        case notFound, notLrcat, notSQLite
        case locked                       // <name>.lrcat.lock exists: Lightroom has it open
        case notEmpty(Int)                // AgLibraryFile rows
        case unreadable(String)

        public var isUsable: Bool { self == .ok }
        public var message: String {
            switch self {
            case .ok: "Empty Lightroom catalog — good template."
            case .notFound: "File not found."
            case .notLrcat: "Not a .lrcat file."
            case .notSQLite: "Not a Lightroom catalog (not an SQLite database)."
            case .locked: "Lightroom has this catalog open (a .lock file is next to it). Quit Lightroom and choose it again."
            case .notEmpty(let n): "This catalog already contains \(n) photo\(n == 1 ? "" : "s") — every new catalog would start with them. Make an empty one with File > New Catalog."
            case .unreadable(let e): "Couldn't read the catalog: \(e)"
            }
        }
    }

    /// Read-only check. Counts photos on a temp *copy* so the real file is never opened by sqlite.
    public static func validateTemplate(_ url: URL) -> TemplateStatus {
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == "lrcat" else { return .notLrcat }
        guard fm.fileExists(atPath: url.path) else { return .notFound }
        if fm.fileExists(atPath: url.path + ".lock") { return .locked }
        guard let h = FileHandle(forReadingAtPath: url.path) else { return .unreadable("can't open file") }
        let header = (try? h.read(upToCount: 16)) ?? Data()
        try? h.close()
        guard header == Data("SQLite format 3\0".utf8) else { return .notSQLite }

        let tmp = fm.temporaryDirectory.appendingPathComponent("offload-lrcat-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let copy = tmp.appendingPathComponent("t.lrcat")
            try fm.copyItem(at: url, to: copy)
            if fm.fileExists(atPath: url.path + "-wal") { try fm.copyItem(atPath: url.path + "-wal", toPath: copy.path + "-wal") }
            let (status, out, err) = sqlite(copy, "SELECT COUNT(*) FROM AgLibraryFile;")
            guard status == 0, let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .unreadable(err.contains("no such table") ? "not a Lightroom catalog (no AgLibraryFile table)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return n == 0 ? .ok : .notEmpty(n)
        } catch { return .unreadable(error.localizedDescription) }
    }

    public struct Discovery: Sendable {
        public let template: URL?                              // first candidate that validates
        public let candidates: [(url: URL, status: TemplateStatus)]   // everything looked at, in order
        /// Why nothing usable was found (e.g. Lightroom has the template open), for the UI.
        public var problem: String? {
            guard template == nil else { return nil }
            guard let (u, st) = candidates.first(where: { $0.status != .notFound }) else {
                return "No template catalog found. In Lightroom, File → New Catalog, name it 'template' in your Pictures folder, then quit Lightroom and click again."
            }
            if st == .locked { return "Lightroom has the template catalog open (\(u.lastPathComponent)). Quit Lightroom, then click again." }
            return "\(u.path): \(st.message)"
        }
    }

    /// Finds the template: optional override first, then <catalogs>/template/template.lrcat, then any
    /// <catalogs>/<dir>/*.lrcat or <catalogs>/*.lrcat whose name contains "template". First valid one wins.
    public static func discoverTemplate(in catalogs: URL, override: URL? = nil) -> Discovery {
        let fm = FileManager.default
        var urls: [URL] = override.map { [$0] } ?? []
        urls.append(catalogs.appendingPathComponent("template/template.lrcat"))
        let isTemplate: (URL) -> Bool = { $0.pathExtension.lowercased() == "lrcat" && $0.lastPathComponent.lowercased().contains("template") }
        let top = ((try? fm.contentsOfDirectory(at: catalogs, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        urls += top.filter(isTemplate)
        for dir in top where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && dir.pathExtension.isEmpty {
            urls += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter(isTemplate)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        var seen = Set<String>(), checked: [(URL, TemplateStatus)] = []
        for u in urls where seen.insert(u.standardizedFileURL.path).inserted {
            let st = validateTemplate(u)
            checked.append((u, st))
            if st.isUsable { return Discovery(template: u, candidates: checked) }
        }
        return Discovery(template: nil, candidates: checked)
    }

    /// <catalogs>/<base>/<base>.lrcat — `base` comes from `Naming.baseName`, same as the import folder.
    public static func catalogURL(base: String, catalogsFolder: URL) -> URL {
        catalogsFolder.appendingPathComponent(base, isDirectory: true).appendingPathComponent("\(base).lrcat")
    }

    public static func instructions(ssdFolder: URL) -> String {
        "In Lightroom: Import → select \(ssdFolder.path) → turn on Include Subfolders → choose Add (not Copy or Move)."
    }

    public enum CreateResult: Equatable, Sendable { case created(URL), existing(URL) }
    public struct TemplateError: LocalizedError { public let status: TemplateStatus; public var errorDescription: String? { "Template catalog: " + status.message } }

    /// Copies ONLY the template .lrcat (no -data, Previews, Helper, -wal, -shm, lock). Never overwrites:
    /// an existing catalog is just opened. `open` is injected (the app uses NSWorkspace; tests record calls).
    @discardableResult
    public static func createAndOpen(template: URL, catalog: URL, open: (URL) -> Void) throws -> CreateResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: catalog.path) { open(catalog); return .existing(catalog) }
        let status = validateTemplate(template)
        guard status.isUsable else { throw TemplateError(status: status) }
        try fm.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: catalog)     // fails rather than overwrites if something raced us
        open(catalog)
        return .created(catalog)
    }

    static func sqlite(_ db: URL, _ sql: String) -> (Int32, String, String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", db.path, sql]
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
