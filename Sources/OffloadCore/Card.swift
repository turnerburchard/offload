import Foundation
import ImageIO

public struct CardFile: Hashable, Sendable {
    public enum Kind: String, Sendable { case photo, video }
    public let kind: Kind
    public let rel: String      // relative to DCIM/ (photo) or PRIVATE/M4ROOT/CLIP/ (video)
    public let size: Int64
    public let url: URL
    public var label: String { (kind == .photo ? "DCIM/" : "CLIP/") + rel }
}

public struct CardScan: Sendable {
    public let root: URL
    public let uuid: String?
    public let files: [CardFile]
    public let scanErrors: [String]
    public var firstCapture: Date?
    public var lastCapture: Date?

    public var name: String { root.lastPathComponent }
    public var photos: [CardFile] { files.filter { $0.kind == .photo } }
    public var videos: [CardFile] { files.filter { $0.kind == .video } }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum Card {
    public static func photoDir(_ root: URL) -> URL { root.appendingPathComponent("DCIM", isDirectory: true) }
    public static func videoDir(_ root: URL) -> URL { root.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true) }

    /// Cards are recognised by a DCIM folder, never by name (both Sony cards mount as "Untitled").
    public static func isCard(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: photoDir(root).path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func scan(_ root: URL) -> CardScan {
        var errors: [String] = []
        let photos = walk(photoDir(root), &errors).map { CardFile(kind: .photo, rel: $0.rel, size: $0.size, url: $0.url) }
        let videos = walk(videoDir(root), &errors).map { CardFile(kind: .video, rel: $0.rel, size: $0.size, url: $0.url) }
        let uuid = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return CardScan(root: root, uuid: uuid, files: photos + videos, scanErrors: errors)
    }

    /// Every regular file rsync will copy: everything except AppleDouble `._*` (matches `--exclude='._*'`).
    /// Listing errors are collected, never swallowed: an unlisted folder must not be declared "safe".
    static func walk(_ dir: URL, _ errors: inout [String]) -> [(rel: String, size: Int64, url: URL)] {
        // The enumerator yields realpath'd URLs (/var -> /private/var), so resolve `dir` the same way or `depth` is off.
        // (URL.resolvingSymlinksInPath() can't be used: it strips /private, going the other way.)
        let dir = realpath(dir.path, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p), isDirectory: true) } ?? dir
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        var errs: [String] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys), errorHandler: { url, err in
            errs.append("\(url.path): \(err.localizedDescription)"); return true
        }) else { errors.append("Can't list \(dir.path)"); return [] }
        var out: [(String, Int64, URL)] = []
        let depth = dir.pathComponents.count
        for case let url as URL in e {
            if url.lastPathComponent.hasPrefix("._") { e.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let rel = url.pathComponents.dropFirst(depth).joined(separator: "/")
            guard url.path.hasSuffix("/" + rel) else { errs.append("\(url.path): unexpected path"); continue }
            out.append((rel, Int64(v.fileSize ?? 0), url))
        }
        errors += errs
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: Capture dates (EXIF DateTimeOriginal via ImageIO; works on Sony ARW)

    static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    public static func captureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate.date(from: s)
    }

    public static func captureRange(_ files: [CardFile]) -> (Date?, Date?) {
        let exts: Set = ["arw", "jpg", "jpeg", "hif", "heic", "dng"]
        let dates = files.filter { exts.contains($0.url.pathExtension.lowercased()) }.compactMap { captureDate($0.url) }
        return (dates.min(), dates.max())
    }
}
