import SwiftUI
import PixoraCore

struct AllPhotosView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = PhotoFilter()
    @State private var photos: [Photo] = []
    @State private var cameras: [String] = []
    @State private var lenses: [String] = []
    @State private var failed: [Photo] = []
    @State private var selecting = false
    @State private var selected: Set<Int64> = []
    /// Until the first load lands, show nothing rather than a flash of "No photos yet".
    @State private var loaded = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    SectionHeader(title: "All Photos", subtitle: "\(Format.count(photos.count, "photo")) shown · \(model.stats.scanned.formatted()) scanned in total")
                    Button { model.quickPick = QuickPickRequest(title: "All Photos", photos: photos) } label: {
                        Label("Quick Pick", systemImage: "hand.draw").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(Capsule().fill(Palette.card)).overlay(Capsule().strokeBorder(Palette.rule)).foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(.plain).hoverLift(scale: 1.04, radius: 16).disabled(photos.isEmpty)
                    .help("Go through these one at a time: keep, favorite or skip")
                    SelectToggle(selecting: $selecting)
                }
                filterBar
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Palette.panel)
            Divider().overlay(Palette.rule)
            if !failed.isEmpty {
                Notice(symbol: "exclamationmark.triangle", text: "\(Format.count(failed.count, "file")) couldn’t be read or decoded, e.g. \(failed.prefix(3).map(\.filename).joined(separator: ", ")).",
                       actions: [("Copy List", { copyFailed() })])
                    .padding(.horizontal, 24).padding(.top, 12)
            }
            if !loaded {
                Spacer()
            } else if photos.isEmpty {
                EmptyState(symbol: "photo.stack", title: filter.isEmpty ? "No photos yet" : "Nothing matches these filters",
                           message: filter.isEmpty ? "Scan a card or folder to fill your library." : "Try clearing a filter.")
            } else {
                PhotoGrid(items: photos.map { ($0, TileInfo()) }, inspected: $model.inspectedPhotoID,
                          selecting: selecting, selected: selected, onToggleSelect: { selected.formSymmetricDifference([$0]) },
                          viewerTitle: "All Photos").padding(.top, 8)
            }
            if selecting {
                SelectionBar(selected: photos.filter { selected.contains($0.id) }, total: photos.count, title: "Selected photos",
                             selectAll: { selected = Set(photos.map(\.id)) }, selectNone: { selected = [] },
                             selectFavorites: !photos.contains { model.favorites.contains($0.id) } ? nil : {
                                 selected = Set(photos.map(\.id)).intersection(model.favorites)
                             },
                             done: { selecting = false; selected = [] })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Palette.canvas)
        .task(id: "\(model.stats.scanned)-\(model.stats.faces)") {
            // Off the main thread, so the page can slide in while 2,000 photos are read.
            let store = model.store, chosen = filter
            let (c, l, f, p) = await Task.detached(priority: .userInitiated) {
                ((try? store.distinctValues("camera")) ?? [], (try? store.distinctValues("lens")) ?? [],
                 (try? store.failedPhotos()) ?? [], (try? store.photos(filter: chosen)) ?? [])
            }.value
            cameras = c; lenses = l; failed = f
            if filter == chosen { photos = p }
            loaded = true
        }
        .onChange(of: filter) { reload() }
    }

    private func reload() { photos = (try? model.store.photos(filter: filter)) ?? [] }

    private var filterBar: some View {
        FilterBar(filter: $filter, cameras: cameras, lenses: lenses, imports: model.imports)
    }

    private func copyFailed() {
        let text = failed.map { "\($0.relPath)\t\($0.scanError ?? "")" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
