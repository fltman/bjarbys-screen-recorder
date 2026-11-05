import Foundation
import CryptoKit
import Network
import os

/// Inloggning hos YouTube (Google) och Dropbox med OAuth 2 och PKCE — utan någon server i
/// mitten. Appen har inga egna nycklar: användaren registrerar en egen app hos tjänsten och
/// anger klient-id (som S3-hinken). Google skickar tillbaka koden till en tillfällig mottagare på
/// `http://127.0.0.1:<port>` (tillåtet för skrivbordsappar); Dropbox kräver exakt registrerade
/// adresser, så där klistrar användaren in koden som Dropbox visar.
public struct OAuthProvider: Sendable {
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scope: String
    public var clientID: String
    /// Googles skrivbordsklienter har en "hemlighet" som inte är hemlig (den följer med appen).
    public var clientSecret: String?
    public var extraParameters: [String: String]
    /// Koden kommer till en lokal mottagare (Google) eller klistras in (Dropbox).
    public var usesLoopback: Bool

    public static func youtube(clientID: String, clientSecret: String?, base: URL? = nil) -> OAuthProvider {
        OAuthProvider(authorizeURL: base.map { $0.appendingPathComponent("o/oauth2/v2/auth") } ?? URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                      tokenURL: base.map { $0.appendingPathComponent("token") } ?? URL(string: "https://oauth2.googleapis.com/token")!,
                      scope: "https://www.googleapis.com/auth/youtube.upload",
                      clientID: clientID, clientSecret: clientSecret,
                      extraParameters: ["access_type": "offline", "prompt": "consent"], usesLoopback: true)
    }

    public static func dropbox(appKey: String, base: URL? = nil) -> OAuthProvider {
        OAuthProvider(authorizeURL: base.map { $0.appendingPathComponent("oauth2/authorize") } ?? URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                      tokenURL: base.map { $0.appendingPathComponent("oauth2/token") } ?? URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                      scope: "files.content.write sharing.write",
                      clientID: appKey, clientSecret: nil,
                      extraParameters: ["token_access_type": "offline"], usesLoopback: false)
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = c.value(.accessToken, "")
        refreshToken = c.value(.refreshToken, nil)
        expiresAt = c.value(.expiresAt, Date.distantPast)
    }

    public var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-60) }
}

public enum OAuthError: LocalizedError {
    case denied(String)
    case badResponse(String)
    case timedOut
    public var errorDescription: String? {
        switch self {
        case .denied(let s): String(localized: "Inloggningen nekades: \(s)")
        case .badResponse(let s): String(localized: "Oväntat svar från tjänsten: \(s)")
        case .timedOut: String(localized: "Inloggningen tog för lång tid.")
        }
    }
}

public enum OAuth {
    /// PKCE: en slumpad nyckel och dess SHA-256 (base64url).
    public static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Adressen inloggningen börjar på.
    public static func authorizeURL(_ p: OAuthProvider, challenge: String, state: String, redirect: String?) -> URL {
        var c = URLComponents(url: p.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "client_id", value: p.clientID), URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "state", value: state), URLQueryItem(name: "scope", value: p.scope)]
        if let redirect { items.append(URLQueryItem(name: "redirect_uri", value: redirect)) }
        items += p.extraParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items
        return c.url!
    }

    /// Hela inloggningen med lokal mottagare (Google): öppnar adressen med `open` och väntar på
    /// att webbläsaren skickas tillbaka (högst 5 min).
    public static func authorizeWithLoopback(_ p: OAuthProvider, open: @escaping @Sendable (URL) -> Void) async throws -> OAuthTokens {
        let (verifier, challenge) = pkce()
        let state = UUID().uuidString
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(receiver.port)/callback"
        open(authorizeURL(p, challenge: challenge, state: state, redirect: redirect))
        let query = try await receiver.waitForCallback(timeout: 300)
        if let error = query["error"] { throw OAuthError.denied(error) }
        guard query["state"] == state, let code = query["code"] else { throw OAuthError.badResponse("state/code") }
        return try await exchange(p, code: code, verifier: verifier, redirect: redirect)
    }

    /// Byter en kod mot nycklar.
    public static func exchange(_ p: OAuthProvider, code: String, verifier: String, redirect: String?) async throws -> OAuthTokens {
        var form = ["grant_type": "authorization_code", "code": code, "client_id": p.clientID, "code_verifier": verifier]
        if let redirect { form["redirect_uri"] = redirect }
        if let s = p.clientSecret, !s.isEmpty { form["client_secret"] = s }
        return try await token(p, form: form, previousRefresh: nil)
    }

    /// Nya åtkomstnycklar med förnyelsenyckeln.
    public static func refresh(_ p: OAuthProvider, refreshToken: String) async throws -> OAuthTokens {
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": p.clientID]
        if let s = p.clientSecret, !s.isEmpty { form["client_secret"] = s }
        return try await token(p, form: form, previousRefresh: refreshToken)
    }

    static func token(_ p: OAuthProvider, form: [String: String], previousRefresh: String?) async throws -> OAuthTokens {
        var request = URLRequest(url: p.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            throw OAuthError.badResponse((json["error_description"] as? String) ?? (json["error"] as? String)
                                         ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        let expires = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: (json["refresh_token"] as? String) ?? previousRefresh,
                           expiresAt: Date().addingTimeInterval(expires))
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}

/// En tillfällig HTTP-mottagare på 127.0.0.1 för inloggningens återkomst (en enda förfrågan).
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "skarminspelare.oauth")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackReceiver {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let r = LoopbackReceiver(listener: listener)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func once() -> Bool { resumed.withLock { done in defer { done = true }; return !done } }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    r.port = listener.port?.rawValue ?? 0
                    if once() { c.resume() }
                case .failed(let e):
                    if once() { c.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { conn in r.handle(conn) }
            listener.start(queue: r.queue)
        }
        return r
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let c = URLComponents(string: String(parts[1])), c.path == "/callback" {
                for item in c.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let ok = !query.isEmpty
            let body = ok ? "<html><body style=\"font-family:-apple-system;padding:3em\"><h2>Klart</h2><p>Du kan stänga fönstret och gå tillbaka till Bjarbys skärminspelare.</p></body></html>"
                          : "<html><body>Fel adress.</body></html>"
            let response = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(body.utf8).count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            guard ok else { return }
            self.lock.withLock {
                if let c = self.continuation { self.continuation = nil; c.resume(returning: query) } else { self.received = query }
            }
        }
    }

    func waitForCallback(timeout: Double) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.lock.withLock {
                        if let r = self.received { c.resume(returning: r) } else { self.continuation = c }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OAuthError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            self.lock.withLock { self.continuation?.resume(throwing: CancellationError()); self.continuation = nil }
            return result
        }
    }
}
