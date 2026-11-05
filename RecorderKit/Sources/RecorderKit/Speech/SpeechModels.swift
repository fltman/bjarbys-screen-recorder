import Foundation
import CryptoKit

/// Talmodellerna appen kan ladda ned själv, för den som inte har whisper.cpp: verktygen följer
/// med appen (`Contents/Helpers`) och modellerna hamnar i Application Support. Storlek och
/// SHA-256 är uppmätta på de filer som whisper.cpp-mappen på utvecklardatorn använder
/// (2026-11-05); en nedladdning som inte stämmer kastas.
public enum SpeechModels {
    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String { file }
        /// Filnamnet i modellmappen (samma namn som `WhisperSetup.preferredModel` letar efter).
        public let file: String
        public let title: String
        public let detail: String
        public let size: Int64
        public let sha256: String
        public let url: URL
    }

    /// Taldetekteringen (Silero), som transkriberingen alltid behöver.
    public static let vad = Entry(
        file: "ggml-silero-v5.1.2.bin", title: "Silero (taldetektering)", detail: "",
        size: 885_098, sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!)

    public static let kbMedium = Entry(
        file: "kb_whisper_ggml_medium.bin", title: "KB-Whisper medium",
        detail: String(localized: "Svenska, bäst. Kungliga bibliotekets modell."),
        size: 1_533_763_076, sha256: "1b7842bc1c3f79fb3bf043a0a3590961d625a49ef3ccbdceb00e738c5dd8b015",
        url: URL(string: "https://huggingface.co/KBLab/kb-whisper-medium/resolve/main/ggml-model.bin")!)

    public static let kbSmall = Entry(
        file: "kb_whisper_ggml_small.bin", title: "KB-Whisper small",
        detail: String(localized: "Svenska, snabbare och mindre."),
        size: 487_601_984, sha256: "de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6",
        url: URL(string: "https://huggingface.co/KBLab/kb-whisper-small/resolve/main/ggml-model.bin")!)

    public static let multilingual = Entry(
        file: "ggml-medium.bin", title: "Whisper medium",
        detail: String(localized: "Flerspråkig. Översätter talet till engelska."),
        size: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!)

    /// Modellerna att välja bland (taldetekteringen följer med den första).
    public static let catalog: [Entry] = [kbMedium, kbSmall, multilingual]

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bjarbys skärminspelare/Modeller", isDirectory: true)
    }

    public static func isInstalled(_ e: Entry, in dir: URL = directory) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(e.file).path)[.size] as? NSNumber)?.int64Value
        return size == e.size
    }

    public enum DownloadError: LocalizedError {
        case http(Int)
        case mismatch(String)
        public var errorDescription: String? {
            switch self {
            case .http(let code): String(localized: "Nedladdningen misslyckades (HTTP \(code)).")
            case .mismatch(let file): String(localized: "\(file) stämmer inte med kontrollsumman och sparades inte.")
            }
        }
    }

    /// Laddar ned modellen till `dir`, kontrollerar storlek och SHA-256 och lägger den på plats.
    /// `progress` får 0–1. Avbryts tasken avbryts nedladdningen.
    public static func download(_ e: Entry, to dir: URL = directory,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = try await Downloader(expected: e.size, progress: progress).fetch(e.url)
        defer { try? FileManager.default.removeItem(at: temp) }
        let size = (try FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == e.size, try sha256(of: temp) == e.sha256 else { throw DownloadError.mismatch(e.file) }
        let target = dir.appendingPathComponent(e.file)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        progress(1)
    }

    /// SHA-256 av en fil, läst i bitar (modellerna är upp till 1,5 GB).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// En nedladdning med förlopp: URLSessions nedladdningsuppgift med en egen delegat (de asynkrona
/// genvägarna rapporterar inget förlopp för nedladdningar).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected; self.progress = progress
    }

    func fetch(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.withLock { continuation = c }
                let t = session.downloadTask(with: url)
                lock.withLock { task = t }
                t.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    private func finish(_ r: Result<URL, Error>) {
        lock.withLock {
            if let c = continuation { continuation = nil; c.resume(with: r) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { progress(min(0.99, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Filen försvinner när metoden returnerar: flytta den först.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(SpeechModels.DownloadError.http(http.statusCode))); return
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("skarminspelare-modell-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: keep); finish(.success(keep)) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
