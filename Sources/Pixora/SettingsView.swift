import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

struct SettingsView: View {
    var body: some View {
        TabView {
            RecognitionSettings().tabItem { Label("Recognition", systemImage: "person.crop.square") }
            PrivacySettings().tabItem { Label("Privacy & Data", systemImage: "hand.raised") }
            CloudSettings().tabItem { Label("Cloud", systemImage: "cloud") }
        }
        .frame(width: 620, height: 520)
    }
}

struct RecognitionSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Processing") {
                LabeledContent("Mode") {
                    Label("Local — on this Mac", systemImage: "lock.laptopcomputer").foregroundStyle(Palette.confirmed)
                }
                LabeledContent("Face detection", value: Detectors.makeDefault().name)
                LabeledContent("Face recognition", value: model.embedder.displayName)
                Text(model.embedder.detail).font(.caption).foregroundStyle(.secondary)
                if model.isBasicMode {
                    Text("No face-recognition model is installed, so Pixora is using Apple Vision’s generic feature print, which isn’t designed to tell people apart. Build the ArcFace model with tools/convert_arcface.py (see README) and install it here.")
                        .font(.caption).foregroundStyle(Palette.safelight)
                }
                Button("Install Face Model…") { model.installModel() }
                if model.stats.facesFromOtherEmbedder > 0 {
                    Text("\(model.stats.facesFromOtherEmbedder) faces were analysed with a different model and are ignored for matching.")
                        .font(.caption).foregroundStyle(Palette.safelight)
                    Button("Clear and Re-analyse…") { model.reanalyseLibrary() }
                }
            }
            Section("Matching") {
                Slider(value: $model.strictness, in: -0.08...0.08, step: 0.02) {
                    Text("Strictness")
                } minimumValueLabel: { Text("Looser").font(.caption) } maximumValueLabel: { Text("Stricter").font(.caption) }
                Text("Stricter: fewer wrong matches, more faces sent to Review. Looser: more automatic matches, more risk of mistakes. Your confirmed faces are never changed by this setting.")
                    .font(.caption).foregroundStyle(.secondary)
                let t = model.thresholds
                Text(String(format: "Cosine similarity thresholds — certain ≥ %.2f · suggest ≥ %.2f · group ≥ %.2f", t.certain, t.suggest, t.group))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var confirmErase = false

    var body: some View {
        let s = model.stats
        Form {
            Section("What Pixora stores") {
                Text("Face templates (lists of numbers describing a face) are biometric data. Pixora keeps them only on this Mac, in its own library — never next to your photos, never uploaded.")
                    .font(.callout)
                LabeledContent("Face templates", value: s.recognizableFaces.formatted())
                LabeledContent("Faces detected (incl. small or ignored)", value: s.faces.formatted())
                LabeledContent("People (named / total)", value: "\(s.namedPeople) / \(s.people)")
                LabeledContent("Photos indexed", value: s.photos.formatted())
                LabeledContent("Library database", value: Format.size(s.databaseBytes))
                LabeledContent("Photo thumbnails cache", value: Format.size(s.thumbnailBytes))
                Text("The library holds names, face templates, small face crops, file paths and photo metadata (date, camera, lens, rating). It is not encrypted by Pixora; it is protected by your macOS account and FileVault.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Library Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database]) }
            }
            Section("Backup") {
                HStack {
                    Button("Back Up People Database…") { backup() }
                    Button("Restore from Backup…") { restore() }
                }
                Text("Backups contain names and face templates. Store them somewhere private.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Delete") {
                Button("Clear All Face Data…", role: .destructive) { confirmClear = true }
                Text("Deletes every face template, face crop, person and correction. Your photo index stays; photos can be scanned again.").font(.caption).foregroundStyle(.secondary)
                Button("Erase Everything…", role: .destructive) { confirmErase = true }
                Text("Deletes the whole library and thumbnail cache. Your original photos are never affected.").font(.caption).foregroundStyle(.secondary)
                Text("To delete one person’s data, open them in People and choose Forget.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all face data?", isPresented: $confirmClear) {
            Button("Delete Face Data", role: .destructive) { model.perform { try model.store.clearFaceData() }; model.clearUndoHistory(); ImageCache.shared.invalidateFaces(); model.selectedPeople = [] }
        } message: { Text("This removes \(s.recognizableFaces) face templates and \(s.people) people. This cannot be undone unless you have a backup.") }
        .confirmationDialog("Erase the entire Pixora library?", isPresented: $confirmErase) {
            Button("Erase Everything", role: .destructive) { model.lockPrivateSpace(); try? model.vault.destroy(); model.perform { try model.store.eraseAll() }; model.clearUndoHistory(); ImageCache.shared.invalidateFaces(); model.selectedPeople = [] }
        } message: { Text("People, faces, sources, import history, thumbnails and Private Space (with its encrypted photos and keys) will be deleted. Original photos are not touched.") }
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pixora People \(Format.day.string(from: Date())).pixorabackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "pixorabackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try model.store.db.backup(to: url)
        } catch { model.errorMessage = "Backup failed: \(error)" }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pixorabackup", "rollcallbackup"].compactMap { UTType(filenameExtension: $0) }   // older backups too
        panel.message = "Restoring replaces the current library with the backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.db.restore(from: url)
            model.clearUndoHistory()
            ImageCache.shared.invalidateFaces()
            model.selectedPeople = []
            model.refreshAll()
        } catch { model.errorMessage = "Restore failed: \(error)" }
    }
}

struct CloudSettings: View {
    var body: some View {
        Form {
            Section("Cloud processing") {
                LabeledContent("Status") { Text("Off — not available in this version").foregroundStyle(.secondary) }
                Text("Pixora never sends photos or face data anywhere. Recognition runs entirely on this Mac.")
                    .font(.callout)
            }
            Section("Why there’s no cloud option yet") {
                Text("""
                • Apple Vision has no public face-recognition API, but on-device SCRFD + ArcFace models handle detection and recognition well (see README for measured accuracy), so the cloud isn’t needed for quality.
                • Google Cloud Vision detects faces but does not recognise individuals.
                • Microsoft Azure Face identification and verification are Limited Access: Microsoft must approve an application.
                • Amazon Rekognition does support face search (US East pricing at time of writing: $0.001 per image for the first million images per month, plus $0.00001 per stored face per month). It uses AWS access keys rather than a single API key, and stores face vectors in your AWS account.
                """)
                .font(.caption).foregroundStyle(.secondary)
                Text("If a cloud provider is added later, its keys will be stored only in the macOS Keychain, and nothing will be uploaded until you turn it on after seeing exactly what is sent and what it may cost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
