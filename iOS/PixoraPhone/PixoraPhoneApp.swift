import SwiftUI
import PixoraCore

@main
struct PixoraPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase
    @State private var shielded = false

    init() { Typo.styleNavigationBars() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.safelight)
                // While the app is in the app switcher or behind Control Center, its snapshot shows this cover,
                // never photos. Private Space also locks the moment the app leaves the foreground.
                .overlay { if shielded { PrivacyShield().transition(.opacity) } }
                .onChange(of: phase) { _, now in
                    switch now {
                    case .active:
                        shielded = false
                        model.reconnectSources()
                        model.scan?.appDidBecomeActive()
                    case .inactive:
                        shielded = true
                    case .background:
                        shielded = true
                        model.lockPrivateSpace()
                        model.scan?.appDidEnterBackground()
                        SlideshowMusic.shared.stop()
                    @unknown default: break
                    }
                }
        }
    }
}

private struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "camera.aperture").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.safelight)
                Text("Pixora").font(Typo.display(.title)).foregroundStyle(Palette.ink)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RootView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            FindScreen()
                .tabItem { Label("Find", systemImage: "person.2.crop.square.stack") }
                .tag(PhoneTab.find)
            PeopleScreen()
                .tabItem { Label("People", systemImage: "person.crop.circle") }
                .tag(PhoneTab.people)
            LibraryScreen()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                .tag(PhoneTab.library)
            ReviewScreen()
                .tabItem { Label("Review", systemImage: "checkmark.bubble") }
                .badge(model.stats.reviewItems)
                .tag(PhoneTab.review)
            PrivateSpaceScreen()
                .tabItem { Label("Private", systemImage: model.isPrivateUnlocked ? "lock.open" : "lock") }
                .tag(PhoneTab.privateSpace)
        }
        .fullScreenCover(item: $model.viewer) { PhotoViewer(request: $0) }
        .fullScreenCover(item: $model.slideshow) { SlideshowPlayer(request: $0) }
        .sheet(item: $model.scan) { ScanSheet(scan: $0) }
        .sheet(item: Binding(get: { model.exportPhotos.map(ExportBatch.init) }, set: { model.exportPhotos = $0?.photos })) { ExportSheet(photos: $0.photos) }
        .sheet(item: $model.share) { ShareSheet(photos: $0.photos) }
        .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 58) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct ExportBatch: Identifiable {
    let id = UUID()
    let photos: [Photo]
}

/// A short confirmation with Undo, above the tab bar. Dismisses itself.
private struct UndoToast: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let offer = model.undo {
                HStack(spacing: 12) {
                    Text(offer.text).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    if offer.snapshot != nil {
                        Button("Undo") { model.applyUndo(offer) }.font(.subheadline.weight(.bold)).foregroundStyle(Palette.safelight)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.leading, 16).padding(.trailing, 8)
                .frame(minHeight: 50)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Palette.rule.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: offer.id) {
                    UIAccessibility.post(notification: .announcement, argument: offer.text)
                    try? await Task.sleep(for: .seconds(5))
                    if model.undo?.id == offer.id { model.undo = nil }
                }
            }
        }
        .animation(Motion.spring, value: model.undo)
    }
}

/// Testing hooks read from the environment by the UI tests. They only seed data inside the app's own sandbox.
enum TestHooks {
    @MainActor static func apply(to model: PhoneModel) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PIXORA_TEST_FOLDER"] {
            // Copy bundled-in-test photos into Pixora's own folder, as if picked from Files, then scan them.
            let src = URL(fileURLWithPath: path, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
            _ = SourceAccess.copyFiles(files)
            model.scanManagedFolder(SourceAccess.fromFiles)
        }
        switch env["PIXORA_TAB"] {
        case "people": model.tab = .people
        case "library": model.tab = .library
        case "review": model.tab = .review
        case "private": model.tab = .privateSpace
        default: break
        }
    }
}
