import EspazioCore
@testable import GoogleProvider
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Scriptable HTTP fake.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String, [String: String])
    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { $0.url?.path }
    }

    private func record(_ request: URLRequest) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = record(request)
        let (status, body, headers) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

final class OAuthTests: XCTestCase {
    func testSHA256Vectors() {
        func hex(_ text: String) -> String { SHA256Digest.hash(Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)).count, 64)
    }

    func testPKCEMatchesRFC7636() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.makeVerifier()
        XCTAssertEqual(verifier.count, 64)
        XCTAssertNotEqual(verifier, PKCE.makeVerifier())
        XCTAssertFalse(PKCE.makeState().contains("="))
    }

    func testAuthorizationURL() {
        let client = GoogleOAuthClient(clientID: "cid.apps.googleusercontent.com", clientSecret: nil, http: FakeHTTP { _ in (200, "", [:]) })
        let url = client.authorizationURL(scopes: GoogleScope.gmailRead, redirectURI: "http://127.0.0.1:5555", state: "st", codeChallenge: "ch", firstConsent: true)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["include_granted_scopes"], "true")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["scope"], GoogleScope.gmailReadonly)
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertNil(items["client_secret"])
    }

    func testRedirectValidation() {
        XCTAssertEqual(try GoogleOAuthClient.code(fromRedirect: ["code": "c", "state": "s"], expectedState: "s"), "c")
        XCTAssertThrowsError(try GoogleOAuthClient.code(fromRedirect: ["code": "c", "state": "x"], expectedState: "s")) {
            XCTAssertEqual($0 as? OAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try GoogleOAuthClient.code(fromRedirect: ["error": "access_denied", "state": "s"], expectedState: "s")) {
            XCTAssertEqual($0 as? OAuthError, .accessDenied("access_denied"))
        }
    }

    func testExchangeAndRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let http = FakeHTTP { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("grant_type=authorization_code") {
                XCTAssertTrue(body.contains("code_verifier=v"))
                XCTAssertTrue(body.contains("client_secret=sec"))
                return (200, #"{"access_token":"at1","expires_in":3600,"refresh_token":"rt","scope":"\#(GoogleScope.gmailReadonly)","token_type":"Bearer"}"#, [:])
            }
            return (200, #"{"access_token":"at2","expires_in":3600}"#, [:])
        }
        let client = GoogleOAuthClient(clientID: "cid", clientSecret: "sec", http: http, now: { now })
        let tokens = try await client.exchange(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
        XCTAssertTrue(tokens.grants(GoogleScope.gmailReadonly))
        let refreshed = try await client.refresh(tokens)
        XCTAssertEqual(refreshed.accessToken, "at2")
        XCTAssertEqual(refreshed.refreshToken, "rt", "refresh token kept")
        XCTAssertEqual(refreshed.scopes, tokens.scopes)
    }

    func testModifyScopeImpliesRead() {
        let tokens = OAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: .distantFuture, scopes: [GoogleScope.gmailModify])
        XCTAssertTrue(tokens.grants(GoogleScope.gmailReadonly))
        XCTAssertFalse(tokens.grants(GoogleScope.chatMessagesCreate))
    }

    func testSessionRefreshesExpiredTokenOnceAndInvalidGrantSignsOut() async throws {
        let clock = Date(timeIntervalSince1970: 0)
        let http = FakeHTTP { _ in (200, #"{"access_token":"fresh","expires_in":3600}"#, [:]) }
        let client = GoogleOAuthClient(clientID: "cid", clientSecret: nil, http: http, now: { clock })
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "old", refreshToken: "rt", expiresAt: clock.addingTimeInterval(10), scopes: []))
        let session = GoogleAuthSession(client: client, store: store, now: { clock })
        async let a = session.accessToken()
        async let b = session.accessToken()
        let tokens = try await [a, b]
        XCTAssertEqual(tokens, ["fresh", "fresh"])
        XCTAssertEqual(http.requestCount, 1, "single-flight refresh")
        XCTAssertEqual(store.load()?.accessToken, "fresh")

        http.setHandler { _ in (400, #"{"error":"invalid_grant"}"#, [:]) }
        do {
            _ = try await session.accessToken(forceRefresh: true)
            XCTFail("expected invalid grant")
        } catch {
            XCTAssertEqual(error as? OAuthError, .invalidGrant)
        }
        XCTAssertNil(store.load())
        let connected = await session.isConnected
        XCTAssertFalse(connected)
    }

    func testIncrementalConsentMergesScopes() async throws {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "rt", expiresAt: .distantFuture, scopes: [GoogleScope.gmailReadonly]))
        let session = GoogleAuthSession(client: GoogleOAuthClient(clientID: "c", clientSecret: nil, http: FakeHTTP { _ in (500, "", [:]) }), store: store)
        try await session.install(OAuthTokens(accessToken: "b", refreshToken: nil, expiresAt: .distantFuture, scopes: [GoogleScope.gmailModify]))
        XCTAssertEqual(store.load()?.refreshToken, "rt")
        XCTAssertEqual(store.load()?.scopes, [GoogleScope.gmailReadonly, GoogleScope.gmailModify])
    }

    func testSignOutRevokesAndDeletes() async {
        let http = FakeHTTP { _ in (200, "", [:]) }
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "rt", expiresAt: .distantFuture, scopes: []))
        let session = GoogleAuthSession(client: GoogleOAuthClient(clientID: "c", clientSecret: nil, http: http), store: store)
        await session.signOut()
        XCTAssertNil(store.load())
        XCTAssertEqual(http.paths(), ["/revoke"])
    }

    func testLoopbackReceiverEndToEnd() async throws {
        let receiver = try LoopbackReceiver()
        XCTAssertGreaterThan(receiver.port, 0)
        let port = receiver.port
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            rawGet(port: port, path: "/favicon.ico")
            rawGet(port: port, path: "/?state=forged&error=access_denied")
            rawGet(port: port, path: "/?state=s1&code=4%2Fabc")
        }
        let query = try await receiver.waitForCallback(timeout: 5, expectedState: "s1")
        XCTAssertEqual(query["code"], "4/abc")
        XCTAssertEqual(query["state"], "s1")
    }

    func testLoopbackTimeout() async throws {
        let receiver = try LoopbackReceiver()
        do {
            _ = try await receiver.waitForCallback(timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? OAuthError, .timeout)
        }
    }

    func testRequestLineParsing() {
        XCTAssertEqual(LoopbackReceiver.parseRequestLine("GET /?code=a&state=b HTTP/1.1"), ["code": "a", "state": "b"])
        XCTAssertNil(LoopbackReceiver.parseRequestLine("POST / HTTP/1.1"))
        XCTAssertNil(LoopbackReceiver.parseRequestLine("GET /other?code=a HTTP/1.1"))
    }

    private static func unused() {}
}

func rawGet(port: UInt16, path: String) {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = recv(fd, &buffer, buffer.count, 0)
        close(fd)
}

final class GoogleAPITests: XCTestCase {
    func session(_ http: FakeHTTP, scopes: Set<String> = [GoogleScope.gmailModify]) -> GoogleAuthSession {
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "tok", refreshToken: "rt", expiresAt: .distantFuture, scopes: scopes))
        return GoogleAuthSession(client: GoogleOAuthClient(clientID: "c", clientSecret: nil, http: http), store: store)
    }

    func testRetriesOnceAfter401WithRefreshedToken() async throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let http = FakeHTTP { request in
            if request.url?.host == "oauth2.googleapis.com" { return (200, #"{"access_token":"new","expires_in":3600}"#, [:]) }
            counter.calls += 1
            let auth = request.value(forHTTPHeaderField: "Authorization")
            return auth == "Bearer new" ? (200, "{}", [:]) : (401, "{}", [:])
        }
        let api = GoogleAPI(auth: session(http), http: http)
        _ = try await api.get(URL(string: "https://gmail.googleapis.com/x")!)
        XCTAssertEqual(counter.calls, 2)
    }

    func testErrorClassification() {
        XCTAssertEqual(GoogleAPI.classify(status: 429, data: Data(), retryAfter: "30"), .rateLimited(retryAfter: 30))
        let rate = #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#
        XCTAssertEqual(GoogleAPI.classify(status: 403, data: Data(rate.utf8), retryAfter: nil), .rateLimited(retryAfter: nil))
        let scope = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED"}}"#
        XCTAssertEqual(GoogleAPI.classify(status: 403, data: Data(scope.utf8), retryAfter: nil), .insufficientScope)
        let workspace = #"{"error":{"code":403,"message":"Google Chat app not found.","status":"PERMISSION_DENIED"}}"#
        XCTAssertEqual(GoogleAPI.classify(status: 403, data: Data(workspace.utf8), retryAfter: nil), .unsupported("Google Chat app not found."))
        XCTAssertEqual(GoogleAPI.classify(status: 503, data: Data(), retryAfter: nil), .server(503))
        XCTAssertTrue(GoogleAPIError.server(503).isRetryable)
        XCTAssertFalse(GoogleAPIError.insufficientScope.isRetryable)
    }

    func testNetworkErrorsAreWrapped() async {
        let http = FakeHTTP { _ in throw URLError(.notConnectedToInternet) }
        let api = GoogleAPI(auth: session(http), http: http)
        do {
            _ = try await api.get(URL(string: "https://gmail.googleapis.com/x")!)
            XCTFail("expected error")
        } catch let error as GoogleAPIError {
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNotConnected() async {
        let http = FakeHTTP { _ in (200, "{}", [:]) }
        let api = GoogleAPI(auth: GoogleAuthSession(client: GoogleOAuthClient(clientID: "c", clientSecret: nil, http: http), store: InMemoryTokenStore()), http: http)
        do {
            _ = try await api.get(URL(string: "https://gmail.googleapis.com/x")!)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GoogleAPIError, .notConnected)
        }
    }

    func testGmailIncrementalSync() async throws {
        final class Mailbox: @unchecked Sendable {
            var historyChanged = false
            var unread = ["m1"]
        }
        let mailbox = Mailbox()
        let http = FakeHTTP { request in
            let path = request.url!.path
            switch path {
            case "/gmail/v1/users/me/profile":
                return (200, #"{"emailAddress":"me@example.com","historyId":"100"}"#, [:])
            case "/gmail/v1/users/me/labels/INBOX":
                return (200, #"{"id":"INBOX","messagesUnread":\#(mailbox.unread.count)}"#, [:])
            case "/gmail/v1/users/me/messages":
                let list = mailbox.unread.map { #"{"id":"\#($0)","threadId":"t\#($0)"}"# }.joined(separator: ",")
                return (200, #"{"messages":[\#(list)]}"#, [:])
            case "/gmail/v1/users/me/history":
                return (200, mailbox.historyChanged ? #"{"history":[{"id":"101"}],"historyId":"101"}"# : #"{"historyId":"100"}"#, [:])
            default:
                let id = (path as NSString).lastPathComponent
                return (200, #"{"id":"\#(id)","threadId":"t\#(id)","labelIds":["UNREAD","INBOX"],"snippet":"Salut &amp; bienvenue","internalDate":"1700000000000","payload":{"headers":[{"name":"From","value":"\"Bob\" <bob@x.com>"},{"name":"Subject","value":"Hello"}]}}"#, [:])
            }
        }
        let monitor = GmailMonitor(service: GmailService(api: GoogleAPI(auth: session(http), http: http)))
        let first = try await monitor.sync()
        XCTAssertEqual(first.account, "me@example.com")
        XCTAssertEqual(first.unreadCount, 1)
        XCTAssertEqual(first.messages.first?.snippet, "Salut & bienvenue")
        XCTAssertEqual(first.messages.first?.senderName, "Bob")
        XCTAssertEqual(first.newMessageIDs, [], "first sync never notifies")

        let before = http.requestCount
        let unchanged = try await monitor.sync()
        XCTAssertEqual(http.requestCount - before, 1, "only the history call when nothing changed")
        XCTAssertEqual(unchanged.messages, first.messages)

        mailbox.historyChanged = true
        mailbox.unread = ["m2", "m1"]
        let changed = try await monitor.sync()
        XCTAssertEqual(changed.newMessageIDs, ["m2"])
        XCTAssertEqual(changed.unreadCount, 2)
    }

    func testGmailModifyBodies() async throws {
        let http = FakeHTTP { _ in (200, "{}", [:]) }
        let gmail = GmailService(api: GoogleAPI(auth: session(http), http: http))
        try await gmail.markRead(id: "abc")
        try await gmail.archive(id: "abc")
        let bodies = http.requests.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(bodies, [#"{"removeLabelIds":["UNREAD"]}"#, #"{"removeLabelIds":["INBOX"]}"#])
        XCTAssertEqual(http.requests.first?.httpMethod, "POST")
    }

    func testChatParsing() throws {
        let spaces = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"spaces":[{"name":"spaces/A","displayName":"Équipe","spaceType":"SPACE","lastActiveTime":"2026-10-13T10:00:00.123456789Z"},
                   {"name":"spaces/B","displayName":"","spaceType":"DIRECT_MESSAGE"}]}
        """#.utf8))
        let parsed = GoogleChatService.parseSpaces(spaces)
        XCTAssertEqual(parsed.map(\.space.displayName), ["Équipe", "Message direct"])
        XCTAssertNotNil(parsed[0].lastActive)
        XCTAssertTrue(parsed[1].space.isDirectMessage)

        let messages = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"messages":[{"name":"spaces/A/messages/1","sender":{"name":"users/1","displayName":"Alice"},"text":"Salut","createTime":"2026-10-13T10:00:00Z","thread":{"name":"spaces/A/threads/t"}},
                     {"name":"spaces/A/messages/2","sender":{"name":"users/2"},"text":"Yo"}]}
        """#.utf8))
        let parsedMessages = GoogleChatService.parseMessages(messages, spaceID: "spaces/A")
        XCTAssertEqual(parsedMessages.map(\.sender), ["Alice", "Participant"])
        XCTAssertEqual(parsedMessages.first?.threadName, "spaces/A/threads/t")
    }

    func testChatUnreadFollowsReadState() async throws {
        final class Workspace: @unchecked Sendable {
            var dmActive = "2026-10-14T10:00:00Z"
            var dmRead = "2026-10-14T09:00:00Z"
            var dmMessages = [#"{"name":"spaces/D/messages/1","sender":{"name":"users/9"},"text":"Salut","createTime":"2026-10-14T10:00:00Z"}"#]
            var peopleCalls = 0
            var mutedActive = "2026-10-14T09:30:00Z"
            var forYouActive = "2026-10-14T09:40:00Z"
            var forYouCount = 1
        }
        let ws = Workspace()
        let http = FakeHTTP { request in
            let url = request.url!
            switch url.path {
            case "/v1/spaces":
                return (200, #"{"spaces":[{"name":"spaces/D","spaceType":"DIRECT_MESSAGE","lastActiveTime":"\#(ws.dmActive)"},{"name":"spaces/G","displayName":"Équipe","spaceType":"SPACE","lastActiveTime":"2026-10-14T08:00:00Z"},{"name":"spaces/OLD","displayName":"Ancien","spaceType":"SPACE","lastActiveTime":"2026-09-01T08:00:00Z"},{"name":"spaces/M","displayName":"Bruit","spaceType":"SPACE","lastActiveTime":"\#(ws.mutedActive)"},{"name":"spaces/F","displayName":"Annonces","spaceType":"SPACE","lastActiveTime":"\#(ws.forYouActive)"}]}"#, [:])
            case "/v1/users/me/spaces/M/spaceReadState", "/v1/users/me/spaces/F/spaceReadState":
                return (200, #"{"lastReadTime":"2026-10-14T07:00:00Z"}"#, [:])
            case "/v1/users/me/spaces/D/spaceNotificationSetting":
                return (200, #"{"notificationSetting":"ALL","muteSetting":"UNMUTED"}"#, [:])
            case "/v1/users/me/spaces/M/spaceNotificationSetting":
                return (200, #"{"notificationSetting":"ALL","muteSetting":"MUTED"}"#, [:])
            case "/v1/users/me/spaces/F/spaceNotificationSetting":
                return (200, #"{"notificationSetting":"FOR_YOU","muteSetting":"UNMUTED"}"#, [:])
            case "/v1/spaces/M/messages":
                XCTFail("muted space messages must not be fetched")
                return (200, "{}", [:])
            case "/v1/spaces/F/messages":
                return (200, #"{"messages":[{"name":"spaces/F/messages/\#(ws.forYouCount)","sender":{"name":"users/9"},"text":"Info","createTime":"\#(ws.forYouActive)"}]}"#, [:])
            case "/v1/users/me/spaces/D/spaceReadState":
                return (200, #"{"lastReadTime":"\#(ws.dmRead)"}"#, [:])
            case "/v1/users/me/spaces/G/spaceReadState":
                return (200, #"{"lastReadTime":"2026-10-14T08:00:00Z"}"#, [:])
            case "/v1/spaces/D/messages":
                XCTAssertTrue(url.query?.contains("filter=createTime") ?? false)
                return (200, #"{"messages":[\#(ws.dmMessages.reversed().joined(separator: ","))]}"#, [:])
            case "/v1/people:batchGet":
                ws.peopleCalls += 1
                return (200, #"{"responses":[{"requestedResourceName":"people/9","person":{"names":[{"displayName":"Alice Martin"}]}}]}"#, [:])
            default:
                XCTFail("unexpected \(url.path)")
                return (404, "{}", [:])
            }
        }
        let api = GoogleAPI(auth: session(http, scopes: GoogleScope.chatRead), http: http)
        let monitor = ChatUnreadMonitor(service: GoogleChatService(api: api), people: GooglePeopleService(api: api))
        let now = ISO8601DateFormatter().date(from: "2026-10-14T10:00:30Z")!

        let first = try await monitor.sync(now: now)
        XCTAssertEqual(first.unread.map(\.id), ["spaces/D", "spaces/F"], "read, old and muted spaces are not unread")
        XCTAssertEqual(first.unread.last?.notifies, false, "\"For you\" conversations are listed silently")
        XCTAssertEqual(first.unread.first?.title, "Alice Martin", "DM named after its sender")
        XCTAssertEqual(first.unread.first?.preview, "Salut")
        XCTAssertTrue(first.fresh.isEmpty, "launch never replays old messages")
        XCTAssertFalse(http.paths().contains("/v1/users/me/spaces/OLD/spaceReadState"), "inactive spaces not scanned")

        // A new message from Alice: reported once as fresh.
        ws.dmActive = "2026-10-14T10:05:00Z"
        ws.dmMessages.append(#"{"name":"spaces/D/messages/2","sender":{"name":"users/9"},"text":"Tu es là ?","createTime":"2026-10-14T10:05:00Z"}"#)
        ws.mutedActive = "2026-10-14T10:04:00Z"
        ws.forYouActive = "2026-10-14T10:04:30Z"
        ws.forYouCount = 2
        let second = try await monitor.sync(now: now.addingTimeInterval(300))
        XCTAssertEqual(second.fresh.map(\.id), ["spaces/D"], "no pop-up for muted or \"For you\" conversations")
        XCTAssertEqual(second.unread.first?.messages.count, 2)
        XCTAssertEqual(ws.peopleCalls, 1, "names are cached")
        let quiet = try await monitor.sync(now: now.addingTimeInterval(305))
        XCTAssertTrue(quiet.fresh.isEmpty)

        // The user answers (from any client): the read state moves, nothing is unread or fresh.
        ws.dmActive = "2026-10-14T10:06:00Z"
        ws.dmRead = "2026-10-14T10:06:00Z"
        let answered = try await monitor.sync(now: now.addingTimeInterval(360))
        XCTAssertEqual(answered.unread.map(\.id), ["spaces/F"], "the answered DM is read")
        XCTAssertTrue(answered.fresh.isEmpty, "the user's own message is never a notification")
    }

    func testPeopleNamesParsing() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"responses":[{"requestedResourceName":"people/1","person":{"names":[{"displayName":"Alice"}]}},
                      {"requestedResourceName":"people/2","status":{"code":404}}]}
        """#.utf8))
        XCTAssertEqual(GooglePeopleService.parseNames(json), ["users/1": "Alice"])
    }

    func testChatUnsupportedAccount() async {
        let http = FakeHTTP { _ in (403, #"{"error":{"code":403,"message":"Google Chat app not found. To create a Chat app, you must turn on the Chat API","status":"NOT_FOUND"}}"#, [:]) }
        let chat = GoogleChatService(api: GoogleAPI(auth: session(http, scopes: GoogleScope.chatRead), http: http))
        do {
            _ = try await chat.listSpaces()
            XCTFail("expected unsupported")
        } catch let GoogleAPIError.unsupported(reason) {
            XCTAssertTrue(reason.contains("Chat"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCalendarParsing() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"items":[{"id":"1","summary":"Daily","start":{"dateTime":"2026-10-13T09:00:00+02:00"},"end":{"dateTime":"2026-10-13T09:15:00+02:00"},"hangoutLink":"https://meet.google.com/aaa-bbbb-ccc","iCalUID":"x@google.com"},
                  {"id":"2","summary":"Off","start":{"date":"2026-10-14"},"end":{"date":"2026-10-15"}},
                  {"id":"3","status":"cancelled","start":{"date":"2026-10-14"},"end":{"date":"2026-10-15"}}]}
        """#.utf8))
        let events = GoogleCalendarService.parseEvents(json)
        XCTAssertEqual(events.map(\.id), ["1", "2"])
        XCTAssertEqual(events[0].meetingURL?.host, "meet.google.com")
        XCTAssertEqual(events[0].iCalUID, "x@google.com")
        XCTAssertTrue(events[1].isAllDay)
    }
}
