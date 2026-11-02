import SwiftUI
import PixoraCore

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest
    @AppStorage("exportPreset") private var presetRaw = ExportOptions.Preset.originals.rawValue
    @AppStorage("exportOrganization") private var organizationRaw = ExportOptions.Organization.flat.rawValue
    @AppStorage("exportLongEdge") private var longEdge = 2048
    @AppStorage("exportVerify") private var verify = true
    @AppStorage("exportNames") private var writeNames = true
    @AppStorage("exportZip") private var zip = false
    @State private var destination: URL?
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var report: ExportReport?

    private var preset: ExportOptions.Preset { .init(rawValue: presetRaw) ?? .originals }
    private var organization: ExportOptions.Organization { .init(rawValue: organizationRaw) ?? .flat }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report == nil ? "Copy \(Format.count(request.results.count, "photo")) to a folder" : "Export finished").font(Typography.display(22))
            if let report { reportView(report) } else if running { runningView } else { optionsView }
        }
        .padding(24).frame(width: 600).background(Palette.panel)
        .onAppear {
            if let hint = exportDestinationHint {
                let dir: FileManager.SearchPathDirectory = ["downloads": .downloadsDirectory, "documents": .documentDirectory, "pictures": .picturesDirectory][hint] ?? .desktopDirectory
                destination = FileManager.default.urls(for: dir, in: .userDomainMask).first
                exportDestinationHint = nil
            }
        }
    }

    private var offlineCount: Int {
        request.results.filter { model.source($0.photo.sourceID)?.isOnline != true }.count
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "folder").foregroundStyle(Palette.ink2)
                Text(destination?.path ?? "No destination chosen").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { chooseDestination() }
            }
            .padding(10).cardBackground(radius: 8)

            Text("What to copy").font(.headline)
            Picker("", selection: $presetRaw) {
                Text("Originals — exact copies of the scanned files").tag(ExportOptions.Preset.originals.rawValue)
                Text("Originals + RAW — also copy the RAW of RAW+JPEG pairs").tag(ExportOptions.Preset.originalsWithRAW.rawValue)
                Text("JPEG only — copy JPEGs, convert HEIC/RAW to full-size JPEG").tag(ExportOptions.Preset.jpegOnly.rawValue)
                Text("Resized for sharing — JPEG, long edge in pixels:").tag(ExportOptions.Preset.resizedForSharing.rawValue)
            }.pickerStyle(.radioGroup).labelsHidden()
            if preset == .resizedForSharing {
                Picker("Long edge", selection: $longEdge) {
                    ForEach([1280, 2048, 3072, 4096], id: \.self) { Text("\($0) px").tag($0) }
                }.frame(width: 220).padding(.leading, 20)
            }

            Text("Organise into folders").font(.headline)
            Picker("", selection: $organizationRaw) {
                Text("None").tag(ExportOptions.Organization.flat.rawValue)
                Text("By person").tag(ExportOptions.Organization.byPerson.rawValue)
                Text("By date").tag(ExportOptions.Organization.byDate.rawValue)
                Text("By event").tag(ExportOptions.Organization.byEvent.rawValue)
            }.pickerStyle(.segmented).labelsHidden()
            Text(organizationHelp).font(.caption).foregroundStyle(Palette.ink2)

            Toggle("Verify every copy (re-read and compare checksums)", isOn: $verify)
            Toggle("Write people’s names into the copies (Lightroom, Photos and Google Photos can read them)", isOn: $writeNames)
            if organization == .byPerson || organization == .byDate || organization == .byEvent {
                Toggle("Also make a .zip of each folder", isOn: $zip)
            }
            Text("Existing files are never overwritten. A file identical to one already in the folder is skipped as a duplicate; a different file with the same name is saved as “name 2”.")
                .font(.caption).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            if offlineCount > 0 {
                Notice(symbol: "sdcard", text: "\(offlineCount) of these photos are on a card or drive that isn’t connected. Connect it first, or they’ll be reported as errors.")
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Photos") { run() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(destination == nil)
            }
        }
    }

    private var organizationHelp: String {
        switch organization {
        case .flat: "All photos in the chosen folder."
        case .byPerson: "A folder per selected person. A photo with several selected people is copied into each of their folders."
        case .byDate: "Year / day folders, from the capture date in the photo’s metadata."
        case .byEvent: "A new folder whenever there’s a gap of more than 3 hours between photos."
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1))).tint(Palette.safelight)
            EdgeLabel("\(progress.0) of \(progress.1)")
        }.frame(minHeight: 80)
    }

    private func reportView(_ r: ExportReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 28) {
                stat("\(r.copied.count)", "files copied")
                stat(Format.size(r.bytesWritten), "written")
                stat("\(r.duplicatesSkipped.count)", "duplicates skipped")
                stat("\(r.errors.count)", "errors")
            }
            if !r.errors.isEmpty {
                DisclosureGroup("Show errors") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                                Text("\(e.file) — \(e.message)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }
            }
            if !r.duplicatesSkipped.isEmpty {
                DisclosureGroup("Show duplicates") {
                    Text(r.duplicatesSkipped.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(r.copied.isEmpty ? [r.destination] : Array(r.copied.prefix(1))) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 22, weight: .semibold, design: .serif)).monospacedDigit()
            EdgeLabel(l)
        }.accessibilityElement(children: .combine)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose (or create) the folder to copy photos into."
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func run() {
        guard let destination else { return }
        var options = ExportOptions(destination: destination)
        options.preset = preset
        options.organization = organization
        options.shareLongEdge = longEdge
        options.verifyCopies = verify
        options.writePeopleNames = writeNames
        options.zipFolders = zip
        let items = model.exportItems(request.results, names: request.peopleNames)
        running = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Exporter.export(items, options: options) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
            }.value
            report = result
            running = false
        }
    }
}
