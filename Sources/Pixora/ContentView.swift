import SwiftUI
import PixoraCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            Group {
                switch model.section {
                case .find: FindView()
                case .review: ReviewView()
                case .people: PeopleView()
                case .allPhotos: AllPhotosView()
                case .insights: InsightsView()
                case .settings: SettingsScreen()
                case .privateSpace: PrivateSpaceView()
                case .importer: ImportView()
                }
            }
            .overlay(alignment: .top) { cardBanner }
            .inspector(isPresented: Binding(get: { model.showInspector && [.find, .allPhotos].contains(model.section) },
                                            set: { model.showInspector = $0 })) {
                PhotoInspector(photoID: model.inspectedPhotoID).inspectorColumnWidth(min: 280, ideal: 340, max: 480)
            }
        }
        .sheet(item: $model.scan) { session in ScanSheet(session: session).interactiveDismissDisabled() }
        .sheet(item: $model.exportRequest) { req in ExportSheet(request: req) }
        .sheet(item: $model.exportEveryone) { req in ExportEveryoneSheet(request: req) }
        .sheet(item: $model.recapRequest) { req in RecapSheet(request: req) }
        .sheet(isPresented: $model.showForgotForTesting) { DeletePrivateSpaceSheet(forgot: true) }
        .sheet(isPresented: $model.showDeletePrivateSpace) { DeletePrivateSpaceSheet(forgot: true) }
        .overlay {
            if model.showCommandBar {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.showCommandBar = false }
                    CommandBar().padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.showCommandBar)
        .overlay(alignment: .bottom) { ToastView(undoManager: undoManager).padding(.bottom, 84) }
        .overlay { if model.viewer != nil { PhotoViewer().id(model.viewer?.id) } }
        .overlay { if let s = model.slideshow { SlideshowPlayer(request: s).id(s.id).transition(.opacity) } }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

extension ContentView {
    @ViewBuilder var cardBanner: some View {
        if let prompt = model.cardPrompt {
            HStack(spacing: 12) {
                Image(systemName: "sdcard.fill").font(.title2).foregroundStyle(Palette.safelight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prompt.volume.name ?? "Card") inserted").font(.system(size: 14, weight: .semibold))
                    Text(prompt.source == nil ? "\(prompt.newPhotos) photos on this card." : "\(prompt.newPhotos) new photos since the last scan.")
                        .font(.caption).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Button("Not Now") { model.cardPrompt = nil }
                Button(prompt.source == nil ? "Preview & Scan" : "Scan New Photos") { model.acceptCardPrompt() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.safelight.opacity(0.5)))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .frame(maxWidth: 620)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s; if s == .people { model.openPersonID = nil } } })) {
                Section("Library") {
                    Label("Find Photos", systemImage: "person.2.crop.square.stack").tag(SidebarItem.find)
                    Label("Review", systemImage: "tray.full")
                        .badge(model.stats.reviewItems)
                        .tag(SidebarItem.review)
                    Label("People", systemImage: "person.crop.rectangle.stack").tag(SidebarItem.people)
                    Label("All Photos", systemImage: "photo.on.rectangle").tag(SidebarItem.allPhotos)
                    Label("Insights", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.insights)
                    // No counts that would reveal anything. Signed out, it explains and offers sign-in.
                    Label("Private Space", systemImage: model.isPrivateUnlocked ? "lock.open" : "lock").tag(SidebarItem.privateSpace)
                }
                Section("Import") {
                    Label("Cards & Folders", systemImage: "sdcard").tag(SidebarItem.importer)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                    ForEach(model.volumes) { v in
                        Button { model.scanVolume(v) } label: {
                            Label(v.name ?? v.url.lastPathComponent, systemImage: v.looksLikeCameraCard ? "sdcard.fill" : "externaldrive")
                        }.buttonStyle(.plain).help("Preview and scan this card")
                    }
                }
                if !model.namedPeople.isEmpty && ThemeManager.shared.sidebarPeople > 0 {
                    Section("People") {
                        ForEach(model.namedPeople.prefix(ThemeManager.shared.sidebarPeople)) { p in
                            SidebarPersonRow(person: p)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            processingFooter
        }
    }

    /// Always-visible statement of where processing happens.
    private var processingFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
            Image(systemName: "lock.laptopcomputer").foregroundStyle(Palette.confirmed)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local processing").font(.system(size: 11, weight: .semibold))
                Text(model.isBasicMode ? "Basic mode — install face model" : "\(model.embedder.displayName.replacingOccurrences(of: " (on-device)", with: "")) on this Mac · nothing uploaded")
                    .font(.system(size: 10)).foregroundStyle(model.isBasicMode ? Palette.safelight : .secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        Button { model.section = .settings; UserDefaults.standard.set("about", forKey: "settingsPage") } label: {
            Text("Made by \(Credits.author)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("About Pixora · \(Credits.email)")
        }
        .padding(12)
    }
}

/// A person in the sidebar: click to find their photos; drop a face here to assign it to them.
private struct SidebarPersonRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var targeted = false
    @State private var hovering = false
    var body: some View {
        Button { model.selectedPeople = [person.id]; model.section = .find } label: {
            HStack(spacing: 8) {
                FaceImage(faceID: person.coverFaceID, size: hovering || targeted ? 24 : 20, shape: AnyShape(Circle()))
                    .overlay(Circle().strokeBorder(targeted ? Palette.safelight : .clear, lineWidth: 2))
                Text(person.displayName).lineLimit(1)
                if person.id == model.mePersonID { Text("me").font(Typography.edge).foregroundStyle(Palette.confirmed) }
                Spacer()
                Text("\(person.photoCount)").font(Typography.edge).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Palette.safelight.opacity(0.25) : (hovering ? Palette.rule.opacity(0.5) : .clear)))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering || targeted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            items.contains { model.dropFace($0, on: person.id) }
        } isTargeted: { targeted = $0 }
        .help(targeted ? "Drop to assign this face to \(person.displayName)" : "\(person.displayName) — click for photos, or drop a face here")
    }
}

/// "Named Ana — Undo" after each correction; disappears after a few seconds.
private struct ToastView: View {
    @Environment(AppModel.self) private var model
    let undoManager: UndoManager?
    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.confirmed)
                    Text(toast.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if toast.offersUndo, undoManager?.canUndo == true {
                        Button("Undo") { undoManager?.undo() }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.safelight)
                            .help("Undo (⌘Z) — Redo is ⇧⌘Z")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Palette.rule))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.toast)
    }
}
