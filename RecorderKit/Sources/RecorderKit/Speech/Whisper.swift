import Foundation
import AVFoundation

/// Transkribering med whisper.cpp som extern process. Svenska går via KB-Whisper (Kungliga
/// bibliotekets modeller); Apples SpeechTranscriber kan inte svenska.
///
/// Gången:
/// 1. Spåret läses som 16 kHz mono.
/// 2. Silero (`vad-speech-segments`) hittar talet. ⚠️ whisper-cli:s egen `--vad` ger
///    ordtider på en hoptryckt tidslinje där tystnaden är borta — uppmätt: ett ord som sägs
///    vid 7,4 s fick tiden 4,75 s. Därför gör vi uppdelningen själva.
/// 3. Taldelarna läggs efter varandra med en kort tystnad emellan och transkriberas i ett svep
///    (modellen laddas en gång). Utan långa tystnader hittar whisper inte på text ur dem.
/// 4. Ordens tider räknas tillbaka till inspelningens tidslinje via `SpeechChunks`.
public struct WhisperSetup: Sendable, Equatable {
    /// Mappen med `build/bin/whisper-cli` och `models/`.
    public var root: URL
    /// Modellfilens namn i `models/`.
    public var model: String
    /// "sv", "en" … eller "auto".
    public var language: String

    public static let vadModel = "ggml-silero-v5.1.2.bin"

    public init(root: URL, model: String, language: String) {
        self.root = root; self.model = model; self.language = language
    }

    public var cli: URL { root.appendingPathComponent("build/bin/whisper-cli") }
    public var vadTool: URL { root.appendingPathComponent("build/bin/vad-speech-segments") }
    public var modelsDir: URL { root.appendingPathComponent("models") }
    public var modelURL: URL { modelsDir.appendingPathComponent(model) }
    public var vadModelURL: URL { modelsDir.appendingPathComponent(Self.vadModel) }

    /// whisper.cpp:s förinställning för DTW-ordtider, ur modellens storlek. KB-Whispers
    /// modeller är finjusterade ur OpenAI:s och har samma uppmärksamhetshuvuden.
    /// ⚠️ Utan DTW driver ordtiderna över tystnader: uppmätt 4,5 s för ett ord vid 8,7 s.
    public var dtwPreset: String? {
        let m = model.lowercased()
        let english = m.contains(".en")
        let presets: [(String, String)] = [("large-v3-turbo", "large.v3.turbo"), ("large-v3", "large.v3"),
                                           ("large-v2", "large.v2"), ("medium", "medium"), ("small", "small"),
                                           ("base", "base"), ("tiny", "tiny")]
        guard let p = presets.first(where: { m.contains($0.0) })?.1 else { return nil }
        return english && !p.hasPrefix("large") ? p + ".en" : p
    }

    /// Vad som saknas, på svenska, eller tom lista om allt finns.
    public var problems: [String] {
        let fm = FileManager.default
        var out: [String] = []
        if !fm.isExecutableFile(atPath: cli.path) { out.append(String(localized: "whisper-cli saknas i \(root.path)/build/bin")) }
        if !fm.isExecutableFile(atPath: vadTool.path) { out.append(String(localized: "vad-speech-segments saknas i \(root.path)/build/bin")) }
        if !fm.fileExists(atPath: modelURL.path) { out.append(String(localized: "Modellen \(model) saknas")) }
        if !fm.fileExists(atPath: vadModelURL.path) { out.append(String(localized: "Taldetektorn \(Self.vadModel) saknas")) }
        return out
    }

    /// Modellerna i `models/` som går att transkribera med (inte provmodellerna eller Silero).
    public var availableModels: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return names.filter { $0.hasSuffix(".bin") && !$0.hasPrefix("for-tests") && !$0.contains("silero") }.sorted()
    }

    /// Där whisper.cpp brukar ligga.
    public static let candidateRoots: [String] = ["~/Projekt/whisper.cpp", "~/whisper.cpp", "~/Developer/whisper.cpp",
                                                   "~/src/whisper.cpp", "/opt/whisper.cpp"]

    public static func findRoot() -> URL? {
        candidateRoots.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("build/bin/whisper-cli").path) }
    }

    /// Kan modellen översätta talet till engelska (`-tr`)? Bara OpenAI:s flerspråkiga modeller.
    /// Uppmätt med svenskt tal: KB-Whisper (tiny, small, medium) och large-v3-turbo skrev
    /// svenska även med `-tr` och med `-l en`; `.en`-modellerna förstår bara engelska.
    public static func canTranslate(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("ggml-") && m.hasSuffix(".bin") && !m.contains("turbo") && !m.contains(".en")
            && !m.contains("silero") && !m.hasPrefix("for-tests")
    }

    /// Modellen att översätta med bland dem som finns (ggml-medium är den uppmätta).
    public static func translationModel(among models: [String]) -> String? {
        let order = ["ggml-large-v3.bin", "ggml-large-v2.bin", "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin"]
        return order.first(where: models.contains) ?? models.first(where: canTranslate)
    }

    /// Bästa modellen för språket bland dem som finns: KB-Whisper för svenska, annars den
    /// största flerspråkiga.
    public static func preferredModel(among models: [String], language: String) -> String? {
        let order = language == "sv"
            ? ["kb_whisper_ggml_medium.bin", "kb_whisper_ggml_small.bin", "ggml-large-v3-turbo.bin", "kb_whisper_ggml_tiny.bin"]
            : ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin", "ggml-medium.en.bin"]
        return order.first(where: models.contains) ?? models.first
    }
}

public enum WhisperError: LocalizedError {
    case missing([String])
    case failed(String)
    case noAudio
    case cannotTranslate(String)

    public var errorDescription: String? {
        switch self {
        case .cannotTranslate(let m):
            return String(localized: "Modellen \(m) kan inte översätta. Lägg en flerspråkig modell (till exempel ggml-medium.bin) i whisper.cpp/models.")
        case .missing(let p): return p.joined(separator: "\n")
        case .failed(let s): return String(localized: "whisper.cpp misslyckades: \(s)")
        case .noAudio: return String(localized: "Inspelningen har inget ljudspår att transkribera.")
        }
    }
}

public enum Transcriber {
    public static let sampleRate = 16_000.0

    /// Transkriberar mikrofonen (eller datorljudet om mikrofon saknas, eller första appen med
    /// eget spår om bara sådana finns). `progress` får 0–1.
    public static func run(_ rec: LoadedRecording, setup: WhisperSetup,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Transcript {
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let speech = try await prepare(rec, setup: setup, in: work, progress: progress)
        guard let speech else {
            return Transcript(model: setup.model, language: setup.language, track: speechTrack(rec), words: [])
        }
        var args = ["-m", setup.modelURL.path, "-l", setup.language]
        if let dtw = setup.dtwPreset { args += ["-dtw", dtw] }
        let data = try await whisper(setup, speech, args, in: work, progress: progress)
        let words = try parse(data, chunks: speech.chunks, offset: speech.offset)
        progress(1)
        return Transcript(model: setup.model, language: setup.language, track: speech.kind, words: words)
    }

    /// Undertexterna på engelska, översatta av whisper ur talet (`-tr`) — helt på datorn.
    /// `setup.language` = talets språk, `setup.model` en modell som `canTranslate`. Raderna
    /// får whispers meningar, med tiderna tillbakaräknade till inspelningen och fästa vid
    /// originalets ordgränser när transkriptet finns (whispers egna tider är grova:
    /// uppmätt 4,84 s för en mening som började efter en paus vid 5,6 s).
    public static func translate(_ rec: LoadedRecording, setup: WhisperSetup,
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CaptionTranslation {
        guard WhisperSetup.canTranslate(setup.model) else { throw WhisperError.cannotTranslate(setup.model) }
        let work = try workDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        guard let speech = try await prepare(rec, setup: setup, in: work, progress: progress) else {
            return CaptionTranslation(language: "en", cues: [])
        }
        let data = try await whisper(setup, speech, ["-m", setup.modelURL.path, "-l", setup.language, "-tr"],
                                     in: work, progress: progress)
        let cues = try translatedCues(data, chunks: speech.chunks, offset: speech.offset, words: rec.transcript?.words ?? [])
        progress(1)
        return CaptionTranslation(language: "en", cues: cues)
    }

    /// Spåret som transkriberas: mikrofonen, annars datorljudet, annars första appen.
    static func speechTrack(_ rec: LoadedRecording) -> RecordingMeta.TrackKind {
        rec.hasMicrophone ? .microphone : (rec.hasSystemAudio ? .system : .app)
    }

    /// Talet hopfogat i `tal.wav`, och vägen tillbaka till inspelningens tid.
    struct PreparedSpeech {
        let kind: RecordingMeta.TrackKind
        let joined: URL
        let chunks: SpeechChunks
        /// Tiden för spårets första sampel på inspelningens tidslinje.
        let offset: Double
    }

    static func workDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("skarminspelare-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// Läser spåret, hittar talet och fogar ihop det (förlopp 0–0,15). nil = inget tal.
    static func prepare(_ rec: LoadedRecording, setup: WhisperSetup, in work: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedSpeech? {
        let problems = setup.problems
        guard problems.isEmpty else { throw WhisperError.missing(problems) }
        let kind = speechTrack(rec)
        // Den röstisolerade mikrofonen om den finns (samma tidslinje, utan brus).
        let isolated = kind == .microphone ? rec.isolatedMicrophone : nil
        guard let asset = isolated ?? (kind == .app ? rec.apps.first?.asset : rec.asset(kind)) else { throw WhisperError.noAudio }

        progress(0.02)
        let (samples, offset) = try await readMono16k(asset)
        guard !samples.isEmpty else { throw WhisperError.noAudio }
        let full = work.appendingPathComponent("hela.wav")
        try writeWAV(samples, to: full)
        progress(0.08)

        let speech = try await detectSpeech(full, setup: setup)
        guard !speech.isEmpty else { return nil }
        let chunks = SpeechChunks(speech: speech, sampleRate: sampleRate, total: samples.count)
        let joined = work.appendingPathComponent("tal.wav")
        try writeWAV(chunks.joined(from: samples), to: joined)
        progress(0.15)
        return PreparedSpeech(kind: kind, joined: joined, chunks: chunks, offset: offset)
    }

    /// Kör whisper-cli på det hopfogade talet med `args` (modell, språk …) och ger JSON-utdatan.
    static func whisper(_ setup: WhisperSetup, _ speech: PreparedSpeech, _ args: [String], in work: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let base = work.appendingPathComponent("ut")
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        try await execute(setup.cli, args + ["-f", speech.joined.path, "-ojf", "-of", base.path,
                                             "-np", "-pp", "-t", String(threads), "-sns"]) { line in
            // "whisper_print_progress_callback: progress =  45%"
            if let r = line.range(of: "progress =") {
                let n = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " %\n"))
                if let p = Double(n) { progress(0.15 + 0.83 * p / 100) }
            }
        }
        return try Data(contentsOf: base.appendingPathExtension("json"))
    }

    // MARK: - Ljud

    /// Spåret som 16 kHz mono, och tiden för första samplet på inspelningens tidslinje
    /// (mikrofonen kan börja en halv sekund efter skärmen).
    static func readMono16k(_ asset: AVURLAsset) async throws -> ([Float], Double) {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw WhisperError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: sampleRate,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? WhisperError.noAudio }
        var samples: [Float] = []
        var first: Double?
        while let buffer = out.copyNextSampleBuffer() {
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                samples.append(contentsOf: UnsafeBufferPointer(start: p, count: length / 4))
            }
        }
        return (samples, first ?? 0)
    }

    /// 16-bitars PCM-WAV, som whisper.cpp läser.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    // MARK: - Tal

    static func detectSpeech(_ wav: URL, setup: WhisperSetup) async throws -> [ClosedRange<Double>] {
        let collected = Collector()
        // Samma inställningar som Kundkoll: korta pauser klipper inte mitt i en mening,
        // lite marginal så att begynnelseljud kommer med.
        try await execute(setup.vadTool, ["-vm", setup.vadModelURL.path, "-f", wav.path, "-vt", "0.5",
                                          "-vsd", "300", "-vp", "120"]) { collected.append($0 + "\n") }
        return parseSpeechSegments(collected.text)
    }

    /// "Speech segment 2: start = 852.00, end = 1155.00" — hundradelar av sekunder.
    static func parseSpeechSegments(_ text: String) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for line in text.split(separator: "\n") where line.contains("Speech segment") {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: "=,"))
            guard parts.count >= 4,
                  let s = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let e = Double(parts[3].trimmingCharacters(in: .whitespaces)), e > s else { continue }
            out.append(s / 100...e / 100)
        }
        return out
    }

    // MARK: - whisper-cli:s JSON

    struct Output: Decodable {
        struct Segment: Decodable {
            struct Token: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let text: String
                let offsets: Offsets
                /// DTW-tiden i hundradelar, om whisper-cli kördes med `-dtw`.
                let t_dtw: Int?
            }
            let text: String
            let tokens: [Token]
            /// Segmentets början och slut i millisekunder.
            let offsets: Token.Offsets?
        }
        let transcription: [Segment]
    }

    /// Raderna ur en översättning (`-tr`), i inspelningens källtid. whispers segment går gärna
    /// tvärs över meningar och pauser (uppmätt: «… with a» | «chapter. First we open …» över en
    /// paus på 2,5 s), så texten delas i meningar, en mening som fortsätter i nästa segment slås
    /// ihop, och tiden fördelas efter textlängd i den *hopfogade* filen — där pauserna bara är
    /// 0,4 s, så fördelningen följer talet. Gränser nära en paus fästs vid pausen, sedan vid
    /// originalets ord. Långa meningar delas så att de ryms på två rader.
    static func translatedCues(_ data: Data, chunks: SpeechChunks, offset: Double,
                               words: [Transcript.Word]) throws -> [CaptionTranslation.Cue] {
        let out = try JSONDecoder().decode(Output.self, from: data)
        struct Sentence { var text: String; var from: Double; var to: Double }
        var sentences: [Sentence] = []
        for segment in out.transcription where !Hallucination.isNoise(segment.text) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let o = segment.offsets else { continue }
            let from = Double(o.from) / 1000, to = max(Double(o.to) / 1000, Double(o.from) / 1000)
            let parts = CaptionTranslation.sentences(text)
            let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
            var done = 0
            for part in parts {
                let a = from + (to - from) * Double(done) / total
                done += part.count + 1
                let b = from + (to - from) * Double(done) / total
                if let last = sentences.last, !CaptionTranslation.endsSentence(last.text) || part.first?.isLowercase == true {
                    sentences[sentences.count - 1].text += " " + part
                    sentences[sentences.count - 1].to = b
                } else {
                    sentences.append(Sentence(text: part, from: a, to: b))
                }
            }
        }
        var cues: [CaptionTranslation.Cue] = []
        for sentence in sentences {
            var start = chunks.startTime(sentence.from) + offset
            var end = chunks.endTime(sentence.to) + offset
            if !words.isEmpty {
                start = CaptionTranslation.snap(start, to: words.map(\.start), within: 0.8)
                end = CaptionTranslation.snap(end, to: words.map(\.end), within: 0.8)
            }
            if let last = cues.last { start = max(start, last.end) }
            guard end > start + 0.2 else { continue }
            cues += CaptionTranslation.pieces(sentence.text, start: start, end: end, words: words)
        }
        return cues
    }

    /// Orden ur whisper-cli:s `-ojf`, med tiderna tillbakaräknade till inspelningen.
    static func parse(_ data: Data, chunks: SpeechChunks, offset: Double) throws -> [Transcript.Word] {
        let out = try JSONDecoder().decode(Output.self, from: data)
        // Orden i den hopfogade filens tid: början, när sista ljudande token sägs, och
        // whispers egen sluttid.
        struct Raw { var text: String; var start: Double; var last: Double; var end: Double; var newSegment: Bool }
        var raws: [Raw] = []
        for segment in out.transcription where !Hallucination.isNoise(segment.text) {
            var first = true
            for token in segment.tokens {
                let text = token.text
                // Specialtoken: [_BEG_], [_TT_123], <|endoftext|> …
                if text.hasPrefix("[_") || text.hasPrefix("<|") { continue }
                let dtw = token.t_dtw.flatMap { $0 >= 0 ? Double($0) / 100 : nil }
                let from = dtw ?? Double(token.offsets.from) / 1000
                let to = Double(token.offsets.to) / 1000
                let punctuation = text.trimmingCharacters(in: .whitespaces).allSatisfy { $0.isPunctuation }
                if punctuation && !raws.isEmpty {
                    // Ett skiljetecken hör till ordet före; dess tid säger inget om ordet.
                    raws[raws.count - 1].text += text.trimmingCharacters(in: .whitespaces)
                    continue
                }
                if text.hasPrefix(" ") || first || raws.isEmpty {
                    raws.append(Raw(text: text.trimmingCharacters(in: .whitespaces), start: from, last: from,
                                    end: dtw.map { $0 + 0.25 } ?? to, newSegment: first))
                    first = false
                } else {
                    raws[raws.count - 1].text += text
                    raws[raws.count - 1].last = from
                    raws[raws.count - 1].end = dtw.map { $0 + 0.25 } ?? max(raws[raws.count - 1].end, to)
                }
            }
        }
        var words: [Transcript.Word] = []
        for (i, r) in raws.enumerated() where !r.text.isEmpty {
            // Ett ord ligger alltid inom en taldel; både början och slut räknas via den.
            let chunk = chunks.locate(r.start)
            var end = max(r.end, r.last + 0.05)
            if i + 1 < raws.count { end = min(end, max(raws[i + 1].start, r.start + 0.05)) }
            let start = chunks.original(r.start, in: chunk) + offset
            let stop = chunks.original(end, in: chunk) + offset
            words.append(Transcript.Word(start: start, end: max(stop, start + 0.02), text: r.text,
                                         startsSegment: r.newSegment))
        }
        return words
    }

    // MARK: - Process

    /// Kör ett verktyg och skickar varje rad på stderr/stdout till `line`. Avbryts tasken
    /// avbryts processen.
    static func execute(_ tool: URL, _ args: [String], line: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tail = TailBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            tail.append(s)
            for l in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) { line(String(l)) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if p.terminationStatus == 0 { cont.resume() }
                    else { cont.resume(throwing: WhisperError.failed(tail.text)) }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// De sista raderna en process skrev, för felmeddelandet.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) {
        lock.lock(); buffer = String((buffer + s).suffix(600)); lock.unlock()
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Taldelarna lagda efter varandra med en kort tystnad emellan, och vägen tillbaka från en
/// tid i den hopfogade filen till inspelningens.
public struct SpeechChunks: Sendable {
    public struct Chunk: Sendable, Equatable {
        /// Var delen börjar i originalet och i den hopfogade filen, och hur lång den är (s).
        public let original: Double
        public let joined: Double
        public let length: Double
    }
    public static let gap = 0.4
    public let chunks: [Chunk]
    let sampleRate: Double

    public init(speech: [ClosedRange<Double>], sampleRate: Double, total: Int) {
        self.sampleRate = sampleRate
        let end = Double(total) / sampleRate
        var out: [Chunk] = []
        var at = 0.0
        for r in speech {
            let s = max(0, r.lowerBound), e = min(end, r.upperBound)
            guard e - s > 0.05 else { continue }
            out.append(Chunk(original: s, joined: at, length: e - s))
            at += e - s + Self.gap
        }
        chunks = out
    }

    /// Sampel för den hopfogade filen.
    public func joined(from samples: [Float]) -> [Float] {
        var out: [Float] = []
        let silence = [Float](repeating: 0, count: Int(Self.gap * sampleRate))
        for c in chunks {
            let a = Int(c.original * sampleRate), b = min(samples.count, a + Int(c.length * sampleRate))
            guard a < b else { continue }
            out.append(contentsOf: samples[a..<b])
            out.append(contentsOf: silence)
        }
        return out
    }

    /// Delen en tid i den hopfogade filen hör till. En tid i tystnaden mellan två delar hör
    /// till delen efter: whisper sätter gärna början på ett ord i pausen före det.
    public func locate(_ t: Double) -> Chunk? {
        guard !chunks.isEmpty else { return nil }
        for c in chunks where t < c.joined + c.length { return c }
        return chunks.last
    }

    /// Delen en *sluttid* hör till: en tid i tystnaden efter en del hör till den delen.
    public func locateEnd(_ t: Double) -> Chunk? {
        chunks.last(where: { $0.joined <= t }) ?? chunks.first
    }

    /// Var en rad som börjar vid `t` (hopfogad tid) börjar i inspelningen: nära en paus fästs
    /// den vid där talet tar vid efter pausen.
    public func startTime(_ t: Double, snap: Double = 0.5) -> Double {
        guard let c = locate(t), let i = chunks.firstIndex(of: c) else { return t }
        if t - c.joined < snap { return c.original }
        if c.joined + c.length - t < snap, i + 1 < chunks.count { return chunks[i + 1].original }
        return original(t, in: c)
    }

    /// Var en rad som slutar vid `t` slutar i inspelningen: nära en paus fästs den vid där
    /// talet slutar före pausen.
    public func endTime(_ t: Double, snap: Double = 0.5) -> Double {
        guard let c = locateEnd(t), let i = chunks.firstIndex(of: c) else { return t }
        if t - c.joined < snap, i > 0 { return chunks[i - 1].original + chunks[i - 1].length }
        if c.joined + c.length - t < snap { return c.original + c.length }
        return original(t, in: c)
    }

    /// En tid i den hopfogade filen → inspelningens, inom delen `chunk`.
    public func original(_ t: Double, in chunk: Chunk?) -> Double {
        guard let c = chunk else { return t }
        return c.original + min(max(0, t - c.joined), c.length)
    }

    /// En tid i den hopfogade filen → inspelningens.
    public func original(_ t: Double) -> Double { original(t, in: locate(t)) }
}
