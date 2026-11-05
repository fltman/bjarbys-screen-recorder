import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Förvalen i exportdialogen.
public struct ExportPreset: Identifiable, Hashable, Sendable {
    public enum Codec: String, Sendable { case h264, hevc, hevcHDR, av1, prores, proresAlpha, gif, audioAAC, audioWAV, audioStems, editorPackage }

    public let id: String
    public let name: String
    public let detail: String
    public let codec: Codec
    /// Bildytans kortaste sida i pixlar.
    public let shortSide: Int
    public let fps: Int
    /// Filmen packas om till Matroska (.mkv) efter exporten (samma kodek, ingen omkodning).
    public var matroska: Bool = false

    public static let all: [ExportPreset] = [
        .init(id: "mp4-1080", name: "MP4 1080p", detail: "H.264 — spelas överallt", codec: .h264, shortSide: 1080, fps: 60),
        .init(id: "mp4-4k", name: "MP4 4K", detail: "HEVC — skarpast, mindre filer", codec: .hevc, shortSide: 2160, fps: 60),
        .init(id: "mp4-4k-hdr", name: "MP4 4K HDR", detail: "HEVC 10 bit, HLG — ljusare högdagrar på HDR-skärmar, YouTube",
              codec: .hevcHDR, shortSide: 2160, fps: 60),
        .init(id: "prores", name: "ProRes 422", detail: "För vidare redigering i Final Cut, Resolve, Premiere", codec: .prores, shortSide: 1080, fps: 60),
        .init(id: "prores-alfa", name: "ProRes 4444 med alfa",
              detail: "Genomskinlig bakgrund — lägg skärmen ovanpå något eget i Final Cut, Resolve, Premiere",
              codec: .proresAlpha, shortSide: 1080, fps: 60),
        .init(id: "mp4-av1", name: "MP4 AV1", detail: "Minst filer vid samma kvalitet — kodas med ffmpeg på datorn, tar längre tid",
              codec: .av1, shortSide: 1080, fps: 60),
        .init(id: "mkv-1080", name: "MKV 1080p", detail: "H.264 i Matroska — för OBS-vana arbetsflöden, VLC, mpv",
              codec: .h264, shortSide: 1080, fps: 60, matroska: true),
        .init(id: "fcpxml", name: "Final Cut / Resolve",
              detail: "En mapp: den färdiga bilden (ProRes), ett ljudspår per källa och en tidslinje (FCPXML) med kapitel och markeringar",
              codec: .editorPackage, shortSide: 1080, fps: 60),
        .init(id: "gif", name: "GIF", detail: "För Slack och GitHub, högst 800 px", codec: .gif, shortSide: 450, fps: 15),
        .init(id: "ljud-m4a", name: "Ljud M4A", detail: "AAC 256 kbit/s — bara ljudet, för en podd", codec: .audioAAC, shortSide: 0, fps: 30),
        .init(id: "ljud-wav", name: "Ljud WAV", detail: "24 bit, 48 kHz, okomprimerat", codec: .audioWAV, shortSide: 0, fps: 30),
        .init(id: "ljud-spar", name: "Ljudspår var för sig",
              detail: "En WAV per källa (mikrofon, datorljud, appar, inslag) i en mapp — för Logic, Resolve; summerar till mixen",
              codec: .audioStems, shortSide: 0, fps: 30),
    ]

    public var fileExtension: String {
        if matroska { return "mkv" }
        return switch codec {
        case .h264, .hevc, .hevcHDR, .av1: "mp4"
        case .prores, .proresAlpha: "mov"
        case .gif: "gif"
        case .audioAAC: "m4a"
        case .audioWAV: "wav"
        case .audioStems, .editorPackage: ""
        }
    }

    /// Bara ljudet (ingen bild renderas).
    public var isAudioOnly: Bool { codec == .audioAAC || codec == .audioWAV || codec == .audioStems }

    /// Bakgrunden lämnas genomskinlig (bara skärmen, skuggan, markören, bubblan och texterna ritas).
    public var transparentBackground: Bool { codec == .proresAlpha }

    /// HDR-utdata (HLG). Bara för HDR-inspelningar; de andra förvalen ger SDR även då.
    public var isHDR: Bool { codec == .hevcHDR }

    /// Förvalen som passar inspelningen (HDR-förvalet bara för en HDR-inspelning).
    public static func available(hdr: Bool) -> [ExportPreset] {
        all.filter { (hdr || !$0.isHDR) && ($0.codec != .av1 || FFmpeg.av1Encoder != nil) }
    }

    /// Bitrate i bit/s för en bildyta.
    public func bitrate(for canvas: CGSize, fps override: Int? = nil) -> Int {
        let pixels = Double(canvas.width * canvas.height)
        let fps = override ?? self.fps
        switch codec {
        case .h264: return Int(pixels * Double(fps) * 0.09)
        case .hevc: return Int(pixels * Double(fps) * 0.06)
        case .hevcHDR: return Int(pixels * Double(fps) * 0.075)
        case .av1: return Int(pixels * Double(fps) * 0.025) // bara för uppskattningen (CRF)
        case .prores, .editorPackage: return Int(pixels * Double(fps) * 1.6) // bara för uppskattningen
        case .proresAlpha: return Int(pixels * Double(fps) * 3.6)
        case .gif: return Int(pixels * Double(fps) * 0.25)
        case .audioAAC: return 256_000
        case .audioWAV, .audioStems: return 48_000 * 2 * 24
        }
    }

    /// Ungefärlig filstorlek i byte.
    public func estimatedBytes(canvas: CGSize, duration: Double, quality: Exporter.Quality = .normal) -> Int64 {
        Int64(Double(bitrate(for: canvas)) * (usesQuality ? quality.factor : 1) / 8 * duration)
            + (codec == .gif || isAudioOnly ? 0 : Int64(24_000 * duration))
    }

    /// Kvalitetsvalet gäller H.264 och HEVC (ProRes, GIF och ljud har sin egen).
    public var usesQuality: Bool { codec == .h264 || codec == .hevc || codec == .hevcHDR || codec == .av1 }

    /// Bildytan för exporten. GIF begränsas till 800 px på längsta sidan.
    public func canvas(aspect: EditProject.Aspect, source: CGSize) -> CGSize {
        var size = RenderPlan.canvasSize(aspect: aspect, source: source, shortSide: shortSide)
        if codec == .gif, max(size.width, size.height) > 800 {
            let k = 800 / max(size.width, size.height)
            size = CGSize(width: (size.width * k / 2).rounded() * 2, height: (size.height * k / 2).rounded() * 2)
        }
        return size
    }
}

/// Exporterar ett redigeringsläge till en fil, med samma kompositör som förhandsvisningen.
public final class Exporter: @unchecked Sendable {
    public enum ExportError: LocalizedError {
        case cancelled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: "Exporten avbröts"
            case .failed(let s): s
            }
        }
    }

    private let recording: LoadedRecording
    private let project: EditProject
    private let preset: ExportPreset
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    /// Läsarna för de andra språkens ljudspår (dubbning).
    private var extraReaders: [AVAssetReader] = []
    private var cancelled = false
    private let lock = NSLock()

    /// Bildfrekvensen i filen: förvalets, eller (för en 120-fps-inspelning) inspelningens.
    public let fps: Int
    /// Bara ett utsnitt av filmen (utdatatid, s), eller nil = hela.
    public let range: ClosedRange<Double>?
    /// Kvaliteten för H.264 och HEVC: bitraten gånger `factor` (ProRes och GIF påverkas inte).
    public enum Quality: String, CaseIterable, Sendable {
        case small, normal, high
        public var factor: Double {
            switch self {
            case .small: 0.5
            case .normal: 1
            case .high: 1.8
            }
        }
    }
    public let quality: Quality

    /// Jämna ut hela ljudet till den här ljudstyrkan (LUFS), t.ex. −14 för YouTube, eller nil.
    public let loudnessTarget: Double?
    /// Vad mätningen gav och hur mycket ljudet ändrades (när `loudnessTarget` är satt).
    public private(set) var loudnessReport: (measured: Double, gainDB: Double, limitedByPeaks: Bool)?

    public init(recording: LoadedRecording, project: EditProject, preset: ExportPreset, fps: Int? = nil,
                range: ClosedRange<Double>? = nil, loudnessTarget: Double? = nil, quality: Quality = .normal) {
        self.quality = quality
        self.loudnessTarget = loudnessTarget
        self.recording = recording
        self.project = project
        self.preset = preset
        self.range = range.flatMap { $0.upperBound - $0.lowerBound > 0.05 ? $0 : nil }
        self.fps = preset.codec == .gif ? preset.fps : min(240, max(1, fps ?? preset.fps))
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        reader?.cancelReading()
        lock.withLock { extraReaders }.forEach { $0.cancelReading() }
        writer?.cancelWriting()
        lock.withLock { process }?.terminate()
    }

    /// ffmpeg under en AV1-export (avbryts med `cancel`).
    private var process: Process?

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Kör exporten. `progress` anropas med 0–1 från en bakgrundskö.
    public func run(to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Bara ljud: bilden renderas aldrig, så en liten bildyta räcker för planen.
        let canvas = preset.isAudioOnly ? CGSize(width: 640, height: 360)
            : preset.canvas(aspect: project.aspect, source: recording.sourceSize)
        let plan = recording.makePlan(project: project, canvas: canvas, transparentBackground: preset.transparentBackground,
                                      hdr: preset.isHDR)
        let built = try await CompositionBuilder.build(recording, plan: plan, fps: fps)
        try? FileManager.default.removeItem(at: url)
        if preset.matroska {
            // Först en vanlig MP4 bredvid, sedan omkodning bara av behållaren.
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await exportMovie(built, canvas: canvas, to: temp) { progress($0 * 0.95) }
            if isCancelled { throw ExportError.cancelled }
            let span = clampedRange(built)
            let chapters = built.plan.overlayTrack.chapterList(in: span.seconds).map {
                Matroska.Chapter(start: $0.start - span.seconds.lowerBound, end: $0.end - span.seconds.lowerBound, title: $0.title)
            }
            try await Matroska.remux(temp, to: url, chapters: chapters) { progress(0.95 + $0 * 0.05) }
        } else if preset.codec == .editorPackage {
            try await exportEditorPackage(built, canvas: canvas, to: url, progress: progress)
        } else if preset.codec == .av1 {
            try await exportAV1(built, canvas: canvas, to: url, progress: progress)
        } else if preset.isAudioOnly {
            try await exportAudio(built, to: url, progress: progress)
        } else if preset.codec == .gif {
            try await exportGIF(built, canvas: canvas, to: url, progress: progress)
        } else {
            try await exportMovie(built, canvas: canvas, to: url, progress: progress)
        }
    }

    // MARK: - Film

    private func exportMovie(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL, includeAudio: Bool = true,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let span = clampedRange(built)
        reader.timeRange = span.time
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let audioTracks = includeAudio ? try await built.composition.loadTracks(withMediaType: .audio) : []
        // HDR: 10 bit 4:2:0 direkt till HEVC Main10 (kompositören ritar HLG i halvflyttal).
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: preset.isHDR && recording.isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderAudioMixOutput?
        let mix = range == nil ? built.audioMix
            : CompositionBuilder.audioMix(for: built.composition, plan: built.plan, appIDs: recording.apps.map(\.id), edges: span.seconds)
        // Ljudstyrkan: hela mixen (eller utsnittet) mäts först, sedan skalas varje buffert.
        var gain: Float = 1
        if let target = loudnessTarget, !audioTracks.isEmpty,
           let m = try await Loudness.measureMix(built.composition, audioMix: mix, range: span.time) {
            let g = Loudness.mixGain(for: m, target: target)
            gain = Float(pow(10, g.db / 20))
            loudnessReport = (m.integrated, g.db, g.limitedByPeaks)
        }
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = mix
            out.audioTimePitchAlgorithm = .spectral
            reader.add(out)
            audioOut = out
        }

        // ProRes (även 4444) bara i .mov; i .mp4 kastar AVAssetWriter ett undantag.
        let isMov = preset.fileExtension == "mov" || preset.codec == .editorPackage
        let writer = try AVAssetWriter(outputURL: url, fileType: isMov ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = !isMov
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(canvas: canvas))
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let settings: [String: Any] = isMov
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                   AVLinearPCMIsNonInterleaved: false,
                   AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                   AVEncoderBitRateKey: 192_000,
                   AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }
        // Dubbning: originalet och varje dubbning som var sitt ljudspår, med språkkod, i samma
        // grupp — spelaren väljer (QuickTime: Visa › Språk). Huvudspåret är filmens röst.
        var alternates: [(reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput, gain: Float)] = []
        if let audioIn, let audioOut, !Dubbing.languages(project).isEmpty {
            let original = recording.transcript?.language.isEmpty == false ? recording.transcript!.language : "sv"
            let main = Dubbing.languages(project).contains(project.audio.voice) ? project.audio.voice : ""
            Self.tag(audioIn, language: main.isEmpty ? original : main)
            for voice in ([""] + Dubbing.languages(project)) where voice != main {
                let r = try AVAssetReader(asset: built.composition)
                r.timeRange = span.time
                let altMix = CompositionBuilder.audioMix(for: built.composition, plan: built.plan, appIDs: recording.apps.map(\.id),
                                                         edges: range == nil ? nil : span.seconds, voice: voice)
                let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: audioOut.audioSettings)
                out.audioMix = altMix
                out.audioTimePitchAlgorithm = .spectral
                r.add(out)
                var g: Float = 1
                if let target = loudnessTarget, let m = try await Loudness.measureMix(built.composition, audioMix: altMix, range: span.time) {
                    g = Float(pow(10, Loudness.mixGain(for: m, target: target).db / 20))
                }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioIn.outputSettings)
                input.expectsMediaDataInRealTime = false
                input.marksOutputTrackAsEnabled = false
                Self.tag(input, language: voice.isEmpty ? original : voice)
                guard writer.canAdd(input) else { continue }
                writer.add(input)
                alternates.append((r, out, input, g))
            }
            if !alternates.isEmpty {
                let group = AVAssetWriterInputGroup(inputs: [audioIn] + alternates.map(\.input), defaultInput: audioIn)
                if writer.canAdd(group) { writer.add(group) }
            }
        }
        // Kapitlen som kapitelspår (QuickTime, IINA, VLC visar dem), när projektet har kapitel.
        // Ett textspår (tx3g) — det klassiska QuickTime-formatet, som både AVFoundation och
        // ffmpeg-baserade spelare läser titlarna ur (ett metadataspår gav tomma titlar i ffprobe).
        let chapters = built.plan.overlayTrack.chapterList(in: span.seconds).compactMap { c in
            Self.chapterSample(c.title, from: c.start, to: c.end)
        }
        var chapterIn: AVAssetWriterInput?
        if !chapters.isEmpty, let hint = Self.chapterFormat {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            let type = AVAssetTrack.AssociationType.chapterList.rawValue
            if writer.canAdd(input), videoIn.canAddTrackAssociation(withTrackOf: input, type: type) {
                writer.add(input)
                videoIn.addTrackAssociation(withTrackOf: input, type: type)
                chapterIn = input
            }
        }
        self.reader = reader
        self.writer = writer

        lock.withLock { extraReaders = alternates.map(\.reader) }
        defer { lock.withLock { extraReaders = [] } }
        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }
        for a in alternates where !a.reader.startReading() {
            throw ExportError.failed(a.reader.error?.localizedDescription ?? "Läsningen startade inte")
        }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Skrivningen startade inte") }
        writer.startSession(atSourceTime: span.time.start)

        let total = max(span.seconds.upperBound - span.seconds.lowerBound, 0.001)
        let offset = span.seconds.lowerBound
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pump(videoOut, into: videoIn, queue: "skarminspelare.export.video") { t in
                    progress(min(1, max(0, t - offset) / total))
                }
            }
            if let audioOut, let audioIn {
                group.addTask {
                    await Self.pump(audioOut, into: audioIn, queue: "skarminspelare.export.audio", gain: gain) { _ in }
                }
            }
            if let chapterIn {
                group.addTask { await Self.pumpChapters(chapters, into: chapterIn) }
            }
            for (n, a) in alternates.enumerated() {
                group.addTask {
                    await Self.pump(a.output, into: a.input, queue: "skarminspelare.export.audio\(n + 2)", gain: a.gain) { _ in }
                }
            }
        }
        if alternates.contains(where: { $0.reader.status == .failed }) {
            writer.cancelWriting()
            throw ExportError.failed(alternates.first { $0.reader.status == .failed }?.reader.error?.localizedDescription ?? "Läsningen misslyckades")
        }
        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen misslyckades")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Skrivningen misslyckades")
        }
        progress(1)
    }

    private func videoSettings(canvas: CGSize) -> [String: Any] {
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        switch preset.codec {
        case .prores, .editorPackage:
            return [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color]
        case .proresAlpha:
            return [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color]
        case .hevcHDR where recording.isHDR:
            return [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                    ],
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(Double(preset.bitrate(for: canvas, fps: fps)) * quality.factor),
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                    ]]
        case .hevc, .hevcHDR:
            return [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(Double(preset.bitrate(for: canvas, fps: fps)) * quality.factor),
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    ]]
        default:
            return [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(Double(preset.bitrate(for: canvas, fps: fps)) * quality.factor),
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    ]]
        }
    }

    /// Flyttar buffertar från läsare till skrivare tills läsaren är slut.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue label: String,
                             gain: Float = 1, progress: @escaping (Double) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: label)
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finished = true
                        done.resume()
                        return
                    }
                    progress(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                    // Ljudstyrkan: 32-bitars flyttal från läsaren, skalas på plats.
                    if gain != 1, let block = CMSampleBufferGetDataBuffer(buffer) {
                        var length = 0, total = 0
                        var pointer: UnsafeMutablePointer<CChar>?
                        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total,
                                                       dataPointerOut: &pointer) == noErr, let pointer, length == total {
                            pointer.withMemoryRebound(to: Float.self, capacity: total / 4) { p in
                                for i in 0..<(total / 4) { p[i] *= gain }
                            }
                        }
                    }
                    // Core Image ritar förmultiplicerad alfa; säg det till kodaren (ProRes 4444).
                    if let image = CMSampleBufferGetImageBuffer(buffer) {
                        CVBufferSetAttachment(image, kCVImageBufferAlphaChannelModeKey,
                                              kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
                    }
                    if !input.append(buffer) {
                        finished = true
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Final Cut / Resolve

    /// En mapp med den färdiga bilden (ProRes 422, utan ljud), ett ljudspår per källa (WAV) och
    /// en tidslinje (FCPXML) som lägger dem kant i kant från noll, med kapitel och markeringar.
    private func exportEditorPackage(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let span = clampedRange(built)
        let video = url.appendingPathComponent(String(localized: "Bild") + ".mov")
        try await exportMovie(built, canvas: canvas, to: video, includeAudio: false) { progress($0 * 0.8) }
        if isCancelled { throw ExportError.cancelled }

        var audio: [FCPXML.Audio] = []
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let mix = range == nil ? built.audioMix
                : CompositionBuilder.audioMix(for: built.composition, plan: built.plan, appIDs: recording.apps.map(\.id), edges: span.seconds)
            var gain: Float = 1
            if let target = loudnessTarget, let m = try await Loudness.measureMix(built.composition, audioMix: mix, range: span.time) {
                let g = Loudness.mixGain(for: m, target: target)
                gain = Float(pow(10, g.db / 20))
                loudnessReport = (m.integrated, g.db, g.limitedByPeaks)
            }
            let groups = stemGroups(audioTracks)
            for (i, g) in groups.enumerated() {
                let file = url.appendingPathComponent(String(format: "%02d ", i + 1) + g.name.replacingOccurrences(of: "/", with: "-") + ".wav")
                try await writeAudio(built.composition, tracks: g.tracks, mix: mix, gain: gain, span: span.time, to: file, wav: true) { p in
                    progress(0.8 + 0.18 * (Double(i) + p) / Double(groups.count))
                }
                audio.append(.init(name: g.name, url: file, role: FCPXML.role(forStem: g.key)))
            }
        }

        let a = span.seconds.lowerBound, b = span.seconds.upperBound
        var markers = built.plan.overlayTrack.chapterList(in: span.seconds).map {
            FCPXML.Marker(time: $0.start - a, title: $0.title, chapter: true)
        }
        for (i, m) in recording.markers.enumerated() {
            guard let t = built.plan.timeMap.output(at: m), t >= a, t < b else { continue }
            markers.append(.init(time: t - a, title: String(localized: "Markering \(i + 1)"), chapter: false))
        }
        let name = recording.meta.name.isEmpty ? recording.bundle.name : recording.meta.name
        let xml = FCPXML.document(name: name, video: video, size: canvas, fps: fps, duration: b - a, audio: audio, markers: markers)
        try xml.write(to: url.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".fcpxml"),
                      atomically: true, encoding: .utf8)
        progress(1)
    }

    // MARK: - AV1 (via ffmpeg)

    /// AV1 i MP4: rutorna renderas som vanligt och skickas råa (BGRA) till ffmpeg, som kodar dem
    /// med den AV1-kodare den har. Ljudet görs först till en tillfällig M4A (med ljudnivån) och
    /// läggs in rakt över; kapitlen följer med som ffmpeg-metadata.
    private func exportAV1(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpeg = FFmpeg.executable, let encoder = FFmpeg.av1Encoder else {
            throw ExportError.failed(String(localized: "AV1 kräver ffmpeg med en AV1-kodare (t.ex. brew install ffmpeg)."))
        }
        let span = clampedRange(built)
        let dir = url.deletingLastPathComponent()
        let tag = UUID().uuidString
        var temps: [URL] = []
        defer { for t in temps { try? FileManager.default.removeItem(at: t) } }

        // Ljudet.
        var audioURL: URL?
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let mix = range == nil ? built.audioMix
                : CompositionBuilder.audioMix(for: built.composition, plan: built.plan, appIDs: recording.apps.map(\.id), edges: span.seconds)
            var gain: Float = 1
            if let target = loudnessTarget, let m = try await Loudness.measureMix(built.composition, audioMix: mix, range: span.time) {
                let g = Loudness.mixGain(for: m, target: target)
                gain = Float(pow(10, g.db / 20))
                loudnessReport = (m.integrated, g.db, g.limitedByPeaks)
            }
            let a = dir.appendingPathComponent(".\(tag).m4a")
            temps.append(a)
            try await writeAudio(built.composition, tracks: audioTracks, mix: mix, gain: gain, span: span.time, to: a, wav: false) { _ in }
            audioURL = a
        }
        // Kapitlen.
        let chapters = built.plan.overlayTrack.chapterList(in: span.seconds).map {
            (start: $0.start - span.seconds.lowerBound, end: $0.end - span.seconds.lowerBound, title: $0.title)
        }
        var chapterURL: URL?
        if !chapters.isEmpty {
            let c = dir.appendingPathComponent(".\(tag).txt")
            temps.append(c)
            try FFmpeg.chapterMetadata(chapters).write(to: c, atomically: true, encoding: .utf8)
            chapterURL = c
        }

        let w = Int(canvas.width), h = Int(canvas.height)
        var args = ["-hide_banner", "-loglevel", "error", "-y",
                    "-f", "rawvideo", "-pix_fmt", "bgra", "-video_size", "\(w)x\(h)", "-framerate", "\(fps)", "-i", "pipe:0"]
        if let audioURL { args += ["-i", audioURL.path] }
        if let chapterURL { args += ["-f", "ffmetadata", "-i", chapterURL.path] }
        args += ["-map", "0:v"]
        if audioURL != nil { args += ["-map", "1:a", "-c:a", "copy"] }
        if chapterURL != nil { args += ["-map_chapters", audioURL != nil ? "2" : "1"] }
        // Rutorna är sRGB; till YUV med BT.709 (ffmpegs förval är BT.601) och märkt så. Märkningen
        // sätts också på rutorna (setparams): kodaren tar den därifrån, flaggorna räckte inte.
        args += ["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,"
                     + "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv",
                 "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]
        args += FFmpeg.av1Arguments(encoder, quality: quality)
        args += ["-movflags", "+faststart", url.path]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        // Avslutas ffmpeg i förtid ska skrivningen i röret ge ett fel, inte döda appen (SIGPIPE).
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        lock.withLock { self.process = process }

        // Bilden: kompositörens rutor, rad för rad (raderna kan ha utfyllnad) in i röret.
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = span.time
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.videoComposition = built.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        self.reader = reader
        guard reader.startReading() else { process.terminate(); throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }
        let total = max(span.seconds.upperBound - span.seconds.lowerBound, 0.001)
        let offset = span.seconds.lowerBound
        let handle = input.fileHandleForWriting
        var broken = false
        await Task.detached { [self] in
            var row = Data(count: w * 4)
            while !isCancelled, let sb = out.copyNextSampleBuffer() {
                guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(px, .readOnly)
                let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(px)
                let rows = min(h, CVPixelBufferGetHeight(px)), cols = min(w, CVPixelBufferGetWidth(px)) * 4
                var frame = Data(capacity: w * h * 4)
                for y in 0..<rows {
                    row.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: base + y * bpr, count: cols)) }
                    frame.append(row)
                }
                CVPixelBufferUnlockBaseAddress(px, .readOnly)
                do { try handle.write(contentsOf: frame) } catch { broken = true; break }
                progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sb).seconds - offset) / total))
            }
            try? handle.close()
        }.value
        process.waitUntilExit()
        lock.withLock { self.process = nil }
        if isCancelled || reader.status == .cancelled {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !broken else {
            throw ExportError.failed(String(localized: "ffmpeg (\(encoder)) misslyckades: \(message.isEmpty ? "kod \(process.terminationStatus)" : message)"))
        }
        progress(1)
    }

    // MARK: - Bara ljud

    /// Mixen som M4A eller WAV, eller ett spår per källa (`audioStems`): en WAV per grupp i en mapp,
    /// alla lika långa som filmen och med mixens volymer och förstärkning, så att de summerar till
    /// mixen när de läggs på noll i ett ljudprogram.
    private func exportAudio(_ built: CompositionBuilder.Result, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let span = clampedRange(built)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ExportError.failed(String(localized: "Inspelningen har inget ljud.")) }
        let mix = range == nil ? built.audioMix
            : CompositionBuilder.audioMix(for: built.composition, plan: built.plan, appIDs: recording.apps.map(\.id), edges: span.seconds)
        var gain: Float = 1
        if let target = loudnessTarget, let m = try await Loudness.measureMix(built.composition, audioMix: mix, range: span.time) {
            let g = Loudness.mixGain(for: m, target: target)
            gain = Float(pow(10, g.db / 20))
            loudnessReport = (m.integrated, g.db, g.limitedByPeaks)
        }
        guard preset.codec == .audioStems else {
            // M4A får kapitlen som kapitelspår (poddspelare visar dem), WAV kan inte bära dem.
            let chapters = preset.codec == .audioAAC
                ? built.plan.overlayTrack.chapterList(in: span.seconds).compactMap { Self.chapterSample($0.title, from: $0.start, to: $0.end) }
                : []
            try await writeAudio(built.composition, tracks: audioTracks, mix: mix, gain: gain, span: span.time, to: url,
                                 wav: preset.codec == .audioWAV, chapters: chapters) { t in progress(min(1, max(0, t - span.seconds.lowerBound) / max(0.001, span.time.duration.seconds))) }
            progress(1)
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let groups = stemGroups(audioTracks)
        for (i, g) in groups.enumerated() {
            let file = url.appendingPathComponent(String(format: "%02d ", i + 1) + g.name.replacingOccurrences(of: "/", with: "-") + ".wav")
            try await writeAudio(built.composition, tracks: g.tracks, mix: mix, gain: gain, span: span.time, to: file, wav: true) { t in
                let part = min(1, max(0, t - span.seconds.lowerBound) / max(0.001, span.time.duration.seconds))
                progress((Double(i) + part) / Double(groups.count))
            }
        }
        progress(1)
    }

    /// Kompositionens ljudspår i grupper: ett spår och dess B-spår (övertoningar) hör ihop.
    func stemGroups(_ tracks: [AVAssetTrack]) -> [(key: String, name: String, tracks: [AVAssetTrack])] {
        typealias B = CompositionBuilder
        var groups: [(key: String, name: String, tracks: [AVAssetTrack])] = []
        func add(_ key: String, _ name: String, _ t: AVAssetTrack) {
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].tracks.append(t) }
            else { groups.append((key, name, [t])) }
        }
        let clips = project.audioClips
        for t in tracks.sorted(by: { $0.trackID < $1.trackID }) {
            let id = t.trackID
            switch id {
            case B.microphoneTrackID, B.alternateMicTrackID: add("mic", String(localized: "Mikrofon"), t)
            case B.systemTrackID, B.alternateSystemTrackID: add("system", String(localized: "Datorljud"), t)
            case B.clickTrackID: add("click", String(localized: "Klickljud"), t)
            case B.audioClipTrackBase..<B.videoOverlayTrackBase:
                let i = Int(id - B.audioClipTrackBase)
                let role = i < clips.count ? clips[i].role : .effect
                switch role {
                case .narration: add("narration", String(localized: "Berättarröst"), t)
                case .dub:
                    let lang = clips[i].language
                    let name = Locale(identifier: Locale.preferredLanguages.first ?? "sv").localizedString(forLanguageCode: lang) ?? lang
                    add("dub-\(lang)", String(localized: "Dubbning (\(name))"), t)
                case .music: add("music", String(localized: "Musik"), t)
                default: add("effect", String(localized: "Ljudeffekter"), t)
                }
            case B.videoAudioTrackBase..<B.appTrackBase: add("video", String(localized: "Videoinslag"), t)
            case B.appTrackBase..<(B.alternateAppTrackBase + 100):
                let i = Int((id - B.appTrackBase) % 100)
                let app = i < recording.apps.count ? recording.apps[i].name : String(localized: "App \(i + 1)")
                add("app\(i)", app, t)
            default: add("other", String(localized: "Övrigt"), t)
            }
        }
        return groups
    }

    private func writeAudio(_ composition: AVComposition, tracks: [AVAssetTrack], mix: AVAudioMix, gain: Float, span: CMTimeRange,
                            to url: URL, wav: Bool, chapters: [CMSampleBuffer] = [],
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = span
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        // Bara de här spårens volymer (mixens parametrar för andra spår hör inte hit).
        let ids = Set(tracks.map(\.trackID))
        let subset = AVMutableAudioMix()
        subset.inputParameters = mix.inputParameters.filter { ids.contains($0.trackID) }
        out.audioMix = subset
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let writer = try AVAssetWriter(outputURL: url, fileType: wav ? .wav : .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: wav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
               AVEncoderBitRateKey: 256_000, AVChannelLayoutKey: layoutData])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        var chapterIn: AVAssetWriterInput?
        if !chapters.isEmpty, let hint = Self.chapterFormat {
            let c = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: hint)
            c.expectsMediaDataInRealTime = false
            c.marksOutputTrackAsEnabled = false
            let type = AVAssetTrack.AssociationType.chapterList.rawValue
            if writer.canAdd(c), input.canAddTrackAssociation(withTrackOf: c, type: type) {
                writer.add(c)
                input.addTrackAssociation(withTrackOf: c, type: type)
                chapterIn = c
            }
        }
        self.reader = reader
        self.writer = writer
        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Skrivningen startade inte") }
        writer.startSession(atSourceTime: span.start)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(out, into: input, queue: "skarminspelare.export.ljud", gain: gain, progress: progress) }
            if let chapterIn { group.addTask { await Self.pumpChapters(chapters, into: chapterIn) } }
        }
        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen misslyckades")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Skrivningen misslyckades")
        }
    }

    /// Formatbeskrivningen för kapitelspårets text (3GPP timed text, tx3g).
    static let chapterFormat: CMFormatDescription? = {
        let color: [String: Any] = [kCMTextFormatDescriptionColor_Red as String: 0, kCMTextFormatDescriptionColor_Green as String: 0,
                                    kCMTextFormatDescriptionColor_Blue as String: 0, kCMTextFormatDescriptionColor_Alpha as String: 255]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: color,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: 0, kCMTextFormatDescriptionRect_Right as String: 0],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1, kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: color.merging([kCMTextFormatDescriptionColor_Red as String: 255,
                    kCMTextFormatDescriptionColor_Green as String: 255, kCMTextFormatDescriptionColor_Blue as String: 255]) { $1 },
                kCMTextFormatDescriptionStyle_FontSize as String: 12],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        var fd: CMFormatDescription?
        CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
                                  extensions: extensions as CFDictionary, formatDescriptionOut: &fd)
        return fd
    }()

    /// Ett kapitel som textprov: längden (2 byte, big-endian) och titeln i UTF-8.
    static func chapterSample(_ title: String, from a: Double, to b: Double) -> CMSampleBuffer? {
        guard let format = chapterFormat else { return nil }
        let text = Array(title.utf8.prefix(0xFFFF))
        var bytes: [UInt8] = [UInt8(text.count >> 8), UInt8(text.count & 0xFF)] + text
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: b - a, preferredTimescale: 600),
                                        presentationTimeStamp: CMTime(seconds: a, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    private static func pumpChapters(_ samples: [CMSampleBuffer], into input: AVAssetWriterInput) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var next = 0
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "skarminspelare.export.kapitel")) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData && next < samples.count {
                    if !input.append(samples[next]) { next = samples.count; break }
                    next += 1
                }
                if next >= samples.count {
                    input.markAsFinished()
                    finished = true
                    done.resume()
                }
            }
        }
    }

    /// Utsnittet inom filmen (eller hela filmen), som tidsintervall och sekunder.
    /// Språkkoden på ett ljudspår: ISO 639-2 (`swe`, `eng`) och BCP 47 (`sv`, `en`).
    static func tag(_ input: AVAssetWriterInput, language: String) {
        guard !language.isEmpty, language != "auto" else { return }
        input.extendedLanguageTag = language
        if let alpha3 = Locale.Language(identifier: language).languageCode?.identifier(.alpha3) {
            input.languageCode = alpha3
        }
    }

    private func clampedRange(_ built: CompositionBuilder.Result) -> (time: CMTimeRange, seconds: ClosedRange<Double>) {
        let d = built.duration.seconds
        let a = min(max(0, range?.lowerBound ?? 0), d), b = min(max(a, range?.upperBound ?? d), d)
        let time = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
        return (time, a...b)
    }

    // MARK: - GIF

    /// GIF i två varv: först stickprov ur hela filmen till en gemensam palett (median cut),
    /// sedan varje ruta med ordnat gitter mot den (`GIFPalette`). ImageIOs palett per ruta bandade.
    private func exportGIF(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let span = clampedRange(built).seconds
        let total = max(span.upperBound - span.lowerBound, 0.001)
        let offset = span.lowerBound
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        func makeReader() throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
            let reader = try AVAssetReader(asset: built.composition)
            reader.timeRange = clampedRange(built).time
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            out.videoComposition = built.videoComposition
            reader.add(out)
            self.reader = reader
            guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }
            return (reader, out)
        }
        func withPixels<T>(_ buffer: CMSampleBuffer, _ body: (UnsafePointer<UInt8>, Int, Int, Int) -> T) -> T? {
            guard let px = CMSampleBufferGetImageBuffer(buffer) else { return nil }
            CVPixelBufferLockBaseAddress(px, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
            return body(base.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px),
                        CVPixelBufferGetBytesPerRow(px))
        }

        // Varv 1: stickprov ur var tredje ruta.
        var samples: [UInt32] = []
        do {
            let (reader, out) = try makeReader()
            var n = 0
            while let buffer = out.copyNextSampleBuffer() {
                if isCancelled { reader.cancelReading(); throw ExportError.cancelled }
                if n % 3 == 0, let s = withPixels(buffer, { GIFPalette.samples(bgra: $0, width: $1, height: $2, bytesPerRow: $3) }) {
                    samples += s
                }
                n += 1
                progress(min(0.3, (CMSampleBufferGetPresentationTimeStamp(buffer).seconds - offset) / total * 0.3))
            }
            if reader.status == .failed { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen misslyckades") }
        }
        if samples.count > 400_000 {
            let k = samples.count / 400_000 + 1
            samples = stride(from: 0, to: samples.count, by: k).map { samples[$0] }
        }
        let mapper = GIFPalette.Mapper(GIFPalette.build(samples: samples))

        // Varv 2: gittra och skriv.
        let (reader, out) = try makeReader()
        let frameCount = Int(total * Double(preset.fps)) + 1
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.failed("GIF-filen gick inte att skapa")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // GIF anger fördröjning i hundradelar. 1/15 s avrundas annars till 0,07 och filmen
        // blir 5 % för lång; i stället följer varje ruta den exakta klockan avrundad.
        var frameIndex = 0
        func delay(_ i: Int) -> Double {
            let fps = Double(preset.fps)
            return ((Double(i + 1) / fps * 100).rounded() - (Double(i) / fps * 100).rounded()) / 100
        }
        while let buffer = out.copyNextSampleBuffer() {
            if isCancelled { reader.cancelReading(); throw ExportError.cancelled }
            if let cg = withPixels(buffer, { mapper.orderedImage(bgra: $0, width: $1, height: $2, bytesPerRow: $3) }) ?? nil {
                let d = delay(frameIndex)
                let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d,
                                                             kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary
                CGImageDestinationAddImage(dest, cg, props)
                frameIndex += 1
            }
            progress(min(1, 0.3 + (CMSampleBufferGetPresentationTimeStamp(buffer).seconds - offset) / total * 0.7))
        }
        if reader.status == .failed { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen misslyckades") }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.failed("GIF-filen gick inte att skriva klart") }
        progress(1)
    }
}
