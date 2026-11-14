import AppKit
import SwiftUI
import Updater

struct StagedUpdate { let version: String; let app: URL }

/// Updates: checked on launch and every 24 h (quietly), or from "Check for Updates…".
/// Auto mode (default): download + verify silently, swap the bundle when the app quits (or "Restart now").
/// Manual mode: ask first. Never swaps during a copy/verify run.
extension AppModel {
    var updateRepo: String { Bundle.main.object(forInfoDictionaryKey: "OffloadUpdateRepo") as? String ?? "turnerburchard/offload" }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    /// Only a real .app bundle can update itself (not `swift run`).
    var canSelfUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func startUpdateChecks() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                checkForUpdates(userInitiated: false)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        guard canSelfUpdate else {
            if userInitiated { alert("Updates aren't available", "Run the built Offload.app to use the updater.") }
            return
        }
        Task {
            do {
                let latest = try await Updater.latestRelease(repo: updateRepo)
                guard let r = Updater.newer(latest, than: currentVersion) else {
                    if userInitiated { alert("You're up to date", "Offload \(currentVersion) is the latest version.") }
                    return
                }
                if autoUpdate { stageInBackground(r, userInitiated: userInitiated); return }
                if !userInitiated && UserDefaults.standard.string(forKey: "skippedVersion") == r.tag_name { return }
                if run != nil {
                    pendingUpdate = r      // offered when the run finishes
                    if userInitiated { alert("Update available", "Offload \(r.tag_name) will be offered when the current copy finishes.") }
                    return
                }
                promptForUpdate(r)
            } catch {
                if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }   // quiet otherwise (e.g. offline)
            }
        }
    }

    /// Download + verify now (safe during a run: nothing is swapped); install happens on quit.
    private func stageInBackground(_ r: Release, userInitiated: Bool) {
        if stagedUpdate?.version == r.tag_name {
            if userInitiated { alert("Update ready", "Offload \(r.tag_name) will be installed when you quit.") }
            return
        }
        guard !stagingUpdate, let id = Bundle.main.bundleIdentifier else { return }
        stagingUpdate = true
        Task {
            defer { stagingUpdate = false }
            do {
                let app = try await Updater.stage(r, bundleID: id, appURL: Bundle.main.bundleURL)
                if let old = stagedUpdate { try? FileManager.default.removeItem(at: old.app) }
                stagedUpdate = StagedUpdate(version: r.version?.description ?? r.tag_name, app: app)
                if userInitiated { alert("Update ready", "Offload \(r.tag_name) will be installed when you quit.") }
            } catch {
                if userInitiated { alert("Update failed", error.localizedDescription + "\n\nThe current version was left in place.") }
            }
        }
    }

    /// Called from applicationWillTerminate. Never during a run.
    func installStagedUpdateOnQuit() {
        Updater.installOnQuit(staged: stagedUpdate?.app, appURL: Bundle.main.bundleURL, runInProgress: run != nil)
    }

    func restartIntoUpdate() {
        guard run == nil, stagedUpdate != nil else { return }
        Updater.relaunch(Bundle.main.bundleURL)   // waits for this process to exit; the swap happens on quit
        NSApp.terminate(nil)
    }

    func offerPendingUpdate() {
        guard let r = pendingUpdate, run == nil else { return }
        pendingUpdate = nil
        promptForUpdate(r)
    }

    private func promptForUpdate(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Offload \(r.version?.description ?? r.tag_name) is available"
        a.informativeText = "You have \(currentVersion).\n\n" + String((r.body ?? "").prefix(1500))
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.tag_name, forKey: "skippedVersion")
        default: break
        }
    }

    private func install(_ r: Release) {
        guard run == nil else { alert("Finish the current copy first", "Updates never install during a copy or verification."); return }
        guard let id = Bundle.main.bundleIdentifier else { return }
        updating = true
        let appURL = Bundle.main.bundleURL
        Task {
            do {
                try await Updater.downloadAndInstall(r, bundleID: id, appURL: appURL)
                Updater.relaunch(appURL)
                NSApp.terminate(nil)
            } catch {
                updating = false
                alert("Update failed", error.localizedDescription + "\n\nThe current version was left in place.")
            }
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

/// Quit protection during a run, and install-on-quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.model?.run != nil else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A copy/verify is still running"
        a.informativeText = "If you quit now the card is NOT verified. Updates are not installed while a run is in progress."
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        Self.model?.installStagedUpdateOnQuit()
    }
}

struct UpdateFooter: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let s = m.stagedUpdate {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Update \(s.version) ready — installs when you quit.").font(.callout)
                Spacer()
                Button("Restart now") { m.restartIntoUpdate() }
                    .disabled(m.run != nil)
                    .help(m.run != nil ? "Available after the current copy finishes" : "Install the update and relaunch")
            }
        }
    }
}
