import Foundation
import AVFoundation

/// En inläst inspelning: rådata och spår, redo att byggas till en komposition.
public struct LoadedRecording: @unchecked Sendable {
    public let bundle: RecordingBundle
    public let meta: RecordingMeta
    public let events: [InputEvent]
    public let cursors: CursorCatalog
    public let mapping: ContentMapping
    /// Vad som sades, om inspelningen är transkriberad.
    public var transcript: Transcript?
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
                               mapping: ContentMapping(meta: meta, events: events),
                               transcript: bundle.readTranscript(), assets: assets)
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
                   cursorsDir: bundle.cursorsDir, hasCamera: hasCamera, words: transcript?.words ?? [],
                   cursorPath: cursorPath, cameraPath: cameraPath)
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
        let mix = audioMix(for: composition, audio: plan.project.audio, speech: plan.speech)
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

    /// `speech` är talet i utdatatid; med `duckSystem` sänks datorljudet under det.
    public static func audioMix(for composition: AVComposition, audio mix: EditProject.AudioMix,
                                speech: [ClosedRange<Double>] = []) -> AVMutableAudioMix {
        var params: [AVMutableAudioMixInputParameters] = []
        for track in composition.tracks(withMediaType: .audio) {
            let p = AVMutableAudioMixInputParameters(track: track)
            let isMic = track.trackID == microphoneTrackID
            let volume = isMic ? (mix.microphoneMuted ? 0 : mix.microphoneVolume) : (mix.systemMuted ? 0 : mix.systemVolume)
            let ramps = !isMic && mix.duckSystem && volume > 0
                ? Ducking.ramps(speech: speech, level: volume * mix.duckLevel, normal: volume) : []
            // En punkt och en ramp får inte överlappa; börjar en ramp direkt bär den nivån.
            if ramps.first.map({ $0.start > 0.001 }) ?? true { p.setVolume(Float(volume), at: .zero) }
            do {
                for ramp in ramps {
                    p.setVolumeRamp(fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to),
                                    timeRange: CMTimeRange(start: CMTime(seconds: ramp.start, preferredTimescale: 600),
                                                           end: CMTime(seconds: ramp.end, preferredTimescale: 600)))
                }
            }
            p.audioTimePitchAlgorithm = .spectral
            params.append(p)
        }
        let m = AVMutableAudioMix()
        m.inputParameters = params
        return m
    }
}

/// Datorljudet sänks mjukt strax före talet och höjs igen en stund efter. Pauser kortare än
/// en sekund behåller sänkningen, så att ljudet inte pumpar mellan meningarna.
public enum Ducking {
    public struct Ramp: Equatable, Sendable {
        public let start: Double, end: Double, from: Double, to: Double
    }
    static let down = 0.25, up = 0.5, hold = 1.0

    public static func ramps(speech: [ClosedRange<Double>], level: Double, normal: Double) -> [Ramp] {
        var merged: [ClosedRange<Double>] = []
        for r in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound - last.upperBound < hold + down + up {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var out: [Ramp] = []
        for r in merged {
            let a = max(0, r.lowerBound - down)
            out.append(Ramp(start: a, end: max(a + 0.01, r.lowerBound), from: normal, to: level))
            out.append(Ramp(start: r.upperBound, end: r.upperBound + up, from: level, to: normal))
        }
        return out
    }
}
