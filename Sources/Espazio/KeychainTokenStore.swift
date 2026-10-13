import Foundation
import GoogleProvider
import Security

/// Generic-password Keychain storage, device-only, available after first unlock.
struct KeychainItem: Sendable {
    let service: String
    let account: String

    func read() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete() {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Google OAuth tokens in the Keychain (never in UserDefaults or logs).
struct KeychainTokenStore: TokenStore {
    private let item = KeychainItem(service: "app.espazio.google", account: "oauth-tokens")

    func load() -> OAuthTokens? {
        item.read().flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }

    func save(_ tokens: OAuthTokens) throws {
        try item.write(JSONEncoder().encode(tokens))
    }

    func delete() {
        item.delete()
    }
}
