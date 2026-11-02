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

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    SectionHeader(title: "All Photos", subtitle: "\(Format.count(photos.count, "photo")) shown · \(model.stats.scanned.formatted()) scanned in total")
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
            if photos.isEmpty {
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
                             done: { selecting = false; selected = [] })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Palette.canvas)
        .task(id: "\(model.stats.scanned)-\(model.stats.faces)") {
            cameras = (try? model.store.distinctValues("camera")) ?? []
            lenses = (try? model.store.distinctValues("lens")) ?? []
            failed = (try? model.store.failedPhotos()) ?? []
            reload()
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
