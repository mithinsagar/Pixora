import Foundation
import Security
import CryptoKit

/// Generic-password items in the login Keychain, readable only on this Mac (not synced, not in backups that
/// leave the device) and only after the user has unlocked the Mac once since boot.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

    /// The app's namespace. Test libraries (PIXORA_HOME) get their own, so tests never touch real items.
    public static var app: Keychain {
        if let home = ProcessInfo.processInfo.environment["PIXORA_HOME"] {
            let tag = SHA256.hash(data: Data(home.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            return Keychain(service: "local.pixora.Pixora.test.\(tag)")
        }
        // Items written by earlier, ad-hoc-signed builds under "local.pixora.Pixora" can make macOS ask for the
        // keychain password; this build uses a fresh namespace and a stable signature instead.
        return Keychain(service: "local.pixora.PrivateSpace")
    }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func set(_ data: Data, for account: String) throws {
        var query = base(account)
        let attrs: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attrs) { $1 }
            query[kSecAttrSynchronizable] = kCFBooleanFalse
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func data(for account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    /// Remove every item in this namespace (used by tests and "Erase everything").
    public func deleteAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
    }
}
