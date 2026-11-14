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
