import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Förvalen i exportdialogen.
public struct ExportPreset: Identifiable, Hashable, Sendable {
    public enum Codec: String, Sendable { case h264, hevc, prores, proresAlpha, gif }

    public let id: String
    public let name: String
    public let detail: String
    public let codec: Codec
    /// Bildytans kortaste sida i pixlar.
    public let shortSide: Int
    public let fps: Int

    public static let all: [ExportPreset] = [
        .init(id: "mp4-1080", name: "MP4 1080p", detail: "H.264 — spelas överallt", codec: .h264, shortSide: 1080, fps: 60),
        .init(id: "mp4-4k", name: "MP4 4K", detail: "HEVC — skarpast, mindre filer", codec: .hevc, shortSide: 2160, fps: 60),
        .init(id: "prores", name: "ProRes 422", detail: "För vidare redigering i Final Cut, Resolve, Premiere", codec: .prores, shortSide: 1080, fps: 60),
        .init(id: "prores-alfa", name: "ProRes 4444 med alfa",
              detail: "Genomskinlig bakgrund — lägg skärmen ovanpå något eget i Final Cut, Resolve, Premiere",
              codec: .proresAlpha, shortSide: 1080, fps: 60),
        .init(id: "gif", name: "GIF", detail: "För Slack och GitHub, högst 800 px", codec: .gif, shortSide: 450, fps: 15),
    ]

    public var fileExtension: String {
        switch codec {
        case .h264, .hevc: "mp4"
        case .prores, .proresAlpha: "mov"
        case .gif: "gif"
        }
    }

    /// Bakgrunden lämnas genomskinlig (bara skärmen, skuggan, markören, bubblan och texterna ritas).
    public var transparentBackground: Bool { codec == .proresAlpha }

    /// Bitrate i bit/s för en bildyta.
    public func bitrate(for canvas: CGSize) -> Int {
        let pixels = Double(canvas.width * canvas.height)
        switch codec {
        case .h264: return Int(pixels * Double(fps) * 0.09)
        case .hevc: return Int(pixels * Double(fps) * 0.06)
        case .prores: return Int(pixels * Double(fps) * 1.6) // bara för uppskattningen
        case .proresAlpha: return Int(pixels * Double(fps) * 3.6)
        case .gif: return Int(pixels * Double(fps) * 0.25)
        }
    }

    /// Ungefärlig filstorlek i byte.
    public func estimatedBytes(canvas: CGSize, duration: Double) -> Int64 {
        Int64(Double(bitrate(for: canvas)) / 8 * duration) + (codec == .gif ? 0 : Int64(24_000 * duration))
    }

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
    private var cancelled = false
    private let lock = NSLock()

    public init(recording: LoadedRecording, project: EditProject, preset: ExportPreset) {
        self.recording = recording
        self.project = project
        self.preset = preset
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Kör exporten. `progress` anropas med 0–1 från en bakgrundskö.
    public func run(to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let canvas = preset.canvas(aspect: project.aspect, source: recording.sourceSize)
        let plan = recording.makePlan(project: project, canvas: canvas, transparentBackground: preset.transparentBackground)
        let built = try await CompositionBuilder.build(recording, plan: plan, fps: preset.fps)
        try? FileManager.default.removeItem(at: url)
        if preset.codec == .gif {
            try await exportGIF(built, canvas: canvas, to: url, progress: progress)
        } else {
            try await exportMovie(built, canvas: canvas, to: url, progress: progress)
        }
    }

    // MARK: - Film

    private func exportMovie(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral
            reader.add(out)
            audioOut = out
        }

        // ProRes (även 4444) bara i .mov; i .mp4 kastar AVAssetWriter ett undantag.
        let isMov = preset.fileExtension == "mov"
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
        self.reader = reader
        self.writer = writer

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Skrivningen startade inte") }
        writer.startSession(atSourceTime: .zero)

        let total = max(built.duration.seconds, 0.001)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.pump(videoOut, into: videoIn, queue: "skarminspelare.export.video") { t in
                    progress(min(1, t / total))
                }
            }
            if let audioOut, let audioIn {
                group.addTask {
                    await Self.pump(audioOut, into: audioIn, queue: "skarminspelare.export.audio") { _ in }
                }
            }
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
        case .prores:
            return [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color]
        case .proresAlpha:
            return [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color]
        case .hevc:
            return [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: preset.bitrate(for: canvas),
                        AVVideoExpectedSourceFrameRateKey: preset.fps,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    ]]
        default:
            return [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: canvas.width,
                    AVVideoHeightKey: canvas.height, AVVideoColorPropertiesKey: color,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: preset.bitrate(for: canvas),
                        AVVideoExpectedSourceFrameRateKey: preset.fps,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    ]]
        }
    }

    /// Flyttar buffertar från läsare till skrivare tills läsaren är slut.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue label: String,
                             progress: @escaping (Double) -> Void) async {
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

    // MARK: - GIF

    private func exportGIF(_ built: CompositionBuilder.Result, canvas: CGSize, to url: URL,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.videoComposition = built.videoComposition
        reader.add(out)
        self.reader = reader
        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen startade inte") }

        let total = max(built.duration.seconds, 0.001)
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
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let image = CIImage(cvPixelBuffer: pixels)
            if let cg = RenderContext.shared.createCGImage(image, from: image.extent) {
                let d = delay(frameIndex)
                let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d,
                                                             kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary
                CGImageDestinationAddImage(dest, cg, props)
                frameIndex += 1
            }
            progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / total))
        }
        if reader.status == .failed { throw ExportError.failed(reader.error?.localizedDescription ?? "Läsningen misslyckades") }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.failed("GIF-filen gick inte att skriva klart") }
        progress(1)
    }
}
