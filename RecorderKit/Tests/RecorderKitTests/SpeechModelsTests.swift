import Testing
import Foundation
@testable import RecorderKit

@Suite struct SpeechModelsTests {
    func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("modeller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func downloadsVerifiesAndRejects() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("källa.bin")
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        try data.write(to: source)
        let sha = try SpeechModels.sha256(of: source)
        #expect(sha.count == 64)
        let target = dir.appendingPathComponent("modeller", isDirectory: true)
        let good = SpeechModels.Entry(file: "prov.bin", title: "Prov", detail: "", size: Int64(data.count), sha256: sha, url: source)
        try await SpeechModels.download(good, to: target)
        #expect(SpeechModels.isInstalled(good, in: target))
        #expect(try Data(contentsOf: target.appendingPathComponent("prov.bin")) == data)

        // Fel kontrollsumma: kastas och lämnar ingen fil efter sig.
        let bad = SpeechModels.Entry(file: "fel.bin", title: "Fel", detail: "", size: Int64(data.count),
                                     sha256: String(repeating: "0", count: 64), url: source)
        await #expect(throws: SpeechModels.DownloadError.self) { try await SpeechModels.download(bad, to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("fel.bin").path))
    }

    @Test func catalogMatchesWhatTheAppLooksFor() {
        // Filnamnen ska vara de som preferredModel/translationModel väljer bland.
        let names = SpeechModels.catalog.map(\.file)
        #expect(WhisperSetup.preferredModel(among: names, language: "sv") == "kb_whisper_ggml_medium.bin")
        #expect(WhisperSetup.translationModel(among: names) == "ggml-medium.bin")
        #expect(SpeechModels.vad.file == WhisperSetup.vadModel)
        #expect(SpeechModels.catalog.allSatisfy { $0.sha256.count == 64 && $0.url.scheme == "https" })
    }

    @Test func bundledSetupUsesTheAppsFolders() {
        let s = WhisperSetup(root: SpeechModels.directory, model: "kb_whisper_ggml_small.bin", language: "sv", bundled: true)
        #expect(s.cli.path.hasSuffix("Contents/Helpers/whisper-cli"))
        #expect(s.modelsDir == SpeechModels.directory)
        let dev = WhisperSetup(root: URL(fileURLWithPath: "/x/whisper.cpp"), model: "m.bin", language: "sv")
        #expect(dev.cli.path == "/x/whisper.cpp/build/bin/whisper-cli" && dev.modelURL.path == "/x/whisper.cpp/models/m.bin")
    }
}
