import Foundation

/// "Create Lightroom catalog": copy the app's bundled empty catalog to <catalogs>/<base>/<base>.lrcat and open it.
/// Deliberately minimal — never writes to any catalog database.
public enum Lightroom {
    public static let bundleID = "com.adobe.LightroomClassicCC7"

    /// <catalogs>/<base>/<base>.lrcat — `base` comes from `Naming.baseName`, same as the import folder.
    public static func catalogURL(base: String, catalogsFolder: URL) -> URL {
        catalogsFolder.appendingPathComponent(base, isDirectory: true).appendingPathComponent("\(base).lrcat")
    }

    public static func instructions(ssdFolder: URL) -> String {
        "In Lightroom: Import → select \(ssdFolder.path) → turn on Include Subfolders → choose Add (not Copy or Move)."
    }

    public enum CreateResult: Equatable, Sendable { case created(URL), existing(URL) }

    /// Copies the empty template catalog (Resources/EmptyCatalog.lrcat, made with Lightroom Classic and scrubbed of
    /// personal settings). Never overwrites: an existing catalog is just opened. `open` is injected for tests.
    @discardableResult
    public static func createAndOpen(template: URL, catalog: URL, open: (URL) -> Void) throws -> CreateResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: catalog.path) { open(catalog); return .existing(catalog) }
        try fm.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: catalog)     // fails rather than overwrites if something raced us
        open(catalog)
        return .created(catalog)
    }
}
