import AppKit
import Contacts
import ContactsUI

/// Picks a contact with the system Contacts picker and returns its phone numbers / emails.
@MainActor
final class ContactLinker: NSObject, CNContactPickerDelegate {
    static let shared = ContactLinker()
    private var picker: CNContactPicker?
    private var completion: ((_ id: String, _ name: String, _ handles: [String]) -> Void)?

    func pick(relativeTo view: NSView?, completion: @escaping (_ id: String, _ name: String, _ handles: [String]) -> Void) {
        guard let view = view ?? NSApp.keyWindow?.contentView else { return }
        let p = CNContactPicker()
        p.displayedKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        p.delegate = self
        picker = p
        self.completion = completion
        p.showRelative(to: view.bounds, of: view, preferredEdge: .maxY)
    }

    nonisolated func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
        var handles: [String] = []
        if contact.isKeyAvailable(CNContactPhoneNumbersKey) { handles += contact.phoneNumbers.map { $0.value.stringValue } }
        if contact.isKeyAvailable(CNContactEmailAddressesKey) { handles += contact.emailAddresses.map { $0.value as String } }
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let id = contact.identifier
        Task { @MainActor in self.completion?(id, name, handles); picker.close() }
    }

    nonisolated func contactPickerDidClose(_ picker: CNContactPicker) {}
}
