// Self-test against fake volumes + offline updater tests.
// Usage: offload-selftest [scratch-dir] [sample.ARW]   (default: a fresh temp dir; the ARW only adds an EXIF check)
import Foundation
import OffloadCore
import Updater

let args = CommandLine.arguments
let fm = FileManager.default
let scratchArg = args.count >= 2 ? URL(fileURLWithPath: args[1])
    : fm.temporaryDirectory.appendingPathComponent("offload-selftest-\(UUID().uuidString.prefix(8))")
try! fm.createDirectory(at: scratchArg, withIntermediateDirectories: true)
// Resolve symlinks (/var -> /private/var) so URLs built here compare equal to ones found by directory scans.
let scratch = realpath(scratchArg.path, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p), isDirectory: true) } ?? scratchArg
print("scratch: \(scratch.path)")
let root = scratch.appendingPathComponent("Volumes")
try? fm.removeItem(at: root)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

func write(_ rel: String, _ data: Data) {
    let u = root.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: u)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: u.path)
}
func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

// Fake card: Sony layout, a reused DSC number in a second folder, AppleDouble junk, video + sidecar.
let card = "Untitled"
write("\(card)/DCIM/100MSDCF/DSC00001.ARW", args.count > 2 ? try! Data(contentsOf: URL(fileURLWithPath: args[2])) : random(500_000))
write("\(card)/DCIM/100MSDCF/DSC00002.ARW", random(300_000))
write("\(card)/DCIM/100MSDCF/DSC00003.JPG", random(100_000))
write("\(card)/DCIM/101MSDCF/DSC00001.ARW", random(400_000))      // same name, different photo
write("\(card)/DCIM/100MSDCF/._DSC00001.ARW", random(4096))         // must be ignored
write("\(card)/PRIVATE/M4ROOT/CLIP/C0001.MP4", random(800_000))
write("\(card)/PRIVATE/M4ROOT/CLIP/C0001M01.XML", Data("<xml/>".utf8))
write("\(card)/PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", random(1000))   // not copied
for d in ["Crucial X6", "Seagate", "HDD Backup 2"] { try! fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
let roles: [String: DriveRole] = ["Crucial X6": .primary, "Seagate": .backup, "HDD Backup 2": .backup]
let cardURL = root.appendingPathComponent(card)

// 1. Naming
check(Naming.slug("  Bears Ears! ") == "bears-ears", "slug")
check(Naming.photoFolder("2026-11", "Bears Ears") == "import-2026-11-bears-ears", "photo folder name")
check(Naming.isValidMonth("2026-11") && !Naming.isValidMonth("2026-13") && !Naming.isValidMonth("2026-9"), "month validation")

// 2. Scan
check(Card.isCard(cardURL) && !Card.isCard(root.appendingPathComponent("Seagate")), "card detected by DCIM, drives aren't")
var scan = Card.scan(cardURL)
check(scan.photos.count == 4 && scan.videos.count == 2, "scan: 4 photos + 2 video files, ._ and THMBNL excluded (got \(scan.photos.count)+\(scan.videos.count))")
let (first, last) = Card.captureRange(scan.photos)
scan.firstCapture = first; scan.lastCapture = last
if args.count > 2 { check(first != nil, "EXIF DateTimeOriginal read from real ARW via ImageIO: \(first.map { "\($0)" } ?? "nil")") }

func runOnce(_ desc: String, _ scan: CardScan, mount: Bool = false) -> (Plan, Report?) {
    let plan = Engine.plan(card: scan, month: "2026-11", desc: desc, roles: roles, volumesRoot: root, requireMountPoint: mount)
    guard plan.problems.isEmpty else { return (plan, nil) }
    return (plan, OffloadRun(card: scan, plan: plan).run())
}

// 3. Stale /Volumes folders are not treated as drives when the mount-point check is on
let (strict, _) = runOnce("strict", scan, mount: true)
check(strict.targets.isEmpty && strict.missing.count == 3, "fake dirs aren't mount points -> treated as not connected")

// 4. Happy path
let (plan, rep) = runOnce("Bears Ears", scan)
check(rep?.verdict.isSafe == true, "happy path verdict: \(rep?.headline ?? "no report") \(plan.problems)")
let sg = root.appendingPathComponent("Seagate/import-2026-11-bears-ears")
check(fm.fileExists(atPath: sg.appendingPathComponent("101MSDCF/DSC00001.ARW").path), "reused DSC number copied in its own folder")
check(!fm.fileExists(atPath: sg.appendingPathComponent("100MSDCF/._DSC00001.ARW").path), "._ files not copied")
check(fm.fileExists(atPath: root.appendingPathComponent("HDD Backup 2/video/2026-11-bears-ears/C0001.MP4").path), "video to video/YYYY-MM-name on backups")
check(!fm.fileExists(atPath: root.appendingPathComponent("Crucial X6/video").path), "no video on editing SSD")
check(rep?.drives.allSatisfy { !$0.logs.isEmpty } == true, "verification log written to every destination")
if let log = rep?.drives.first?.logs.first { print("----- \(log.lastPathComponent)\n" + (try! String(contentsOf: log, encoding: .utf8)) + "-----") }

// 5. Silent corruption: same size + same mtime, so rsync's quick check skips it on resume. MD5 must catch it.
let victim = sg.appendingPathComponent("100MSDCF/DSC00002.ARW")
var bytes = try! Data(contentsOf: victim); bytes[1000] ^= 0xFF
try! bytes.write(to: victim)
try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: victim.path)
let (_, rep2) = runOnce("Bears Ears", scan)   // resume of the same import is allowed
let sgSum = rep2?.drives.first { $0.drive == "Seagate" }
check(rep2?.verdict.isSafe == false && sgSum?.mismatched == ["DCIM/100MSDCF/DSC00002.ARW"], "corrupted copy -> MISMATCH, NOT safe")
if case .notSafe(let r)? = rep2?.verdict { print("  reasons:", r) }

// 6. Missing file on a backup
try! fm.removeItem(at: root.appendingPathComponent("HDD Backup 2/import-2026-11-bears-ears/100MSDCF/DSC00003.JPG"))
let v = Engine.verify(scan, plan.targets)
let r3 = Report(card: scan, plan: plan, results: v, copyErrors: [:], cancelled: false)
check(r3.drives.first { $0.drive == "HDD Backup 2" }?.missing == ["DCIM/100MSDCF/DSC00003.JPG"] && !r3.verdict.isSafe, "deleted file -> MISSING, NOT safe")

// 7. Existing folder with foreign content is refused
write("Seagate/import-2026-11-escalante/100MSDCF/DSC09999.ARW", random(10))
let (p4, r4) = runOnce("escalante", scan)
check(r4 == nil && p4.problems.contains { $0.contains("not from this card") }, "refuses non-empty folder from another import")

// 8. A backup drive not plugged in: copy to the rest, verdict NOT safe
let hdd2 = root.appendingPathComponent("HDD Backup 2"), away = root.appendingPathComponent("../HDD2-unplugged")
try! fm.moveItem(at: hdd2, to: away)
let (p5, r5) = runOnce("utah", scan)
check(p5.missing == ["HDD Backup 2"] && p5.targets.count == 2, "missing backup reported, copies to the other two")
check(r5?.verdict.isSafe == false && r5?.drives.allSatisfy(\.clean) == true, "available drives verify clean but verdict NOT safe")
try! fm.moveItem(at: away, to: hdd2)

// 9. Unreadable card file: BLOCKS the wipe, plain error text, top of log, then "Retry unreadable files" fixes it
let bad = cardURL.appendingPathComponent("DCIM/100MSDCF/DSC00003.JPG")
try! fm.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
let p6 = Engine.plan(card: scan, month: "2026-11", desc: "oregon", roles: roles, volumesRoot: root, requireMountPoint: false)
let run6 = OffloadRun(card: scan, plan: p6)
let r6 = run6.run()
check(!r6.verdict.isSafe && r6.headline == "NOT safe to wipe — 1 file could not be read from the card", "unreadable -> NOT safe: \(r6.headline)")
let err = r6.cardUnreadable.first?.error ?? ""
check(err.hasPrefix("Couldn't be read from the card") && !err.contains("save"), "plain error text: \(err)")
let log6 = try! String(contentsOf: r6.drives[0].logs[0], encoding: .utf8)
check(log6.split(separator: "\n").dropFirst().first(where: { !$0.isEmpty })?.contains("COULD NOT BE READ FROM THE CARD") == true, "unreadable files at top of log")
print(log6.split(separator: "\n").prefix(5).joined(separator: "\n"))
try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad.path)
let r6b = run6.retryUnreadable(r6)
check(r6b.verdict.isSafe && r6b.cardUnreadable.isEmpty, "retry after the file becomes readable -> \(r6b.headline)")
check(r6b.drives.allSatisfy { fm.fileExists(atPath: root.appendingPathComponent("\($0.drive)/import-2026-11-oregon/100MSDCF/DSC00003.JPG").path) },
      "retried file now on every drive")

// 10. SSD first: SSD copied + verified ("ready for Lightroom") before any backup folder exists
let p7 = Engine.plan(card: scan, month: "2026-11", desc: "winds", roles: roles, volumesRoot: root, requireMountPoint: false)
let run7 = OffloadRun(card: scan, plan: p7)
var phases: [OffloadRun.Phase] = [], backupsExistedAtReady = true, ready: OffloadRun.SSDStatus?
run7.onPhase = { phases.append($0) }
run7.onSSDVerified = { s in ready = s
    backupsExistedAtReady = ["Seagate", "HDD Backup 2"].contains { fm.fileExists(atPath: root.appendingPathComponent("\($0)/import-2026-11-winds").path) } }
let r7 = run7.run()
check(phases == [.copyingSSD, .verifyingSSD, .copyingBackups, .verifyingBackups, .done], "phase order: \(phases)")
check(ready?.ready == true && ready?.ok == 4 && ready?.folder.lastPathComponent == "import-2026-11-winds", "SSD reported ready for Lightroom with its folder")
check(!backupsExistedAtReady, "no backup folder existed when the SSD was declared ready")
check(r7.verdict.isSafe, "final verdict after SSD-first run: \(r7.headline)")

// 11. No SSD configured: straight to backups; SSD not needed for the verdict
let p8 = Engine.plan(card: scan, month: "2026-11", desc: "nossd", roles: ["Seagate": .backup, "HDD Backup 2": .backup], volumesRoot: root, requireMountPoint: false)
let run8 = OffloadRun(card: scan, plan: p8)
var phases8: [OffloadRun.Phase] = [], ssdCalled = false
run8.onPhase = { phases8.append($0) }; run8.onSSDVerified = { _ in ssdCalled = true }
let r8 = run8.run()
check(phases8 == [.copyingBackups, .verifyingBackups, .done] && !ssdCalled && r8.verdict.isSafe, "no SSD: skips straight to backups, still safe")

// MARK: - Lightroom catalog (never launches Lightroom: `open` is injected)
print("\n--- lightroom")
let lr = scratch.appendingPathComponent("lightroom")
try? fm.removeItem(at: lr)
try! fm.createDirectory(at: lr, withIntermediateDirectories: true)
func sqliteDB(_ name: String, rows: Int, table: Bool = true) -> URL {
    let u = lr.appendingPathComponent(name)
    let sql = (table ? "CREATE TABLE AgLibraryFile(id_local INTEGER PRIMARY KEY, baseName TEXT);" : "CREATE TABLE Other(x);")
        + (0..<rows).map { "INSERT INTO AgLibraryFile(baseName) VALUES('DSC\($0)');" }.joined()
    shell("/usr/bin/sqlite3", u.path, sql)
    return u
}
check(Naming.baseName("2026-11", "bears ears") == "import-2026-11-bears-ears"
      && Naming.photoFolder("2026-11", "bears ears") == Naming.baseName("2026-11", "bears ears"), "baseName is the import folder name")
let cats = lr.appendingPathComponent("Catalogs")
let catURL = Lightroom.catalogURL(base: Naming.baseName("2026-11", "bears ears"), catalogsFolder: cats)
check(catURL.path.hasSuffix("Catalogs/import-2026-11-bears-ears/import-2026-11-bears-ears.lrcat"), "catalog path <folder>/<base>/<base>.lrcat")

let emptyT = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()   // .build/<config>/
    .appendingPathComponent("../../Resources/EmptyCatalog.lrcat").standardizedFileURL
let bundled = emptyT
check(fm.fileExists(atPath: bundled.path), "Resources/EmptyCatalog.lrcat exists (\(bundled.path))")
let photos = capture("/usr/bin/sqlite3", "-readonly", bundled.path, "SELECT COUNT(*) FROM AgLibraryFile;")
check(photos.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "bundled template is an empty catalog (\(bundled.lastPathComponent))")
let leaked = capture("/usr/bin/sqlite3", "-readonly", bundled.path,
    "SELECT COUNT(*) FROM Adobe_variablesTable WHERE name IN ('Adobe_identityPlate','Adobe_lastScannedCatalogPath') OR value LIKE '%/Users/%';")
check(leaked.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "bundled template has no user paths or identity plate")
let beforeHash = try! Updater.sha256(of: bundled)

var opened: [URL] = []
let res = try? Lightroom.createAndOpen(template: bundled, catalog: catURL, open: { opened.append($0) })
let contents = (try? fm.contentsOfDirectory(atPath: catURL.deletingLastPathComponent().path)) ?? []
check(res == .created(catURL) && contents == ["import-2026-11-bears-ears.lrcat"], "creates catalog folder with just the .lrcat (\(contents))")
check((try? Updater.sha256(of: catURL)) == beforeHash && opened == [catURL], "catalog is a byte copy of the template, then opened")

try! Data("user's edits".utf8).write(to: catURL)    // pretend the user has been working in it
let res2 = try? Lightroom.createAndOpen(template: bundled, catalog: catURL, open: { opened.append($0) })
check(res2 == .existing(catURL) && (try? String(contentsOf: catURL, encoding: .utf8)) == "user's edits" && opened.count == 2,
      "existing catalog is opened, never overwritten")

// MARK: - Updater (offline)
print("\n--- updater")
func v(_ s: String) -> SemVer { SemVer(s)! }
check(v("0.10.0") > v("0.9.9") && v("v1.2.3") == v("1.2.3") && v("1.2") == v("1.2.0"), "semver: numeric compare, v-prefix, short form")
check(v("1.0.0-beta.2") < v("1.0.0-beta.10") && v("1.0.0-beta.10") < v("1.0.0-rc.1") && v("1.0.0-rc.1") < v("1.0.0"), "semver: prerelease ordering")
check(SemVer("banana") == nil && SemVer("1.2.3.4") == nil && SemVer("") == nil, "semver: rejects garbage")

let hashA = String(repeating: "a", count: 64), hashB = String(repeating: "B", count: 64)
check(Updater.parseChecksum("\(hashA)  Offload-1.0.0.zip\n\(hashB)  other.zip", for: "Offload-1.0.0.zip") == hashA, "checksum: shasum-style line picked by name")
check(Updater.parseChecksum("Release notes\n\nSHA-256: `\(hashB)`", for: "Offload-1.0.0.zip") == hashB.lowercased(), "checksum: single hash in release body")
check(Updater.parseChecksum("\(hashA) x.zip\n\(hashB) y.zip", for: "z.zip") == nil, "checksum: ambiguous -> none")

func release(_ tag: String, assets: [(String, String)], body: String? = nil, pre: Bool = false) -> Release {
    let a = assets.map { #"{"name":"\#($0.0)","browser_download_url":"https://example.invalid/\#($0.1)","size":1}"# }.joined(separator: ",")
    let b = body.map { #","body":"\#($0)""# } ?? ""
    return try! JSONDecoder().decode(Release.self, from: Data(#"{"tag_name":"\#(tag)","prerelease":\#(pre),"assets":[\#(a)]\#(b)}"#.utf8))
}
let rel = release("v0.3.0", assets: [("Offload-0.3.0.zip", "z"), ("Offload-0.3.0.zip.sha256", "s")])
check(Updater.newer(rel, than: "0.2.0") != nil && Updater.newer(rel, than: "0.3.0") == nil && Updater.newer(rel, than: "1.0.0") == nil, "newer(): only strictly newer versions")
check(Updater.newer(release("v9.0.0", assets: [("Offload.zip", "z")], pre: true), than: "0.1.0") == nil, "newer(): prereleases ignored")
check(Updater.newer(release("v9.0.0", assets: []), than: "0.1.0") == nil, "newer(): releases without a zip ignored")

// Fake signed app bundle -> zip, like the release workflow produces.
let upd = scratch.appendingPathComponent("updater")
try? fm.removeItem(at: upd)
func makeApp(_ dir: URL, id: String, version: String) -> URL {
    let app = dir.appendingPathComponent("Offload.app")
    try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try! fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Offload").path)
    let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleExecutable": "Offload", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
    plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    shell("/usr/bin/codesign", "--force", "--sign", "-", app.path)
    return app
}
@discardableResult func shell(_ tool: String, _ a: String...) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = a
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit(); return p.terminationStatus
}
func capture(_ tool: String, _ a: String...) -> String {
    let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = a
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try! p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}
func zipApp(_ app: URL, _ name: String) -> URL {
    let z = upd.appendingPathComponent(name)
    shell("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, z.path); return z
}
let bundleID = "io.github.turnerburchard.offload"
let good = zipApp(makeApp(upd.appendingPathComponent("build-good"), id: bundleID, version: "0.3.0"), "good.zip")
let goodSHA = try! Updater.sha256(of: good)
check(goodSHA.count == 64, "sha256 of zip")
let work = upd.appendingPathComponent("work")
try! fm.createDirectory(at: work, withIntermediateDirectories: true)

func expectThrow(_ what: String, _ body: () throws -> Void) {
    do { try body(); check(false, what) } catch { check(true, "\(what): \(error.localizedDescription)") }
}
expectThrow("rejects wrong checksum") { _ = try Updater.prepare(zip: good, expectedSHA256: hashA, bundleID: bundleID, workDir: work) }
expectThrow("rejects different bundle id") {
    let z = zipApp(makeApp(upd.appendingPathComponent("build-other"), id: "com.example.evil", version: "0.3.0"), "other.zip")
    _ = try Updater.prepare(zip: z, expectedSHA256: try Updater.sha256(of: z), bundleID: bundleID, workDir: work)
}
expectThrow("rejects tampered bundle (codesign --verify)") {
    let app = makeApp(upd.appendingPathComponent("build-tampered"), id: bundleID, version: "0.3.0")
    try Data("evil".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Offload"))
    let z = zipApp(app, "tampered.zip")
    _ = try Updater.prepare(zip: z, expectedSHA256: try Updater.sha256(of: z), bundleID: bundleID, workDir: work)
}

// Install into a fake Applications folder.
let apps = upd.appendingPathComponent("Applications")
let installed = makeApp(apps, id: bundleID, version: "0.2.0")
let quarantined = makeApp(upd.appendingPathComponent("build-q"), id: bundleID, version: "0.3.0")
shell("/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;Test;", quarantined.path)
let qzip = zipApp(quarantined, "q.zip")
do {
    let ready = try Updater.prepare(zip: qzip, expectedSHA256: try Updater.sha256(of: qzip), bundleID: bundleID, workDir: work)
    check(shell("/usr/bin/xattr", "-p", "com.apple.quarantine", ready.path) != 0, "quarantine stripped from update")
    try Updater.install(ready, replacing: installed)
    let ver = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    let leftovers = try fm.contentsOfDirectory(atPath: apps.path)
    check(ver == "0.3.0" && leftovers == ["Offload.app"], "install swaps in new version, no leftovers (\(leftovers))")
    check(shell("/usr/bin/codesign", "--verify", "--deep", "--strict", installed.path) == 0, "installed app passes codesign --verify")
} catch { check(false, "prepare+install: \(error)") }
expectThrow("failed install leaves old app intact") {
    defer {
        let ver = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        check(ver == "0.3.0" && (try? fm.contentsOfDirectory(atPath: apps.path)) == ["Offload.app"], "old app still in place after failed swap")
    }
    try Updater.install(upd.appendingPathComponent("does-not-exist.app"), replacing: installed)
}
expectThrow("refuses translocated app") { try Updater.install(installed, replacing: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Offload.app")) }

// Install-on-quit staging
print("\n--- install on quit")
let stagingDir = upd.appendingPathComponent("staging")
try! fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
func installedVersion() -> String? { NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String }
let z4 = zipApp(makeApp(upd.appendingPathComponent("build-0.4"), id: bundleID, version: "0.4.0"), "v4.zip")
let staged = try! Updater.prepare(zip: z4, expectedSHA256: try! Updater.sha256(of: z4), bundleID: bundleID, workDir: stagingDir, matchSignerOf: installed)
check(installedVersion() == "0.3.0", "staging (download+verify) doesn't touch the installed app; ad-hoc running app accepts any valid signer (migration)")
check(!Updater.installOnQuit(staged: staged, appURL: installed, runInProgress: true) && installedVersion() == "0.3.0" && fm.fileExists(atPath: staged.path),
      "quit during a run: NOT installed, staged copy kept")
check(Updater.installOnQuit(staged: staged, appURL: installed, runInProgress: false) && installedVersion() == "0.4.0" && !fm.fileExists(atPath: staged.path),
      "quit with no run: staged update swapped in")
check(!Updater.installOnQuit(staged: nil, appURL: installed, runInProgress: false) && installedVersion() == "0.4.0", "nothing staged: nothing happens")
check(!Updater.installOnQuit(staged: upd.appendingPathComponent("gone.app"), appURL: installed, runInProgress: false) && installedVersion() == "0.4.0",
      "staged copy vanished (temp cleaned): old app intact")

// Certificate pinning. Needs two code-signing identities: run scripts/test-signing.sh, which makes throwaway
// self-signed certs in a temporary keychain and sets OFFLOAD_TEST_SIGN_IDS="<sha1 A>,<sha1 B>".
if let ids = ProcessInfo.processInfo.environment["OFFLOAD_TEST_SIGN_IDS"]?.split(separator: ","), ids.count == 2 {
    print("\n--- certificate pinning")
    func signedApp(_ name: String, _ identity: String, version: String) -> URL {
        let app = makeApp(upd.appendingPathComponent("cert-\(name)"), id: bundleID, version: version)
        check(shell("/usr/bin/codesign", "--force", "--sign", identity, app.path) == 0, "signed \(name) with \(identity == "-" ? "ad-hoc" : "cert " + identity.prefix(8))")
        return app
    }
    let runningA = signedApp("running-A", String(ids[0]), version: "0.3.0")
    let sig = Updater.signing(of: runningA)
    check(!sig.adhoc && sig.requirement?.contains("certificate leaf") == true && sig.requirement?.contains(bundleID) == true,
          "running app's designated requirement pins identifier + certificate leaf: \(sig.requirement ?? "nil")")
    do { try Updater.checkSigner(signedApp("update-A", String(ids[0]), version: "0.4.0"), matches: runningA); check(true, "same certificate -> accepted") }
    catch { check(false, "same certificate -> accepted (\(error.localizedDescription))") }
    expectThrow("different certificate -> rejected") { try Updater.checkSigner(signedApp("update-B", String(ids[1]), version: "0.4.0"), matches: runningA) }
    expectThrow("ad-hoc update for a cert-signed app -> rejected") { try Updater.checkSigner(signedApp("update-adhoc", "-", version: "0.4.0"), matches: runningA) }
    expectThrow("end-to-end prepare() rejects other-cert zip") {
        let z = zipApp(signedApp("zip-B", String(ids[1]), version: "0.4.0"), "certB.zip")
        _ = try Updater.prepare(zip: z, expectedSHA256: try Updater.sha256(of: z), bundleID: bundleID, workDir: work, matchSignerOf: runningA)
    }
} else { print("(skipping certificate-pinning tests: run scripts/test-signing.sh)") }

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
