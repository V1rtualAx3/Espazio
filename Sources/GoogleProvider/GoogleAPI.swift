import EspazioCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GoogleAPIError: Error, Equatable, Sendable {
    case notConnected
    case reauthorizationRequired
    /// The granted scopes do not cover the call (progressive consent needed).
    case insufficientScope
    /// The API refuses this account (e.g. Google Chat on a consumer account, admin policy).
    case unsupported(String)
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case http(Int)
    case invalidResponse
    case network(String)

    /// User-facing French message, never containing tokens or content.
    public var message: String {
        switch self {
        case .notConnected: return "Compte Google non connecté."
        case .reauthorizationRequired: return "Autorisation expirée ou révoquée."
        case .insufficientScope: return "Autorisation supplémentaire nécessaire."
        case let .unsupported(reason): return reason
        case .notFound: return "Ressource introuvable."
        case .rateLimited: return "Quota Google atteint, nouvel essai plus tard."
        case let .server(code): return "Erreur serveur Google (\(code))."
        case let .http(code): return "Erreur HTTP \(code)."
        case .invalidResponse: return "Réponse inattendue de Google."
        case .network: return "Réseau indisponible."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network: return true
        default: return false
        }
    }
}

/// Authorized JSON calls with one forced refresh on 401 and error classification.
public struct GoogleAPI: Sendable {
    let auth: GoogleAuthSession
    let http: HTTPClient

    public init(auth: GoogleAuthSession, http: HTTPClient) {
        self.auth = auth
        self.http = http
    }

    public func get(_ url: URL) async throws -> Data {
        try await send(method: "GET", url: url, body: nil)
    }

    public func post(_ url: URL, json: JSONValue) async throws -> Data {
        try await send(method: "POST", url: url, body: Data(json.compactString().utf8))
    }

    func send(method: String, url: URL, body: Data?) async throws -> Data {
        var attempt = 0
        while true {
            let token: String
            do {
                token = try await auth.accessToken(forceRefresh: attempt > 0)
            } catch OAuthError.invalidGrant {
                throw GoogleAPIError.reauthorizationRequired
            } catch OAuthError.notConfigured {
                throw GoogleAPIError.notConnected
            } catch {
                throw GoogleAPIError.network(String(describing: type(of: error)))
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.send(request)
            } catch {
                throw GoogleAPIError.network((error as? URLError)?.code.rawValue.description ?? "unknown")
            }
            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                continue
            }
            if (200..<300).contains(response.statusCode) { return data }
            throw Self.classify(status: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
    }

    static func classify(status: Int, data: Data, retryAfter: String?) -> GoogleAPIError {
        let error = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]
        let reasons = (error?["errors"]?.arrayValue ?? []).compactMap { $0["reason"]?.stringValue }
        let statusText = error?["status"]?.stringValue ?? ""
        let message = error?["message"]?.stringValue ?? ""
        let rateReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded"]
        switch status {
        case 401:
            return .reauthorizationRequired
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        case 403:
            if reasons.contains(where: rateReasons.contains) || statusText == "RESOURCE_EXHAUSTED" {
                return .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
            }
            if reasons.contains("insufficientPermissions") || message.localizedCaseInsensitiveContains("insufficient authentication scopes") {
                return .insufficientScope
            }
            return .unsupported(message.isEmpty ? "Accès refusé par Google pour ce compte." : Redactor.truncate(Redactor.redact(message), limit: 160))
        case 404:
            return .notFound
        case 500...599:
            return .server(status)
        default:
            return .http(status)
        }
    }
}
