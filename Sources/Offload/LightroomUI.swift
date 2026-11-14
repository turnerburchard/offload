import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OffloadCore

extension AppModel {
    func revalidateTemplate() { templateStatus = lrTemplate.map(Lightroom.validateTemplate) }

    func chooseTemplate() {
        let p = NSOpenPanel()
        p.message = "Choose an EMPTY Lightroom catalog (make one with File > New Catalog)"
        p.allowedContentTypes = [UTType(filenameExtension: "lrcat") ?? .data]
        p.treatsFilePackagesAsDirectories = true
        if p.runModal() == .OK, let u = p.url { lrTemplate = u }
    }

    func chooseCatalogsFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.directoryURL = catalogsFolder
        if p.runModal() == .OK, let u = p.url { catalogsFolder = u }
    }

    func createCatalog(ssdFolder: URL) {
        guard let template = lrTemplate else {
            catalogMessage = "No template catalog set. In Lightroom Classic choose File > New Catalog to make an empty one and quit Lightroom, then pick it in Settings (⌘,) under “Lightroom template catalog”."
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
            else if m.lrTemplate == nil { Text("Set a template catalog in Settings first.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct LightroomSettingsSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Section {
            LabeledContent("Lightroom template catalog") {
                HStack {
                    Text(m.lrTemplate?.lastPathComponent ?? "none").foregroundStyle(.secondary)
                    Button("Choose…") { m.chooseTemplate() }
                }
            }
            if let s = m.templateStatus {
                Label(s.message, systemImage: s.isUsable ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.isUsable ? Color.green : .orange)
            }
            LabeledContent("Catalogs folder") {
                HStack {
                    Text(m.catalogsFolder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { m.chooseCatalogsFolder() }
                }
            }
        } header: { Text("Lightroom") } footer: {
            Text("New catalogs are copies of the template at <Catalogs folder>/<import name>/<import name>.lrcat. Make the template once in Lightroom Classic with File > New Catalog, then quit Lightroom.")
                .foregroundStyle(.secondary)
        }
        .onAppear { m.revalidateTemplate() }
    }
}
