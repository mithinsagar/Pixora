import SwiftUI
import PixoraCore

extension PhoneModel {
    var isPrivateUnlocked: Bool { privateContent != nil }
    var isPrivateSetUp: Bool { _ = vaultEpoch; return vault.isSetUp }

    // MARK: Lock / unlock

    /// Unlock with the Private Space password. Key derivation (PBKDF2, 600,000 rounds) runs off the main thread;
    /// the reveal animation starts only after the content is already loaded, so it never delays access.
    func unlockPrivateSpace(password: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.unlock(password: password) }.value
        reloadPrivateContent()
        privateRevealID = UUID()
        restartIdleTimer()
    }

    /// Lock now: forget the key, drop decrypted content and every private image held in memory, and close any
    /// private viewer or slideshow. Synchronous, so nothing private is left on screen for another frame.
    func lockPrivateSpace() {
        guard privateContent != nil || vault.isUnlocked else { return }
        vault.lockNow()
        privateContent = nil
        PhotoImages.shared.purgePrivate()
        if viewer?.isPrivate == true { viewer = nil }
        if slideshow?.isPrivate == true { slideshow = nil; SlideshowMusic.shared.stop() }
        if exportPhotos?.contains(where: { $0.id < 0 }) == true { exportPhotos = nil }
        if share?.photos.contains(where: { $0.id < 0 }) == true { share = nil }
        idleTimer?.invalidate()
    }

    func reloadPrivateContent() {
        guard vault.isUnlocked else { privateContent = nil; return }
        do {
            let content = try vault.loadContent()
            PhotoImages.shared.purgePrivate()
            for item in content.items {
                PhotoImages.shared.registerPrivate(photoID: item.photo.id, jpeg: item.preview, faces: item.faces.map { ($0.id, $0.thumb) })
            }
            privateContent = content
        } catch { errorMessage = error.localizedDescription }
    }

    func restartIdleTimer() {
        idleTimer?.invalidate()
        let minutes = UserDefaults.standard.object(forKey: "privateIdleMinutes") as? Int ?? 5
        guard minutes > 0, isPrivateUnlocked else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockPrivateSpace() }
        }
    }

    // MARK: Setup, password, delete

    func createPrivateSpace(password: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.setUp(password: password) }.value
        vaultEpoch += 1
        reloadPrivateContent()
        privateRevealID = UUID()
        restartIdleTimer()
    }

    func changePrivatePassword(current: String, new: String) async throws {
        let vault = vault
        try await Task.detached(priority: .userInitiated) { try vault.changePassword(current: current, new: new) }.value
        vaultEpoch += 1
    }

    /// Delete Private Space (e.g. forgotten password). Only Pixora's encrypted copies, private people and keys are
    /// removed. Original photos in Photos, Files, cards and drives, and the regular library, are untouched.
    func deletePrivateSpace() throws {
        lockPrivateSpace()
        try vault.destroy()
        privateContent = nil
        PhotoImages.shared.purgePrivate()
        vaultEpoch += 1
        refreshAll()
    }

    // MARK: Moving things in and out

    func makePrivate(photos: [Photo]) {
        let ids = photos.map(\.id).filter { $0 > 0 }
        guard isPrivateSetUp, !ids.isEmpty else { return }
        do { try vault.makePhotosPrivate(ids) } catch { errorMessage = error.localizedDescription }
        PhotoImages.shared.forget(photoIDs: ids)
        if let v = viewer, v.photos.contains(where: { ids.contains($0.id) }) { viewer = nil }
        refreshAll(); reloadPrivateContent()
        undo = UndoOffer(text: "\(Format.count(ids.count, "photo")) moved to Private Space", snapshot: nil)
    }

    func makePrivate(personID: Int64) {
        guard isPrivateSetUp else { return }
        let name = person(personID)?.displayName ?? "This person"
        do { try vault.makePersonPrivate(personID) } catch { errorMessage = error.localizedDescription }
        PhotoImages.shared.invalidateFaces()
        selectedPeople.removeAll { $0 == personID }
        viewer = nil
        refreshAll(); reloadPrivateContent()
        undo = UndoOffer(text: "\(name) is now private", snapshot: nil)
    }

    func moveToLibrary(photos: [Photo]) {
        let items = photos.compactMap { p in privateContent?.items.first { $0.photo.id == p.id }?.id }
        guard !items.isEmpty else { return }
        do { try vault.moveToLibrary(items) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
        undo = UndoOffer(text: "\(Format.count(items.count, "photo")) moved back to the library", snapshot: nil)
    }

    func confirmPrivateMatch(_ item: PrivateVault.Item) {
        do { try vault.confirmPending(item.id) } catch { errorMessage = error.localizedDescription }
        reloadPrivateContent()
    }

    func rejectPrivateMatch(_ item: PrivateVault.Item) {
        do { try vault.rejectPending(item.id) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
    }

    func makePersonPublic(_ personID: Int64) {
        do { try vault.makePersonPublic(personID) } catch { errorMessage = error.localizedDescription }
        refreshAll(); reloadPrivateContent()
    }
}
