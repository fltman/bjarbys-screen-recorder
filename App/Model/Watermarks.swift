import Foundation
import CryptoKit

/// Logotyperna i appens stödmapp, namngivna efter innehållet (samma bild sparas en gång).
enum Watermarks {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bjarbys skärminspelare/Logotyper", isDirectory: true)
    }

    static func store(_ source: URL) -> URL? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        let name = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension.lowercased())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        return url
    }
}
