import Foundation
import AVFoundation

/// En inläst inspelning: rådata och spår, redo att byggas till en komposition.
public struct LoadedRecording: @unchecked Sendable {
    public let bundle: RecordingBundle
    public let meta: RecordingMeta
    public let events: [InputEvent]
    public let cursors: CursorCatalog
    public let mapping: ContentMapping
    let assets: [RecordingMeta.TrackKind: AVURLAsset]

    public static func load(_ bundle: RecordingBundle) throws -> LoadedRecording {
        let meta = try bundle.readMeta()
        let events = bundle.readEvents()
        var assets: [RecordingMeta.TrackKind: AVURLAsset] = [:]
        for track in meta.tracks where !track.failed {
            let url = bundle.url(for: track)
            if FileManager.default.fileExists(atPath: url.path) {
                assets[track.kind] = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            }
        }
        return LoadedRecording(bundle: bundle, meta: meta, events: events, cursors: bundle.readCursors(),
                               mapping: ContentMapping(meta: meta, events: events), assets: assets)
    }

    public var hasCamera: Bool { assets[.camera] != nil }
    public var hasMicrophone: Bool { assets[.microphone] != nil }
    public var hasSystemAudio: Bool { assets[.system] != nil }
    public func asset(_ kind: RecordingMeta.TrackKind) -> AVURLAsset? { assets[kind] }

    public var sourceSize: CGSize {
        CGSize(width: meta.source.pixelWidth, height: meta.source.pixelHeight)
    }

    public func makePlan(project: EditProject, canvas: CGSize, cursorPath: CursorPath? = nil,
                         cameraPath: CameraPath? = nil) -> RenderPlan {
        RenderPlan(canvas: canvas, project: project, meta: meta, events: events, cursors: cursors,
                   cursorsDir: bundle.cursorsDir, hasCamera: hasCamera, cursorPath: cursorPath, cameraPath: cameraPath)
    }
}

/// Gör ett redigeringsläge till något AVFoundation kan spela och exportera: en komposition med
/// klippen och hastigheterna, en videokomposition med `PolishCompositor` och en ljudmix.
public enum CompositionBuilder {
    public struct Result: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition
        public let audioMix: AVMutableAudioMix
        public let duration: CMTime
    }

    public static func build(_ rec: LoadedRecording, plan: RenderPlan, fps: Int) async throws -> Result {
        let composition = AVMutableComposition()
        let timescale: CMTimeScale = 600

        func sourceTrack(_ kind: RecordingMeta.TrackKind, _ type: AVMediaType) async -> AVAssetTrack? {
            guard let asset = rec.asset(kind) else { return nil }
            return try? await asset.loadTracks(withMediaType: type).first
        }
        guard let screenSource = await sourceTrack(.screen, .video),
              let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: screenTrackID) else {
            throw NSError(domain: "CompositionBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Skärmspåret saknas eller går inte att läsa"])
        }
        var pairs: [(AVAssetTrack, AVMutableCompositionTrack, CMTimeRange)] = []
        pairs.append((screenSource, screenTrack, try await screenSource.load(.timeRange)))

        var hasCamera = false
        if let cam = await sourceTrack(.camera, .video),
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: cameraTrackID) {
            pairs.append((cam, track, try await cam.load(.timeRange)))
            hasCamera = true
        }
        for (kind, id) in [(RecordingMeta.TrackKind.microphone, microphoneTrackID), (.system, systemTrackID)] {
            guard let src = await sourceTrack(kind, .audio),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: id) else { continue }
            pairs.append((src, track, try await src.load(.timeRange)))
        }

        // Delarna läggs efter varandra. Ett spår som börjar senare eller slutar tidigare än
        // delen (mikrofonen startar ~0,5 s in) läggs in där det finns, på rätt plats.
        var cursor = CMTime.zero
        for segment in plan.project.segments where segment.duration > 0.001 {
            let start = CMTime(seconds: segment.start, preferredTimescale: timescale)
            let end = CMTime(seconds: segment.end, preferredTimescale: timescale)
            let range = CMTimeRange(start: start, end: end)
            for (source, target, available) in pairs {
                let clipped = range.intersection(available)
                guard clipped.duration > .zero else { continue }
                try target.insertTimeRange(clipped, of: source, at: cursor + (clipped.start - start))
            }
            let length = end - start
            if abs(segment.speed - 1) > 0.001 {
                let scaled = CMTime(seconds: length.seconds / segment.speed, preferredTimescale: timescale)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: length), toDuration: scaled)
                cursor = cursor + scaled
            } else {
                cursor = cursor + length
            }
        }

        let video = videoComposition(plan: plan, duration: cursor, fps: fps, hasCamera: hasCamera)
        let mix = audioMix(for: composition, audio: plan.project.audio)
        return Result(composition: composition, videoComposition: video, audioMix: mix, duration: cursor)
    }

    /// Spår-id:n i kompositionen är fasta, så utseendet kan bytas utan att klippen byggs om.
    static let screenTrackID: CMPersistentTrackID = 1
    static let cameraTrackID: CMPersistentTrackID = 2
    static let microphoneTrackID: CMPersistentTrackID = 3
    static let systemTrackID: CMPersistentTrackID = 4

    public static func videoComposition(plan: RenderPlan, duration: CMTime, fps: Int, hasCamera: Bool) -> AVVideoComposition {
        let instruction = PolishInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), plan: plan,
                                            screenTrackID: screenTrackID, cameraTrackID: hasCamera ? cameraTrackID : nil)
        return AVVideoComposition(configuration: .init(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: PolishCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            instructions: [instruction],
            renderSize: plan.canvas))
    }

    public static func audioMix(for composition: AVComposition, audio mix: EditProject.AudioMix) -> AVMutableAudioMix {
        var params: [AVMutableAudioMixInputParameters] = []
        for track in composition.tracks(withMediaType: .audio) {
            let p = AVMutableAudioMixInputParameters(track: track)
            let isMic = track.trackID == microphoneTrackID
            let volume = isMic ? (mix.microphoneMuted ? 0 : mix.microphoneVolume) : (mix.systemMuted ? 0 : mix.systemVolume)
            p.setVolume(Float(volume), at: .zero)
            p.audioTimePitchAlgorithm = .spectral
            params.append(p)
        }
        let m = AVMutableAudioMix()
        m.inputParameters = params
        return m
    }
}
