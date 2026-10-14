import EspazioCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google scopes used by Espazio. Requested progressively, per feature (spec §3.5).
public enum GoogleScope {
    public static let gmailReadonly = "https://www.googleapis.com/auth/gmail.readonly"
    public static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
    public static let chatSpacesReadonly = "https://www.googleapis.com/auth/chat.spaces.readonly"
    public static let chatMessagesReadonly = "https://www.googleapis.com/auth/chat.messages.readonly"
    public static let chatMessagesCreate = "https://www.googleapis.com/auth/chat.messages.create"
    /// Per-space read state: tells which conversations are unread, as in the Chat app.
    public static let chatReadStateReadonly = "https://www.googleapis.com/auth/chat.users.readstate.readonly"
    /// Per-space notification settings (muted conversations are ignored). Google offers no
    /// read-only variant; Espazio only reads them.
    public static let chatSpaceSettings = "https://www.googleapis.com/auth/chat.users.spacesettings"
    /// Names of the people in the organization (the Chat API returns user IDs only).
    public static let directoryReadonly = "https://www.googleapis.com/auth/directory.readonly"
    public static let calendarEventsReadonly = "https://www.googleapis.com/auth/calendar.events.readonly"

    public static let gmailRead: Set<String> = [gmailReadonly]
    public static let chatRead: Set<String> = [
        chatSpacesReadonly, chatMessagesReadonly, chatReadStateReadonly, chatSpaceSettings, directoryReadonly,
    ]
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: Set<String>

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: Set<String>) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public func isExpiring(at date: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) < margin
    }

    /// `gmail.modify` implies read access.
    public func grants(_ scope: String) -> Bool {
        if scopes.contains(scope) { return true }
        return scope == GoogleScope.gmailReadonly && scopes.contains(GoogleScope.gmailModify)
    }
}

public enum OAuthError: Error, Equatable, Sendable {
    case notConfigured
    case stateMismatch
    case accessDenied(String)
    case invalidGrant
    case timeout
    case missingCode
    case http(status: Int)
    case invalidResponse
}

/// PKCE helpers (RFC 7636).
public enum PKCE {
    static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 64-character verifier from the system CSPRNG.
    public static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in unreserved[Int(generator.next(upperBound: UInt64(unreserved.count)))] })
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256Digest.hash(Array(verifier.utf8)))
    }

    public static func makeState() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        return base64URL(bytes)
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Google OAuth 2.0 for installed (desktop) applications with PKCE and loopback redirect.
/// Docs: https://developers.google.com/identity/protocols/oauth2/native-app
public struct GoogleOAuthClient: Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public let clientID: String
    /// Desktop clients receive a "client secret" that Google documents as non-confidential; it is
    /// supplied by the user and kept in the Keychain, never shipped in the binary.
    public let clientSecret: String?
    let http: HTTPClient
    let now: @Sendable () -> Date

    public init(clientID: String, clientSecret: String?, http: HTTPClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.clientID = clientID
        self.clientSecret = clientSecret?.isEmpty == true ? nil : clientSecret
        self.http = http
        self.now = now
    }

    public func authorizationURL(scopes: Set<String>, redirectURI: String, state: String, codeChallenge: String, firstConsent: Bool) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        if firstConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        components.queryItems = items
        return components.url!
    }

    /// Validates the redirect query and returns the authorization code.
    public static func code(fromRedirect query: [String: String], expectedState: String) throws -> String {
        guard query["state"] == expectedState else { throw OAuthError.stateMismatch }
        if let error = query["error"] { throw OAuthError.accessDenied(error) }
        guard let code = query["code"], !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    public func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        var form = [
            "client_id": clientID, "code": code, "code_verifier": verifier, "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let clientSecret { form["client_secret"] = clientSecret }
        return try await tokenRequest(form, previous: nil)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.invalidGrant }
        var form = ["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        if let clientSecret { form["client_secret"] = clientSecret }
        return try await tokenRequest(form, previous: tokens)
    }

    public func revoke(_ token: String) async {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(["token": token])
        _ = try? await http.send(request)
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Double?
        let refresh_token: String?
        let scope: String?
        let error: String?
    }

    private func tokenRequest(_ form: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form)
        let (data, response) = try await http.send(request)
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if decoded?.error == "invalid_grant" { throw OAuthError.invalidGrant }
        guard (200..<300).contains(response.statusCode) else { throw OAuthError.http(status: response.statusCode) }
        guard let decoded, let accessToken = decoded.access_token else { throw OAuthError.invalidResponse }
        let scopes = decoded.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        return OAuthTokens(
            accessToken: accessToken, refreshToken: decoded.refresh_token ?? previous?.refreshToken,
            expiresAt: now().addingTimeInterval(decoded.expires_in ?? 3600), scopes: scopes)
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.sorted { $0.key < $1.key }
            .map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

/// Persistent token storage (Keychain on macOS; in-memory in tests).
public protocol TokenStore: Sendable {
    func load() -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func delete()
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(_ tokens: OAuthTokens? = nil) { self.tokens = tokens }

    public func load() -> OAuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: OAuthTokens) throws {
        lock.lock()
        self.tokens = tokens
        lock.unlock()
    }

    public func delete() {
        lock.lock()
        tokens = nil
        lock.unlock()
    }
}

/// Owns the tokens: refreshes them on demand (single flight), persists them, signs out.
public actor GoogleAuthSession {
    private let client: GoogleOAuthClient
    private let store: TokenStore
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?
    /// Bumped by install/sign-out so a refresh that finishes afterwards cannot resurrect or
    /// overwrite newer tokens.
    private var generation = 0

    public init(client: GoogleOAuthClient, store: TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
        self.tokens = store.load()
    }

    public var isConnected: Bool { tokens != nil }
    public var scopes: Set<String> { tokens?.scopes ?? [] }

    public func grants(_ scope: String) -> Bool { tokens?.grants(scope) ?? false }

    public func install(_ newTokens: OAuthTokens) throws {
        var merged = newTokens
        if let tokens {
            // Incremental consent: keep the refresh token and union the scopes.
            merged.refreshToken = newTokens.refreshToken ?? tokens.refreshToken
            merged.scopes.formUnion(tokens.scopes)
        }
        tokens = merged
        generation += 1
        try store.save(merged)
    }

    /// A valid access token, refreshing it if it expires within a minute.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw OAuthError.notConfigured }
        if !forceRefresh, !current.isExpiring(at: now()) { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let client = self.client
        let task = Task { try await client.refresh(current) }
        refreshTask = task
        let startGeneration = generation
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            guard generation == startGeneration else {
                guard let tokens else { throw OAuthError.notConfigured }
                return tokens.accessToken
            }
            tokens = refreshed
            try? store.save(refreshed)
            return refreshed.accessToken
        } catch OAuthError.invalidGrant {
            guard generation == startGeneration else { throw OAuthError.invalidGrant }
            tokens = nil
            store.delete()
            throw OAuthError.invalidGrant
        }
    }

    /// Revokes the grant at Google and deletes local tokens.
    public func signOut() async {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            await client.revoke(token)
        }
        tokens = nil
        generation += 1
        store.delete()
    }
}
