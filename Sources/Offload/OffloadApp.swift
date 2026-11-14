import SwiftUI
import AppKit
import OffloadCore
import Updater

@main
struct OffloadApp: App {
    @StateObject private var model = AppModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }   // so `swift run` also gets a Dock icon / focus
    var body: some Scene {
        WindowGroup("SD Offload") { ContentView().environmentObject(model).frame(minWidth: 640, minHeight: 680) }
        Settings { DrivesView().environmentObject(model).frame(width: 520).padding() }
            .commands {
                CommandGroup(after: .appInfo) { Button("Check for Updates…") { model.checkForUpdates(userInitiated: true) } }
            }
    }
}

// MARK: - Model

@MainActor final class AppModel: ObservableObject {
    /// OFFLOAD_VOLUMES_ROOT points the app at a fake /Volumes for testing (also relaxes the mount-point check).
    let volumesRoot: URL
    let testMode: Bool
    private let defaultsKey = "driveRoles"

    @Published var roles: [String: DriveRole] { didSet { saveRoles(); refresh() } }
    @Published var volumes: [String] = []
    @Published var cards: [URL] = []
    @Published var cardURL: URL? { didSet { if oldValue != cardURL { scanCard() } } }
    @Published var scan: CardScan? { didSet { replan() } }
    @Published var readingDates = false
    @Published var desc = "" { didSet { replan() } }
    @Published var month = Naming.month(Date()) { didSet { replan() } }
    @Published private(set) var plan: Plan?
    @Published var copyProgress: [String: Double] = [:]
    @Published var verifyProgress = 0.0
    @Published var phase: OffloadRun.Phase?
    @Published var report: Report?
    @Published var ssd: OffloadRun.SSDStatus?
    @Published private(set) var run: OffloadRun?
    @Published var updating = false          // an update is downloading/installing: no new runs
    var pendingUpdate: Release?              // found during a run; offered once it ends

    init() {
        if let o = ProcessInfo.processInfo.environment["OFFLOAD_VOLUMES_ROOT"] {
            volumesRoot = URL(fileURLWithPath: o, isDirectory: true); testMode = true
        } else {
            volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true); testMode = false
        }
        roles = (UserDefaults.standard.data(forKey: defaultsKey)).flatMap { try? JSONDecoder().decode([String: DriveRole].self, from: $0) } ?? [:]
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
        Task { try? await Task.sleep(for: .seconds(2)); checkForUpdates(userInitiated: false) }
    }

    private func saveRoles() { UserDefaults.standard.set(try? JSONEncoder().encode(roles), forKey: defaultsKey) }

    func refresh() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: volumesRoot.path)) ?? []
        volumes = names.filter { n in
            !n.hasPrefix(".") && (try? fm.destinationOfSymbolicLink(atPath: volumesRoot.appendingPathComponent(n).path)) == nil  // skips "Macintosh HD" -> /
        }.sorted()
        cards = volumes.filter { (roles[$0] ?? DriveRole.none) == DriveRole.none }.map { volumesRoot.appendingPathComponent($0) }.filter(Card.isCard)
        if let c = cardURL, !cards.contains(c), run == nil { cardURL = nil }
        if cardURL == nil { cardURL = cards.first }
        replan()
    }

    func scanCard() {
        scan = nil; report = nil; ssd = nil; copyProgress = [:]
        guard let url = cardURL else { return }
        readingDates = true
        Task.detached {
            let s = Card.scan(url)
            await MainActor.run { if self.cardURL == url { self.scan = s } }
            let (first, last) = Card.captureRange(s.photos)
            await MainActor.run {
                guard self.cardURL == url, var cur = self.scan else { return }
                cur.firstCapture = first; cur.lastCapture = last
                self.readingDates = false
                if let first { self.month = Naming.month(first) }
                self.scan = cur
            }
        }
    }

    func replan() {
        guard run == nil else { return }   // frozen while running
        plan = scan.map { Engine.plan(card: $0, month: month, desc: desc, roles: roles, volumesRoot: volumesRoot, requireMountPoint: !testMode) }
    }

    func start() {
        guard let scan, let plan, plan.problems.isEmpty, run == nil, !updating else { return }
        report = nil; ssd = nil; copyProgress = [:]
        launch(OffloadRun(card: scan, plan: plan)) { $0.run() }
    }

    func retryUnreadable() {
        guard let prev = report, !prev.cardUnreadable.isEmpty, run == nil, !updating else { return }
        launch(OffloadRun(card: prev.card, plan: prev.plan)) { $0.retryUnreadable(prev) }
    }

    private func launch(_ r: OffloadRun, _ body: @escaping @Sendable (OffloadRun) -> Report) {
        r.onCopyProgress = { d, p in Task { @MainActor in self.copyProgress[d] = p } }
        r.onVerifyProgress = { p in Task { @MainActor in self.verifyProgress = p } }
        r.onPhase = { p in Task { @MainActor in self.phase = p; self.verifyProgress = 0 } }
        r.onSSDVerified = { s in Task { @MainActor in self.ssd = s } }
        verifyProgress = 0; run = r
        Task.detached {
            let rep = body(r)
            await MainActor.run { self.report = rep; self.run = nil; self.replan(); self.refresh(); self.offerPendingUpdate() }
        }
    }

    func cancel() { run?.cancel() }
}

// MARK: - Views

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Form {
            Section("SD card") { cardSection }
            if m.scan != nil {
                Section("Import") {
                    TextField("Name", text: $m.desc, prompt: Text("e.g. escalante"))
                    TextField("Month", text: $m.month, prompt: Text("YYYY-MM"))
                    LabeledContent("Photos folder", value: Naming.photoFolder(m.month, m.desc))
                    if !(m.scan?.videos.isEmpty ?? true) { LabeledContent("Video folder (backups)", value: Naming.videoFolder(m.month, m.desc)) }
                }
            }
            Section {
                destinations
            } header: {
                HStack { Text("Destinations"); Spacer(); Button("Drives…") { openSettings() }.controlSize(.small) }
            }
            if let p = m.plan, !(p.problems.isEmpty && p.warnings.isEmpty) {
                Section {
                    ForEach(p.problems, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    ForEach(p.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            Section { actions }
            if let s = m.ssd { Section("Editing SSD") { SSDView(status: s) } }
            if let r = m.report { Section("Result") { ReportView(report: r) } }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var cardSection: some View {
        if m.cards.count > 1 {
            Picker("Card", selection: $m.cardURL) { ForEach(m.cards, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) } }
        }
        if let s = m.scan {
            LabeledContent("Volume", value: "\(s.name)  ·  \(s.uuid.map { String($0.prefix(8)) } ?? "no UUID")")
            LabeledContent("Contents", value: "\(s.photos.count) photos, \(s.videos.count) video files — \(bytes(s.totalBytes))")
            LabeledContent("Captured") {
                if m.readingDates { ProgressView().controlSize(.small) } else { Text(dateRange(s)) }
            }
            if let a = s.firstCapture, let b = s.lastCapture, Naming.month(a) != Naming.month(b) {
                Label("Card spans \(Naming.month(a)) to \(Naming.month(b)) — check it's the card you think it is.", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            ForEach(s.scanErrors.prefix(5), id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
        } else if m.cardURL != nil {
            HStack { ProgressView().controlSize(.small); Text("Scanning card…") }
        } else {
            Text("Insert an SD card. It's detected by its DCIM folder, not its name.").foregroundStyle(.secondary)
        }
    }

    func dateRange(_ s: CardScan) -> String {
        guard let a = s.firstCapture, let b = s.lastCapture else { return "no EXIF dates found" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return a == b ? f.string(from: a) : "\(f.string(from: a)) → \(f.string(from: b))"
    }

    @ViewBuilder var destinations: some View {
        if let p = m.plan {
            ForEach(p.targets) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: t.role == .primary ? "bolt.horizontal.circle" : "externaldrive")
                        Text(t.drive).bold()
                        Text(t.role == .primary ? "editing" : "backup").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let free = try? t.volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                            Text("\(bytes(Int64(free))) free").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(t.photoDir.path + (t.videoDir.map { "\n" + $0.path } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let prog = m.copyProgress[t.drive] { ProgressView(value: prog) }
                }
            }
            ForEach(p.missing, id: \.self) { Label("\($0) — not connected", systemImage: "externaldrive.badge.xmark").foregroundStyle(.secondary) }
        } else if m.roles.values.allSatisfy({ $0 == .none }) {
            Text("No drives configured yet. Click “Drives…” to pick your editing SSD and backup HDDs.").foregroundStyle(.secondary)
        } else {
            Text(m.roles.filter { $0.value != .none }.keys.sorted().joined(separator: ", ")).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var actions: some View {
        HStack {
            Button(m.run == nil ? "Copy & Verify" : "Working…") { m.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(m.run != nil || m.updating || m.plan == nil || !(m.plan?.problems.isEmpty ?? false))
            if m.run != nil { Button("Cancel", role: .destructive) { m.cancel() } }
            Spacer()
            if let ph = m.phase, m.run != nil {
                Text(phaseText(ph)).foregroundStyle(.secondary)
            }
        }
        if m.run != nil && [.verifyingSSD, .verifyingBackups, .retrying].contains(m.phase) { ProgressView(value: m.verifyProgress) }
        if m.run != nil { Text("Sleep is blocked while this runs. Keep the lid open.").font(.caption).foregroundStyle(.secondary) }
    }
}

func phaseText(_ p: OffloadRun.Phase) -> String {
    switch p {
    case .copyingSSD: "Copying to editing SSD…"
    case .verifyingSSD: "Verifying SSD copy (MD5)…"
    case .copyingBackups: "Copying to backup drives…"
    case .verifyingBackups: "Verifying backups (MD5)…"
    case .retrying: "Retrying unreadable files…"
    case .done, .cancelled: "Finishing…"
    }
}

struct SSDView: View {
    let status: OffloadRun.SSDStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.ready {
                Label("Ready for Lightroom", systemImage: "checkmark.circle.fill").font(.title3.bold()).foregroundStyle(.green)
                Text("\(status.ok) files on \(status.drive) match the card by MD5." +
                     (status.unreadableOnCard > 0 ? " \(status.unreadableOnCard) couldn't be read from the card and are not there." : ""))
            } else {
                Label("SSD copy has problems — don't import yet", systemImage: "exclamationmark.triangle.fill").font(.title3.bold()).foregroundStyle(.orange)
                ForEach(status.problems.prefix(8), id: \.self) { Text($0).font(.caption.monospaced()) }
            }
            HStack {
                Text(status.folder.path).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([status.folder]) }
            }
        }
    }
}

struct ReportView: View {
    @EnvironmentObject var m: AppModel
    let report: Report
    var body: some View {
        let v = report.verdict
        VStack(alignment: .leading, spacing: 8) {
            Label(report.headline, systemImage: v.isSafe ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.title2.bold()).foregroundStyle(v.isSafe ? .green : .red)
            if !report.cardUnreadable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These files couldn't be read from the card, so no drive has a verified copy:").bold()
                    ForEach(report.cardUnreadable, id: \.file) { u in
                        Text("\(u.file) — \(u.error)").font(.caption.monospaced())
                    }
                    Button("Retry unreadable files") { m.retryUnreadable() }.disabled(m.run != nil)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            switch v {
            case .safe: Text("Every file on the card matched by MD5 on every backup drive.")
            case .notSafe(let reasons): ForEach(reasons, id: \.self) { Text("• " + $0) }
            }
            Divider()
            ForEach(report.drives, id: \.drive) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(d.drive) (\(d.role.rawValue)): \(d.ok) OK, \(d.missing.count) missing, \(d.mismatched.count) mismatched, \(d.readErrors.count) read errors")
                        .foregroundStyle(d.clean ? Color.primary : .red)
                    ForEach((d.mismatched.map { "MISMATCH " + $0 } + d.missing.map { "MISSING " + $0 } + d.readErrors).prefix(8), id: \.self) {
                        Text($0).font(.caption.monospaced()).foregroundStyle(.red)
                    }
                    if let e = d.copyError { Text(e).font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(4) }
                    ForEach(d.logs, id: \.self) { url in
                        Button("Log: " + url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct DrivesView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let names = Set(m.volumes).union(m.roles.keys).subtracting(m.cards.map(\.lastPathComponent)).sorted()
        Form {
            Section {
                ForEach(names, id: \.self) { name in
                    Picker(selection: Binding(get: { m.roles[name] ?? DriveRole.none }, set: { m.roles[name] = $0 == DriveRole.none ? nil : $0 })) {
                        Text("—").tag(DriveRole.none)
                        Text("Editing SSD").tag(DriveRole.primary)
                        Text("Backup").tag(DriveRole.backup)
                    } label: {
                        Text(name) + Text(m.volumes.contains(name) ? "" : "  (not connected)").foregroundColor(.secondary)
                    }
                }
            } header: { Text("Drive roles") } footer: {
                Text("Photos go to every drive; video goes to backups only. The card is only “safe to wipe” when every file matches on every backup drive. Drives are remembered by volume name. SD cards (anything with DCIM/) aren't listed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
