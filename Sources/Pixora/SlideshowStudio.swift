import SwiftUI
import UniformTypeIdentifiers
import PixoraCore

struct SlidePerson: Identifiable, Hashable { let id: Int64; let name: String }

/// Where a slideshow's photos come from.
enum StudioSource {
    /// The regular library (never contains private photos: they aren't in its tables).
    case library
    /// Private Space, already unlocked and decrypted. The slideshow stays private.
    case privateSpace([SlideCandidate], people: [SlidePerson])
    var isPrivate: Bool { if case .privateSpace = self { true } else { false } }
}

/// Colours for the studio: the app theme in the library, brass-on-night inside Private Space.
@MainActor private struct StudioColors {
    let accent, onAccent, ink, ink2, card, rule: Color
    init(_ isPrivate: Bool) {
        if isPrivate { accent = Vault.brass; onAccent = Vault.onBrass; ink = Vault.ink; ink2 = Vault.ink2; card = Vault.card; rule = Vault.rule }
        else { accent = Palette.safelight; onAccent = Palette.onSafelight; ink = Palette.ink; ink2 = Palette.ink2; card = Palette.card; rule = Palette.rule }
    }
}

/// Slideshow Studio: pick where photos come from and a style, check and edit the photos, choose timing,
/// transition and (opt-in) music, then play full screen.
struct SlideshowStudio: View {
    @Environment(AppModel.self) private var model
    let source: StudioSource
    var compact = false
    var onPlay: () -> Void = {}

    enum From: Hashable { case selection, person, chosen }
    @State private var from: From = .person
    @State private var personID: Int64?
    @State private var chosenIDs: [Int64] = []
    @State private var style: SlideStyle = .story
    @State private var candidates: [SlideCandidate] = []
    @State private var loading = false
    @State private var event: SlideEvent?
    @State private var customRange = false
    @State private var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var rangeEnd = Date()
    @State private var skipEyesClosed = true
    @State private var skipSoft = true
    @State private var removed: Set<Int64> = []
    @State private var order: [Int64]?          // set once the user drags to reorder
    @State private var shuffle = false
    @State private var showPicker = false
    @State private var musicOn = false          // never remembered: every slideshow starts muted
    @State private var musicFile: URL?
    @State private var listening = false
    @AppStorage("slideDuration") private var duration = 4.0
    @AppStorage("slideTransition") private var transitionRaw = SlideTransition.crossfade.rawValue
    @AppStorage("slideCaptions") private var showCaptions = true
    @AppStorage("slideVolume") private var volume = 0.35

    private var c: StudioColors { StudioColors(source.isPrivate) }
    private var people: [SlidePerson] {
        switch source {
        case .library: model.namedPeople.map { SlidePerson(id: $0.id, name: $0.displayName) }
        case .privateSpace(_, let p): p
        }
    }
    private var focusPeople: [Int64] {
        switch (source, from) {
        case (.library, .selection): model.selectedPeople
        case (_, .person): personID.map { [$0] } ?? []
        default: []
        }
    }
    private var events: [SlideEvent] { SlideshowPlanner.events(candidates.map(\.photo)) }
    private var eventInterval: DateInterval? {
        customRange ? DateInterval(start: min(rangeStart, rangeEnd), end: max(rangeStart, rangeEnd).addingTimeInterval(86_399)) : event?.interval
    }
    private func picked(_ s: SlideStyle) -> [SlideCandidate] {
        SlideshowPlanner.pick(s, from: candidates, people: focusPeople, event: s == .event ? eventInterval : nil,
                              skipEyesClosed: skipEyesClosed, skipSoft: skipSoft)
    }
    private var slides: [SlideCandidate] {
        let base = picked(style).filter { !removed.contains($0.id) }
        guard let order else { return base }
        let byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return order.compactMap { byID[$0] } + base.filter { !order.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sourceRow
            styleGrid
            if style == .event { eventRow }
            qualityRow
            previewStrip
            settingsRow
            playRow
        }
        .padding(compact ? 0 : 24)
        .task(id: sourceKey) { await loadCandidates() }
        .onChange(of: style) { removed = []; order = nil }
        .onDisappear { if listening { SlideshowMusic.shared.stop(); listening = false } }
        .sheet(isPresented: $showPicker) {
            PhotoChooser(photos: chooserPhotos, chosen: Set(chosenIDs), isPrivate: source.isPrivate) { ids in
                chosenIDs = ids; from = .chosen
            }
        }
    }

    private var sourceKey: String { "\(from)-\(personID ?? -1)-\(chosenIDs.count)-\(model.selectedPeople)-\(model.favorites.count)-\(model.people.count)" }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SLIDESHOW STUDIO").font(.system(size: 11, weight: .semibold)).tracking(2.2).foregroundStyle(c.accent)
                Text(source.isPrivate ? "A private slideshow" : "Turn your people into a slideshow").font(.system(size: compact ? 24 : 28, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Text(source.isPrivate ? "Only plays while Private Space is unlocked, and stops the moment it locks."
                                      : "Choose who, pick a style, check the photos, and play full screen.")
                    .font(.callout).foregroundStyle(c.ink2)
            }
            Spacer()
        }
    }

    @ViewBuilder private var sourceRow: some View {
        HStack(spacing: 10) {
            Text("From").font(.callout.weight(.semibold)).foregroundStyle(c.ink2)
            if case .library = source {
                chip("Selected people\(model.selectedPeople.isEmpty ? "" : " (\(model.selectedPeople.count))")", icon: "person.2", on: from == .selection) { from = .selection }
                    .disabled(model.selectedPeople.isEmpty)
                    .help(model.selectedPeople.isEmpty ? "Pick people at the top of Find Photos first" : "The people selected above")
            } else {
                chip("All private photos", icon: "lock", on: from == .selection) { from = .selection }
            }
            Menu {
                ForEach(people) { p in Button(p.name) { personID = p.id; from = .person } }
            } label: {
                Label(from == .person ? (people.first { $0.id == personID }?.name ?? "One person") : "One person", systemImage: "person.crop.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(from == .person ? c.accent.opacity(0.2) : c.card))
            .overlay(Capsule().strokeBorder(from == .person ? c.accent : c.rule))
            .disabled(people.isEmpty)
            chip(chosenIDs.isEmpty ? "Photos I choose…" : "\(chosenIDs.count) chosen photos", icon: "hand.tap", on: from == .chosen) {
                showPicker = true
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
    }

    private var styleGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(SlideStyle.allCases) { s in
                let n = picked(s).count
                Button { withAnimation(.easeOut(duration: 0.15)) { style = s } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: s.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(style == s ? c.onAccent : c.accent)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(style == s ? c.accent : c.accent.opacity(0.14)))
                            Spacer()
                            Text("\(n)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(n == 0 ? c.ink2.opacity(0.6) : c.ink)
                        }
                        Text(s.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                        Text(s.rule).font(.caption).foregroundStyle(c.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(style == s ? c.accent.opacity(0.1) : c.card))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style == s ? c.accent : c.rule, lineWidth: style == s ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .hoverLift(scale: 1.02, radius: 14)
                .accessibilityLabel("\(s.title), \(n) photos. \(s.rule)")
                .accessibilityAddTraits(style == s ? .isSelected : [])
            }
        }
    }

    private var eventRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty && !customRange {
                Text("Not enough dated photos here to suggest an event. Choose dates instead.").font(.callout).foregroundStyle(c.ink2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(events) { e in
                        chip("\(Self.range(e)) · \(e.count)", icon: "calendar", on: !customRange && event == e) { customRange = false; event = e }
                    }
                    chip("Choose dates", icon: "calendar.badge.plus", on: customRange) { customRange = true }
                }
            }
            if customRange {
                HStack {
                    DatePicker("From", selection: $rangeStart, displayedComponents: .date).fixedSize()
                    DatePicker("to", selection: $rangeEnd, displayedComponents: .date).fixedSize()
                }.font(.callout)
            }
        }
        .onAppear { if event == nil { event = events.first } }
    }

    private var qualityRow: some View {
        HStack(spacing: 16) {
            Toggle("Leave out photos where eyes may be closed", isOn: $skipEyesClosed)
            Toggle("Leave out soft-focus photos", isOn: $skipSoft)
            Spacer()
        }
        .toggleStyle(.checkbox).font(.callout).foregroundStyle(c.ink)
        .help("Pixora’s eye and focus checks are guesses. Check the preview and add back anything you like.")
    }

    private var previewStrip: some View {
        let list = slides
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline).foregroundStyle(c.ink)
                Text(list.isEmpty ? "no photos" : "\(Format.count(list.count, "photo")) · about \(Self.minutes(Double(list.count) * duration))")
                    .font(.callout).foregroundStyle(c.ink2)
                if shuffle { Label("shuffled when it plays", systemImage: "shuffle").font(.caption).foregroundStyle(c.ink2) }
                Spacer()
                if !removed.isEmpty || order != nil {
                    Button("Reset") { removed = []; order = nil }.controlSize(.small)
                }
                if !removed.isEmpty {
                    Menu("Add back (\(removed.count))") {
                        ForEach(picked(style).filter { removed.contains($0.id) }) { r in Button(r.photo.filename) { removed.remove(r.id) } }
                    }.fixedSize().controlSize(.small)
                }
            }
            if list.isEmpty {
                Text(emptyHint).font(.callout).foregroundStyle(c.ink2)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(c.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, cand in
                            StudioThumb(photo: cand.photo, number: i + 1, accent: c.accent, flagged: cand.eyesClosed || cand.soft) {
                                removed.insert(cand.id)
                            }
                            .draggable(String(cand.id))
                            .dropDestination(for: String.self) { items, _ in
                                guard let moved = items.first.flatMap(Int64.init) else { return false }
                                var ids = list.map(\.id)
                                guard let from = ids.firstIndex(of: moved), let to = ids.firstIndex(of: cand.id), from != to else { return false }
                                ids.remove(at: from); ids.insert(moved, at: to)
                                withAnimation(.snappy) { order = ids }
                                return true
                            }
                        }
                    }.padding(.vertical, 6).padding(.horizontal, 2)
                }
                .frame(height: 112)
                Text("Drag to reorder. Hover a photo and press × to leave it out.").font(.caption).foregroundStyle(c.ink2)
            }
        }
    }

    private var settingsRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                Text("Each photo").foregroundStyle(c.ink2)
                HStack {
                    Slider(value: $duration, in: 2...12, step: 1).frame(width: 200)
                    Text("\(Int(duration)) s").monospacedDigit().foregroundStyle(c.ink).frame(width: 40, alignment: .leading)
                }
                Text("Transition").foregroundStyle(c.ink2)
                Picker("", selection: $transitionRaw) {
                    ForEach(SlideTransition.allCases) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            GridRow {
                Text("Order").foregroundStyle(c.ink2)
                HStack(spacing: 16) {
                    Toggle("Shuffle", isOn: $shuffle)
                    Toggle("Show dates and names", isOn: $showCaptions)
                }.toggleStyle(.checkbox)
                Text("Music").foregroundStyle(c.ink2)
                HStack(spacing: 10) {
                    Toggle("Background music", isOn: $musicOn).toggleStyle(.switch).controlSize(.small)
                        .onChange(of: musicOn) { _, on in if !on && listening { SlideshowMusic.shared.stop(); listening = false } }
                    Menu(musicFile?.deletingPathExtension().lastPathComponent ?? "Soft tones (made by Pixora)") {
                        Button("Soft tones (made by Pixora)") { musicFile = nil }
                        Button("Choose an audio file…") { chooseMusic() }
                    }.fixedSize().disabled(!musicOn)
                    Image(systemName: "speaker.fill").foregroundStyle(c.ink2)
                    Slider(value: $volume, in: 0...1).frame(width: 110).disabled(!musicOn)
                        .onChange(of: volume) { _, v in SlideshowMusic.shared.setVolume(Float(v)) }
                        .accessibilityLabel("Music volume")
                    Button(listening ? "Stop" : "Listen") { toggleListen() }.controlSize(.small).disabled(!musicOn)
                }
            }
        }
        .font(.callout)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.rule))
    }

    private var playRow: some View {
        HStack {
            Text(musicOn ? "Music plays only while the slideshow does." : "Music is off — slideshows start silent.")
                .font(.caption).foregroundStyle(c.ink2)
            Spacer()
            Button { play() } label: { Label("Play Slideshow", systemImage: "play.fill").padding(.horizontal, 8) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(slides.isEmpty)
                .help("Full screen · Space pauses · ← → step · Esc exits")
        }
    }

    // MARK: Helpers

    private func chip(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? c.accent.opacity(0.2) : c.card))
                .overlay(Capsule().strokeBorder(on ? c.accent : c.rule))
                .foregroundStyle(c.ink)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var emptyHint: String {
        if candidates.isEmpty {
            switch from {
            case .selection: return source.isPrivate ? "Private Space has no photos yet." : "Pick people at the top of Find Photos, or choose one person here."
            case .person: return personID == nil ? "Choose a person to start." : "No certain matches for this person yet."
            case .chosen: return "Choose some photos."
            }
        }
        switch style {
        case .favorites: return "None of these photos is a favourite yet. Mark photos with ♥ in the viewer or their menu."
        case .together: return "No photo has everyone you picked in it."
        case .event: return "No photos in that date range."
        default: return "No photos fit this style. Try another style or turn off the quality filters."
        }
    }

    private var chooserPhotos: [Photo] {
        switch source {
        case .library: (try? model.store.photos()) ?? []
        case .privateSpace(let cands, _): cands.map(\.photo)
        }
    }

    private func loadCandidates() async {
        if case .privateSpace(let cands, _) = source {
            switch from {
            case .selection: candidates = cands
            case .person: candidates = personID.map { pid in cands.filter { $0.faces.contains { $0.personID == pid && $0.certain } } } ?? []
            case .chosen: candidates = cands.filter { chosenIDs.contains($0.id) }
            }
            if from == .selection || personID == nil { if from == .person, personID == nil { personID = people.first?.id } }
            return
        }
        if from == .selection && model.selectedPeople.isEmpty { from = .person }
        if from == .person && personID == nil { personID = model.mePersonID ?? model.namedPeople.first?.id }
        loading = true
        defer { loading = false }
        let store = model.store, favorites = model.favorites
        let from = from, pid = personID, selection = model.selectedPeople, chosen = chosenIDs
        candidates = await Task.detached(priority: .userInitiated) { () -> [SlideCandidate] in
            var results: [SearchResult] = []
            var photos: [Photo] = []
            switch from {
            case .selection: results = (try? store.search(people: selection, mode: .any, includeUncertain: false)) ?? []
            case .person: if let pid { results = (try? store.search(people: [pid], mode: .all, includeUncertain: false)) ?? [] }
            case .chosen: photos = (try? store.photos(ids: chosen)) ?? []
            }
            if !results.isEmpty { photos = results.map(\.photo) }
            let flags = Dictionary(results.map { ($0.photo.id, ($0.eyesClosed, $0.soft)) }, uniquingKeysWith: { a, _ in a })
            let faces = (try? store.slideFaces(photoIDs: photos.map(\.id))) ?? [:]
            return photos.map { p in
                SlideCandidate(photo: p, faces: faces[p.id] ?? [], eyesClosed: flags[p.id]?.0 ?? false, soft: flags[p.id]?.1 ?? false,
                               favorite: favorites.contains(p.id))
            }
        }.value
        if chosen.isEmpty == false && from == .chosen { order = chosen }
        event = SlideshowPlanner.events(candidates.map(\.photo)).first
    }

    private func caption(for cand: SlideCandidate) -> String {
        var parts: [String] = []
        if let d = cand.photo.takenAt { parts.append(d.formatted(date: .long, time: .omitted)) }
        let names: [String] = Array(Set(cand.faces.filter(\.certain).compactMap(\.personID))).compactMap { id in
            switch source {
            case .library: return model.person(id).flatMap { $0.isNamed ? $0.displayName : nil }
            case .privateSpace(_, let ppl): return ppl.first { $0.id == id }?.name
            }
        }.sorted()
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func play() {
        if listening { SlideshowMusic.shared.stop(); listening = false }
        var list = slides
        if shuffle { list.shuffle() }
        guard !list.isEmpty else { return }
        if source.isPrivate && !model.isPrivateUnlocked { return }
        let title: String = {
            switch from {
            case .selection: return source.isPrivate ? "Private Space" : model.querySentence
            case .person: return people.first { $0.id == personID }?.name ?? style.title
            case .chosen: return "Chosen photos"
            }
        }() + " · " + style.title
        model.slideshow = SlideshowRequest(
            title: title, slides: list.map(\.photo),
            captions: Dictionary(uniqueKeysWithValues: list.map { ($0.id, caption(for: $0)) }),
            duration: duration, transition: SlideTransition(rawValue: transitionRaw) ?? .crossfade, showCaptions: showCaptions,
            music: musicOn ? (musicFile.map(MusicChoice.file) ?? .ambient) : nil, volume: Float(volume),
            isPrivate: source.isPrivate)
        onPlay()
    }

    private func toggleListen() {
        if listening { SlideshowMusic.shared.stop(); listening = false }
        else { SlideshowMusic.shared.start(musicFile.map(MusicChoice.file) ?? .ambient, volume: Float(volume)); listening = true }
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose music you have the rights to use."
        if panel.runModal() == .OK, let url = panel.url { musicFile = url }
    }

    static func range(_ e: SlideEvent) -> String {
        let f = DateIntervalFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: e.start, to: e.end)
    }

    static func minutes(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }
}

/// The studio in a sheet (from results in Find Photos, or inside Private Space).
struct SlideshowStudioSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: StudioSource
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { SlideshowStudio(source: source) { dismiss() }.padding(.top, 8) }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(14)
        }
        .frame(width: 900, height: 760)
        .background(source.isPrivate ? AnyView(VaultBackdrop()) : AnyView(Palette.canvas))
        .modifier(DarkIf(source.isPrivate))
    }
}

private struct StudioThumb: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let number: Int
    let accent: Color
    let flagged: Bool
    let remove: () -> Void
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack { Color.gray.opacity(0.2); if let image { Image(nsImage: image).resizable().scaledToFill() } }
                .frame(width: 132, height: 96).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("\(number)").font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white).padding(5)
            if hover {
                HStack {
                    Spacer()
                    Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, .black.opacity(0.6)) }
                        .buttonStyle(.plain).padding(4).accessibilityLabel("Leave out photo \(number)")
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hover ? accent : .clear, lineWidth: 2))
        .onHover { hover = $0 }
        .help(photo.filename + (flagged ? " — Pixora flagged this one (eyes or focus); your call" : ""))
        .task(id: photo.id) { image = await ImageCache.shared.photoThumb(photo, sourceRoot: model.source(photo.sourceID)?.url) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Slide \(number), \(photo.filename)")
        .accessibilityAction(named: "Leave out", remove)
    }
}

/// Pick photos by hand for a slideshow.
private struct PhotoChooser: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]
    @State var chosen: Set<Int64>
    let isPrivate: Bool
    let done: ([Int64]) -> Void
    @State private var inspected: Int64?

    init(photos: [Photo], chosen: Set<Int64>, isPrivate: Bool, done: @escaping ([Int64]) -> Void) {
        self.photos = photos; self._chosen = State(initialValue: chosen); self.isPrivate = isPrivate; self.done = done
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose photos for the slideshow").font(Typography.display(20))
                Spacer()
                Text("\(chosen.count) chosen").foregroundStyle(Palette.ink2)
                Button("None") { chosen = [] }
            }.padding(16)
            Divider()
            PhotoGrid(items: photos.map { ($0, TileInfo()) }, inspected: $inspected, selecting: true, selected: chosen,
                      onToggleSelect: { chosen.formSymmetricDifference([$0]) }, viewerTitle: "Choose photos")
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use \(chosen.count) Photos") {
                    done(photos.map(\.id).filter(chosen.contains)); dismiss()
                }.buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .frame(width: 960, height: 700)
        .background(isPrivate ? AnyView(Vault.night) : AnyView(Palette.canvas))
    }
}

private struct DarkIf: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on { content.environment(\.colorScheme, .dark) } else { content }
    }
}
