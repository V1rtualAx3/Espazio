import Foundation

/// Secret storage addressed by account name (the Keychain on macOS, memory in tests).
public protocol SecretStorage: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String)
}

/// Everything Espazio keeps secret for Google, stored as a single item.
public struct GoogleCredentials: Codable, Sendable, Equatable {
    public var tokens: OAuthTokens?
    public var clientSecret: String?

    public init(tokens: OAuthTokens? = nil, clientSecret: String? = nil) {
        self.tokens = tokens
        self.clientSecret = clientSecret
    }

    var isEmpty: Bool { tokens == nil && (clientSecret ?? "").isEmpty }
}

/// Google credentials in one storage item, read once per launch. Without a Developer ID, macOS
/// asks again for Keychain access after every update, once per item: one item means one prompt.
/// Items written by earlier versions (tokens and client secret apart) are merged on first read.
public final class GoogleCredentialVault: TokenStore, @unchecked Sendable {
    public static let account = "credentials"
    static let legacyTokensAccount = "oauth-tokens"
    static let legacySecretAccount = "client-secret"

    private let storage: SecretStorage
    private let lock = NSLock()
    private var cached: GoogleCredentials?

    public init(storage: SecretStorage) {
        self.storage = storage
    }

    public var clientSecret: String? {
        let secret = credentials().clientSecret
        return (secret ?? "").isEmpty ? nil : secret
    }

    public func setClientSecret(_ secret: String) throws {
        try update { $0.clientSecret = secret }
    }

    // MARK: TokenStore

    public func load() -> OAuthTokens? {
        credentials().tokens
    }

    public func save(_ tokens: OAuthTokens) throws {
        try update { $0.tokens = tokens }
    }

    /// Signs out: the tokens go, the OAuth client secret stays.
    public func delete() {
        try? update { $0.tokens = nil }
    }

    // MARK: Storage

    private func credentials() -> GoogleCredentials {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private func update(_ change: (inout GoogleCredentials) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var credentials = loadLocked()
        change(&credentials)
        if credentials.isEmpty {
            storage.delete(Self.account)
        } else {
            try storage.write(JSONEncoder().encode(credentials), account: Self.account)
        }
        cached = credentials
    }

    private func loadLocked() -> GoogleCredentials {
        if let cached { return cached }
        let credentials: GoogleCredentials
        if let data = storage.read(Self.account), let stored = try? JSONDecoder().decode(GoogleCredentials.self, from: data) {
            credentials = stored
        } else {
            credentials = migrateLegacyLocked()
        }
        cached = credentials
        return credentials
    }

    private func migrateLegacyLocked() -> GoogleCredentials {
        let tokens = storage.read(Self.legacyTokensAccount).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
        let secret = storage.read(Self.legacySecretAccount).map { String(decoding: $0, as: UTF8.self) }
        let credentials = GoogleCredentials(tokens: tokens, clientSecret: secret)
        guard !credentials.isEmpty else { return credentials }
        // Legacy items are removed only once the merged item is safely written.
        if (try? storage.write(JSONEncoder().encode(credentials), account: Self.account)) != nil {
            storage.delete(Self.legacyTokensAccount)
            storage.delete(Self.legacySecretAccount)
        }
        return credentials
    }
}

public final class InMemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    public private(set) var reads = 0

    public init(_ items: [String: Data] = [:]) { self.items = items }

    public func read(_ account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return items[account]
    }

    public func write(_ data: Data, account: String) throws {
        lock.lock()
        items[account] = data
        lock.unlock()
    }

    public func delete(_ account: String) {
        lock.lock()
        items[account] = nil
        lock.unlock()
    }

    public var accounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.sorted()
    }
}
