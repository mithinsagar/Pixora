import SwiftUI
import PixoraCore

/// One folder per person, wherever you choose: "Ana (42)", "Ben (17)"…
struct ExportEveryoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportEveryoneRequest
    @State private var chosen: Set<Int64> = []
    @State private var destination: URL?
    @AppStorage("everyoneSolo") private var soloOnly = false
    @AppStorage("everyoneUncertain") private var includeUncertain = false
    @AppStorage("everyoneSkipWeaker") private var skipWeaker = true
    @AppStorage("exportPreset") private var presetRaw = ExportOptions.Preset.originals.rawValue
    @AppStorage("exportNames") private var writeNames = true
    @AppStorage("everyoneZip") private var zip = false
    @State private var counts: [Int64: Int] = [:]
    @State private var running = false
    @State private var progress = (0, 0)
    @State private var report: ExportReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(report == nil ? "Export photos for each person" : "Export finished").font(Typography.display(22))
            if let report { reportView(report) } else if running { runningView } else { options }
        }
        .padding(24).frame(width: 640).background(Palette.panel)
        .onAppear { chosen = request.preselected.isEmpty ? Set(model.namedPeople.map(\.id)) : request.preselected; recount() }
        .onChange(of: soloOnly) { recount() }
        .onChange(of: includeUncertain) { recount() }
        .onChange(of: skipWeaker) { recount() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder").foregroundStyle(Palette.ink2)
                Text(destination?.path ?? "Choose where to save the folders").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { choose() }
            }.padding(10).cardBackground(radius: 8)

            HStack {
                Text("People").font(.headline)
                Spacer()
                Button("All") { chosen = Set(model.namedPeople.map(\.id)) }.controlSize(.small)
                Button("None") { chosen = [] }.controlSize(.small)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    ForEach(model.namedPeople) { p in
                        let on = chosen.contains(p.id)
                        Button { chosen.formSymmetricDifference([p.id]) } label: {
                            HStack(spacing: 8) {
                                FaceImage(faceID: p.coverFaceID, size: 30, shape: AnyShape(Circle()))
                                Text(p.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("\(counts[p.id] ?? 0)").font(Typography.edge).foregroundStyle(Palette.ink2)
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Palette.safelight : Palette.ink2)
                            }
                            .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(on ? Palette.safelight.opacity(0.12) : Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Palette.safelight.opacity(0.6) : Palette.rule))
                        }
                        .buttonStyle(.plain).hoverLift(scale: 1.02, radius: 10)
                    }
                }.padding(2)
            }.frame(maxHeight: 220)

            Toggle("Solo photos only — nobody else in the frame", isOn: $soloOnly)
            Toggle("Include uncertain matches", isOn: $includeUncertain)
            Toggle("Leave out shots to check (eyes may be closed, soft focus)", isOn: $skipWeaker)
            Picker("Files", selection: $presetRaw) {
                Text("Originals").tag(ExportOptions.Preset.originals.rawValue)
                Text("Originals + RAW").tag(ExportOptions.Preset.originalsWithRAW.rawValue)
                Text("JPEG only").tag(ExportOptions.Preset.jpegOnly.rawValue)
                Text("Resized for sharing (2048 px)").tag(ExportOptions.Preset.resizedForSharing.rawValue)
            }.frame(width: 360)
            Toggle("Write people’s names into the copies (Lightroom, Photos and Google Photos can read them)", isOn: $writeNames)
            Toggle("Also make a .zip of each person’s folder", isOn: $zip)

            let total = chosen.reduce(0) { $0 + (counts[$1] ?? 0) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(chosen.count) folders · \(total) photos").font(.caption).foregroundStyle(Palette.ink2)
                Button("Export") { run() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || chosen.isEmpty || total == 0)
            }
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1))).tint(Palette.safelight)
            EdgeLabel("\(progress.0) of \(progress.1)")
        }.frame(minHeight: 80)
    }

    private func reportView(_ r: ExportReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                stat("\(r.copied.count)", "files copied")
                stat(Format.size(r.bytesWritten), "written")
                stat("\(r.duplicatesSkipped.count)", "duplicates skipped")
                stat("\(r.errors.count)", "errors")
                if !r.zips.isEmpty { stat("\(r.zips.count)", "zips") }
            }
            if !r.errors.isEmpty {
                DisclosureGroup("Show errors") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                                Text("\(e.file) — \(e.message)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.destination]) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 22, weight: .semibold, design: .serif)).monospacedDigit()
            EdgeLabel(l)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Each person gets their own folder inside this one."
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK { destination = panel.url }
    }

    /// Photos to export for one person under the current options.
    private func photos(for pid: Int64) -> [SearchResult] {
        let results = (try? model.store.search(people: [pid], mode: soloOnly ? .only : .all, includeUncertain: includeUncertain)) ?? []
        guard skipWeaker else { return results }
        return results.filter { !$0.eyesClosed && !$0.soft }   // every burst frame is kept
    }

    private func recount() {
        var c: [Int64: Int] = [:]
        for p in model.namedPeople { c[p.id] = photos(for: p.id).count }
        counts = c
    }

    private func run() {
        guard let destination else { return }
        var options = ExportOptions(destination: destination)
        options.preset = ExportOptions.Preset(rawValue: presetRaw) ?? .originals
        options.writePeopleNames = writeNames
        options.zipFolders = zip
        var items: [ExportItem] = []
        let names = Dictionary(uniqueKeysWithValues: model.people.map { ($0.id, $0.displayName) })
        for pid in chosen {
            guard let name = names[pid] else { continue }
            for r in photos(for: pid) {
                guard let src = model.source(r.photo.sourceID) else { continue }
                items.append(ExportItem(photo: r.photo, sourceRoot: src.url, people: model.namesInPhoto(r.photo.id), folders: [name]))
            }
        }
        running = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Exporter.export(items, options: options) { done, total in Task { @MainActor in progress = (done, total) } }
            }.value
            report = result
            running = false
        }
    }
}
