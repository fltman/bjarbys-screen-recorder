import Foundation

public enum CloudUploadError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let s): String(localized: "Uppladdningen misslyckades: \(s)") }
    }
}

/// Förlopp ur URLSession, för alla uppladdningar.
final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    let base: Double, share: Double
    init(base: Double = 0, share: Double = 1, _ report: @escaping @Sendable (Double) -> Void) {
        self.base = base; self.share = share; self.report = report
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(base + share * Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

/// Uppladdning till YouTube med "resumable upload" (Data API v3): först metadata, sedan filen
/// till adressen tjänsten svarar med. Filmen blir **privat** som standard — inget publiceras av
/// misstag; ändra synligheten i YouTube Studio.
public enum YouTubeUploader {
    public enum Privacy: String, CaseIterable, Sendable { case `private`, unlisted, `public` }

    /// Laddar upp och returnerar filmens adress (https://youtu.be/<id>).
    public static func upload(_ file: URL, title: String, description: String, privacy: Privacy = .private,
                              accessToken: String, base: URL? = nil,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        var c = URLComponents(url: (base ?? URL(string: "https://www.googleapis.com")!).appendingPathComponent("upload/youtube/v3/videos"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"), URLQueryItem(name: "part", value: "snippet,status")]
        var start = URLRequest(url: c.url!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        start.setValue(file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        // YouTube tar högst 100 tecken i titeln och 5000 i beskrivningen.
        start.httpBody = try JSONSerialization.data(withJSONObject: [
            "snippet": ["title": String(title.prefix(100)), "description": String(description.prefix(5000)), "categoryId": "28"],
            "status": ["privacyStatus": privacy.rawValue, "selfDeclaredMadeForKids": false],
        ])
        let (startData, startResponse) = try await URLSession.shared.data(for: start)
        guard let http = startResponse as? HTTPURLResponse, http.statusCode == 200,
              let location = http.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw CloudUploadError.failed(String(decoding: startData.prefix(300), as: UTF8.self))
        }
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        put.setValue(file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: UploadProgress(progress))
        guard let r = response as? HTTPURLResponse, (200...201).contains(r.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = json["id"] as? String else {
            throw CloudUploadError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        progress(1)
        return URL(string: "https://youtu.be/\(id)")!
    }
}

/// Uppladdning till Dropbox (API v2): en förfrågan för små filer, annars i bitar med en
/// uppladdningssession. Filen hamnar i `folder` (appens mapp om appen är begränsad till en
/// mapp), och en delningslänk skapas.
public enum DropboxUploader {
    /// Större filer än så går i bitar (Dropbox tar högst 150 MB i en förfrågan).
    public static var chunkSize = 64 * 1024 * 1024

    public static func upload(_ file: URL, folder: String, accessToken: String,
                              contentBase: URL? = nil, apiBase: URL? = nil,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let content = contentBase ?? URL(string: "https://content.dropboxapi.com")!
        let api = apiBase ?? URL(string: "https://api.dropboxapi.com")!
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let folder = folder.hasPrefix("/") ? folder : "/" + folder
        let path = (folder.hasSuffix("/") ? folder : folder + "/") + file.lastPathComponent
        let commit: [String: Any] = ["path": path, "mode": "add", "autorename": true, "mute": false]

        var finalPath = path
        if size <= chunkSize {
            var r = request(content.appendingPathComponent("2/files/upload"), token: accessToken, arg: commit)
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.upload(for: r, fromFile: file, delegate: UploadProgress(progress))
            finalPath = try pathFrom(data, response)
        } else {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            // Starta en session med första biten, lägg till resten, avsluta med sökvägen.
            var offset = 0
            var sessionID = ""
            while offset < size {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                let last = offset + chunk.count >= size
                let url: URL, arg: [String: Any]
                if offset == 0 {
                    url = content.appendingPathComponent("2/files/upload_session/start"); arg = ["close": false]
                } else if !last {
                    url = content.appendingPathComponent("2/files/upload_session/append_v2")
                    arg = ["cursor": ["session_id": sessionID, "offset": offset], "close": false]
                } else {
                    url = content.appendingPathComponent("2/files/upload_session/finish")
                    arg = ["cursor": ["session_id": sessionID, "offset": offset], "commit": commit]
                }
                var r = request(url, token: accessToken, arg: arg)
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let share = Double(chunk.count) / Double(max(size, 1))
                let (data, response) = try await URLSession.shared.upload(
                    for: r, from: chunk, delegate: UploadProgress(base: Double(offset) / Double(max(size, 1)), share: share, progress))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw CloudUploadError.failed(String(decoding: data.prefix(300), as: UTF8.self))
                }
                if offset == 0 {
                    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let id = json["session_id"] as? String else { throw CloudUploadError.failed("session_id") }
                    sessionID = id
                    if last {
                        // En fil som precis ryms i en bit: avsluta utan data.
                        var fin = request(content.appendingPathComponent("2/files/upload_session/finish"), token: accessToken,
                                          arg: ["cursor": ["session_id": id, "offset": chunk.count], "commit": commit])
                        fin.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        let (d, resp) = try await URLSession.shared.upload(for: fin, from: Data())
                        finalPath = try pathFrom(d, resp)
                    }
                } else if last {
                    finalPath = try pathFrom(data, response)
                }
                offset += chunk.count
            }
        }

        // Delningslänken (eller den som redan finns).
        var link = URLRequest(url: api.appendingPathComponent("2/sharing/create_shared_link_with_settings"))
        link.httpMethod = "POST"
        link.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        link.setValue("application/json", forHTTPHeaderField: "Content-Type")
        link.httpBody = try JSONSerialization.data(withJSONObject: ["path": finalPath])
        let (data, response) = try await URLSession.shared.data(for: link)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let url = (json?["url"] as? String).flatMap(URL.init(string:)) { progress(1); return url }
        if (response as? HTTPURLResponse)?.statusCode == 409,
           let error = json?["error"] as? [String: Any], let existing = error["shared_link_already_exists"] as? [String: Any],
           let metadata = existing["metadata"] as? [String: Any], let url = (metadata["url"] as? String).flatMap(URL.init(string:)) {
            progress(1); return url
        }
        throw CloudUploadError.failed(String(decoding: data.prefix(300), as: UTF8.self))
    }

    private static func request(_ url: URL, token: String, arg: [String: Any]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Dropbox-API-Arg är JSON i ett huvud: bara ASCII (å ä ö som \u-sekvenser).
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: arg)) ?? Data(), as: UTF8.self)
        r.setValue(asciiJSON(json), forHTTPHeaderField: "Dropbox-API-Arg")
        return r
    }

    static func asciiJSON(_ s: String) -> String {
        var out = ""
        for u in s.utf16 {
            if u < 0x80 { out.append(Character(Unicode.Scalar(u)!)) } else { out += String(format: "\\u%04x", u) }
        }
        return out
    }

    private static func pathFrom(_ data: Data, _ response: URLResponse) throws -> String {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = (json["path_display"] as? String) ?? (json["path_lower"] as? String) else {
            throw CloudUploadError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return path
    }
}
