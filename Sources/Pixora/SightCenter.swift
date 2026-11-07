import AppKit
import SwiftUI
import PixoraCore

/// The search model and the deep scan: what's installed, how far the scan has got, and asking it questions.
@MainActor @Observable
final class SightCenter {
    enum ModelState: Equatable { case absent, downloading(received: Int64), ready, failed(String) }

    private(set) var modelState: ModelState = Sight.isInstalled ? .ready : .absent
    private(set) var done = 0
    private(set) var total = 0
    private(set) var isScanning = false
    private(set) var secondsLeft: Double?
    /// Set when a deep scan was asked for before the model was here.
    private var scanAfterDownload = false
    private var scanTask: Task<Void, Never>?
    private var installer: SightInstaller?
    private let store: LibraryStore
    private let reader: SightReader

    init(store: LibraryStore) {
        self.store = store
        reader = SightReader(store: store)
        refreshCounts()
    }

    var isReady: Bool { modelState == .ready }
    var pending: Int { max(0, total - done) }
    var isDownloading: Bool { if case .downloading = modelState { true } else { false } }
    /// Stays on across a quit, so an unfinished deep scan carries on next time.
    private var scanWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "deepScanWanted") }
        set { UserDefaults.standard.set(newValue, forKey: "deepScanWanted") }
    }
    private var secondsPerPhoto: Double {
        get { let v = UserDefaults.standard.double(forKey: "deepScanSecondsPerPhoto"); return v > 0 ? v : Sight.typicalSecondsPerPhoto }
        set { UserDefaults.standard.set(newValue, forKey: "deepScanSecondsPerPhoto") }
    }

    func estimate(photos: Int) -> Double { Double(photos) * secondsPerPhoto }

    func refreshCounts() {
        if let counts = try? store.sightCounts() { done = counts.done; total = counts.total }
    }

    func resumeIfInterrupted() {
        if scanWanted, isReady, pending > 0 { startScan() }
    }

    /// What Deep Scan does, whatever state things are in.
    func requestScan() {
        refreshCounts()
        if isReady { startScan() } else { scanAfterDownload = true; download() }
    }

    func download() {
        guard !isDownloading else { return }
        modelState = .downloading(received: 0)
        let installer = SightInstaller { [weak self] received in
            Task { @MainActor [weak self] in self?.downloaded(received) }
        }
        self.installer = installer
        Task { [weak self] in
            do {
                try await installer.run()
                guard let self else { return }
                self.modelState = .ready
                if self.scanAfterDownload { self.scanAfterDownload = false; self.startScan() }
            } catch {
                guard let self else { return }
                self.scanAfterDownload = false
                let stopped = (error as? URLError)?.code == .cancelled
                self.modelState = stopped ? .absent : .failed(Self.message(for: error))
            }
            self?.installer = nil
        }
    }

    /// The network reports far more often than a progress bar can show.
    private func downloaded(_ received: Int64) {
        guard case .downloading(let shown) = modelState, received - shown >= 4 << 20 else { return }
        modelState = .downloading(received: received)
    }

    func cancelDownload() { installer?.cancel() }

    private static func message(for error: Error) -> String {
        if let error = error as? SightInstallError { return error.localizedDescription }
        return "The download stopped. Check your connection and try again."
    }

    /// Reads every photo not read yet, from the saved previews, so the card doesn't need to stay in.
    private func startScan() {
        guard isReady, !isScanning else { return }
        isScanning = true
        scanWanted = true
        secondsLeft = nil
        let store = store
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Deep scan")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let vision = try SightVision()
                let pending = try store.sightPending()
                let started = Date()
                for (n, id) in pending.enumerated() {
                    if Task.isCancelled { break }
                    // No preview yet (they can be turned off): leave it for a later deep scan, not marked unreadable.
                    let preview = AppPaths.thumbnail(photoID: id)
                    guard FileManager.default.fileExists(atPath: preview.path) else { continue }
                    try autoreleasepool {
                        let image = CGImageSourceCreateWithURL(preview as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                        try store.saveSight(photoID: id, vectors: try image.map(vision.vectors(for:)) ?? Data())
                    }
                    let rate = Date().timeIntervalSince(started) / Double(n + 1), left = Double(pending.count - n - 1) * rate
                    await self?.scanned(rate: rate, left: left)
                }
                await self?.scanEnded(finished: !Task.isCancelled)
            } catch {
                await self?.scanEnded(finished: false)
            }
        }
    }

    private func scanned(rate: Double, left: Double) {
        refreshCounts()
        secondsPerPhoto = rate
        secondsLeft = left
    }

    private func scanEnded(finished: Bool) {
        isScanning = false
        secondsLeft = nil
        scanTask = nil
        if finished { scanWanted = false }
        refreshCounts()
    }

    func pauseScan() {
        scanWanted = false
        scanTask?.cancel()
    }

    func removeModel() {
        pauseScan()
        Task { [weak self] in
            await self?.reader.release()
            try? FileManager.default.removeItem(at: Sight.directory)
            try? self?.store.clearSight()
            self?.modelState = .absent
            self?.refreshCounts()
        }
    }

    func hits(for text: String) async throws -> [SightHit] { try await reader.hits(for: text) }

    /// Loads while someone is still typing, so the first search doesn't wait for it.
    func prepare() { if isReady { Task { [reader] in try? await reader.prepare() } } }

    /// The text model is big too, and only needed while someone is searching.
    func release() { Task { [reader] in await reader.release() } }
}

/// Keeps the slow parts of a search off the main thread, and loaded between keystrokes.
private actor SightReader {
    private let store: LibraryStore
    private var text: SightText?
    private var library: SightLibrary?
    private var libraryDone = -1

    init(store: LibraryStore) { self.store = store }

    /// Read again whenever the deep scan has moved on, so photos become searchable as it goes.
    func prepare() throws {
        if text == nil { text = try SightText() }
        let done = try store.sightCounts().done
        if library == nil || done != libraryDone { library = try store.sightLibrary(); libraryDone = done }
    }

    func hits(for query: String) throws -> [SightHit] {
        try prepare()
        guard let text, let library else { return [] }
        return library.hits(for: try text.vector(for: query))
    }

    func release() { text = nil; library = nil }
}
