import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OffloadCore

extension AppModel {
    /// Optional override (Settings) else auto-discovery in the catalogs folder; re-run on every click.
    func revalidateTemplate() { templateDiscovery = Lightroom.discoverTemplate(in: catalogsFolder, override: lrTemplate) }

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
        revalidateTemplate()
        guard let template = templateDiscovery?.template else {
            catalogMessage = templateDiscovery?.problem
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
            LabeledContent("Template catalog") {
                HStack {
                    Text(m.lrTemplate == nil ? "Automatic" : m.lrTemplate!.lastPathComponent).foregroundStyle(.secondary)
                    if m.lrTemplate != nil { Button("Use automatic") { m.lrTemplate = nil } }
                    Button("Choose…") { m.chooseTemplate() }
                }
            }
            if let d = m.templateDiscovery {
                if let t = d.template { Label("Using \(t.path)", systemImage: "checkmark.circle").foregroundStyle(.green) }
                else if let p = d.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            LabeledContent("Catalogs folder") {
                HStack {
                    Text(m.catalogsFolder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { m.chooseCatalogsFolder() }
                }
            }
        } header: { Text("Lightroom") } footer: {
            Text("New catalogs are copies of an empty template catalog, created at <Catalogs folder>/<import name>/<import name>.lrcat. The template is found automatically: <Catalogs folder>/template/template.lrcat, or any .lrcat with “template” in its name. Make it once in Lightroom Classic with File > New Catalog.")
                .foregroundStyle(.secondary)
        }
        .onAppear { m.revalidateTemplate() }
    }
}
