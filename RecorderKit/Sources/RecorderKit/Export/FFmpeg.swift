import Foundation

/// En extern ffmpeg, för det Apples ramverk inte kan: AV1-kodning (VideoToolbox på M5 har ingen
/// AV1-kodare, uppmätt). Appen följer med utan ffmpeg; finns den (Homebrew) visas AV1-förvalet.
public enum FFmpeg {
    /// Var ffmpeg finns, eller nil. Letar på Homebrews platser och i PATH.
    public static let executable: URL? = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", NSHomeDirectory() + "/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in dirs {
            let url = URL(fileURLWithPath: d).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }()

    /// Tar reda på ffmpeg och dess AV1-kodare i bakgrunden, så att exportfönstret inte väntar.
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = av1Encoder }
    }

    /// AV1-kodarna i den ordning de föredras (snabbast först).
    static let av1Preference = ["libsvtav1", "librav1e", "libaom-av1"]

    /// Den bästa AV1-kodaren ffmpeg har, eller nil (ingen ffmpeg, eller ingen AV1-kodare i den).
    /// Väntar med en semafor, inte `waitUntilExit()`: den snurrar körslingan, och på huvudtråden
    /// hann SwiftUI då rita om exportfönstret och fråga efter värdet igen mitt i initieringen
    /// (krasch i `dispatch_once`, 5 av 7 gånger i `--prov-vyer`). Appen frågar redan vid start,
    /// i bakgrunden (`warmUp`).
    public static let av1Encoder: String? = {
        guard let executable else { return nil }
        let p = Process()
        p.executableURL = executable
        p.arguments = ["-hide_banner", "-encoders"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        let text = String(decoding: data, as: UTF8.self)
        let names = Set(text.split(separator: "\n").compactMap { line -> String? in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            return cols.count >= 2 && cols[0].hasPrefix("V") ? String(cols[1]) : nil
        })
        return av1Preference.first { names.contains($0) }
    }()

    /// Kodarens inställningar: snabbt (realtidsläge där det finns) och kvalitet via CRF/QP.
    /// `quality` 0 = normal, negativt = mindre fil, positivt = bättre.
    static func av1Arguments(_ encoder: String, quality: Exporter.Quality) -> [String] {
        let shift = quality == .small ? 6 : quality == .high ? -6 : 0
        switch encoder {
        case "libsvtav1": return ["-c:v", "libsvtav1", "-preset", "8", "-crf", "\(32 + shift)"]
        case "librav1e": return ["-c:v", "librav1e", "-speed", "8", "-qp", "\(100 + shift * 4)"]
        default: return ["-c:v", "libaom-av1", "-usage", "realtime", "-cpu-used", "8", "-row-mt", "1",
                         "-crf", "\(34 + shift)", "-b:v", "0"]
        }
    }

    /// Kapitlen i ffmpegs metadataformat (`;FFMETADATA1`), tider i ms.
    static func chapterMetadata(_ chapters: [(start: Double, end: Double, title: String)]) -> String {
        func escape(_ s: String) -> String {
            var out = ""
            for c in s {
                if "=;#\\\n".contains(c) { out.append("\\") }
                out.append(c)
            }
            return out
        }
        var lines = [";FFMETADATA1"]
        for c in chapters {
            lines += ["[CHAPTER]", "TIMEBASE=1/1000", "START=\(Int((c.start * 1000).rounded()))",
                      "END=\(Int((c.end * 1000).rounded()))", "title=\(escape(c.title))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
