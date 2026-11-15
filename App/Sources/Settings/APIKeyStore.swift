import Foundation
import Security

/// Keeps the Inworld API key in the Keychain, on this device only: it is not
/// synced to iCloud and is not included in backups restored to other devices.
struct APIKeyStore: Sendable {
    private let service: String
    private let account = "inworld-api-key"

    init(service: String = Bundle.main.bundleIdentifier ?? "InworldTranslator") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var hasKey: Bool { load() != nil }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(update) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}
