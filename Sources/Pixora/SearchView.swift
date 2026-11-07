import SwiftUI
import PixoraCore

/// Search by what's in a photo: "cat", "sunset", "asha birthday cake". Words that name someone narrow it to their photos.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var best: [Photo] = []
    @State private var maybe: [Photo] = []
    @State private var searched = ""
    @State private var isSearching = false
    @State private var failed = false
    @State private var selecting = false
    @State private var selected: Set<Int64> = []
    @FocusState private var focused: Bool

    private var sight: SightCenter { model.sight }
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var photos: [Photo] { best + maybe }
    private var bestIDs: Set<Int64> { Set(best.map(\.id)) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    SectionHeader(title: "Search", subtitle: subtitle)
                    Spacer()
                    if !photos.isEmpty { SelectToggle(selecting: $selecting) }
                }
                field
                if sight.isReady && (sight.isScanning || sight.pending > 0) && sight.done > 0 { DeepScanBar() }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            .background(Palette.panel)
            Divider().overlay(Palette.rule)
            content
            if selecting {
                SelectionBar(selected: photos.filter { selected.contains($0.id) }, total: photos.count, title: query.isEmpty ? "Photos" : query,
                             selectAll: { selected = Set(photos.map(\.id)) }, selectNone: { selected = [] },
                             selectFavorites: !photos.contains { model.favorites.contains($0.id) } ? nil : {
                                 selected = Set(photos.map(\.id)).intersection(model.favorites)
                             },
                             done: { selecting = false; selected = [] })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Palette.canvas)
        .onAppear { focused = true; sight.refreshCounts(); sight.prepare() }
        .onDisappear { sight.release() }
        .task(id: "\(query)|\(sight.isReady)|\(sight.done / 50)") { await search() }
    }

    private var subtitle: String {
        if !sight.isReady { return "Find photos by what's in them, on this Mac." }
        if sight.pending > 0 { return "\(sight.done.formatted()) of \(Format.count(sight.total, "photo")) can be searched." }
        return "All \(Format.count(sight.total, "photo")) can be searched. Add a name to narrow it down."
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.ink2)
            TextField("A cat, a sunset, people dancing on a stage", text: $model.searchText)
                .textFieldStyle(.plain).font(.system(size: 17)).focused($focused).disabled(!sight.isReady)
            if isSearching { ProgressView().controlSize(.small) }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.ink2) }
                    .buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Palette.safelight.opacity(0.7) : Palette.rule))
    }

    @ViewBuilder private var content: some View {
        if !sight.isReady {
            ScrollView { SightSetupCard().padding(24).frame(maxWidth: 620) }.frame(maxWidth: .infinity)
        } else if sight.done == 0 {
            EmptyState(symbol: "sparkle.magnifyingglass", title: sight.isScanning ? "Deep scan starting" : "Deep scan your library first",
                       message: sight.isScanning ? "Photos become searchable as they're read." :
                        "Pixora needs to look through your photos once. It uses the saved previews, so no card is needed. About \(Format.duration(sight.estimate(photos: sight.total))).",
                       action: sight.isScanning ? nil : ("Start Deep Scan", { sight.requestScan() }))
        } else if query.isEmpty {
            suggestions
        } else if failed {
            EmptyState(symbol: "exclamationmark.triangle", title: "Search couldn't start", message: "The search model didn't load. Removing it in Settings and downloading it again should fix this.")
        } else if photos.isEmpty {
            if !isSearching && searched == query {
                EmptyState(symbol: "photo.on.rectangle.angled", title: "Nothing found for “\(query)”",
                           message: sight.pending > 0 ? "\(Format.count(sight.pending, "photo")) haven't been read yet, so it may still turn up." : "Try a simpler word, or describe it another way.")
            } else { Spacer() }
        } else {
            PhotoGrid(items: photos.map { ($0, TileInfo()) }, inspected: Bindable(model).inspectedPhotoID,
                      selecting: selecting, selected: selected, onToggleSelect: { selected.formSymmetricDifference([$0]) },
                      onOpen: { model.openViewer(photos, at: $0, title: query) }, viewerTitle: query, groupTitle: { photo in
                          if best.isEmpty { return "No clear match, but these are close" }
                          return bestIDs.contains(photo.id) ? "Best matches" : "Maybe"
                      })
                .padding(.top, 8)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try").font(.headline)
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { word in
                    Button { model.searchText = word } label: {
                        Text(word).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Palette.card)).overlay(Capsule().strokeBorder(Palette.rule))
                    }
                    .buttonStyle(.plain).hoverLift(scale: 1.04, radius: 14, cursor: true)
                }
            }
            Text("Plain words work best. Search runs entirely on this Mac, and Private Space photos are never included.")
                .font(.callout).foregroundStyle(Palette.ink2)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var examples: [String] {
        let name = model.namedPeople.first?.displayName.lowercased()
        return ["cat", "sunset", "birthday cake", "people dancing", "group photo"] + (name.map { ["\($0) smiling"] } ?? [])
    }

    private func search() async {
        let text = query
        guard sight.isReady, sight.done > 0, !text.isEmpty else { best = []; maybe = []; searched = ""; isSearching = false; return }
        try? await Task.sleep(for: .milliseconds(280))   // wait for a pause in the typing
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { if !Task.isCancelled { isSearching = false } }
        let (people, words) = SightQuery.split(text, people: model.namedPeople.map { ($0.id, $0.displayName) })
        do {
            let hits = words.isEmpty ? [] : try await sight.hits(for: words)
            guard !Task.isCancelled else { return }
            var allowed: Set<Int64>?
            var everyone: [Photo] = []
            if !people.isEmpty {
                everyone = try model.store.search(people: people, mode: .all, includeUncertain: false).map(\.photo)
                allowed = Set(everyone.map(\.id))
            }
            let kept = hits.filter { allowed?.contains($0.photoID) ?? true }.prefix(3000)
            let found = Dictionary(uniqueKeysWithValues: try model.store.photos(ids: kept.map(\.photoID)).map { ($0.id, $0) })
            best = kept.filter(\.isBest).compactMap { found[$0.photoID] }
            maybe = kept.filter { !$0.isBest }.compactMap { found[$0.photoID] }
            if words.isEmpty { best = everyone; maybe = [] }
            selected.formIntersection(Set(photos.map(\.id)))
            failed = false
        } catch { failed = true; best = []; maybe = [] }
        searched = text
    }
}

/// Download offer, its progress, and what went wrong. Shared by Search and Settings.
struct SightSetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sight = model.sight
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.safelight)
            Text("Search for anything in your photos").font(Typography.display(22))
            Text("Type “cat”, “parrot” or “a child playing with a dog” and Pixora finds them. This is an optional extra: a one-time download of \(Format.size(Sight.downloadBytes)). After that, search works offline, and your photos and searches stay on this Mac.")
                .font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            switch sight.modelState {
            case .downloading(let received):
                ProgressView(value: Double(received), total: Double(max(Sight.downloadBytes, 1))).tint(Palette.safelight)
                HStack {
                    EdgeLabel("\(Format.size(received)) of \(Format.size(Sight.downloadBytes))")
                    Spacer()
                    Button("Cancel") { sight.cancelDownload() }
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(Palette.safelight).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { sight.download() }.buttonStyle(PrimaryButtonStyle())
            default:
                Button("Download Search Model") { sight.download() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// How far the deep scan has got, with a way to stop and carry on.
struct DeepScanBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sight = model.sight
        HStack(spacing: 12) {
            ProgressView(value: Double(sight.done), total: Double(max(sight.total, 1))).tint(Palette.safelight)
            Text(sight.isScanning ? sight.secondsLeft.map { "about \(Format.duration($0)) left" } ?? "Deep scan running" : "\(Format.count(sight.pending, "photo")) not read yet")
                .font(.caption).foregroundStyle(Palette.ink2).fixedSize()
            Button(sight.isScanning ? "Pause" : "Deep Scan") { if sight.isScanning { sight.pauseScan() } else { sight.requestScan() } }
                .controlSize(.small)
        }
    }
}

/// Settings → Search.
struct SearchSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var askRemove = false
    @State private var modelBytes: Int64 = 0

    var body: some View {
        let sight = model.sight
        VStack(alignment: .leading, spacing: 22) {
            if sight.isReady {
                SettingsGroup(title: "Search model",
                              footnote: "Downloaded once and kept on this Mac. Photos and searches are never sent anywhere.") {
                    SettingRow(title: "Installed", detail: Format.size(modelBytes)) {
                        Button("Remove…", role: .destructive) { askRemove = true }
                    }
                }
                SettingsGroup(title: "Deep scan",
                              footnote: "Reads the saved previews, so it works with the card out. Private Space photos are never read.") {
                    SettingRow(title: "\(sight.done.formatted()) of \(Format.count(sight.total, "photo")) can be searched",
                               detail: sight.pending > 0 ? "The rest would take about \(Format.duration(sight.estimate(photos: sight.pending)))." : "Everything is up to date.") {
                        if sight.pending > 0 {
                            Button(sight.isScanning ? "Pause" : "Deep Scan Library") { if sight.isScanning { sight.pauseScan() } else { sight.requestScan() } }
                        }
                    }
                    if sight.isScanning { DeepScanBar() }
                }
            } else {
                SightSetupCard()
            }
        }
        .task(id: sight.isReady) { modelBytes = StorageInfo.size(of: Sight.directory) }
        .confirmationDialog("Remove the search model?", isPresented: $askRemove) {
            Button("Remove", role: .destructive) { sight.removeModel() }
        } message: { Text("This also clears what the deep scan learned. Your photos aren't touched.") }
    }
}
