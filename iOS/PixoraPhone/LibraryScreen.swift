import SwiftUI
import PixoraCore

struct LibraryScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var photos: [Photo] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var settings = false
    @State private var selecting = false
    @State private var selection: Set<Int64> = []
    @State private var studio = false
    @State private var showFavorites = false

    private var shown: [Photo] { showFavorites ? photos.filter { model.favorites.contains($0.id) } : photos }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.sources.isEmpty && loaded {
                        EmptyState(symbol: "photo.stack", title: "Your library is empty",
                                   message: "Add photos from your Photos library, a folder in Files, or an SD card reader. Everything is analysed on this iPhone and nothing is uploaded.",
                                   actionTitle: "Add Photos", action: { adding = true })
                            .padding(.top, 40)
                    } else {
                        SourcesStrip(onAdd: { adding = true })
                        if !photos.isEmpty {
                            HStack(spacing: 8) {
                                Chip(title: "All \(photos.count.formatted())", on: !showFavorites) { showFavorites = false }
                                Chip(title: "Favourites", symbol: "heart", on: showFavorites) { showFavorites = true }
                            }
                            .padding(.horizontal, 16)
                            if shown.isEmpty {
                                EmptyState(symbol: "heart", title: "No favourites yet", message: "Tap ♥ while viewing a photo to keep it here.")
                            }
                            PhotoGrid(photos: shown, selection: selecting ? $selection : nil) { p in
                                model.openViewer(shown, at: p.id, title: showFavorites ? "Favourites" : "Library")
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .canvas()
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("library.settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !photos.isEmpty { Button(selecting ? "Done" : "Select") { selecting.toggle(); selection = [] } }
                    Button { adding = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Add Photos")
                        .accessibilityIdentifier("library.add")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    SelectionBar(photos: shown.filter { selection.contains($0.id) }, total: shown.count,
                                 onSelectAll: { selection = Set(shown.map(\.id)) }, onSlideshow: { studio = true },
                                 onDone: { selecting = false; selection = [] })
                }
            }
            .task(id: "\(model.stats.photos)-\(model.sources.count)-\(model.privateContent == nil)") { await load() }
            .sheet(isPresented: $adding, onDismiss: model.runAfterAddPhotos) { AddPhotosSheet() }
            .sheet(isPresented: $settings) { SettingsScreen() }
            .sheet(isPresented: $studio) { SlideshowStudio(source: .library, chosen: shown.filter { selection.contains($0.id) }) }
        }
    }

    private func load() async {
        let store = model.store
        photos = await Task.detached(priority: .userInitiated) {
            ((try? store.photos()) ?? []).sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        }.value
        loaded = true
    }
}

/// The places photos come from, with their connection state. Each card offers scan again / reconnect / remove.
private struct SourcesStrip: View {
    @Environment(PhoneModel.self) private var model
    let onAdd: () -> Void
    @State private var reconnecting: Source?
    @State private var removing: Source?
    @State private var mismatch: (source: Source, url: URL, check: (checked: Int, matched: Int))?
    @ScaledMetric(relativeTo: .subheadline) private var cardWidth: CGFloat = 168
    @ScaledMetric(relativeTo: .subheadline) private var cardHeight: CGFloat = 128

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.sources) { s in card(s) }
                Button(action: onAdd) {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.title2.weight(.semibold))
                        Text("Add Photos").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Palette.safelight)
                    .frame(width: cardWidth * 0.72, height: cardHeight)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.safelight.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .fileImporter(isPresented: Binding(get: { reconnecting != nil }, set: { if !$0 { reconnecting = nil } }), allowedContentTypes: [.folder]) { result in
            guard let s = reconnecting, case .success(let url) = result else { return }
            if let check = model.reconnect(s, to: url) { mismatch = (s, url, check) }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Pixora?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let s = removing {
                if SourceAccess.isManaged(s) {
                    Button("Remove and Delete Pixora’s Copies", role: .destructive) { model.remove(s, deleteCopies: true) }
                    Button("Remove, Keep Copies") { model.remove(s, deleteCopies: false) }
                } else {
                    Button("Remove from Pixora", role: .destructive) { model.remove(s, deleteCopies: false) }
                }
            }
        } message: {
            if let s = removing {
                Text(SourceAccess.isManaged(s)
                     ? "Pixora forgets these photos and their faces. Its copies can be deleted too. The originals in Photos or Files are not affected."
                     : "Pixora forgets these photos and their faces. The folder and every photo in it stay exactly as they are.")
            }
        }
        .alert("This folder doesn’t look like “\(mismatch?.source.name ?? "")”", isPresented: Binding(get: { mismatch != nil }, set: { if !$0 { mismatch = nil } })) {
            Button("Reconnect Anyway") { if let m = mismatch { model.forceReconnect(m.source, to: m.url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let m = mismatch { Text("Only \(m.check.matched) of \(m.check.checked) sampled photos were found there with the same size.") }
        }
    }

    private func card(_ s: Source) -> some View {
        let online = s.isOnline
        let managed = SourceAccess.isManaged(s)
        return Menu {
            if online { Button { model.rescan(s) } label: { Label("Scan for New Photos", systemImage: "arrow.clockwise") } }
            if !managed { Button { reconnecting = s } label: { Label(online ? "Choose Folder Again" : "Reconnect…", systemImage: "link") } }
            Button(role: .destructive) { removing = s } label: { Label("Remove from Pixora", systemImage: "minus.circle") }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon(s)).font(.title2).foregroundStyle(online ? Palette.safelight : Palette.ink2)
                Spacer(minLength: 0)
                Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Circle().fill(online ? Palette.confirmed : Palette.warning).frame(width: 7, height: 7)
                    Text(online ? (s.lastScanAt.map { "Scanned \(Format.day($0))" } ?? "Not scanned yet") : "Not connected")
                        .font(.caption).foregroundStyle(online ? Palette.ink2 : Palette.warning).lineLimit(2)
                }
            }
            .padding(14)
            .frame(width: min(cardWidth, 300), alignment: .leading)
            .frame(minHeight: cardHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(online ? Palette.rule.opacity(0.7) : Palette.warning.opacity(0.6), lineWidth: online ? 0.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.name), \(online ? "connected" : "not connected")")
        .accessibilityHint("Shows options to scan, reconnect or remove")
    }

    private func icon(_ s: Source) -> String {
        if s.path.hasSuffix("From Photos") { return "photo.on.rectangle.angled" }
        if s.path.hasSuffix("From Files") { return "doc.on.doc" }
        if s.isRemovable || s.path.contains("/DCIM") { return "sdcard" }
        return "folder"
    }
}
