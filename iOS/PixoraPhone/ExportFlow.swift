import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PixoraCore

/// "Save to Files": copies the chosen photos into a folder the person picks (Files, iCloud Drive, a USB drive),
/// using the same Exporter as the Mac. Originals are only read.
struct ExportSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]
    @State private var preset: ExportOptions.Preset = .originals
    @State private var byPerson = false
    @State private var writeNames = true
    @State private var picking = false
    @State private var running = false
    @State private var done = 0
    @State private var report: ExportReport?

    private var offline: Int { photos.filter { model.isOffline($0) }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: -14) {
                        ForEach(photos.prefix(5)) { p in
                            PhotoTile(photo: p, showsOffline: false).frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.canvas, lineWidth: 2))
                        }
                        Spacer()
                        Text(Format.count(photos.count, "photo")).font(.headline)
                    }
                    .listRowBackground(Color.clear)
                }
                if let report { result(report) } else { options }
            }
            .navigationTitle("Save or Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(report == nil ? "Cancel" : "Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
                if case .success(let url) = r { run(to: url) }
            }
            .disabled(running)
            .overlay {
                if running {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(done), total: Double(max(1, photos.count)))
                        Text("Copying \(done) of \(photos.count)…").font(.headline)
                    }
                    .padding(24).frame(maxWidth: 300)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
                }
            }
        }
    }

    @ViewBuilder private var options: some View {
        Section("Copy as") {
            Picker("Format", selection: $preset) {
                Text("Originals, unchanged").tag(ExportOptions.Preset.originals)
                Text("JPEG").tag(ExportOptions.Preset.jpegOnly)
                Text("Smaller, for sharing").tag(ExportOptions.Preset.resizedForSharing)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Toggle("A folder for each person", isOn: $byPerson)
            Toggle("Write people’s names into the copies", isOn: $writeNames)
        }
        if offline > 0 {
            Section {
                Label("\(Format.count(offline, "original")) aren’t on this iPhone right now. Connect the card or drive first, or share the saved previews instead.",
                      systemImage: "externaldrive.badge.xmark").foregroundStyle(Palette.warning)
            }
        }
        Section {
            Button { picking = true } label: { Label("Save to Files…", systemImage: "folder") }
                .accessibilityIdentifier("export.files")
            Button { model.share = ShareRequest(photos: photos); dismiss() } label: { Label("Share…", systemImage: "square.and.arrow.up") }
        } footer: {
            Text("You choose where copies go. Pixora never moves, renames or changes your originals, and never uploads anything itself.")
        }
    }

    @ViewBuilder private func result(_ r: ExportReport) -> some View {
        Section {
            Label("\(Format.count(r.copied.count, "photo")) copied to “\(r.destination.lastPathComponent)”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.confirmed)
            if !r.duplicatesSkipped.isEmpty { Text("\(Format.count(r.duplicatesSkipped.count, "file")) already there, skipped.") }
            if !r.errors.isEmpty {
                ForEach(Array(r.errors.prefix(6).enumerated()), id: \.offset) { _, e in
                    Text("\(e.file): \(e.message)").font(.footnote).foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private func run(to folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        var options = ExportOptions(destination: folder)
        options.preset = preset
        options.organization = byPerson ? .byPerson : .flat
        options.writePeopleNames = writeNames
        let items = model.exportItems(photos)
        running = true; done = 0
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Exporter.export(items, options: options, progress: { n, _ in Task { @MainActor in done = n } })
            }.value
            if scoped { folder.stopAccessingSecurityScopedResource() }
            running = false
            report = r
        }
    }
}

/// The system share sheet with copies of the photos. Copies go in a temporary folder that is deleted when the
/// sheet closes; offline originals are shared as their saved preview, named so.
struct ShareSheet: UIViewControllerRepresentable {
    @Environment(PhoneModel.self) private var model
    let photos: [Photo]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var urls: [URL] = []
        for p in photos {
            if p.id < 0, let jpeg = model.privateContent?.items.first(where: { $0.photo.id == p.id })?.preview {
                let u = SourceAccess.uniqueURL(temp.appendingPathComponent((p.filename as NSString).deletingPathExtension + ".jpg"))
                if (try? jpeg.write(to: u)) != nil { urls.append(u) }
                continue
            }
            let original = model.source(p.sourceID).map { $0.url.appendingPathComponent(p.relPath) }
            if let original, FileManager.default.fileExists(atPath: original.path) {
                let u = SourceAccess.uniqueURL(temp.appendingPathComponent(p.filename))
                if (try? FileManager.default.copyItem(at: original, to: u)) != nil { urls.append(u) }
            } else if FileManager.default.fileExists(atPath: AppPaths.thumbnail(photoID: p.id).path) {
                let u = SourceAccess.uniqueURL(temp.appendingPathComponent((p.filename as NSString).deletingPathExtension + " preview.jpg"))
                if (try? FileManager.default.copyItem(at: AppPaths.thumbnail(photoID: p.id), to: u)) != nil { urls.append(u) }
            }
        }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: temp) }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
