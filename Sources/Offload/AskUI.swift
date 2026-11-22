import SwiftUI
import AppKit
import Assistant
import Updater

/// Thread-safe "is a copy running?" for background work.
final class RunFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set(_ v: Bool) { lock.withLock { value = v } }
}

struct AskMessage: Identifiable, Equatable {
    enum Who { case user, claude }
    let id = UUID()
    let who: Who
    let text: String
}

extension AppModel {
    // MARK: Availability

    /// Settings choice, else the path baked in by a local build, else ~/code/offload.
    var sourceFolder: URL? {
        let candidates: [String?] = [
            UserDefaults.standard.string(forKey: "sourceFolder"),
            Bundle.main.object(forInfoDictionaryKey: "OffloadSourcePath") as? String,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code/offload").path,
        ]
        return candidates.compactMap { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }.first(where: AskEnvironment.isSourceCheckout)
    }

    var askAvailable: Bool { claudeBinary != nil && sourceFolder != nil }

    func refreshAskAvailability() {
        let found = AskEnvironment.findClaude()
        claudeBinary = found
        objectWillChange.send()
        refreshUndo()
    }

    func chooseSourceFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = "Choose the folder that has Offload's source (it contains Package.swift)"
        if p.runModal() == .OK, let u = p.url {
            if AskEnvironment.isSourceCheckout(u) { UserDefaults.standard.set(u.path, forKey: "sourceFolder"); assistant = nil }
            else { alert("That folder doesn't look right", "Choose the folder that contains Package.swift.") }
        }
        refreshAskAvailability()
    }

    private func makeAssistant() -> AskClaude? {
        if let a = assistant { return a }
        guard let bin = claudeBinary, let repo = sourceFolder else { return nil }
        var cfg = AskClaude.Config(repo: repo, claude: ClaudeCLI(binary: bin))
        let flag = runFlag
        cfg.isRunInProgress = { flag.isSet }
        let a = AskClaude(cfg)
        a.onStep = { s in Task { @MainActor in self.askStep = s } }
        a.onLog = { l in Task { @MainActor in self.askLog.append(l + "\n"); if self.askLog.count > 200_000 { self.askLog.removeFirst(50_000) } } }
        a.onMessage = { t in Task { @MainActor in self.askMessages.append(AskMessage(who: .claude, text: t)) } }
        assistant = a
        return a
    }

    // MARK: Conversation

    func askSend(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !askBusy, let a = makeAssistant() else { return }
        askMessages.append(AskMessage(who: .user, text: text))
        askBusy = true; askStep = "Thinking…"
        Task.detached { let r = a.send(text); await MainActor.run { self.handle(r) } }
    }

    func askUndo() {
        guard !askBusy, let a = makeAssistant(), let s = undoSummary else { return }
        askMessages.append(AskMessage(who: .user, text: "Undo “\(s)”"))
        askBusy = true; askStep = "Undoing…"
        Task.detached { let r = a.undoLastChange(); await MainActor.run { self.handle(r) } }
    }

    private func handle(_ r: AskClaude.Result) {
        askBusy = false; askStep = ""
        switch r {
        case .answer(let t), .needsOK(let t), .failed(let t), .refused(let t):
            askMessages.append(AskMessage(who: .claude, text: t))
        case .built(let version, _, let message):
            askMessages.append(AskMessage(who: .claude, text: message.isEmpty ? "Done!" : message))
            shareThenRestart(version: version)
        }
        refreshUndo()
    }

    var askAwaitingOK: Bool { assistant?.awaitingOK ?? false }

    func refreshUndo() {
        guard let a = makeAssistant() else { undoSummary = nil; return }
        Task.detached { let s = a.lastChangeSummary(); await MainActor.run { self.undoSummary = s } }
    }

    // MARK: Share + restart

    private func shareThenRestart(version: String) {
        guard let a = assistant else { return }
        askBusy = true; askStep = "Sharing to GitHub…"
        Task.detached {
            let ok = a.push(version: version)
            await MainActor.run {
                self.askBusy = false; self.askStep = ""
                if ok { UserDefaults.standard.removeObject(forKey: "unsharedVersion") }
                else { UserDefaults.standard.set(version, forKey: "unsharedVersion") }
                self.unsharedVersion = ok ? nil : version
                self.restartIntoLocalBuild()
            }
        }
    }

    func retryShare() {
        guard let v = unsharedVersion, let a = makeAssistant(), !askBusy else { return }
        askBusy = true; askStep = "Sharing to GitHub…"
        Task.detached {
            let ok = a.push(version: v)
            await MainActor.run {
                self.askBusy = false; self.askStep = ""
                if ok { UserDefaults.standard.removeObject(forKey: "unsharedVersion"); self.unsharedVersion = nil }
                else { self.askMessages.append(AskMessage(who: .claude, text: "Still couldn't share to GitHub. Your change is saved on this Mac.")) }
            }
        }
    }

    /// Never during a copy: waits for the run to finish (see `runFinished`).
    func restartIntoLocalBuild() {
        guard run == nil else {
            pendingLocalRestart = true
            askMessages.append(AskMessage(who: .claude, text: "I'll restart Offload when the copy finishes."))
            return
        }
        pendingLocalRestart = false
        guard let repo = sourceFolder, canSelfUpdate else {
            askMessages.append(AskMessage(who: .claude, text: "Quit and reopen Offload to see the change."))
            return
        }
        do {
            try LocalInstall.install(built: repo.appendingPathComponent("Offload.app"), replacing: Bundle.main.bundleURL)
            stagedUpdate = nil                       // don't let an older downloaded update replace it on quit
            Updater.relaunch(Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            askMessages.append(AskMessage(who: .claude, text: "The change is saved, but I couldn't restart Offload. Quit and reopen it to see the change."))
        }
    }

    func runFinished() {
        if pendingLocalRestart { restartIntoLocalBuild() }
    }
}

// MARK: - Views

struct AskPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("✨ Ask about Offload").font(.headline)
                Spacer()
                if let s = m.undoSummary, !m.askBusy {
                    Button("Undo “\(s)”") { m.askUndo() }.controlSize(.small)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if m.askMessages.isEmpty {
                            Text("Ask how to do something — for example “Can it copy only RAW files?”. If Offload can't do it yet, I can add it for you.")
                                .foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(m.askMessages) { Bubble(message: $0).id($0.id) }
                        if m.askBusy {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m.askStep).foregroundStyle(.secondary) }.id("busy")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: m.askMessages) { _, msgs in withAnimation { proxy.scrollTo(msgs.last?.id) } }
            }
            if let v = m.unsharedVersion {
                HStack {
                    Text("Saved on this Mac; couldn't share to GitHub yet.").font(.caption)
                    Spacer()
                    Button("Retry") { m.retryShare() }.controlSize(.small).disabled(m.askBusy)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(.orange.opacity(0.12))
                .help("Version \(v)")
            }
            if m.askAwaitingOK && !m.askBusy {
                HStack {
                    Button("Yes, go ahead") { m.askSend("Yes, go ahead.") }
                    Button("No, don't") { m.askSend("No, don't do that.") }
                    Spacer()
                }.padding(.horizontal, 12).padding(.top, 6)
            }
            HStack {
                TextField("Ask a question…", text: $draft).textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                    .disabled(m.askBusy)
                Button("Send") { send() }.disabled(m.askBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            DisclosureGroup("Show details", isExpanded: $showDetails) {
                ScrollView { Text(m.askLog.isEmpty ? "Nothing yet." : m.askLog).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 140)
            }
            .font(.caption).padding([.horizontal, .bottom], 12)
        }
        .frame(width: 460, height: 520)
        .onAppear { m.refreshUndo() }
    }

    private func send() { let t = draft; draft = ""; m.askSend(t) }
}

struct Bubble: View {
    let message: AskMessage
    var body: some View {
        HStack {
            if message.who == .user { Spacer(minLength: 40) }
            Text(message.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(message.who == .user ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(message.who == .user ? Color.white : Color.primary)
                .textSelection(.enabled)
            if message.who == .claude { Spacer(minLength: 40) }
        }
    }
}

struct AskSettingsSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Section {
            LabeledContent("Source folder") {
                HStack {
                    Text(m.sourceFolder?.path ?? "Not found").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { m.chooseSourceFolder() }
                }
            }
            Text(m.claudeBinary == nil ? "Claude isn't installed on this Mac, so Ask is turned off."
                 : m.sourceFolder == nil ? "Choose the folder with Offload's source to turn on Ask."
                 : "Ask is ready. Press ⌘K or click ✨ Ask.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Ask Claude") }
        .onAppear { m.refreshAskAvailability() }
    }
}
