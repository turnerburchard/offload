import SwiftUI
import AppKit
import OffloadCore

extension AppModel {
    func chooseCatalogsFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = catalogsFolder
        if p.runModal() == .OK, let u = p.url { catalogsFolder = u }
    }

    func createCatalog(ssdFolder: URL) {
        guard let template = Bundle.main.url(forResource: "EmptyCatalog", withExtension: "lrcat") else {
            catalogMessage = "This copy of Offload is missing its empty catalog. Reinstall it from GitHub Releases."
            return
        }
        // Same base name as the SSD import folder.
        let catalog = Lightroom.catalogURL(base: ssdFolder.lastPathComponent, catalogsFolder: catalogsFolder)
        do {
            switch try Lightroom.createAndOpen(template: template, catalog: catalog, open: Self.openInLightroom) {
            case .created(let u): catalogMessage = "Created \(u.path)\n" + Lightroom.instructions(ssdFolder: ssdFolder)
            case .existing(let u): catalogMessage = "Opened existing \(u.path) (not overwritten).\n" + Lightroom.instructions(ssdFolder: ssdFolder)
            }
        } catch { catalogMessage = error.localizedDescription }
    }

    static func openInLightroom(_ catalog: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Lightroom.bundleID) {
            NSWorkspace.shared.open([catalog], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(catalog)   // whatever handles .lrcat
        }
    }
}

struct CatalogButton: View {
    @EnvironmentObject var m: AppModel
    let ssdFolder: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Create catalog & open in Lightroom") { m.createCatalog(ssdFolder: ssdFolder) }
            if let msg = m.catalogMessage { Text(msg).font(.caption).textSelection(.enabled) }
        }
    }
}

struct LightroomSettingsSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Section {
            LabeledContent("Catalogs folder") {
                HStack {
                    Text(m.catalogsFolder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { m.chooseCatalogsFolder() }
                }
            }
        } header: { Text("Lightroom") } footer: {
            Text("Each import gets its own catalog: <folder>/<import name>/<import name>.lrcat.").foregroundStyle(.secondary)
        }
    }
}
