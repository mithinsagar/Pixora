import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PixoraCore

/// One import on iPhone: preview → scan (pause / resume / cancel) → summary. The same ScanEngine as the Mac.
@MainActor @Observable
final class PhoneScan: Identifiable {
    enum Stage { case previewing, ready, scanning, done }
    let id = UUID()
    let source: Source
    unowned let model: PhoneModel
    var stage: Stage = .previewing
    var preview: ScanPreview?
    var excludedFolders: Set<String> = []
    var alreadyScanned = 0
    var progress = ScanProgress()
    var isPaused = false
    /// Paused because the app went to the background (iOS stops on-device ML work there).
    var pausedForBackground = false
    private var engine: ScanEngine?
    private var task: Task<Void, Never>?
    private var work: Task<ScanProgress, Never>?

    init(model: PhoneModel, source: Source) {
        self.model = model
        self.source = source
        let root = source.url, store = model.store, sid = source.id, embedderID = model.embedder.id
        task = Task { [weak self] in
            let (preview, unchanged) = await Task.detached(priority: .userInitiated) { () -> (ScanPreview, Int) in
                let p = FileScanner.preview(root: root)
                let existing = (try? store.existingPhotos(sourceID: sid)) ?? [:]
                let unchanged = p.files.filter { f in
                    guard let e = existing[f.relPath] else { return false }
                    return e.size == f.size && abs(e.mtime - f.mtime) < 1 && e.scanState == 1 && e.embedder == embedderID
                }.count
                return (p, unchanged)
            }.value
            self?.preview = preview
            self?.alreadyScanned = unchanged
            self?.stage = .ready
            if ProcessInfo.processInfo.environment["PIXORA_AUTOSCAN"] != nil { self?.start() }
        }
    }

    var selectedFiles: [ScanFile] { (preview?.files ?? []).filter { !excludedFolders.contains($0.folder) } }
    var newCount: Int { max(0, selectedFiles.count - alreadyScanned) }

    func start() {
        let engine = model.makeEngine()
        self.engine = engine
        stage = .scanning
        UIApplication.shared.isIdleTimerDisabled = true
        let files = selectedFiles, source = source
        let work = Task.detached(priority: .userInitiated) {
            await engine.run(source: source, files: files) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self, p.processed >= self.progress.processed || p.phase != .scanning else { return }
                    self.progress = p
                }
            }
        }
        self.work = work
        task = Task { [weak self] in
            let final = await work.value
            UIApplication.shared.isIdleTimerDisabled = false
            self?.progress = final
            self?.stage = .done
            self?.model.refreshAll()
        }
    }

    func togglePause() {
        guard let engine else { return }
        isPaused.toggle()
        let paused = isPaused
        Task { if paused { await engine.pause() } else { await engine.resume() } }
    }

    func appDidEnterBackground() {
        guard stage == .scanning, !isPaused, let engine else { return }
        pausedForBackground = true
        Task { await engine.pause() }
    }

    func appDidBecomeActive() {
        guard pausedForBackground, let engine else { return }
        pausedForBackground = false
        if !isPaused { Task { await engine.resume() } }
    }

    func cancel() {
        if isPaused, let engine { Task { await engine.resume() } }
        isPaused = false
        work?.cancel()
        if stage != .scanning { task?.cancel(); UIApplication.shared.isIdleTimerDisabled = false; model.scan = nil }
    }
}

// MARK: - Add photos

/// The import chooser: Photos library, a folder in Files (including card readers and drives), or single files.
struct AddPhotosSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var pickFolder = false
    @State private var pickFiles = false
    @State private var copying: (done: Int, total: Int)?
    @State private var showDriveHelp = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Subtitle(text: "Pixora only reads your photos. It never moves, renames, changes or deletes them.")
                        .padding(.bottom, 4)
                    option("photo.on.rectangle.angled", "Photos library",
                           "Pick photos or albums. Pixora keeps its own copy of each one, so it can find faces and show them offline. Your Photos library isn’t changed.") { showPhotos = true }
                        .accessibilityIdentifier("import.photos")
                    option("folder", "A folder in Files",
                           "iCloud Drive, On My iPhone, or a shared folder. Pixora reads it where it is, and finds new photos when you scan again.") { pickFolder = true }
                        .accessibilityIdentifier("import.folder")
                    option("sdcard", "SD card or USB drive",
                           "Plug in a card reader or drive, then choose its DCIM folder in Files. Pixora reads it while it’s connected.") { pickFolder = true }
                        .accessibilityIdentifier("import.card")
                    Button { showDriveHelp.toggle() } label: {
                        Label("What iOS allows for cards and drives", systemImage: showDriveHelp ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.safelight)
                            .frame(minHeight: 44)
                    }
                    if showDriveHelp { driveHelp.transition(.opacity) }
                    option("doc.on.doc", "Single files",
                           "Choose individual photo files from Files. Pixora copies them, so they stay available after you unplug.") { pickFiles = true }
                        .accessibilityIdentifier("import.files")
                }
                .padding(16)
                .animation(Motion.quick, value: showDriveHelp)
            }
            .canvas()
            .navigationTitle("Add Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .photosPicker(isPresented: $showPhotos, selection: $picked, maxSelectionCount: nil, matching: .images,
                          preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: picked) { _, items in importPhotos(items) }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.afterAddPhotos = { [model] in model.addFolder(url) }; dismiss() }
                else if case .failure(let e) = result { model.errorMessage = e.localizedDescription }
            }
            .fileImporter(isPresented: $pickFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let r = SourceAccess.copyFiles(urls)
                    if r.failed > 0 { model.errorMessage = "\(Format.count(r.failed, "file")) couldn’t be copied." }
                    model.afterAddPhotos = { [model] in model.scanManagedFolder(SourceAccess.fromFiles) }
                    dismiss()
                }
            }
            .overlay { if let copying { copyingOverlay(copying) } }
        }
    }

    private func option(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.safelight.opacity(0.14)).frame(width: 48, height: 48)
                    Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.safelight)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Palette.ink)
                    Text(detail).font(.subheadline).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Palette.ink2.opacity(0.6)).padding(.top, 4)
            }
            .multilineTextAlignment(.leading)
            .card()
        }
        .buttonStyle(.plain)
    }

    private var driveHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            bullet("iOS has no automatic “card inserted” signal for apps. Open Files, or choose the card here, after plugging it in.")
            bullet("Use a USB-C (or Lightning) SD card reader or drive formatted as exFAT, FAT32 or APFS. NTFS drives are read-only or not shown, depending on the iOS version.")
            bullet("Pixora can read the card only while it’s plugged in. If you unplug it, your people and previews stay, and Pixora marks the photos “not connected” until you reconnect.")
            bullet("Pixora never writes to the card. Copies you export go only where you choose.")
        }
        .card(padding: 14)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Palette.safelight).frame(width: 5, height: 5).padding(.top, 7)
            Text(text).font(.subheadline).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        copying = (0, items.count)
        Task {
            let r = await SourceAccess.copyFromPhotos(items) { done in copying = (done, items.count) }
            copying = nil
            picked = []
            if r.failed > 0 { model.errorMessage = "\(Format.count(r.failed, "photo")) couldn’t be copied from Photos (for example, an iCloud photo that hasn’t downloaded yet)." }
            model.afterAddPhotos = { [model] in model.scanManagedFolder(SourceAccess.fromPhotos) }
            dismiss()
        }
    }

    private func copyingOverlay(_ c: (done: Int, total: Int)) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(c.done), total: Double(max(1, c.total))).tint(Palette.safelight)
            Text("Copying \(c.done) of \(c.total) from Photos…").font(.headline).foregroundStyle(Palette.ink)
            Text("Photos stored in iCloud are downloaded first, which can take a moment.").font(.footnote).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25).ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scan

struct ScanSheet: View {
    @Environment(PhoneModel.self) private var model
    @Bindable var scan: PhoneScan

    var body: some View {
        NavigationStack {
            Group {
                switch scan.stage {
                case .previewing: loading
                case .ready: ready
                case .scanning: scanning
                case .done: done
                }
            }
            .canvas()
            .navigationTitle(scan.source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if scan.stage != .scanning { Button(scan.stage == .done ? "Done" : "Cancel") { scan.cancel(); model.scan = nil } }
                }
            }
        }
        .interactiveDismissDisabled(scan.stage == .scanning)
    }

    private var loading: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Palette.safelight)
            Text("Looking for photos…").font(.headline).foregroundStyle(Palette.ink)
            Text("Pixora is only reading the folder.").font(.subheadline).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var ready: some View {
        if let p = scan.preview, !p.files.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(scan.selectedFiles.count.formatted()).font(Typo.display(.largeTitle)).foregroundStyle(Palette.ink)
                        Text(scan.selectedFiles.count == 1 ? "photo" : "photos").font(.title3).foregroundStyle(Palette.ink2)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 8) {
                        EdgeLabel(Format.size(p.totalBytes))
                        if p.rawPairs > 0 { EdgeLabel("· \(p.rawPairs) RAW+JPEG") }
                        if p.videosSkipped > 0 { EdgeLabel("· \(p.videosSkipped) videos skipped") }
                    }
                    if scan.alreadyScanned > 0 {
                        Label("\(Format.count(scan.alreadyScanned, "photo")) already scanned and unchanged. They’ll be skipped.", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(Palette.confirmed)
                    }
                    if p.folders.count > 1 {
                        Text("Folders").font(.headline).foregroundStyle(Palette.ink).padding(.top, 6)
                        VStack(spacing: 0) {
                            ForEach(p.folders) { f in
                                Toggle(isOn: Binding(get: { !scan.excludedFolders.contains(f.path) },
                                                     set: { on in if on { scan.excludedFolders.remove(f.path) } else { scan.excludedFolders.insert(f.path) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.path.isEmpty ? "Top folder" : f.path).font(.body).foregroundStyle(Palette.ink).lineLimit(1)
                                        Text(Format.count(f.photos, "photo")).font(.caption).foregroundStyle(Palette.ink2)
                                    }
                                }
                                .tint(Palette.safelight)
                                .padding(.vertical, 8)
                                if f.id != p.folders.last?.id { Divider() }
                            }
                        }
                        .card(padding: 14)
                    }
                    Label("Scanning runs on this iPhone, offline. Keep Pixora open: iOS pauses on-device analysis in the background, and Pixora carries on when you come back.",
                          systemImage: "iphone")
                        .font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    if model.isBasicMode {
                        Label("The face models aren’t in this build, so Pixora is using Apple’s basic feature print. Grouping will be much weaker.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Palette.warning)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button { scan.start() } label: {
                    Text(scan.newCount == 0 ? "Check Again" : "Scan \(Format.count(scan.newCount, "Photo"))")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scan.selectedFiles.isEmpty)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
                .accessibilityIdentifier("scan.start")
            }
        } else {
            EmptyState(symbol: "photo.badge.exclamationmark", title: "No photos here",
                       message: "Pixora reads JPEG, HEIC, PNG and camera RAW files. If this is a card, choose its DCIM folder.")
        }
    }

    private var scanning: some View {
        let p = scan.progress
        return VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(Palette.rule, lineWidth: 10)
                Circle().trim(from: 0, to: p.fraction).stroke(Palette.safelight, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.3), value: p.fraction)
                VStack(spacing: 2) {
                    Text("\(Int(p.fraction * 100))%").font(Typo.display(.largeTitle)).foregroundStyle(Palette.ink).monospacedDigit()
                    EdgeLabel("\(p.processed) of \(p.total)")
                }
            }
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scanning, \(Int(p.fraction * 100)) percent, \(p.processed) of \(p.total) photos")
            Text(p.phase == .grouping ? "Grouping faces into people…" : (scan.isPaused ? "Paused" : "Finding faces…"))
                .font(.headline).foregroundStyle(Palette.ink)
            HStack(spacing: 18) {
                stat("\(p.facesFound)", "faces")
                stat("\(p.newPhotos)", "new photos")
                if let s = p.secondsRemaining, !scan.isPaused { stat(Format.duration(s), "left") }
            }
            FaceStrip(thumbs: p.recentFaceThumbs, serial: p.thumbSerial)
            if scan.pausedForBackground { Text("Paused while Pixora was in the background.").font(.footnote).foregroundStyle(Palette.ink2) }
            Spacer()
            HStack(spacing: 12) {
                Button(scan.isPaused ? "Resume" : "Pause") { scan.togglePause() }.buttonStyle(SecondaryButtonStyle())
                Button("Stop") { scan.cancel() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 16)
            Text("Stopping keeps everything scanned so far.").font(.footnote).foregroundStyle(Palette.ink2).padding(.bottom, 8)
        }
        .padding(16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            EdgeLabel(label)
        }
        .accessibilityElement(children: .combine)
    }

    private var done: some View {
        let p = scan.progress
        return ScrollView {
            VStack(spacing: 18) {
                Image(systemName: p.phase == .cancelled ? "pause.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 64)).foregroundStyle(p.phase == .cancelled ? Palette.warning : Palette.confirmed)
                    .padding(.top, 30)
                    .accessibilityHidden(true)
                Text(p.phase == .cancelled ? "Scan stopped" : "Scan complete").font(Typo.display(.title)).foregroundStyle(Palette.ink)
                Text("\(Format.count(p.newPhotos, "new photo")), \(Format.count(p.facesFound, "face")) found.")
                    .font(.body).foregroundStyle(Palette.ink2)
                if !p.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(Format.count(p.errors.count, "file")) couldn’t be read", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(Palette.warning)
                        ForEach(Array(p.errors.prefix(5).enumerated()), id: \.offset) { _, e in
                            Text("\(e.file): \(e.message)").font(.footnote).foregroundStyle(Palette.ink2).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                VStack(spacing: 10) {
                    if model.stats.uncertainItems > 0 || !model.unnamedGroups.isEmpty {
                        Button("Name People and Review") { model.scan = nil; model.tab = model.unnamedGroups.isEmpty ? .review : .people }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Button("Find Photos") { model.scan = nil; model.tab = .find }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
    }
}

/// The last few faces found, sliding in as the scan goes.
private struct FaceStrip: View {
    let thumbs: [Data]
    let serial: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(thumbs.suffix(6).enumerated()), id: \.offset) { _, d in
                if let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(Circle())
                        .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 2))
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
        }
        .frame(height: 48)
        .animation(reduceMotion ? nil : Motion.spring, value: serial)
        .accessibilityHidden(true)
    }
}
