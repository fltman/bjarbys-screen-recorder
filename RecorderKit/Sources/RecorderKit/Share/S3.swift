import Foundation
import CryptoKit

/// Delning till egen S3-kompatibel lagring (AWS S3, Cloudflare R2, MinIO, Backblaze B2 …):
/// filen laddas upp och den publika länken kommer tillbaka. Inget konto hos oss, ingen tjänst
/// emellan — bara den egna hinken.
public struct S3Config: Codable, Equatable, Sendable {
    /// T.ex. `https://<konto>.r2.cloudflarestorage.com` eller `https://s3.eu-north-1.amazonaws.com`.
    public var endpoint: String
    public var bucket: String
    /// `auto` för R2, annars t.ex. `eu-north-1`.
    public var region: String
    public var accessKeyID: String
    /// Där filerna syns publikt, t.ex. `https://media.exempel.se` (R2: egen domän eller r2.dev).
    public var publicBaseURL: String
    /// Mapp i hinken, t.ex. `skarminspelare`.
    public var prefix: String

    public init(endpoint: String = "", bucket: String = "", region: String = "auto", accessKeyID: String = "",
                publicBaseURL: String = "", prefix: String = "skarminspelare") {
        self.endpoint = endpoint; self.bucket = bucket; self.region = region
        self.accessKeyID = accessKeyID; self.publicBaseURL = publicBaseURL; self.prefix = prefix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = S3Config()
        endpoint = c.value(.endpoint, d.endpoint); bucket = c.value(.bucket, d.bucket)
        region = c.value(.region, d.region); accessKeyID = c.value(.accessKeyID, d.accessKeyID)
        publicBaseURL = c.value(.publicBaseURL, d.publicBaseURL); prefix = c.value(.prefix, d.prefix)
    }

    public var isComplete: Bool {
        !endpoint.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty && !publicBaseURL.isEmpty
    }

    /// Objektets adress för uppladdning (sökvägsstil: `endpoint/hink/nyckel`, som R2 och MinIO vill ha).
    public func uploadURL(key: String) -> URL? {
        URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + SigV4.encodePath(bucket + "/" + key))
    }

    public func publicURL(key: String) -> URL? {
        URL(string: publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + SigV4.encodePath(key))
    }
}

/// AWS Signature Version 4. Provad mot AWS publicerade exempel (IAM ListUsers och S3 GET Object).
public enum SigV4 {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// URI-kodning enligt SigV4: allt utom A–Z a–z 0–9 - . _ ~ kodas; `/` behålls i sökvägar.
    public static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    public static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func amzDate(_ date: Date) -> (full: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let full = f.string(from: date)
        return (full, String(full.prefix(8)))
    }

    /// Den kanoniska begäran. `path` redan kodad; `query` okodade par.
    public static func canonicalRequest(method: String, path: String, query: [(String, String)],
                                        headers: [String: String], payloadHash: String) -> (request: String, signedHeaders: String) {
        let encoded: [(String, String)] = query.map { (encode($0.0), encode($0.1)) }
        let sortedPairs = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let q = sortedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let lowered = headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = lowered.map { "\($0.0):\($0.1)\n" }.joined()
        let signed = lowered.map(\.0).joined(separator: ";")
        let request = [method, path.isEmpty ? "/" : path, q, canonicalHeaders, signed, payloadHash].joined(separator: "\n")
        return (request, signed)
    }

    public static func signingKey(secret: String, day: String, region: String, service: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
        }
        let k = hmac(SymmetricKey(data: Data(("AWS4" + secret).utf8)), day)
        return hmac(hmac(hmac(k, region), service), "aws4_request")
    }

    /// Signerar en begäran. Returnerar alla rubriker som ska skickas (inklusive Authorization).
    public static func sign(method: String, url: URL, headers: [String: String], payloadHash: String,
                            accessKey: String, secret: String, region: String, service: String,
                            date: Date) -> [String: String] {
        let (full, day) = amzDate(date)
        var all = headers
        all["host"] = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        all["x-amz-date"] = full
        if service == "s3" { all["x-amz-content-sha256"] = payloadHash }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        let (request, signed) = canonicalRequest(method: method, path: components?.percentEncodedPath ?? "/",
                                                 query: query, headers: all, payloadHash: payloadHash)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", full, scope, sha256(Data(request.utf8))].joined(separator: "\n")
        let key = signingKey(secret: secret, day: day, region: region, service: service)
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        all["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
        return all
    }
}

public enum S3Uploader {
    public enum UploadError: LocalizedError {
        case incomplete, http(Int, String)
        public var errorDescription: String? {
            switch self {
            case .incomplete: String(localized: "Delningen är inte inställd (adress, hink, nyckel och publik adress behövs).")
            case .http(let code, let body): String(localized: "Uppladdningen misslyckades (\(code)): \(body)")
            }
        }
    }

    /// Nyckeln (sökvägen i hinken) för en fil: `prefix/ÅÅÅÅ-MM-DD-namn-slump.ext`.
    public static func key(for file: URL, prefix: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let base = file.deletingPathExtension().lastPathComponent.folding(options: [.diacriticInsensitive], locale: nil)
            .lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(base).split(separator: "-").joined(separator: "-").prefix(40)
        let random = UUID().uuidString.prefix(6).lowercased()
        let name = "\(f.string(from: date))-\(slug)-\(random).\(file.pathExtension.lowercased())"
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return p.isEmpty ? name : "\(p)/\(name)"
    }

    /// Laddar upp filen och returnerar den publika länken.
    public static func upload(_ file: URL, config: S3Config, secret: String,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard config.isComplete, !secret.isEmpty else { throw UploadError.incomplete }
        let key = key(for: file, prefix: config.prefix)
        guard let url = config.uploadURL(key: key), let publicURL = config.publicURL(key: key) else { throw UploadError.incomplete }
        let type: String = switch file.pathExtension.lowercased() {
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "gif": "image/gif"
        case "png": "image/png"
        case "zip": "application/zip"
        case "srt": "application/x-subrip"
        default: "application/octet-stream"
        }
        // UNSIGNED-PAYLOAD: över https behöver en stor film inte hashas först (S3 och R2 godtar det).
        let headers = SigV4.sign(method: "PUT", url: url, headers: ["content-type": type], payloadHash: "UNSIGNED-PAYLOAD",
                                 accessKey: config.accessKeyID, secret: secret,
                                 region: config.region.isEmpty ? "auto" : config.region, service: "s3", date: Date())
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in headers where k != "host" { request.setValue(v, forHTTPHeaderField: k) }
        let delegate = ProgressDelegate(progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw UploadError.http(code, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        progress(1)
        return publicURL
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
        }
    }
}
