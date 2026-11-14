import AppKit
import Updater

/// Update checks: on launch (quietly) and from "Check for Updates…". Always asks; never installs during a run.
extension AppModel {
    var updateRepo: String { Bundle.main.object(forInfoDictionaryKey: "OffloadUpdateRepo") as? String ?? "turnerburchard/offload" }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    /// Only a real .app bundle can update itself (not `swift run`).
    var canSelfUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

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
                if !userInitiated && UserDefaults.standard.string(forKey: "skippedVersion") == r.tag_name { return }
                if run != nil {
                    pendingUpdate = r      // offered when the run finishes
                    if userInitiated { alert("Update available", "Offload \(r.tag_name) will be offered when the current copy finishes.") }
                    return
                }
                promptForUpdate(r)
            } catch {
                if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }   // quiet on launch (e.g. offline)
            }
        }
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
