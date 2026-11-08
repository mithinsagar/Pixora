import SwiftUI
import PixoraCore

struct FindScreen: View {
    @Environment(PhoneModel.self) private var model
    @State private var query = ""
    @State private var selecting = false
    @State private var selection: Set<Int64> = []
    @State private var studio = false
    @State private var adding = false

    private var filteredPeople: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.namedPeople }
        return model.namedPeople.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }
    private var resultPhotos: [Photo] { model.results.map(\.photo) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.namedPeople.isEmpty {
                        noPeople
                    } else {
                        Subtitle(text: model.querySentence)
                            .padding(.horizontal, 16)
                            .accessibilityAddTraits(.updatesFrequently)
                        peopleStrip
                        if model.selectedPeople.count >= 2 { modePicker.padding(.horizontal, 16) }
                        if !model.selectedPeople.isEmpty { filters }
                        results
                    }
                }
                .padding(.vertical, 8)
                .animation(Motion.spring, value: model.selectedPeople)
            }
            .canvas()
            .navigationTitle("Find Photos")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.selectedPeople.isEmpty {
                        Button("Clear") { model.selectedPeople = []; selecting = false; selection = [] }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.results.isEmpty {
                        Button(selecting ? "Done" : "Select") { selecting.toggle(); selection = [] }
                            .accessibilityIdentifier("find.select")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    SelectionBar(photos: resultPhotos.filter { selection.contains($0.id) }, total: resultPhotos.count,
                                 onSelectAll: { selection = Set(resultPhotos.map(\.id)) },
                                 onSlideshow: { studio = true }, onDone: { selecting = false; selection = [] })
                }
            }
            .sheet(isPresented: $studio) {
                SlideshowStudio(source: .library, chosen: selecting ? resultPhotos.filter { selection.contains($0.id) } : [])
            }
            .sheet(isPresented: $adding, onDismiss: model.runAfterAddPhotos) { AddPhotosSheet() }
        }
    }

    // MARK: People

    private var peopleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(orderedPeople) { p in
                    PersonBubble(person: p, selected: model.selectedPeople.contains(p.id)) { model.toggle(p.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People")
    }

    /// Selected people first, in the order they were picked, so they're always in reach.
    private var orderedPeople: [Person] {
        let picked = model.selectedPeople.compactMap { id in filteredPeople.first { $0.id == id } }
        return picked + filteredPeople.filter { !model.selectedPeople.contains($0.id) }
    }

    private var modePicker: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Show photos with", selection: $model.matchMode) {
                Text("All of them").tag(MatchMode.all)
                Text("Any of them").tag(MatchMode.any)
                Text("Only them").tag(MatchMode.only)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("find.mode")
            Text(modeExplanation).font(.footnote).foregroundStyle(Palette.ink2)
        }
        .selectionHaptic(model.matchMode)
    }

    private var modeExplanation: String {
        switch model.matchMode {
        case .all: "Every selected person is in the photo."
        case .any: "At least one selected person is in the photo."
        case .only: "Just the selected people, nobody else."
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: model.includeUncertain ? "Including unsure matches" : "Unsure matches" + (model.uncertainExtra > 0 ? " (+\(model.uncertainExtra))" : ""),
                     symbol: "questionmark.circle", on: model.includeUncertain) { model.includeUncertain.toggle() }
                if !model.results.isEmpty {
                    Chip(title: "Slideshow", symbol: "play.rectangle", on: false) { studio = true }
                        .accessibilityIdentifier("find.slideshow")
                    Chip(title: "Save or Share", symbol: "square.and.arrow.up", on: false) { model.exportPhotos = resultPhotos }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if model.selectedPeople.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap").foregroundStyle(Palette.safelight)
                Text("Tap one or more people. Pick two or more to choose between photos with all of them or any of them.")
                    .font(.subheadline).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .card()
            .padding(.horizontal, 16)
        } else if model.results.isEmpty && !model.isSearching {
            EmptyState(symbol: "person.2.slash", title: "No photos found",
                       message: model.uncertainExtra > 0
                       ? "There are \(model.uncertainExtra) unsure matches. Include them, or confirm them in Review."
                       : (model.matchMode == .all ? "Try “Any of them”, or check Review for faces Pixora wasn’t sure about." : "Check Review for faces Pixora wasn’t sure about."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    EdgeLabel(Format.count(model.results.count, "photo"))
                    if model.isSearching { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .padding(.horizontal, 16)
                grid(model.strongResults.map(\.photo))
                if !model.weakerResults.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Maybe weaker shots").font(.headline).foregroundStyle(Palette.ink)
                        Text("Eyes may be closed or slightly soft. A guess, so they’re kept, just shown apart.").font(.footnote).foregroundStyle(Palette.ink2)
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    grid(model.weakerResults.map(\.photo))
                }
            }
        }
    }

    private func grid(_ photos: [Photo]) -> some View {
        PhotoGrid(photos: photos, selection: selecting ? $selection : nil) { p in
            model.openViewer(resultPhotos, at: p.id, title: model.querySentence)
        }
    }

    private var noPeople: some View {
        EmptyState(symbol: model.stats.photos == 0 ? "photo.stack" : "person.crop.circle.badge.plus",
                   title: model.stats.photos == 0 ? "Find the people in your photos" : "Name someone to start",
                   message: model.stats.photos == 0
                   ? "Add photos from your library, Files, or a card reader. Pixora groups faces on this iPhone, offline, and never changes your originals."
                   : "Pixora found \(Format.count(model.unnamedGroups.count, "group")) of faces. Give someone a name in People, then find every photo they’re in.",
                   actionTitle: model.stats.photos == 0 ? "Add Photos" : "Go to People",
                   action: { if model.stats.photos == 0 { adding = true } else { model.tab = .people } })
            .padding(.top, 40)
    }
}

/// A person's face with their name. Selected people get an amber ring and a check.
struct PersonBubble: View {
    let person: Person
    let selected: Bool
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                FaceImage(faceID: person.coverFaceID, size: size)
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? Palette.safelight : .clear, lineWidth: 3))
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                                .symbolRenderingMode(.palette).foregroundStyle(Palette.onSafelight, Palette.safelight)
                                .background(Circle().fill(Palette.canvas).padding(2))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(selected ? 1.04 : 1)
                Text(person.displayName).font(.caption.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Palette.ink : Palette.ink2).lineLimit(1)
                    .frame(width: size + 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.spring, value: selected)
        .selectionHaptic(selected)
        .accessibilityLabel("\(person.displayName), \(Format.count(person.photoCount, "photo"))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("person.\(person.displayName)")
    }
}

/// Actions for picked photos, in thumb reach at the bottom of the screen.
struct SelectionBar: View {
    @Environment(PhoneModel.self) private var model
    let photos: [Photo]
    let total: Int
    var onSelectAll: (() -> Void)? = nil
    var onSlideshow: (() -> Void)? = nil
    let onDone: () -> Void
    @State private var askSetup = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(photos.isEmpty ? "Tap photos to select" : "\(photos.count) of \(total) selected")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if let onSelectAll, photos.count < total { Button("Select All", action: onSelectAll).font(.subheadline.weight(.semibold)) }
            }
            HStack(spacing: 0) {
                action("square.and.arrow.down", "Save") { model.exportPhotos = photos }
                action("square.and.arrow.up", "Share") { model.share = ShareRequest(photos: photos) }
                action(photos.allSatisfy { model.favorites.contains($0.id) } && !photos.isEmpty ? "heart.slash" : "heart", "Favourite") { model.toggleFavorite(photos) }
                if let onSlideshow { action("play.rectangle", "Slideshow", onSlideshow) }
                action("lock", "Private") {
                    if model.isPrivateSetUp { model.makePrivate(photos: photos); onDone() } else { askSetup = true }
                }
            }
            .disabled(photos.isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.bar)
        .alert("Set up Private Space first", isPresented: $askSetup) {
            Button("Set Up") { model.tab = .privateSpace }
            Button("Not Now", role: .cancel) {}
        } message: { Text("Private Space keeps photos hidden behind a password made just for Pixora.") }
    }

    private func action(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(photos.isEmpty ? Palette.ink2.opacity(0.5) : Palette.safelight)
    }
}
