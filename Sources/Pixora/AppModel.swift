import SwiftUI
import AppKit
import PixoraCore

enum SidebarItem: Hashable {
    case find, search, review, people, allPhotos, places, insights, importer, settings, privateSpace

    /// Top to bottom, as the sidebar lists them.
    var order: Int { [.find, .search, .review, .people, .allPhotos, .places, .insights, .privateSpace, .importer, .settings].firstIndex(of: self) ?? 0 }
}

/// Find results arranged for display: strong shots first, weaker ones (eyes closed, soft, extra burst frames)
/// kept in a separate section, never removed.
struct ResultsPresentation {
    var strong: [SearchResult] = []
    var weaker: [SearchResult] = []
    /// burst id → all frames of that burst present in the results (best first).
    var bursts: [Int64: [SearchResult]] = [:]
    /// Photo ids marked ★ Best (top fifth by shot quality, when there are enough results).
    var best: Set<Int64> = []
    func reason(_ r: SearchResult, stacked: Bool) -> String? {
        var parts: [String] = []
        if r.eyesClosed { parts.append("eyes may be closed") }
        if r.soft { parts.append("soft focus") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct CardPrompt: Identifiable, Equatable {
    var id: String { volume.id }
    let volume: VolumeInfo
    let source: Source?
    let newPhotos: Int
}

@MainActor @Observable
final class AppModel {
    let store: LibraryStore
    @ObservationIgnored lazy var sight = SightCenter(store: store)
    var searchText = ""
    let vault: PrivateVault
    /// Decrypted Private Space content while unlocked; nil when locked.
    var privateContent: PrivateVault.Content?
    /// Changes on each successful unlock (drives the reveal animation).
    var privateRevealID: UUID?
    /// Bumped when Private Space is created or erased, so views re-read the (non-observable) vault.
    var vaultEpoch = 0
    @ObservationIgnored var vaultSetUpCache: (epoch: Int, isSetUp: Bool)?
    /// Private Space was just created and setup is showing its second step (keep a copy of the password).
    var privateSetupInProgress = false
    /// Show the delete-and-recreate sheet (forgotten password), from anywhere.
    var showDeletePrivateSpace = false
    /// Photos marked with ♥ (library photos only).
    var favorites: Set<Int64> = []
    /// The slideshow playing full screen, if any.
    var slideshow: SlideshowRequest?
    @ObservationIgnored var idleTimer: Timer?
    private(set) var embedder: FaceEmbedder
    var strictness: Double {
        didSet { UserDefaults.standard.set(strictness, forKey: "strictness"); scheduleRematch() }
    }
    var thresholds: MatchThresholds { embedder.thresholds.adjusted(by: Float(strictness)) }
    var isBasicMode: Bool { embedder is VisionFeaturePrintEmbedder }

    var section: SidebarItem = .find {
        didSet {
            if section != oldValue { sectionStep = section.order >= oldValue.order ? 1 : -1 }
            if oldValue == .privateSpace && section != .privateSpace && UserDefaults.standard.object(forKey: "lockOnLeave") as? Bool ?? true { lockPrivateSpace() }
        }
    }
    /// Which way the last page change went down the sidebar (1) or up it (-1), so the new page arrives from that side.
    @ObservationIgnored var sectionStep: CGFloat = 1
    var people: [Person] = []
    var sources: [Source] = []
    var volumes: [VolumeInfo] = []
    var imports: [ImportRecord] = []
    var stats = LibraryStats()
    var errorMessage: String?
    var isMatching = false

    // Find
    var selectedPeople: [Int64] = [] { didSet { runSearch() } }
    var matchMode: MatchMode = .all { didSet { runSearch() } }
    var includeUncertain = UserDefaults.standard.bool(forKey: "defaultIncludeUncertain") { didSet { runSearch() } }
    var filter = PhotoFilter() { didSet { runSearch() } }
    var results: [SearchResult] = []
    var presentation = ResultsPresentation()
    /// Extra photos that would appear if uncertain matches were included.
    var uncertainExtra = 0
    /// Photos left out of export. Weaker shots start out excluded; the user can include or exclude anything.
    var excludedFromExport: Set<Int64> = []
    private var userIncluded: Set<Int64> = []
    private var userExcluded: Set<Int64> = []
    /// Opt-in: show every frame unless the user chooses to stack bursts.
    var stackBursts = UserDefaults.standard.bool(forKey: "stackBurstsOptIn") {
        didSet { UserDefaults.standard.set(stackBursts, forKey: "stackBurstsOptIn"); arrange() }
    }
    var separateWeaker = UserDefaults.standard.object(forKey: "separateWeaker") as? Bool ?? true {
        didSet { UserDefaults.standard.set(separateWeaker, forKey: "separateWeaker"); arrange() }
    }
    var sortBestFirst = false { didSet { arrange() } }
    var bestOnly = false { didSet { arrange() } }
    var expandedBursts: Set<Int64> = [] { didSet { arrange() } }

    /// The person who is "me" (for ⌘K "me + asha" and the Me badge).
    var mePersonID: Int64? = (UserDefaults.standard.object(forKey: "mePersonID") as? NSNumber)?.int64Value {
        didSet { UserDefaults.standard.set(mePersonID.map { NSNumber(value: $0) }, forKey: "mePersonID") }
    }
    var showCommandBar = false
    var viewer: ViewerState?
    var quickPick: QuickPickRequest?
    var faceTime: FaceTimeRequest?
    /// A full-window photo screen is showing.
    var isImmersive: Bool { viewer != nil || quickPick != nil || faceTime != nil }
    /// The window's undo manager (set by ContentView), so ⌘Z / ⇧⌘Z undo and redo corrections.
    weak var undoManager: UndoManager?
    var toast: Toast?
    var recapRequest: RecapRequest?
    var showForgotForTesting = false
    /// Find: Select mode — clicking photos picks them instead of opening details.
    var findSelecting = false {
        didSet {
            guard findSelecting != oldValue else { return }
            if findSelecting { setExportAll(false) } else { clearSearchChoices(); arrange() }   // start empty; restore defaults after
        }
    }
    var cardPrompt: CardPrompt?
    var exportEveryone: ExportEveryoneRequest?
    var inspectedPhotoID: Int64?
    var showInspector = false

    // Import / export
    var scan: ScanSession?
    var exportRequest: ExportRequest?
    var openPersonID: Int64?

    init() {
        do { store = try LibraryStore.openDefault() } catch {
            fatalError("Pixora could not open its library at \(AppPaths.database.path): \(error)")
        }
        vault = PrivateVault(store: store)
        embedder = Embedders.makeDefault()
        strictness = UserDefaults.standard.double(forKey: "strictness")
        refreshAll()
        observeVolumes()
        startPrivateSpaceGuards()
        applyTestingHooks()
        // Libraries scanned before shot-quality analysis existed get it once, quietly, in the background.
        let store = store
        Task { [weak self] in
            await Task.detached(priority: .utility) { try? Enrichment.run(store: store) }.value
            self?.runSearch()
        }
    }

    /// Testing/screenshot hooks, read only from environment variables set by the developer:
    /// PIXORA_SELECT="Name A,Name B"  PIXORA_SECTION=find|review|people|all|import  PIXORA_INSPECT=1  PIXORA_PREVIEW=/path
    private func applyTestingHooks() {
        let env = ProcessInfo.processInfo.environment
        if let names = env["PIXORA_SELECT"] {
            selectedPeople = names.split(separator: ",").compactMap { n in namedPeople.first { $0.displayName == n.trimmingCharacters(in: .whitespaces) }?.id }
        }
        switch env["PIXORA_SECTION"] {
        case "review": section = .review
        case "people": section = .people
        case "all": section = .allPhotos
        case "import": section = .importer
        case "settings": section = .settings
        case "search": section = .search; searchText = env["PIXORA_SEARCH"] ?? ""
        case "places": section = .places
        case "private": section = .privateSpace
        default: break
        }
        if env["PIXORA_MODE"] == "any" { matchMode = .any }
        if let t = env["PIXORA_THEME"] { ThemeManager.shared.showWithoutSaving(t) }
        if env["PIXORA_MODE"] == "only" { matchMode = .only }
        if env["PIXORA_SECTION"] == "insights" { section = .insights }
        switch env["PIXORA_SHEET"] {
        case "everyone": exportEveryone = ExportEveryoneRequest(preselected: [])
        case "command": showCommandBar = true
        case "export": requestExport()
        case "forgot": showForgotForTesting = true
        case "studio": section = .find; selectedPeople = []
        case "recap": recapRequest = RecapRequest(title: "Serena & Tony", photos: visibleResults.map(\.photo))
        default: break
        }
        if let path = env["PIXORA_PREVIEW"] { startPreview(URL(fileURLWithPath: path, isDirectory: true)) }
        if env["PIXORA_INSPECT"] != nil, let first = results.first { inspectedPhotoID = first.id; showInspector = true }
        #if PIXORA_UI_TESTING
        // Testing build only — never compiled into the real app.
        if env["PIXORA_TEST_CLEANUP"] != nil { try? vault.destroy(); Keychain.app.deleteAll() }
        if let pw = env["PIXORA_TEST_SETUP"], !vault.isSetUp {
            try? vault.setUp(password: pw, iterations: VaultCrypto.defaultIterations)
            if let name = env["PIXORA_TEST_PRIVATE_PERSON"], let p = namedPeople.first(where: { $0.displayName == name }) { makePrivate(personID: p.id) }
            vault.lockNow(); privateContent = nil
        }
        if let pw = env["PIXORA_TEST_UNLOCK"] { Task { try? await unlockPrivateSpace(password: pw) } }
        #endif
        if let name = env["PIXORA_PERSON"], let p = namedPeople.first(where: { $0.displayName == name }) { section = .people; openPersonID = p.id }
        if env["PIXORA_VIEWER"] != nil, let first = visibleResults.first { openViewer(visibleResults.map(\.photo), at: first.id, title: querySentence) }
        #if PIXORA_UI_TESTING
        if let n = env["PIXORA_TEST_FAVORITES"].flatMap(Int.init) {
            toggleFavorite(results.prefix(n).map(\.photo))
            selectFavorites()
            requestExport()
            fputs("favorites selected: \(exportablePhotos.count), export request: \(exportRequest?.results.count ?? -1), of \(results.count)\n", stderr)
            exportRequest = nil
        }
        #endif
        if env["PIXORA_SELECTING"] != nil {
            findSelecting = true
            for r in visibleResults.prefix(3) { toggleExport(r.id) }
        }
        #if PIXORA_UI_TESTING
        switch env["PIXORA_TEST_OPEN"] {
        case "scan": if let source = sources.first { rescan(source) }
        case "quickpick": quickPick = QuickPickRequest(title: querySentence, photos: visibleResults.map(\.photo))
        case "facetime":
            if let id = selectedPeople.first, let p = person(id) { faceTime = FaceTimeRequest(personID: id, name: p.displayName) }
        default: break
        }
        if let script = env["PIXORA_TEST_SCRIPT"] { Rehearsal.run(script, model: self) }
        #endif
    }

    // MARK: Refresh

    func refreshAll() {
        do {
            sources = try store.reconnectSources()
            people = try store.people()
            imports = try store.imports()
            stats = try store.stats(currentEmbedder: embedder.id)
            favorites = try store.favoriteIDs()
        } catch { errorMessage = "\(error)" }
        volumes = VolumeInfo.mountedVolumes()
        selectedPeople.removeAll { id in !people.contains { $0.id == id } }
        runSearch()
    }

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    self?.refreshAll()
                    if name == NSWorkspace.didMountNotification, let url { self?.checkInsertedCard(url) }
                    if name == NSWorkspace.didUnmountNotification, self?.cardPrompt?.volume.url.path == url?.path { self?.cardPrompt = nil }
                }
            }
        }
    }

    func person(_ id: Int64?) -> Person? {
        if let p = people.first(where: { $0.id == id }) { return p }
        // Private people are only known while Private Space is unlocked.
        guard let id, let pp = privateContent?.people.first(where: { $0.id == id }) else { return nil }
        return Person(id: pp.id, name: pp.name, coverFaceID: nil, photoCount: 0, faceCount: 0, uncertainCount: 0, lastSeen: nil,
                      contactID: pp.contactID, contactHandles: pp.handles)
    }
    func source(_ id: Int64) -> Source? { sources.first { $0.id == id } }
    var namedPeople: [Person] { people.filter(\.isNamed) }
    var unnamedGroups: [Person] { people.filter { !$0.isNamed } }

    // MARK: Find

    func toggle(_ personID: Int64) {
        if let i = selectedPeople.firstIndex(of: personID) { selectedPeople.remove(at: i) } else { selectedPeople.append(personID) }
    }

    func runSearch() {
        guard !selectedPeople.isEmpty else { results = []; uncertainExtra = 0; return }
        do {
            results = try store.search(people: selectedPeople, mode: matchMode, includeUncertain: includeUncertain, filter: filter)
            if includeUncertain {
                let certain = try store.search(people: selectedPeople, mode: matchMode, includeUncertain: false, filter: filter).count
                uncertainExtra = results.count - certain
            } else {
                uncertainExtra = try store.search(people: selectedPeople, mode: matchMode, includeUncertain: true, filter: filter).count - results.count
            }
        } catch { errorMessage = "\(error)" }
        arrange()
        if let id = inspectedPhotoID, !results.contains(where: { $0.id == id }), section == .find { inspectedPhotoID = nil }
    }

    func clearSearchChoices() { userIncluded = []; userExcluded = []; expandedBursts = [] }

    /// Split results into strong / weaker, stack bursts, mark the best, and set export defaults.
    func arrange() {
        var p = ResultsPresentation()
        for r in results { if let b = r.burstID { p.bursts[b, default: []].append(r) } }
        for (b, frames) in p.bursts { p.bursts[b] = frames.sorted { $0.score > $1.score } }
        if results.count >= 5 {
            let cut = results.map(\.score).sorted(by: >)[max(0, results.count / 5 - 1)]
            p.best = Set(results.filter { $0.score >= cut && !$0.eyesClosed && !$0.soft }.map(\.id))
        }
        var strong: [SearchResult] = [], weaker: [SearchResult] = []
        for r in results {
            let isBurstExtra = r.burstID.map { b in p.bursts[b]?.first?.id != r.id } ?? false
            if isBurstExtra && stackBursts && !expandedBursts.contains(r.burstID!) { continue }   // stacked only when asked
            // Burst frames are never moved out of the main grid; only possible closed eyes / soft focus are.
            let weak = r.eyesClosed || r.soft
            if bestOnly && !p.best.contains(r.id) { continue }
            if weak && separateWeaker { weaker.append(r) } else { strong.append(r) }
        }
        if sortBestFirst { strong.sort { $0.score > $1.score }; weaker.sort { $0.score > $1.score } }
        p.strong = strong; p.weaker = weaker
        presentation = p
        let visible = Set((strong + weaker).map(\.id))
        excludedFromExport = (Set(weaker.map(\.id)).union(userExcluded)).subtracting(userIncluded).union(Set(results.map(\.id)).subtracting(visible))
        if let id = inspectedPhotoID, !results.contains(where: { $0.id == id }), section == .find { inspectedPhotoID = nil }
    }

    var visibleResults: [SearchResult] { presentation.strong + presentation.weaker }

    func toggleExport(_ id: Int64) {
        if excludedFromExport.contains(id) { userIncluded.insert(id); userExcluded.remove(id) }
        else { userExcluded.insert(id); userIncluded.remove(id) }
        arrange()
    }
    func setExportAll(_ include: Bool) {
        let ids = Set(visibleResults.map(\.id))
        if include { userIncluded.formUnion(ids); userExcluded.subtract(ids) } else { userExcluded.formUnion(ids); userIncluded.subtract(ids) }
        arrange()
    }

    /// How many of the current results are favorites, whether or not they're showing right now.
    var favoriteResultCount: Int { results.lazy.filter { self.favorites.contains($0.id) }.count }

    /// Select exactly the favorites in these results. One hidden behind "best shots only" or stacked in a burst is
    /// brought into view first, because only what's showing gets copied.
    func selectFavorites() {
        let all = Set(results.map(\.id))
        let chosen = all.intersection(favorites)
        guard !chosen.isEmpty else { return }
        if bestOnly { bestOnly = false }
        expandedBursts.formUnion(results.filter { chosen.contains($0.id) }.compactMap(\.burstID))
        userIncluded = chosen
        userExcluded = all.subtracting(chosen)
        arrange()
    }

    /// Plain-language description of the current query, e.g. "Photos where Ana and Ben both appear".
    var querySentence: String {
        let names = selectedPeople.compactMap { person($0)?.displayName }
        switch names.count {
        case 0: return "Choose one or more people below."
        case 1: return matchMode == .only ? "Solo photos of \(names[0])" : "Photos of \(names[0])"
        default:
            let list = ListFormatter.localizedString(byJoining: names)
            switch matchMode {
            case .all: return "Photos where \(list) \(names.count == 2 ? "both" : "all") appear"
            case .any: return "Photos with \(list.replacingOccurrences(of: " and ", with: " or "))"
            case .only: return "Photos of just \(list) — nobody else"
            }
        }
    }

    // MARK: Corrections (each re-runs matching so the library learns from the fix)

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
        refreshAll()
        scheduleRematch()
    }

    private var rematchTask: Task<Void, Never>?
    func scheduleRematch() {
        rematchTask?.cancel()
        let store = store, id = embedder.id, t = thresholds
        rematchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isMatching = true
            let vault = self?.vault
            await Task.detached(priority: .userInitiated) {
                if let vault, vault.isSetUp { try? vault.matchAndRoute(embedderID: id, thresholds: t) }
                else { try? store.runMatching(embedderID: id, thresholds: t) }
            }.value
            self?.reloadPrivateContent()
            self?.isMatching = false
            self?.refreshAll()
        }
    }

    /// An undoable correction: snapshot, apply, register with ⌘Z, and offer an Undo toast.
    func change(_ label: String, fragile: [Int64] = [], _ action: () throws -> Void) {
        let snapshot = try? store.captureUndo(label, fragileFaceIDs: fragile)
        perform(action)
        guard let snapshot else { return }
        registerUndo(snapshot)
        toast = Toast(text: label)
    }

    private func registerUndo(_ snapshot: UndoSnapshot) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applyUndo(snapshot) }
        }
        undoManager?.setActionName(snapshot.label)
    }

    /// Restore a snapshot; the state being replaced is registered in turn, which makes it the redo.
    func applyUndo(_ snapshot: UndoSnapshot) {
        let current = try? store.captureUndo(snapshot.label)
        do { try store.restore(snapshot) } catch { errorMessage = "Couldn’t undo: \(error)" }
        ImageCache.shared.invalidateFaces()
        refreshAll()
        if let current { registerUndo(current) }
        toast = Toast(text: (undoManager?.isUndoing == true ? "Undone: " : "Redone: ") + snapshot.label, offersUndo: false)
    }

    /// Scans and bulk deletions change the faces underneath; older undo steps no longer apply.
    func clearUndoHistory() { undoManager?.removeAllActions(withTarget: self) }

    func name(personID: Int64, as name: String) {
        change("Name “\(name.trimmingCharacters(in: .whitespaces))”") { _ = try store.name(personID: personID, as: name) }
    }
    func confirm(_ faceIDs: [Int64]) { change(faceIDs.count == 1 ? "Confirm face" : "Confirm \(faceIDs.count) faces") { try store.confirm(faceIDs: faceIDs) } }
    func reject(_ faceIDs: [Int64]) {
        let who = faceIDs.count == 1 ? (try? store.face(id: faceIDs[0])).flatMap { person($0?.personID)?.displayName } : nil
        change(who.map { "Not \($0)" } ?? "Remove \(Format.count(faceIDs.count, "face"))") { try store.reject(faceIDs: faceIDs) }
    }
    func assign(_ faceIDs: [Int64], to personID: Int64) {
        change("Assign \(Format.count(faceIDs.count, "face")) to \(person(personID)?.displayName ?? "person")") { try store.assign(faceIDs: faceIDs, to: personID) }
    }
    func ignore(_ faceIDs: [Int64]) { change("Ignore \(Format.count(faceIDs.count, "face"))", fragile: faceIDs) { try store.ignore(faceIDs: faceIDs) } }
    func merge(_ source: Int64, into target: Int64) {
        change("Merge \(person(source)?.displayName ?? "") into \(person(target)?.displayName ?? "")") { try store.merge(source, into: target) }
        selectedPeople = selectedPeople.map { $0 == source ? target : $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    func forget(_ personID: Int64) {
        selectedPeople.removeAll { $0 == personID }
        if openPersonID == personID { openPersonID = nil }
        let faceIDs = (try? store.db.read { try $0.query("SELECT id FROM faces WHERE person_id = ?", [personID]) { $0.int(0) } }) ?? []
        change("Forget \(person(personID)?.displayName ?? "person")", fragile: faceIDs) { try store.forget(personID: personID) }
    }
    @discardableResult
    func newPerson(from faceIDs: [Int64], name: String?) -> Int64? {
        var id: Int64?
        change(name.map { "New person “\($0)”" } ?? "Split \(Format.count(faceIDs.count, "face"))") { id = try store.moveToNewPerson(faceIDs: faceIDs, name: name) }
        return id
    }

    // MARK: Sources & scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Preview"
        panel.message = "Choose a folder, drive or card to scan. Pixora only reads your photos — it never moves, renames or deletes them."
        if panel.runModal() == .OK, let url = panel.url { startPreview(url) }
    }

    func startPreview(_ url: URL) {
        do {
            let source = try store.addSource(url: url)
            sources = try store.sources()
            scan = ScanSession(model: self, source: source)
        } catch { errorMessage = error.localizedDescription }
    }

    func scanVolume(_ v: VolumeInfo) {
        let dcim = v.url.appendingPathComponent("DCIM", isDirectory: true)
        startPreview(FileManager.default.fileExists(atPath: dcim.path) ? dcim : v.url)
    }

    func rescan(_ source: Source) {
        guard source.isOnline else { errorMessage = "\(source.name) is not connected."; return }
        scan = ScanSession(model: self, source: source)
    }

    func makeEngine() -> ScanEngine {
        let e = ScanEngine(store: store, embedder: embedder, thresholds: thresholds)
        if vault.isSetUp { e.vault = vault }
        return e
    }

    func locate(_ source: Source) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Where is “\(source.name)” now? Choose the folder that contains the same photos."
        panel.prompt = "Reconnect"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let check = try store.verifyRelocation(sourceID: source.id, to: url)
            if check.checked > 0 && check.matched * 2 < check.checked {
                let alert = NSAlert()
                alert.messageText = "This folder doesn’t look like “\(source.name)”."
                alert.informativeText = "Only \(check.matched) of \(check.checked) sampled photos were found there with the same size. Reconnect anyway?"
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reconnect Anyway")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            try store.relocate(sourceID: source.id, to: url)
        } catch { errorMessage = error.localizedDescription }
        refreshAll()
    }

    func remove(_ source: Source) { perform { try store.removeSource(source.id) } }

    // MARK: Model management

    /// Faces analysed by an older model don't take part in matching. Offer a clean re-analysis.
    var needsReanalysis: Bool { stats.facesFromOtherEmbedder > 0 }

    func reanalyseLibrary() {
        let alert = NSAlert()
        alert.messageText = "Re-analyse your photos with \(embedder.displayName)?"
        alert.informativeText = "Your current people and groups were made by the older face model. This clears all face data, people and corrections, then scans your connected cards and folders again so every face is grouped by the new model. Your photos are not touched."
        alert.addButton(withTitle: "Clear and Re-scan"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectedPeople = []
        ImageCache.shared.invalidateFaces()
        perform { try store.clearFaceData() }
        if let source = sources.first(where: \.isOnline) { scan = ScanSession(model: self, source: source) }
        else { errorMessage = "Face data cleared. Connect your card or drive, then choose Scan Again in Cards & Folders." }
    }


    func installModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "mlpackage")!, .init(filenameExtension: "mlmodel")!]
        panel.message = "Choose a Core ML face-embedding model (image in, vector out), e.g. FaceNet512.mlpackage made by tools/convert_facenet.py."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let compiled = try CoreMLFaceEmbedder.install(modelAt: url)
            embedder = try CoreMLFaceEmbedder(compiledModelURL: compiled)
            refreshAll()
        } catch { errorMessage = "That model could not be used: \(error.localizedDescription)" }
    }

    // MARK: Export

    func requestExport() {
        let chosen = visibleResults.filter { !excludedFromExport.contains($0.id) }
        guard !chosen.isEmpty else { return }
        exportRequest = ExportRequest(results: chosen, peopleNames: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) }))
    }

    /// Copy any set of photos (from a selection, the viewer, a person's page…).
    func requestExport(photos: [Photo]) {
        guard !photos.isEmpty else { return }
        exportRequest = ExportRequest(results: photos.map { SearchResult(photo: $0, matches: []) },
                                      peopleNames: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) }))
    }

    func openViewer(_ photos: [Photo], at id: Int64, title: String) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        viewer = ViewerState(photos: photos, index: i, title: title, origin: tileFrame(id))
    }

    // Tiles register their view so the viewer can zoom from / back to the exact spot. Not observed: no re-renders.
    @ObservationIgnored private var tileViews: [Int64: WeakView] = [:]
    @ObservationIgnored private var tilePhotos: [Int64: Photo] = [:]
    /// What's picked in the grid on screen while selecting: dragging one of these carries them all.
    @ObservationIgnored var dragSelection: [Photo] = []
    func registerTile(_ photo: Photo, _ view: NSView?) {
        guard let view else { return }
        tileViews[photo.id] = WeakView(view: view)
        tilePhotos[photo.id] = photo
    }
    func unregisterTile(_ id: Int64, _ view: NSView?) {
        guard tileViews[id]?.view === view else { return }
        tileViews[id] = nil
        tilePhotos[id] = nil
    }

    /// The photo tile under a mouse event, if there is one.
    func tile(at event: NSEvent) -> (photo: Photo, view: NSView)? {
        for (id, entry) in tileViews {
            guard let view = entry.view, view.window === event.window, let photo = tilePhotos[id] else { continue }
            let point = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(point) && view.visibleRect.contains(point) { return (photo, view) }
        }
        return nil
    }

    /// A tile's picture area in window (SwiftUI global) coordinates, if it is on screen.
    func tileFrame(_ id: Int64) -> CGRect? {
        guard let v = tileViews[id]?.view, let window = v.window, let root = window.contentView else { return nil }
        var r = v.convert(v.bounds, to: root)
        if !root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        guard r.width > 4, r.height > 4, root.bounds.intersects(r) else { return nil }
        return r
    }

    func exportItems(_ results: [SearchResult], names: [Int64: String]) -> [ExportItem] {
        results.compactMap { r in
            guard let s = source(r.photo.sourceID) else { return nil }
            // Folder-by-person uses the selected people; the names written into the file are everyone named in it.
            let selected = r.matches.compactMap { names[$0.personID] }
            let everyone = namesInPhoto(r.photo.id)
            return ExportItem(photo: r.photo, sourceRoot: s.url, people: everyone.isEmpty ? selected : everyone,
                              folders: nil).withFolders(selected: selected.isEmpty ? nil : selected)
        }
    }
}

struct ExportRequest: Identifiable {
    let id = UUID()
    let results: [SearchResult]
    let peopleNames: [Int64: String]
}

/// One import: preview → scan (pause/resume/cancel) → summary.
@MainActor @Observable
final class ScanSession: Identifiable {
    enum Stage { case previewing, ready, scanning, done }
    let id = UUID()
    let source: Source
    unowned let model: AppModel
    var stage: Stage = .previewing
    var preview: ScanPreview?
    var excludedFolders: Set<String> = []
    var alreadyScanned = 0
    var progress = ScanProgress()
    var isPaused = false
    /// Also learn what's in each photo. Remembered as the choice for next time, but still asked every time.
    var deep = UserDefaults.standard.bool(forKey: "deepScanChosen") { didSet { UserDefaults.standard.set(deep, forKey: "deepScanChosen") } }
    private var engine: ScanEngine?
    private var task: Task<Void, Never>?
    private var scanWork: Task<ScanProgress, Never>?

    init(model: AppModel, source: Source) {
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
            if ProcessInfo.processInfo.environment["PIXORA_AUTOSCAN"] != nil { self?.start() }   // screenshot/testing hook
        }
    }

    var selectedFiles: [ScanFile] {
        (preview?.files ?? []).filter { !excludedFolders.contains($0.folder) }
    }

    func start() {
        let engine = model.makeEngine()
        self.engine = engine
        stage = .scanning
        let files = selectedFiles, source = source
        // Detached so analysis stays off the main thread; kept so Cancel can reach it.
        let work = Task.detached(priority: .userInitiated) {
            await engine.run(source: source, files: files) { [weak self] p in
                Task { @MainActor [weak self] in
                    // Callbacks can arrive out of order; never move the bar backwards.
                    guard let self, p.processed >= self.progress.processed || p.phase != .scanning else { return }
                    self.progress = p
                }
            }
        }
        scanWork = work
        task = Task { [weak self] in
            let final = await work.value
            self?.progress = final
            self?.stage = .done
            self?.model.clearUndoHistory()
            self?.model.refreshAll()
            self?.model.sight.refreshCounts()
            if self?.deep == true { self?.model.sight.requestScan() }
        }
    }

    func togglePause() {
        guard let engine else { return }
        isPaused.toggle()
        let paused = isPaused
        Task { if paused { await engine.pause() } else { await engine.resume() } }
    }

    func cancel() {
        if isPaused, let engine { Task { await engine.resume() } }
        isPaused = false
        scanWork?.cancel()
        if stage != .scanning { task?.cancel(); model.scan = nil }
    }
}

private extension ExportItem {
    /// By-person export should file a photo under the *selected* people only, even though the metadata names everyone.
    func withFolders(selected: [String]?) -> ExportItem {
        ExportItem(photo: photo, sourceRoot: sourceRoot, people: people, folders: nil, byPersonFolders: selected)
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var offersUndo = true
}

final class WeakView { weak var view: NSView?; init(view: NSView) { self.view = view } }

extension AppModel {
    /// A recap card for an import (one card's or folder's shoot).
    func recap(importRecord i: ImportRecord) {
        var f = PhotoFilter(); f.importID = i.id
        let photos = (try? store.photos(filter: f)) ?? []
        guard !photos.isEmpty else { errorMessage = "That import has no photos left in the library."; return }
        recapRequest = RecapRequest(title: "\(i.sourceName) · \(Format.day.string(from: i.startedAt))", photos: photos)
    }
}
